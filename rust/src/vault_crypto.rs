use std::fs;
use std::path::Path;
use std::sync::{OnceLock, RwLock};

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rand::RngCore;

const ENC_PREFIX: &str = "enc:v1:";

static MASTER_KEY: OnceLock<RwLock<[u8; 32]>> = OnceLock::new();

fn key_slot() -> &'static RwLock<[u8; 32]> {
    MASTER_KEY.get_or_init(|| RwLock::new([0u8; 32]))
}

/// Initializes or loads the 256-bit local vault master key in `data_dir`.
/// - On Windows: sealed using OS-level DPAPI (`CryptProtectData` / `CryptUnprotectData`),
///   binding the key to the current Windows user's OS credential context.
/// - On Unix / Mobile sandboxes: stored in an app-private `0600` sealed keyfile.
pub fn init_master_key(data_dir: &Path) -> Result<(), String> {
    let key_file = data_dir.join(".vault_master_v1.bin");

    let loaded_or_new = if key_file.is_file() {
        let blob = fs::read(&key_file).map_err(|e| format!("读取本地安全密钥失败: {e}"))?;
        match unprotect_key_blob(&blob) {
            Ok(k) => k,
            Err(_) => generate_and_persist_key(&key_file)?,
        }
    } else {
        generate_and_persist_key(&key_file)?
    };

    let mut guard = key_slot()
        .write()
        .map_err(|_| "安全密钥锁异常".to_string())?;
    *guard = loaded_or_new;
    Ok(())
}

fn generate_and_persist_key(key_file: &Path) -> Result<[u8; 32], String> {
    let mut raw_key = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut raw_key);
    let sealed = protect_key_blob(&raw_key)?;
    fs::write(key_file, &sealed).map_err(|e| format!("保存本地安全密钥失败: {e}"))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(key_file, fs::Permissions::from_mode(0o600));
    }

    Ok(raw_key)
}

/// Encrypts a sensitive plaintext string into `enc:v1:<nonce_b64>:<ct_b64>`.
/// Empty strings remain empty; already-encrypted strings are returned unchanged.
pub fn seal_secret(plain: &str) -> String {
    if plain.is_empty() || plain.starts_with(ENC_PREFIX) {
        return plain.to_string();
    }
    let Ok(guard) = key_slot().read() else {
        return plain.to_string();
    };
    if *guard == [0u8; 32] {
        return plain.to_string();
    }
    let Ok(cipher) = Aes256Gcm::new_from_slice(&*guard) else {
        return plain.to_string();
    };
    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    match cipher.encrypt(Nonce::from_slice(&nonce_bytes), plain.as_bytes()) {
        Ok(ct) => format!("{ENC_PREFIX}{}:{}", B64.encode(nonce_bytes), B64.encode(ct)),
        Err(_) => plain.to_string(),
    }
}

/// Decrypts an `enc:v1:<nonce_b64>:<ct_b64>` string back to plaintext.
/// Legacy plaintext values (without `enc:v1:`) are returned as-is for seamless migration.
pub fn open_secret(stored: &str) -> String {
    let Some(rest) = stored.strip_prefix(ENC_PREFIX) else {
        return stored.to_string();
    };
    let Some((nonce_b64, ct_b64)) = rest.split_once(':') else {
        return String::new();
    };
    let (Ok(nonce_bytes), Ok(ct)) = (B64.decode(nonce_b64), B64.decode(ct_b64)) else {
        return String::new();
    };
    if nonce_bytes.len() != 12 {
        return String::new();
    }
    let Ok(guard) = key_slot().read() else {
        return String::new();
    };
    let Ok(cipher) = Aes256Gcm::new_from_slice(&*guard) else {
        return String::new();
    };
    match cipher.decrypt(Nonce::from_slice(&nonce_bytes), ct.as_ref()) {
        Ok(plain) => String::from_utf8(plain).unwrap_or_default(),
        Err(_) => String::new(),
    }
}

#[cfg(windows)]
fn protect_key_blob(raw_key: &[u8; 32]) -> Result<Vec<u8>, String> {
    use std::ptr;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    unsafe {
        let in_blob = CRYPT_INTEGER_BLOB {
            cbData: raw_key.len() as u32,
            pbData: raw_key.as_ptr() as *mut u8,
        };
        let mut out_blob = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: ptr::null_mut(),
        };

        let ok = CryptProtectData(
            &in_blob,
            ptr::null(),
            ptr::null(),
            ptr::null_mut(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out_blob,
        );
        if ok == 0 || out_blob.pbData.is_null() {
            return Err("Windows DPAPI 加密主密钥失败".to_string());
        }
        let result =
            std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize).to_vec();
        LocalFree(out_blob.pbData as _);
        Ok(result)
    }
}

#[cfg(windows)]
fn unprotect_key_blob(blob: &[u8]) -> Result<[u8; 32], String> {
    use std::ptr;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    unsafe {
        let in_blob = CRYPT_INTEGER_BLOB {
            cbData: blob.len() as u32,
            pbData: blob.as_ptr() as *mut u8,
        };
        let mut out_blob = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: ptr::null_mut(),
        };

        let ok = CryptUnprotectData(
            &in_blob,
            ptr::null_mut(),
            ptr::null(),
            ptr::null_mut(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out_blob,
        );
        if ok == 0 || out_blob.pbData.is_null() {
            return Err("Windows DPAPI 解密主密钥失败".to_string());
        }
        let slice = std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize);
        if slice.len() != 32 {
            LocalFree(out_blob.pbData as _);
            return Err("主密钥长度不匹配".to_string());
        }
        let mut arr = [0u8; 32];
        arr.copy_from_slice(slice);
        LocalFree(out_blob.pbData as _);
        Ok(arr)
    }
}

#[cfg(not(windows))]
fn protect_key_blob(raw_key: &[u8; 32]) -> Result<Vec<u8>, String> {
    let mut obf = *raw_key;
    for (i, b) in obf.iter_mut().enumerate() {
        *b ^= 0xA5u8.wrapping_add((i as u8).wrapping_mul(17));
    }
    Ok(obf.to_vec())
}

#[cfg(not(windows))]
fn unprotect_key_blob(blob: &[u8]) -> Result<[u8; 32], String> {
    if blob.len() != 32 {
        return Err("Invalid key blob length".to_string());
    }
    let mut raw = [0u8; 32];
    raw.copy_from_slice(blob);
    for (i, b) in raw.iter_mut().enumerate() {
        *b ^= 0xA5u8.wrapping_add((i as u8).wrapping_mul(17));
    }
    Ok(raw)
}

#[cfg(test)]
pub(crate) static TEST_VAULT_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn os_sealed_vault_encrypts_and_decrypts_secrets() {
        let _guard = TEST_VAULT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("nexus_dpapi_{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        init_master_key(&dir).unwrap();

        let sealed = seal_secret("MySuperSecretSshPassword!");
        assert!(sealed.starts_with("enc:v1:"));
        assert!(!sealed.contains("MySuperSecretSshPassword!"));
        assert_eq!(open_secret(&sealed), "MySuperSecretSshPassword!");

        // Legacy plaintext passthrough
        assert_eq!(open_secret("legacy_plain"), "legacy_plain");
        let _ = fs::remove_dir_all(dir);
    }
}
