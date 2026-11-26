pub mod local_pty;
pub mod models;
pub mod monitor;
pub mod sftp;
pub mod ssh;
pub mod store;
pub mod vault_crypto;
pub mod webdav;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicUsize, Ordering};

use models::{parse_quick_connect, ApiResponse, HostProfile, SessionStatusEvent, SnippetItem};

pub type DartOutputCallback = extern "C" fn(*mut c_char, *mut u8, usize);
pub type DartStatusCallback = extern "C" fn(*mut c_char);

static OUTPUT_CB_ADDR: AtomicUsize = AtomicUsize::new(0);
static STATUS_CB_ADDR: AtomicUsize = AtomicUsize::new(0);

fn forward_output_to_dart(session_id: &str, bytes: &[u8]) {
    let addr = OUTPUT_CB_ADDR.load(Ordering::Acquire);
    if addr == 0 || bytes.is_empty() {
        return;
    }
    let Ok(c_sid) = CString::new(session_id) else {
        return;
    };
    let mut boxed = bytes.to_vec().into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);

    let cb: DartOutputCallback = unsafe { std::mem::transmute(addr) };
    cb(c_sid.into_raw(), ptr, len);
}

fn forward_status_to_dart(event: SessionStatusEvent) {
    let addr = STATUS_CB_ADDR.load(Ordering::Acquire);
    if addr == 0 {
        return;
    }
    let Ok(json) = serde_json::to_string(&event) else {
        return;
    };
    let Ok(c_json) = CString::new(json) else {
        return;
    };
    let cb: DartStatusCallback = unsafe { std::mem::transmute(addr) };
    cb(c_json.into_raw());
}

fn cstr_to_str<'a>(ptr: *const c_char) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err("Null string pointer".to_string());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|e| format!("Invalid UTF-8 string: {e}"))
}

fn into_c_string(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new(r#"{"ok":false,"error":"NUL byte in response"}"#).unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn nexus_register_callbacks(
    output_cb: Option<DartOutputCallback>,
    status_cb: Option<DartStatusCallback>,
) {
    let has_status = status_cb.is_some();
    OUTPUT_CB_ADDR.store(output_cb.map(|f| f as usize).unwrap_or(0), Ordering::Release);
    STATUS_CB_ADDR.store(status_cb.map(|f| f as usize).unwrap_or(0), Ordering::Release);
    ssh::register_sinks(forward_output_to_dart, forward_status_to_dart, has_status);
}

#[no_mangle]
pub extern "C" fn nexus_init_core(data_dir: *const c_char) -> *mut c_char {
    let resp = match cstr_to_str(data_dir).and_then(store::init_store) {
        Ok(hosts) => {
            let _ = ssh::runtime();
            let redacted: Vec<HostProfile> =
                hosts.into_iter().map(|h| h.redacted_for_ui()).collect();
            ApiResponse::success(redacted)
        }
        Err(e) => ApiResponse::<Vec<HostProfile>>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_list_hosts() -> *mut c_char {
    let resp = match store::list_hosts_redacted() {
        Ok(hosts) => ApiResponse::success(hosts),
        Err(e) => ApiResponse::<Vec<HostProfile>>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_upsert_host(profile_json: *const c_char) -> *mut c_char {
    let result = cstr_to_str(profile_json)
        .and_then(|raw| {
            serde_json::from_str::<HostProfile>(raw).map_err(|e| format!("无效的主机参数: {e}"))
        })
        .and_then(store::upsert_host);

    let resp = match result {
        Ok(saved) => ApiResponse::success(saved.redacted_for_ui()),
        Err(e) => ApiResponse::<HostProfile>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_delete_host(host_id: *const c_char) -> *mut c_char {
    let resp = match cstr_to_str(host_id).and_then(store::delete_host) {
        Ok(deleted) => ApiResponse::success(deleted),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

// --- Snippets FFI ---

#[no_mangle]
pub extern "C" fn nexus_list_snippets() -> *mut c_char {
    let resp = match store::list_snippets() {
        Ok(items) => ApiResponse::success(items),
        Err(e) => ApiResponse::<Vec<SnippetItem>>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_upsert_snippet(snippet_json: *const c_char) -> *mut c_char {
    let result = cstr_to_str(snippet_json)
        .and_then(|raw| {
            serde_json::from_str::<SnippetItem>(raw).map_err(|e| format!("无效的命令片段参数: {e}"))
        })
        .and_then(store::upsert_snippet);

    let resp = match result {
        Ok(saved) => ApiResponse::success(saved),
        Err(e) => ApiResponse::<SnippetItem>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_delete_snippet(snippet_id: *const c_char) -> *mut c_char {
    let resp = match cstr_to_str(snippet_id).and_then(store::delete_snippet) {
        Ok(deleted) => ApiResponse::success(deleted),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

// --- Known Hosts (TOFU) FFI ---

#[no_mangle]
pub extern "C" fn nexus_respond_host_key(
    request_id: *const c_char,
    accept: u8,
    persist: u8,
) -> *mut c_char {
    let resp = match cstr_to_str(request_id)
        .and_then(|rid| ssh::respond_host_key_prompt(rid, accept != 0, persist != 0))
    {
        Ok(ok) => ApiResponse::success(ok),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_list_known_hosts() -> *mut c_char {
    let resp = match store::list_known_hosts() {
        Ok(list) => ApiResponse::success(list),
        Err(e) => ApiResponse::<Vec<models::KnownHostEntry>>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_delete_known_host(host_key: *const c_char) -> *mut c_char {
    let resp = match cstr_to_str(host_key).and_then(store::delete_known_host) {
        Ok(removed) => ApiResponse::success(removed),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

// --- App Lock FFI ---

#[no_mangle]
pub extern "C" fn nexus_get_app_lock_config() -> *mut c_char {
    let resp = match store::get_app_lock_config_redacted() {
        Ok(cfg) => ApiResponse::success(cfg),
        Err(e) => ApiResponse::<models::AppLockConfig>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_set_app_lock_passcode(
    passcode: *const c_char,
    biometrics_enabled: u8,
    lock_on_startup: u8,
    auto_lock_minutes: i32,
) -> *mut c_char {
    let result = cstr_to_str(passcode).and_then(|pin| {
        store::set_app_lock_passcode(
            pin,
            biometrics_enabled != 0,
            lock_on_startup != 0,
            auto_lock_minutes,
        )
    });
    let resp = match result {
        Ok(cfg) => ApiResponse::success(cfg),
        Err(e) => ApiResponse::<models::AppLockConfig>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_verify_app_lock_passcode(passcode: *const c_char) -> *mut c_char {
    let result = cstr_to_str(passcode).and_then(store::verify_app_lock_passcode);
    let resp = match result {
        Ok(ok) => ApiResponse::success(ok),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_update_app_lock_settings(
    biometrics_enabled: u8,
    lock_on_startup: u8,
    auto_lock_minutes: i32,
) -> *mut c_char {
    let resp = match store::update_app_lock_settings(
        biometrics_enabled != 0,
        lock_on_startup != 0,
        auto_lock_minutes,
    ) {
        Ok(cfg) => ApiResponse::success(cfg),
        Err(e) => ApiResponse::<models::AppLockConfig>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_disable_app_lock(
    current_passcode: *const c_char,
    bypass_verified: u8,
) -> *mut c_char {
    let result = cstr_to_str(current_passcode)
        .and_then(|pin| store::disable_app_lock(pin, bypass_verified != 0));
    let resp = match result {
        Ok(cfg) => ApiResponse::success(cfg),
        Err(e) => ApiResponse::<models::AppLockConfig>::err(e),
    };
    into_c_string(resp)
}

// --- SFTP & Server Monitor FFI ---

#[no_mangle]
pub extern "C" fn nexus_sftp_list_dir(
    session_id: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?;
        let p = cstr_to_str(path)?;
        sftp::list_dir_blocking(sid, p)
    })();
    let resp = match result {
        Ok(listing) => ApiResponse::success(listing),
        Err(e) => ApiResponse::<models::SftpDirListing>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_sftp_mkdir(
    session_id: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?;
        let p = cstr_to_str(path)?;
        sftp::create_dir_blocking(sid, p)?;
        Ok::<bool, String>(true)
    })();
    let resp = match result {
        Ok(v) => ApiResponse::success(v),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_sftp_rename(
    session_id: *const c_char,
    old_path: *const c_char,
    new_path: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?;
        let from = cstr_to_str(old_path)?;
        let to = cstr_to_str(new_path)?;
        sftp::rename_blocking(sid, from, to)?;
        Ok::<bool, String>(true)
    })();
    let resp = match result {
        Ok(v) => ApiResponse::success(v),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_sftp_delete(
    session_id: *const c_char,
    path: *const c_char,
    is_dir: u8,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?;
        let p = cstr_to_str(path)?;
        sftp::delete_blocking(sid, p, is_dir != 0)?;
        Ok::<bool, String>(true)
    })();
    let resp = match result {
        Ok(v) => ApiResponse::success(v),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_sftp_chmod(
    session_id: *const c_char,
    path: *const c_char,
    mode_octal: u32,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?;
        let p = cstr_to_str(path)?;
        sftp::chmod_blocking(sid, p, mode_octal)?;
        Ok::<bool, String>(true)
    })();
    let resp = match result {
        Ok(v) => ApiResponse::success(v),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_sftp_download(
    session_id: *const c_char,
    transfer_id: *const c_char,
    remote_path: *const c_char,
    local_path: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?;
        let tid = cstr_to_str(transfer_id)?;
        let r_path = cstr_to_str(remote_path)?;
        let l_path = cstr_to_str(local_path)?;
        sftp::download_file_blocking(sid, tid, r_path, l_path)
    })();
    let resp = match result {
        Ok(bytes) => ApiResponse::success(bytes),
        Err(e) => ApiResponse::<u64>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_sftp_upload(
    session_id: *const c_char,
    transfer_id: *const c_char,
    local_path: *const c_char,
    remote_path: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?;
        let tid = cstr_to_str(transfer_id)?;
        let l_path = cstr_to_str(local_path)?;
        let r_path = cstr_to_str(remote_path)?;
        sftp::upload_file_blocking(sid, tid, l_path, r_path)
    })();
    let resp = match result {
        Ok(bytes) => ApiResponse::success(bytes),
        Err(e) => ApiResponse::<u64>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_fetch_server_metrics(session_id: *const c_char) -> *mut c_char {
    let result = cstr_to_str(session_id).and_then(monitor::fetch_metrics_blocking);
    let resp = match result {
        Ok(metrics) => ApiResponse::success(metrics),
        Err(e) => ApiResponse::<models::ServerMetrics>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_fetch_remote_history(
    session_id: *const c_char,
    max_entries: u32,
) -> *mut c_char {
    let result = cstr_to_str(session_id)
        .and_then(|sid| monitor::fetch_remote_history_blocking(sid, max_entries as usize));
    let resp = match result {
        Ok(items) => ApiResponse::success(items),
        Err(e) => ApiResponse::<Vec<String>>::err(e),
    };
    into_c_string(resp)
}

// --- Helpers & WebDAV FFI ---

#[no_mangle]
pub extern "C" fn nexus_parse_quick_connect(expr: *const c_char) -> *mut c_char {
    let resp = match cstr_to_str(expr).and_then(parse_quick_connect) {
        Ok(target) => ApiResponse::success(target),
        Err(e) => ApiResponse::<models::QuickConnectTarget>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_inspect_private_key(
    pem_content: *const c_char,
    file_path: *const c_char,
    passphrase: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let pem = cstr_to_str(pem_content)?;
        let path = cstr_to_str(file_path)?;
        let pass = cstr_to_str(passphrase)?;
        Ok::<models::KeyInspectionResult, String>(ssh::inspect_private_key(pem, path, pass))
    })();
    let resp = match result {
        Ok(info) => ApiResponse::success(info),
        Err(e) => ApiResponse::<models::KeyInspectionResult>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_discover_local_keys() -> *mut c_char {
    let keys = ssh::discover_local_ssh_keys();
    into_c_string(ApiResponse::success(keys))
}

#[no_mangle]
pub extern "C" fn nexus_get_webdav_config() -> *mut c_char {
    let resp = match store::get_webdav_config_redacted() {
        Ok(cfg) => ApiResponse::success(cfg),
        Err(e) => ApiResponse::<models::WebDavConfig>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_save_webdav_config(config_json: *const c_char) -> *mut c_char {
    let result = cstr_to_str(config_json)
        .and_then(|raw| {
            serde_json::from_str::<models::WebDavConfig>(raw)
                .map_err(|e| format!("无效的 WebDAV 配置参数: {e}"))
        })
        .and_then(store::save_webdav_config);

    let resp = match result {
        Ok(saved) => ApiResponse::success(saved.redacted_for_ui()),
        Err(e) => ApiResponse::<models::WebDavConfig>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_test_webdav(config_json: *const c_char) -> *mut c_char {
    let parsed = cstr_to_str(config_json).and_then(|raw| {
        serde_json::from_str::<models::WebDavConfig>(raw)
            .map_err(|e| format!("无效的 WebDAV 配置参数: {e}"))
    });
    let resp = match parsed {
        Ok(cfg) => ApiResponse::success(webdav::test_connection_blocking(cfg)),
        Err(e) => ApiResponse::<models::ConnectionTestResult>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_sync_webdav(
    config_json_or_empty: *const c_char,
    mode_str: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let raw_cfg = cstr_to_str(config_json_or_empty)?.trim();
        let cfg_opt = if raw_cfg.is_empty() {
            None
        } else {
            Some(
                serde_json::from_str::<models::WebDavConfig>(raw_cfg)
                    .map_err(|e| format!("无效的 WebDAV 配置参数: {e}"))?,
            )
        };
        let mode = match cstr_to_str(mode_str)?.trim() {
            "push_overwrite" => models::SyncMode::PushOverwrite,
            "pull_overwrite" => models::SyncMode::PullOverwrite,
            _ => models::SyncMode::Merge,
        };
        webdav::sync_blocking(cfg_opt, mode)
    })();

    let resp = match result {
        Ok(mut res) => {
            res.hosts = res.hosts.into_iter().map(|h| h.redacted_for_ui()).collect();
            ApiResponse::success(res)
        }
        Err(e) => ApiResponse::<models::WebDavSyncResult>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_test_connection(
    profile_json: *const c_char,
    timeout_secs: u32,
) -> *mut c_char {
    let parsed = cstr_to_str(profile_json).and_then(|raw| {
        serde_json::from_str::<HostProfile>(raw).map_err(|e| format!("无效的主机参数: {e}"))
    });
    let resp = match parsed {
        Ok(profile) => {
            let test_res = ssh::test_connection_blocking(profile, u64::from(timeout_secs));
            ApiResponse::success(test_res)
        }
        Err(e) => ApiResponse::<models::ConnectionTestResult>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_session_connect(
    session_id: *const c_char,
    profile_json: *const c_char,
    cols: u32,
    rows: u32,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?.to_string();
        let raw_profile = cstr_to_str(profile_json)?;
        let profile = serde_json::from_str::<HostProfile>(raw_profile)
            .map_err(|e| format!("无效的主机参数: {e}"))?;
        ssh::start_session(sid, profile, cols, rows)?;
        Ok::<bool, String>(true)
    })();

    let resp = match result {
        Ok(v) => ApiResponse::success(v),
        Err(e) => ApiResponse::<bool>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_list_local_shells() -> *mut c_char {
    let shells = local_pty::discover_local_shells();
    into_c_string(ApiResponse::success(shells))
}

#[no_mangle]
pub extern "C" fn nexus_session_connect_local(
    session_id: *const c_char,
    shell_program: *const c_char,
    cwd: *const c_char,
    cols: u32,
    rows: u32,
) -> *mut c_char {
    let result = (|| {
        let sid = cstr_to_str(session_id)?.to_string();
        let prog = cstr_to_str(shell_program)?.to_string();
        let dir = cstr_to_str(cwd)?.to_string();
        local_pty::start_local_session(sid, prog, Vec::new(), dir, cols, rows)
    })();

    let resp = match result {
        Ok(name) => ApiResponse::success(name),
        Err(e) => ApiResponse::<String>::err(e),
    };
    into_c_string(resp)
}

#[no_mangle]
pub extern "C" fn nexus_session_write(
    session_id: *const c_char,
    data_ptr: *const u8,
    data_len: usize,
) -> i32 {
    let Ok(sid) = cstr_to_str(session_id) else {
        return -1;
    };
    if data_ptr.is_null() || data_len == 0 {
        return 0;
    }
    let bytes = unsafe { slice::from_raw_parts(data_ptr, data_len) };
    if matches!(local_pty::write_to_session(sid, bytes), Ok(true)) {
        return 0;
    }
    if ssh::write_to_session(sid, bytes).is_ok() {
        0
    } else {
        -2
    }
}

#[no_mangle]
pub extern "C" fn nexus_session_resize(
    session_id: *const c_char,
    cols: u32,
    rows: u32,
    pixel_width: u32,
    pixel_height: u32,
) -> i32 {
    let Ok(sid) = cstr_to_str(session_id) else {
        return -1;
    };
    if matches!(
        local_pty::resize_session(sid, cols, rows, pixel_width, pixel_height),
        Ok(true)
    ) {
        return 0;
    }
    if ssh::resize_session(sid, cols, rows, pixel_width, pixel_height).is_ok() {
        0
    } else {
        -2
    }
}

#[no_mangle]
pub extern "C" fn nexus_session_fill_sudo_password(session_id: *const c_char) -> i32 {
    let Ok(sid) = cstr_to_str(session_id) else {
        return -1;
    };
    match ssh::fill_sudo_password(sid) {
        Ok(true) => 0,
        Ok(false) => 1,
        Err(_) => -2,
    }
}

#[no_mangle]
pub extern "C" fn nexus_session_disconnect(session_id: *const c_char) -> i32 {
    let Ok(sid) = cstr_to_str(session_id) else {
        return -1;
    };
    if matches!(local_pty::disconnect_session(sid), Ok(true)) {
        return 0;
    }
    if ssh::disconnect_session(sid).is_ok() {
        0
    } else {
        -2
    }
}

/// Fast non-blocking shutdown hook: silences all Rust -> Dart callbacks so
/// teardown never races with Dart isolate destruction, and disconnects all
/// active SSH & local PTY sessions asynchronously.
#[no_mangle]
pub extern "C" fn nexus_prepare_shutdown() {
    OUTPUT_CB_ADDR.store(0, Ordering::Release);
    STATUS_CB_ADDR.store(0, Ordering::Release);
    ssh::disconnect_all_sessions();
    local_pty::disconnect_all_sessions();
}

#[no_mangle]
pub extern "C" fn nexus_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

#[no_mangle]
pub extern "C" fn nexus_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        unsafe {
            let slice_ptr = ptr::slice_from_raw_parts_mut(ptr, len);
            let _ = Box::from_raw(slice_ptr);
        }
    }
}
