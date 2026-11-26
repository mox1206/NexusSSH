use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{OnceLock, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use pbkdf2::pbkdf2_hmac;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use uuid::Uuid;

use crate::models::{
    AppLockConfig, AuthMethod, HostProfile, KnownHostEntry, SnippetItem, WebDavConfig,
};
use crate::vault_crypto;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SyncSnapshot {
    pub hosts: Vec<HostProfile>,
    #[serde(default)]
    pub deleted_tombstones: HashMap<String, i64>,
    #[serde(default)]
    pub snippets: Vec<SnippetItem>,
    #[serde(default)]
    pub deleted_snippet_tombstones: HashMap<String, i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KnownHostCheck {
    Trusted,
    Unknown,
    Mismatch { previous_fingerprint: String },
}

struct HostVault {
    data_dir: Option<PathBuf>,
    hosts_path: Option<PathBuf>,
    tombstones_path: Option<PathBuf>,
    snippets_path: Option<PathBuf>,
    snippet_tombstones_path: Option<PathBuf>,
    known_hosts_path: Option<PathBuf>,
    webdav_path: Option<PathBuf>,
    app_lock_path: Option<PathBuf>,
    hosts: Vec<HostProfile>,
    deleted_tombstones: HashMap<String, i64>,
    snippets: Vec<SnippetItem>,
    deleted_snippet_tombstones: HashMap<String, i64>,
    known_hosts: HashMap<String, KnownHostEntry>,
    webdav_config: WebDavConfig,
    app_lock: AppLockConfig,
}

static VAULT: OnceLock<RwLock<HostVault>> = OnceLock::new();

fn vault() -> &'static RwLock<HostVault> {
    VAULT.get_or_init(|| {
        RwLock::new(HostVault {
            data_dir: None,
            hosts_path: None,
            tombstones_path: None,
            snippets_path: None,
            snippet_tombstones_path: None,
            known_hosts_path: None,
            webdav_path: None,
            app_lock_path: None,
            hosts: Vec::new(),
            deleted_tombstones: HashMap::new(),
            snippets: Vec::new(),
            deleted_snippet_tombstones: HashMap::new(),
            known_hosts: HashMap::new(),
            webdav_config: WebDavConfig::default(),
            app_lock: AppLockConfig::default(),
        })
    })
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn unseal_host(mut h: HostProfile) -> HostProfile {
    h.password = vault_crypto::open_secret(&h.password);
    h.private_key = vault_crypto::open_secret(&h.private_key);
    h.passphrase = vault_crypto::open_secret(&h.passphrase);
    h.sync_secret_flags();
    h
}

fn seal_host_for_disk(mut h: HostProfile) -> HostProfile {
    h.sync_secret_flags();
    h.password = vault_crypto::seal_secret(&h.password);
    h.private_key = vault_crypto::seal_secret(&h.private_key);
    h.passphrase = vault_crypto::seal_secret(&h.passphrase);
    h
}

fn unseal_webdav(mut c: WebDavConfig) -> WebDavConfig {
    c.password = vault_crypto::open_secret(&c.password);
    c.encryption_password = vault_crypto::open_secret(&c.encryption_password);
    c.sync_secret_flags();
    c
}

fn seal_webdav_for_disk(mut c: WebDavConfig) -> WebDavConfig {
    c.sync_secret_flags();
    c.password = vault_crypto::seal_secret(&c.password);
    c.encryption_password = vault_crypto::seal_secret(&c.encryption_password);
    c
}

pub fn init_store(data_dir: &str) -> Result<Vec<HostProfile>, String> {
    let dir = Path::new(data_dir);
    fs::create_dir_all(dir).map_err(|e| format!("无法创建数据目录: {e}"))?;
    vault_crypto::init_master_key(dir)?;

    let hosts_path = dir.join("hosts_v1.json");
    let tombstones_path = dir.join("deleted_tombstones_v1.json");
    let snippets_path = dir.join("snippets_v1.json");
    let snippet_tombstones_path = dir.join("deleted_snippet_tombstones_v1.json");
    let known_hosts_path = dir.join("known_hosts_v1.json");
    let webdav_path = dir.join("webdav_config_v1.json");
    let app_lock_path = dir.join("app_lock_v1.json");
    let snippets_seed_marker = dir.join(".default_snippets_seeded");

    let raw_hosts: Vec<HostProfile> = read_json_or_default(&hosts_path)?;
    let mut loaded_hosts: Vec<HostProfile> = raw_hosts.into_iter().map(unseal_host).collect();
    let loaded_tombstones: HashMap<String, i64> = read_json_or_default(&tombstones_path)?;
    let mut loaded_snippets: Vec<SnippetItem> = read_json_or_default(&snippets_path)?;
    let loaded_snippet_tombstones: HashMap<String, i64> =
        read_json_or_default(&snippet_tombstones_path)?;
    let loaded_known_hosts: HashMap<String, KnownHostEntry> =
        read_json_or_default(&known_hosts_path)?;
    let loaded_webdav = unseal_webdav(read_json_or_default(&webdav_path)?);
    let mut loaded_app_lock: AppLockConfig = read_json_or_default(&app_lock_path)?;
    loaded_app_lock.has_passcode = !loaded_app_lock.hash_b64.is_empty();
    if !loaded_app_lock.has_passcode {
        loaded_app_lock.enabled = false;
    }

    if !snippets_seed_marker.exists() && loaded_snippets.is_empty() {
        let ts = now_ms();
        loaded_snippets = vec![
            SnippetItem {
                id: "builtin-sys-overview".to_string(),
                title: "系统负载与内存概览".to_string(),
                command: "uptime && free -h && df -h /".to_string(),
                category: "运维巡检".to_string(),
                auto_enter: true,
                created_at_ms: ts,
                updated_at_ms: ts,
            },
            SnippetItem {
                id: "builtin-ports".to_string(),
                title: "查看监听端口".to_string(),
                command: "ss -tulpn".to_string(),
                category: "网络排查".to_string(),
                auto_enter: true,
                created_at_ms: ts,
                updated_at_ms: ts,
            },
            SnippetItem {
                id: "builtin-docker-ps".to_string(),
                title: "Docker 运行容器".to_string(),
                command: "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'"
                    .to_string(),
                category: "容器".to_string(),
                auto_enter: true,
                created_at_ms: ts,
                updated_at_ms: ts,
            },
            SnippetItem {
                id: "builtin-journalctl-var".to_string(),
                title: "查看服务实时日志".to_string(),
                command: "journalctl -u {{服务名:nginx}} -n {{行数:100}} -f".to_string(),
                category: "日志排查".to_string(),
                auto_enter: true,
                created_at_ms: ts,
                updated_at_ms: ts,
            },
        ];
        let _ = fs::write(&snippets_seed_marker, "1");
    }

    for h in &mut loaded_hosts {
        if h.updated_at_ms == 0 {
            h.updated_at_ms = h.created_at_ms.max(1);
        }
    }

    let mut guard = vault()
        .write()
        .map_err(|_| "主机配置锁异常".to_string())?;
    guard.data_dir = Some(dir.to_path_buf());
    guard.hosts_path = Some(hosts_path);
    guard.tombstones_path = Some(tombstones_path);
    guard.snippets_path = Some(snippets_path);
    guard.snippet_tombstones_path = Some(snippet_tombstones_path);
    guard.known_hosts_path = Some(known_hosts_path);
    guard.webdav_path = Some(webdav_path);
    guard.app_lock_path = Some(app_lock_path);
    guard.hosts = loaded_hosts;
    guard.deleted_tombstones = loaded_tombstones;
    guard.snippets = loaded_snippets;
    guard.deleted_snippet_tombstones = loaded_snippet_tombstones;
    guard.known_hosts = loaded_known_hosts;
    guard.webdav_config = loaded_webdav;
    guard.app_lock = loaded_app_lock;

    // Persist immediately so any legacy plaintext credentials on disk are upgraded to `enc:v1:`
    persist_hosts_locked(&guard)?;
    persist_snippets_locked(&guard)?;
    if guard.webdav_config.is_configured() {
        persist_webdav_locked(&guard)?;
    }

    Ok(sorted_hosts(&guard.hosts))
}

fn read_json_or_default<T: for<'de> Deserialize<'de> + Default>(path: &Path) -> Result<T, String> {
    if !path.exists() {
        return Ok(T::default());
    }
    let raw = fs::read_to_string(path)
        .map_err(|e| format!("读取文件失败 ({}): {e}", path.display()))?;
    if raw.trim().is_empty() {
        return Ok(T::default());
    }
    serde_json::from_str(&raw).map_err(|e| format!("解析 JSON 失败 ({}): {e}", path.display()))
}

fn sorted_hosts(hosts: &[HostProfile]) -> Vec<HostProfile> {
    let mut list = hosts.to_vec();
    list.sort_by(|a, b| {
        b.last_connected_ms
            .unwrap_or(0)
            .cmp(&a.last_connected_ms.unwrap_or(0))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    list
}

fn sorted_snippets(snippets: &[SnippetItem]) -> Vec<SnippetItem> {
    let mut list = snippets.to_vec();
    list.sort_by(|a, b| {
        a.category
            .to_lowercase()
            .cmp(&b.category.to_lowercase())
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    list
}

pub fn list_hosts() -> Result<Vec<HostProfile>, String> {
    let guard = vault()
        .read()
        .map_err(|_| "主机配置锁异常".to_string())?;
    Ok(sorted_hosts(&guard.hosts))
}

pub fn list_hosts_redacted() -> Result<Vec<HostProfile>, String> {
    Ok(list_hosts()?
        .into_iter()
        .map(|h| h.redacted_for_ui())
        .collect())
}

/// Fills empty secret fields in `profile` from the in-memory vault when `profile.id`
/// matches a saved host (used internally in Rust for SSH dial / connection test).
pub fn hydrate_host_secrets(profile: &mut HostProfile) {
    let id = profile.id.trim();
    if id.is_empty() {
        return;
    }
    let Ok(guard) = vault().read() else {
        return;
    };
    let Some(existing) = guard.hosts.iter().find(|h| h.id == id) else {
        return;
    };

    if profile.password.is_empty() {
        profile.password = existing.password.clone();
    }
    if profile.private_key.trim().is_empty()
        && (profile.private_key_path.trim().is_empty()
            || profile.private_key_path.trim() == existing.private_key_path.trim())
    {
        if profile.private_key_path.trim().is_empty() {
            profile.private_key_path = existing.private_key_path.clone();
        }
        if profile.private_key_label.trim().is_empty() {
            profile.private_key_label = existing.private_key_label.clone();
        }
        profile.private_key = existing.private_key.clone();
    }
    if profile.passphrase.is_empty() && !profile.clear_passphrase {
        profile.passphrase = existing.passphrase.clone();
    }
}

pub const MAX_PROXY_JUMP_HOPS: usize = 5;

/// Resolves the ordered ProxyJump chain for `profile`, from the outermost bastion
/// down to the immediate jump host (excluding `profile` itself).
/// Returns an empty vector for direct connections.
pub fn resolve_jump_chain(profile: &HostProfile) -> Result<Vec<HostProfile>, String> {
    let first_jump_id = profile
        .jump_host_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let Some(mut next_id) = first_jump_id.map(ToString::to_string) else {
        return Ok(Vec::new());
    };

    let guard = vault()
        .read()
        .map_err(|_| "主机配置锁异常".to_string())?;

    let mut visited = std::collections::HashSet::<String>::new();
    if !profile.id.trim().is_empty() {
        visited.insert(profile.id.trim().to_string());
    }

    let mut reversed_chain = Vec::<HostProfile>::new();
    loop {
        if !visited.insert(next_id.clone()) {
            return Err("ProxyJump 链存在循环引用，请检查跳板主机配置".to_string());
        }
        if reversed_chain.len() >= MAX_PROXY_JUMP_HOPS {
            return Err(format!(
                "ProxyJump 级联跳数超过上限（最多支持 {MAX_PROXY_JUMP_HOPS} 级）"
            ));
        }
        let jump_host = guard
            .hosts
            .iter()
            .find(|h| h.id == next_id)
            .cloned()
            .ok_or_else(|| "找不到指定的 ProxyJump 主机，请重新选择或检查是否已被删除".to_string())?;

        let parent_id = jump_host
            .jump_host_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToString::to_string);
        reversed_chain.push(jump_host);

        match parent_id {
            Some(pid) => next_id = pid,
            None => break,
        }
    }

    reversed_chain.reverse();
    Ok(reversed_chain)
}

fn validate_jump_host_locked(
    hosts: &[HostProfile],
    self_id: &str,
    jump_host_id: &Option<String>,
) -> Result<(), String> {
    let Some(ref first_id) = jump_host_id else {
        return Ok(());
    };
    if !self_id.is_empty() && first_id == self_id {
        return Err("不能将当前主机设置为自身的 ProxyJump 跳板机".to_string());
    }
    let mut visited = std::collections::HashSet::<String>::new();
    if !self_id.is_empty() {
        visited.insert(self_id.to_string());
    }
    let mut cursor = first_id.clone();
    let mut hops = 0usize;
    loop {
        if !visited.insert(cursor.clone()) {
            return Err("ProxyJump 配置存在循环引用，请重新选择跳板主机".to_string());
        }
        hops += 1;
        if hops > MAX_PROXY_JUMP_HOPS {
            return Err(format!(
                "ProxyJump 级联跳数超过上限（最多支持 {MAX_PROXY_JUMP_HOPS} 级）"
            ));
        }
        let found = hosts
            .iter()
            .find(|h| h.id == cursor)
            .ok_or_else(|| "所选的 ProxyJump 主机不存在".to_string())?;
        match found
            .jump_host_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            Some(next) => cursor = next.to_string(),
            None => return Ok(()),
        }
    }
}

pub fn upsert_host(mut profile: HostProfile) -> Result<HostProfile, String> {
    profile.host = profile.host.trim().to_string();
    profile.username = profile.username.trim().to_string();
    profile.name = if profile.name.trim().is_empty() {
        profile.host.clone()
    } else {
        profile.name.trim().to_string()
    };
    profile.group = if profile.group.trim().is_empty() {
        "Default".to_string()
    } else {
        profile.group.trim().to_string()
    };
    profile.jump_host_id = profile
        .jump_host_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string);

    // Preserve existing stored secrets when editing an existing host with blank write-only fields
    hydrate_host_secrets(&mut profile);

    if profile.auth_method == AuthMethod::PrivateKey && !profile.private_key_path.trim().is_empty() {
        let key_path = Path::new(profile.private_key_path.trim());
        if profile.private_key_label.trim().is_empty() {
            if let Some(fname) = key_path.file_name().and_then(|s| s.to_str()) {
                profile.private_key_label = fname.to_string();
            }
        }
        if profile.private_key.trim().is_empty() && key_path.is_file() {
            if let Ok(pem) = fs::read_to_string(key_path) {
                profile.private_key = pem;
            }
        }
    }

    profile.sync_secret_flags();
    profile.validate()?;

    let mut guard = vault()
        .write()
        .map_err(|_| "主机配置锁异常".to_string())?;

    validate_jump_host_locked(&guard.hosts, profile.id.trim(), &profile.jump_host_id)?;

    let now = now_ms();
    profile.updated_at_ms = now;

    if profile.id.trim().is_empty() {
        profile.id = Uuid::new_v4().to_string();
        profile.created_at_ms = now;
        guard.hosts.push(profile.clone());
    } else if let Some(existing) = guard.hosts.iter_mut().find(|h| h.id == profile.id) {
        if profile.created_at_ms == 0 {
            profile.created_at_ms = existing.created_at_ms;
        }
        if profile.last_connected_ms.is_none() {
            profile.last_connected_ms = existing.last_connected_ms;
        }
        *existing = profile.clone();
    } else {
        if profile.created_at_ms == 0 {
            profile.created_at_ms = now;
        }
        guard.hosts.push(profile.clone());
    }

    guard.deleted_tombstones.remove(&profile.id);
    persist_hosts_locked(&guard)?;
    persist_tombstones_locked(&guard)?;
    Ok(profile)
}

pub fn delete_host(host_id: &str) -> Result<bool, String> {
    let mut guard = vault()
        .write()
        .map_err(|_| "主机配置锁异常".to_string())?;
    let before = guard.hosts.len();
    guard.hosts.retain(|h| h.id != host_id);
    let removed = guard.hosts.len() != before;
    if removed {
        guard
            .deleted_tombstones
            .insert(host_id.to_string(), now_ms());
        persist_hosts_locked(&guard)?;
        persist_tombstones_locked(&guard)?;
    }
    Ok(removed)
}

pub fn mark_host_connected(host_id: &str) {
    if host_id.trim().is_empty() {
        return;
    }
    if let Ok(mut guard) = vault().write() {
        if let Some(host) = guard.hosts.iter_mut().find(|h| h.id == host_id) {
            host.last_connected_ms = Some(now_ms());
            let _ = persist_hosts_locked(&guard);
        }
    }
}

// --- Snippets Management ---

pub fn list_snippets() -> Result<Vec<SnippetItem>, String> {
    let guard = vault()
        .read()
        .map_err(|_| "配置库锁异常".to_string())?;
    Ok(sorted_snippets(&guard.snippets))
}

pub fn upsert_snippet(mut item: SnippetItem) -> Result<SnippetItem, String> {
    item.title = item.title.trim().to_string();
    item.category = if item.category.trim().is_empty() {
        "常用".to_string()
    } else {
        item.category.trim().to_string()
    };
    item.validate()?;

    let mut guard = vault()
        .write()
        .map_err(|_| "配置库锁异常".to_string())?;

    let now = now_ms();
    item.updated_at_ms = now;
    if item.id.trim().is_empty() {
        item.id = Uuid::new_v4().to_string();
        item.created_at_ms = now;
        guard.snippets.push(item.clone());
    } else if let Some(existing) = guard.snippets.iter_mut().find(|s| s.id == item.id) {
        if item.created_at_ms == 0 {
            item.created_at_ms = existing.created_at_ms;
        }
        *existing = item.clone();
    } else {
        if item.created_at_ms == 0 {
            item.created_at_ms = now;
        }
        guard.snippets.push(item.clone());
    }

    guard.deleted_snippet_tombstones.remove(&item.id);
    persist_snippets_locked(&guard)?;
    persist_snippet_tombstones_locked(&guard)?;
    Ok(item)
}

pub fn delete_snippet(snippet_id: &str) -> Result<bool, String> {
    let mut guard = vault()
        .write()
        .map_err(|_| "配置库锁异常".to_string())?;
    let before = guard.snippets.len();
    guard.snippets.retain(|s| s.id != snippet_id);
    let removed = guard.snippets.len() != before;
    if removed {
        guard
            .deleted_snippet_tombstones
            .insert(snippet_id.to_string(), now_ms());
        persist_snippets_locked(&guard)?;
        persist_snippet_tombstones_locked(&guard)?;
    }
    Ok(removed)
}

// --- Known Hosts (TOFU) Management ---

pub fn format_host_port_key(host: &str, port: u16) -> String {
    let h = host.trim().to_ascii_lowercase();
    if port == 22 {
        h
    } else {
        format!("[{h}]:{port}")
    }
}

pub fn check_known_host(host: &str, port: u16, fingerprint: &str) -> KnownHostCheck {
    let key = format_host_port_key(host, port);
    let Ok(guard) = vault().read() else {
        return KnownHostCheck::Unknown;
    };
    match guard.known_hosts.get(&key) {
        None => KnownHostCheck::Unknown,
        Some(entry) if entry.fingerprint == fingerprint => KnownHostCheck::Trusted,
        Some(entry) => KnownHostCheck::Mismatch {
            previous_fingerprint: entry.fingerprint.clone(),
        },
    }
}

pub fn trust_known_host(
    host: &str,
    port: u16,
    algorithm: &str,
    fingerprint: &str,
    public_key_base64: &str,
) -> Result<KnownHostEntry, String> {
    let host_key = format_host_port_key(host, port);
    let entry = KnownHostEntry {
        host_key: host_key.clone(),
        host: host.trim().to_string(),
        port,
        algorithm: algorithm.to_string(),
        fingerprint: fingerprint.to_string(),
        public_key_base64: public_key_base64.to_string(),
        trusted_at_ms: now_ms(),
    };

    let mut guard = vault()
        .write()
        .map_err(|_| "known_hosts 锁异常".to_string())?;
    guard.known_hosts.insert(host_key, entry.clone());
    persist_known_hosts_locked(&guard)?;
    Ok(entry)
}

pub fn list_known_hosts() -> Result<Vec<KnownHostEntry>, String> {
    let guard = vault()
        .read()
        .map_err(|_| "known_hosts 锁异常".to_string())?;
    let mut entries: Vec<KnownHostEntry> = guard.known_hosts.values().cloned().collect();
    entries.sort_by(|a, b| b.trusted_at_ms.cmp(&a.trusted_at_ms));
    Ok(entries)
}

pub fn delete_known_host(host_key: &str) -> Result<bool, String> {
    let mut guard = vault()
        .write()
        .map_err(|_| "known_hosts 锁异常".to_string())?;
    let removed = guard.known_hosts.remove(host_key).is_some();
    if removed {
        persist_known_hosts_locked(&guard)?;
    }
    Ok(removed)
}

// --- WebDAV Config & Sync Snapshot ---

pub fn get_webdav_config() -> Result<WebDavConfig, String> {
    let guard = vault()
        .read()
        .map_err(|_| "主机配置锁异常".to_string())?;
    Ok(guard.webdav_config.clone())
}

pub fn get_webdav_config_redacted() -> Result<WebDavConfig, String> {
    Ok(get_webdav_config()?.redacted_for_ui())
}

pub fn hydrate_webdav_secrets(config: &mut WebDavConfig) {
    let Ok(guard) = vault().read() else {
        return;
    };
    if config.password.is_empty() {
        config.password = guard.webdav_config.password.clone();
    }
    if config.encryption_password.is_empty() && !config.clear_encryption_password {
        config.encryption_password = guard.webdav_config.encryption_password.clone();
    }
}

pub fn save_webdav_config(mut config: WebDavConfig) -> Result<WebDavConfig, String> {
    config.url = config.url.trim().to_string();
    config.username = config.username.trim().to_string();
    if config.remote_path.trim().is_empty() {
        config.remote_path = "NexusSSH/hosts_sync.json".to_string();
    } else {
        config.remote_path = config.remote_path.trim().to_string();
    }
    if !config.url.is_empty() {
        config.validate()?;
    }

    let mut guard = vault()
        .write()
        .map_err(|_| "主机配置锁异常".to_string())?;
    if config.password.is_empty() {
        config.password = guard.webdav_config.password.clone();
    }
    if config.encryption_password.is_empty() && !config.clear_encryption_password {
        config.encryption_password = guard.webdav_config.encryption_password.clone();
    }
    config.sync_secret_flags();
    if config.last_sync_ms.is_none() {
        config.last_sync_ms = guard.webdav_config.last_sync_ms;
        config.last_sync_message = guard.webdav_config.last_sync_message.clone();
    }
    guard.webdav_config = config.clone();
    persist_webdav_locked(&guard)?;
    Ok(config)
}

pub fn record_webdav_sync_status(synced_at_ms: i64, message: String) {
    if let Ok(mut guard) = vault().write() {
        guard.webdav_config.last_sync_ms = Some(synced_at_ms);
        guard.webdav_config.last_sync_message = Some(message);
        let _ = persist_webdav_locked(&guard);
    }
}

pub fn export_local_snapshot() -> Result<SyncSnapshot, String> {
    let guard = vault()
        .read()
        .map_err(|_| "主机配置锁异常".to_string())?;
    Ok(SyncSnapshot {
        hosts: guard.hosts.clone(),
        deleted_tombstones: guard.deleted_tombstones.clone(),
        snippets: guard.snippets.clone(),
        deleted_snippet_tombstones: guard.deleted_snippet_tombstones.clone(),
    })
}

pub fn replace_with_snapshot(
    snapshot: SyncSnapshot,
) -> Result<(Vec<HostProfile>, Vec<SnippetItem>), String> {
    let mut guard = vault()
        .write()
        .map_err(|_| "主机配置锁异常".to_string())?;
    guard.hosts = snapshot.hosts.into_iter().map(unseal_host).collect();
    guard.deleted_tombstones = snapshot.deleted_tombstones;
    if !snapshot.snippets.is_empty() || !snapshot.deleted_snippet_tombstones.is_empty() {
        guard.snippets = snapshot.snippets;
        guard.deleted_snippet_tombstones = snapshot.deleted_snippet_tombstones;
    }
    persist_hosts_locked(&guard)?;
    persist_tombstones_locked(&guard)?;
    persist_snippets_locked(&guard)?;
    persist_snippet_tombstones_locked(&guard)?;
    Ok((sorted_hosts(&guard.hosts), sorted_snippets(&guard.snippets)))
}

pub fn merge_with_remote_snapshot(
    remote: SyncSnapshot,
) -> Result<(SyncSnapshot, Vec<HostProfile>, Vec<SnippetItem>), String> {
    let mut guard = vault()
        .write()
        .map_err(|_| "主机配置锁异常".to_string())?;

    let remote_hosts: Vec<HostProfile> = remote.hosts.into_iter().map(unseal_host).collect();

    // 1. Merge host tombstones
    let mut merged_tombstones = guard.deleted_tombstones.clone();
    for (id, del_ts) in remote.deleted_tombstones {
        let entry = merged_tombstones.entry(id).or_insert(0);
        if del_ts > *entry {
            *entry = del_ts;
        }
    }

    // 2. Merge hosts by ID
    let mut by_id: HashMap<String, HostProfile> = HashMap::new();
    for h in guard.hosts.iter().chain(remote_hosts.iter()) {
        if h.id.trim().is_empty() {
            continue;
        }
        let effective_updated = h.updated_at_ms.max(h.created_at_ms);
        if let Some(&del_ts) = merged_tombstones.get(&h.id) {
            if del_ts >= effective_updated {
                continue;
            }
        }
        match by_id.get(&h.id) {
            None => {
                by_id.insert(h.id.clone(), h.clone());
            }
            Some(existing) => {
                let existing_ts = existing.updated_at_ms.max(existing.created_at_ms);
                if effective_updated > existing_ts {
                    let mut winner = h.clone();
                    if winner.last_connected_ms.is_none() {
                        winner.last_connected_ms = existing.last_connected_ms;
                    }
                    by_id.insert(h.id.clone(), winner);
                }
            }
        }
    }

    // 3. Deduplicate exact matches across fresh devices
    let mut deduped: Vec<HostProfile> = Vec::with_capacity(by_id.len());
    let mut candidates: Vec<HostProfile> = by_id.into_values().collect();
    candidates.sort_by_key(|b| std::cmp::Reverse(b.updated_at_ms.max(b.created_at_ms)));

    for candidate in candidates {
        let is_exact_dup = deduped.iter().any(|kept| {
            kept.host.eq_ignore_ascii_case(&candidate.host)
                && kept.port == candidate.port
                && kept.username == candidate.username
                && kept.name == candidate.name
                && kept.auth_method == candidate.auth_method
        });
        if is_exact_dup {
            merged_tombstones.insert(candidate.id.clone(), now_ms());
        } else {
            deduped.push(candidate);
        }
    }

    // 4. Merge snippets & snippet tombstones
    let mut merged_snip_tombstones = guard.deleted_snippet_tombstones.clone();
    for (id, del_ts) in remote.deleted_snippet_tombstones {
        let entry = merged_snip_tombstones.entry(id).or_insert(0);
        if del_ts > *entry {
            *entry = del_ts;
        }
    }

    let mut snip_by_id: HashMap<String, SnippetItem> = HashMap::new();
    for s in guard.snippets.iter().chain(remote.snippets.iter()) {
        if s.id.trim().is_empty() {
            continue;
        }
        let effective_updated = s.updated_at_ms.max(s.created_at_ms);
        if let Some(&del_ts) = merged_snip_tombstones.get(&s.id) {
            if del_ts >= effective_updated {
                continue;
            }
        }
        match snip_by_id.get(&s.id) {
            None => {
                snip_by_id.insert(s.id.clone(), s.clone());
            }
            Some(existing) => {
                let existing_ts = existing.updated_at_ms.max(existing.created_at_ms);
                if effective_updated > existing_ts {
                    snip_by_id.insert(s.id.clone(), s.clone());
                }
            }
        }
    }

    guard.hosts = deduped;
    guard.deleted_tombstones = merged_tombstones;
    guard.snippets = snip_by_id.into_values().collect();
    guard.deleted_snippet_tombstones = merged_snip_tombstones;

    persist_hosts_locked(&guard)?;
    persist_tombstones_locked(&guard)?;
    persist_snippets_locked(&guard)?;
    persist_snippet_tombstones_locked(&guard)?;

    let snapshot = SyncSnapshot {
        hosts: guard.hosts.clone(),
        deleted_tombstones: guard.deleted_tombstones.clone(),
        snippets: guard.snippets.clone(),
        deleted_snippet_tombstones: guard.deleted_snippet_tombstones.clone(),
    };
    Ok((
        snapshot,
        sorted_hosts(&guard.hosts),
        sorted_snippets(&guard.snippets),
    ))
}

fn persist_hosts_locked(vault: &HostVault) -> Result<(), String> {
    if let Some(ref path) = vault.hosts_path {
        let sealed_hosts: Vec<HostProfile> =
            vault.hosts.iter().cloned().map(seal_host_for_disk).collect();
        atomic_write_json(path, &sealed_hosts)?;
    }
    Ok(())
}

fn persist_tombstones_locked(vault: &HostVault) -> Result<(), String> {
    if let Some(ref path) = vault.tombstones_path {
        atomic_write_json(path, &vault.deleted_tombstones)?;
    }
    Ok(())
}

fn persist_snippets_locked(vault: &HostVault) -> Result<(), String> {
    if let Some(ref path) = vault.snippets_path {
        atomic_write_json(path, &vault.snippets)?;
    }
    Ok(())
}

fn persist_snippet_tombstones_locked(vault: &HostVault) -> Result<(), String> {
    if let Some(ref path) = vault.snippet_tombstones_path {
        atomic_write_json(path, &vault.deleted_snippet_tombstones)?;
    }
    Ok(())
}

fn persist_known_hosts_locked(vault: &HostVault) -> Result<(), String> {
    if let Some(ref path) = vault.known_hosts_path {
        atomic_write_json(path, &vault.known_hosts)?;
    }
    Ok(())
}

fn persist_webdav_locked(vault: &HostVault) -> Result<(), String> {
    if let Some(ref path) = vault.webdav_path {
        let sealed_cfg = seal_webdav_for_disk(vault.webdav_config.clone());
        atomic_write_json(path, &sealed_cfg)?;
    }
    Ok(())
}

// --- App Lock (PBKDF2-HMAC-SHA256) ---

const APP_LOCK_PBKDF2_ROUNDS: u32 = 200_000;

fn derive_passcode_hash(passcode: &str, salt: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    pbkdf2_hmac::<Sha256>(passcode.as_bytes(), salt, APP_LOCK_PBKDF2_ROUNDS, &mut out);
    out
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn verify_passcode_against_config(cfg: &AppLockConfig, passcode: &str) -> bool {
    if cfg.salt_b64.is_empty() || cfg.hash_b64.is_empty() || passcode.is_empty() {
        return false;
    }
    let Ok(salt) = B64.decode(cfg.salt_b64.as_bytes()) else {
        return false;
    };
    let Ok(expected) = B64.decode(cfg.hash_b64.as_bytes()) else {
        return false;
    };
    let actual = derive_passcode_hash(passcode, &salt);
    constant_time_eq(&actual, &expected)
}

pub fn get_app_lock_config_redacted() -> Result<AppLockConfig, String> {
    let guard = vault()
        .read()
        .map_err(|_| "应用锁配置读锁异常".to_string())?;
    Ok(guard.app_lock.redacted_for_ui())
}

pub fn set_app_lock_passcode(
    passcode: &str,
    biometrics_enabled: bool,
    lock_on_startup: bool,
    auto_lock_minutes: i32,
) -> Result<AppLockConfig, String> {
    if passcode.chars().count() < 4 {
        return Err("应用锁密码至少需要 4 位字符".to_string());
    }
    let mut salt = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut salt);
    let hash = derive_passcode_hash(passcode, &salt);

    let mut guard = vault()
        .write()
        .map_err(|_| "应用锁配置写锁异常".to_string())?;
    guard.app_lock = AppLockConfig {
        enabled: true,
        biometrics_enabled,
        lock_on_startup,
        auto_lock_minutes,
        has_passcode: true,
        salt_b64: B64.encode(salt),
        hash_b64: B64.encode(hash),
    };
    persist_app_lock_locked(&guard)?;
    Ok(guard.app_lock.redacted_for_ui())
}

pub fn verify_app_lock_passcode(passcode: &str) -> Result<bool, String> {
    let guard = vault()
        .read()
        .map_err(|_| "应用锁配置读锁异常".to_string())?;
    Ok(verify_passcode_against_config(&guard.app_lock, passcode))
}

pub fn update_app_lock_settings(
    biometrics_enabled: bool,
    lock_on_startup: bool,
    auto_lock_minutes: i32,
) -> Result<AppLockConfig, String> {
    let mut guard = vault()
        .write()
        .map_err(|_| "应用锁配置写锁异常".to_string())?;
    if !guard.app_lock.enabled || guard.app_lock.hash_b64.is_empty() {
        return Err("尚未开启应用锁".to_string());
    }
    guard.app_lock.biometrics_enabled = biometrics_enabled;
    guard.app_lock.lock_on_startup = lock_on_startup;
    guard.app_lock.auto_lock_minutes = auto_lock_minutes;
    persist_app_lock_locked(&guard)?;
    Ok(guard.app_lock.redacted_for_ui())
}

pub fn disable_app_lock(current_passcode: &str, bypass_verified: bool) -> Result<AppLockConfig, String> {
    let mut guard = vault()
        .write()
        .map_err(|_| "应用锁配置写锁异常".to_string())?;
    if guard.app_lock.enabled && !bypass_verified {
        if !verify_passcode_against_config(&guard.app_lock, current_passcode) {
            return Err("当前应用密码不正确".to_string());
        }
    }
    guard.app_lock = AppLockConfig::default();
    persist_app_lock_locked(&guard)?;
    Ok(guard.app_lock.redacted_for_ui())
}

fn persist_app_lock_locked(vault: &HostVault) -> Result<(), String> {
    if let Some(ref path) = vault.app_lock_path {
        atomic_write_json(path, &vault.app_lock)?;
    }
    Ok(())
}

fn atomic_write_json<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let serialized =
        serde_json::to_string_pretty(value).map_err(|e| format!("序列化 JSON 失败: {e}"))?;
    let tmp_path = path.with_extension("json.tmp");
    fs::write(&tmp_path, serialized).map_err(|e| format!("写入文件失败: {e}"))?;
    fs::rename(&tmp_path, path).or_else(|_| {
        fs::copy(&tmp_path, path)
            .map(|_| {
                let _ = fs::remove_file(&tmp_path);
            })
            .map_err(|e| format!("保存文件失败: {e}"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::AuthMethod;

    #[test]
    fn host_crud_encrypts_secrets_on_disk_and_roundtrips() {
        let _guard = crate::vault_crypto::TEST_VAULT_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let temp_dir = std::env::temp_dir().join(format!("nexus_ssh_test_{}", Uuid::new_v4()));
        let initial = init_store(temp_dir.to_str().unwrap()).unwrap();
        let initial_len = initial.len();

        let created = upsert_host(HostProfile {
            name: "Prod Gateway".to_string(),
            host: "10.0.1.8".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            auth_method: AuthMethod::Password,
            password: "plain_secret_password_123".to_string(),
            group: "Production".to_string(),
            accent_hex: "#2AD882".to_string(),
            ..Default::default()
        })
        .unwrap();

        // Verify disk file does NOT contain plaintext password!
        let on_disk = fs::read_to_string(temp_dir.join("hosts_v1.json")).unwrap();
        assert!(!on_disk.contains("plain_secret_password_123"));
        assert!(on_disk.contains("enc:v1:"));

        // Verify UI-redacted list hides plaintext secret but reports `has_password == true`
        let redacted_list = list_hosts_redacted().unwrap();
        let redacted_host = redacted_list.iter().find(|h| h.id == created.id).unwrap();
        assert!(redacted_host.password.is_empty());
        assert!(redacted_host.has_password);

        // Verify editing the host with blank password preserves the stored secret!
        let mut renamed = redacted_host.clone();
        renamed.name = "Prod Gateway Renamed".to_string();
        upsert_host(renamed).unwrap();

        // Verify internal store still holds the preserved password
        let listed = list_hosts().unwrap();
        assert_eq!(listed.len(), initial_len + 1);
        let loaded = listed.iter().find(|h| h.id == created.id).unwrap();
        assert_eq!(loaded.name, "Prod Gateway Renamed");
        assert_eq!(loaded.password, "plain_secret_password_123");

        assert!(delete_host(&created.id).unwrap());
        for h in initial {
            assert!(delete_host(&h.id).unwrap());
        }
        assert!(list_hosts().unwrap().is_empty());

        // Verify WebDavConfig persists default_sync_mode, redacts secrets, and preserves blank updates
        let saved_dav = save_webdav_config(WebDavConfig {
            url: "https://dav.example.com/dav/".to_string(),
            username: "tester".to_string(),
            password: "dav_secret_password".to_string(),
            remote_path: "NexusSSH/hosts_sync.json".to_string(),
            encryption_password: "e2e_secret_password".to_string(),
            auto_sync: false,
            default_sync_mode: crate::models::SyncMode::PullOverwrite,
            ..Default::default()
        })
        .unwrap();
        assert_eq!(
            saved_dav.default_sync_mode,
            crate::models::SyncMode::PullOverwrite
        );
        assert!(!saved_dav.auto_sync);

        let redacted_dav = get_webdav_config_redacted().unwrap();
        assert!(redacted_dav.password.is_empty());
        assert!(redacted_dav.encryption_password.is_empty());
        assert!(redacted_dav.has_password);
        assert!(redacted_dav.has_encryption_password);

        // Updating with blank password preserves stored password
        let mut dav_edit = redacted_dav;
        dav_edit.auto_sync = true;
        save_webdav_config(dav_edit).unwrap();
        let full_dav = get_webdav_config().unwrap();
        assert_eq!(full_dav.password, "dav_secret_password");
        assert_eq!(full_dav.encryption_password, "e2e_secret_password");
        assert!(full_dav.auto_sync);

        // Reload store from disk and confirm default_sync_mode roundtrips
        let _ = init_store(temp_dir.to_str().unwrap()).unwrap();
        let reloaded_dav = get_webdav_config().unwrap();
        assert_eq!(
            reloaded_dav.default_sync_mode,
            crate::models::SyncMode::PullOverwrite
        );
        assert!(reloaded_dav.auto_sync);
        assert_eq!(reloaded_dav.password, "dav_secret_password");
        assert_eq!(reloaded_dav.encryption_password, "e2e_secret_password");

        // Verify App Lock PBKDF2 hash setup, redaction, verification, settings update, and disable
        assert!(!get_app_lock_config_redacted().unwrap().enabled);
        assert!(set_app_lock_passcode("123", true, true, 5).is_err());
        let lock_cfg = set_app_lock_passcode("2580", true, true, 1).unwrap();
        assert!(lock_cfg.enabled);
        assert!(lock_cfg.has_passcode);
        assert!(lock_cfg.hash_b64.is_empty());
        assert!(lock_cfg.salt_b64.is_empty());
        assert!(verify_app_lock_passcode("2580").unwrap());
        assert!(!verify_app_lock_passcode("0000").unwrap());
        let updated_lock = update_app_lock_settings(false, false, 15).unwrap();
        assert!(!updated_lock.biometrics_enabled);
        assert_eq!(updated_lock.auto_lock_minutes, 15);
        assert!(disable_app_lock("wrong", false).is_err());
        let disabled = disable_app_lock("2580", false).unwrap();
        assert!(!disabled.enabled);
        assert!(!disabled.has_passcode);

        let _ = fs::remove_dir_all(temp_dir);
    }
}
