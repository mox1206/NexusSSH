use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthMethod {
    Password,
    PrivateKey,
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostProfile {
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    pub username: String,
    #[serde(default = "default_auth_method")]
    pub auth_method: AuthMethod,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub private_key: String,
    #[serde(default)]
    pub private_key_path: String,
    #[serde(default)]
    pub private_key_label: String,
    #[serde(default)]
    pub passphrase: String,
    #[serde(default)]
    pub has_password: bool,
    #[serde(default)]
    pub has_private_key: bool,
    #[serde(default)]
    pub has_passphrase: bool,
    #[serde(default)]
    pub clear_passphrase: bool,
    #[serde(default)]
    pub jump_host_id: Option<String>,
    #[serde(default = "default_group")]
    pub group: String,
    #[serde(default = "default_accent")]
    pub accent_hex: String,
    #[serde(default)]
    pub created_at_ms: i64,
    #[serde(default)]
    pub updated_at_ms: i64,
    #[serde(default)]
    pub last_connected_ms: Option<i64>,
}

fn default_port() -> u16 {
    22
}

fn default_auth_method() -> AuthMethod {
    AuthMethod::Password
}

fn default_group() -> String {
    "Default".to_string()
}

fn default_accent() -> String {
    "#2AD882".to_string()
}

impl HostProfile {
    pub fn validate(&self) -> Result<(), String> {
        if self.host.trim().is_empty() {
            return Err("主机地址不能为空".to_string());
        }
        if self.port == 0 {
            return Err("端口号必须在 1 ~ 65535 之间".to_string());
        }
        if self.username.trim().is_empty() {
            return Err("用户名不能为空".to_string());
        }
        if self.auth_method == AuthMethod::PrivateKey
            && self.private_key.trim().is_empty()
            && self.private_key_path.trim().is_empty()
        {
            return Err("请选择私钥文件或粘贴私钥内容".to_string());
        }
        Ok(())
    }

    /// Resolves PEM/OpenSSH private key text from `private_key_path` (if set and readable)
    /// with fallback to embedded `private_key` content (used on mobile sandboxes or manual paste).
    pub fn resolve_private_key_pem(&self) -> Result<String, String> {
        let trimmed_path = self.private_key_path.trim();
        if !trimmed_path.is_empty() {
            let p = std::path::Path::new(trimmed_path);
            if p.is_file() {
                return std::fs::read_to_string(p)
                    .map_err(|e| format!("读取私钥文件失败 ({trimmed_path}): {e}"));
            }
            if !self.private_key.trim().is_empty() {
                return Ok(self.private_key.clone());
            }
            return Err(format!("找不到指定的私钥文件: {trimmed_path}"));
        }

        if !self.private_key.trim().is_empty() {
            return Ok(self.private_key.clone());
        }

        Err("请选择私钥文件或粘贴私钥内容".to_string())
    }

    /// Refreshes secret presence flags based on actual in-memory values.
    pub fn sync_secret_flags(&mut self) {
        self.has_password = !self.password.is_empty();
        self.has_private_key =
            !self.private_key.trim().is_empty() || !self.private_key_path.trim().is_empty();
        self.has_passphrase = !self.passphrase.is_empty();
        self.clear_passphrase = false;
    }

    /// Returns a UI-safe copy with all plaintext secrets stripped (write-only masking).
    pub fn redacted_for_ui(&self) -> Self {
        let mut copy = self.clone();
        copy.sync_secret_flags();
        copy.password.clear();
        copy.private_key.clear();
        copy.passphrase.clear();
        copy
    }
}

impl Default for HostProfile {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            host: String::new(),
            port: default_port(),
            username: String::new(),
            auth_method: default_auth_method(),
            password: String::new(),
            private_key: String::new(),
            private_key_path: String::new(),
            private_key_label: String::new(),
            passphrase: String::new(),
            has_password: false,
            has_private_key: false,
            has_passphrase: false,
            clear_passphrase: false,
            jump_host_id: None,
            group: default_group(),
            accent_hex: default_accent(),
            created_at_ms: 0,
            updated_at_ms: 0,
            last_connected_ms: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalShellOption {
    pub id: String,
    pub name: String,
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub is_default: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyInspectionResult {
    pub valid: bool,
    pub encrypted: bool,
    pub algorithm: Option<String>,
    pub fingerprint: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredSshKey {
    pub name: String,
    pub path: String,
    pub encrypted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebDavConfig {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    #[serde(default = "default_remote_path")]
    pub remote_path: String,
    #[serde(default)]
    pub encryption_password: String,
    #[serde(default)]
    pub has_password: bool,
    #[serde(default)]
    pub has_encryption_password: bool,
    #[serde(default)]
    pub clear_encryption_password: bool,
    #[serde(default)]
    pub auto_sync: bool,
    #[serde(default)]
    pub default_sync_mode: SyncMode,
    #[serde(default)]
    pub last_sync_ms: Option<i64>,
    #[serde(default)]
    pub last_sync_message: Option<String>,
}

fn default_remote_path() -> String {
    "NexusSSH/hosts_sync.json".to_string()
}

impl Default for WebDavConfig {
    fn default() -> Self {
        Self {
            url: String::new(),
            username: String::new(),
            password: String::new(),
            remote_path: default_remote_path(),
            encryption_password: String::new(),
            has_password: false,
            has_encryption_password: false,
            clear_encryption_password: false,
            auto_sync: false,
            default_sync_mode: SyncMode::Merge,
            last_sync_ms: None,
            last_sync_message: None,
        }
    }
}

impl WebDavConfig {
    pub fn is_configured(&self) -> bool {
        !self.url.trim().is_empty()
    }

    pub fn validate(&self) -> Result<(), String> {
        let u = self.url.trim();
        if u.is_empty() {
            return Err("请输入 WebDAV 服务器地址".to_string());
        }
        if !u.starts_with("http://") && !u.starts_with("https://") {
            return Err("WebDAV 地址需以 https:// 或 http:// 开头".to_string());
        }
        Ok(())
    }

    pub fn sync_secret_flags(&mut self) {
        self.has_password = !self.password.is_empty();
        self.has_encryption_password = !self.encryption_password.is_empty();
        self.clear_encryption_password = false;
    }

    /// Returns a UI-safe copy with WebDAV password and E2E encryption password stripped.
    pub fn redacted_for_ui(&self) -> Self {
        let mut copy = self.clone();
        copy.sync_secret_flags();
        copy.password.clear();
        copy.encryption_password.clear();
        copy
    }
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncMode {
    #[default]
    Merge,
    PushOverwrite,
    PullOverwrite,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnippetItem {
    #[serde(default)]
    pub id: String,
    pub title: String,
    pub command: String,
    #[serde(default = "default_snippet_category")]
    pub category: String,
    #[serde(default = "default_true")]
    pub auto_enter: bool,
    #[serde(default)]
    pub created_at_ms: i64,
    #[serde(default)]
    pub updated_at_ms: i64,
}

fn default_snippet_category() -> String {
    "常用".to_string()
}

fn default_true() -> bool {
    true
}

impl SnippetItem {
    pub fn validate(&self) -> Result<(), String> {
        if self.title.trim().is_empty() {
            return Err("片段标题不能为空".to_string());
        }
        if self.command.trim().is_empty() {
            return Err("命令内容不能为空".to_string());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppLockConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_true")]
    pub biometrics_enabled: bool,
    #[serde(default = "default_true")]
    pub lock_on_startup: bool,
    /// Minutes before auto-lock after backgrounding/tray: 0 = immediate, -1 = manual only
    #[serde(default = "default_auto_lock_minutes")]
    pub auto_lock_minutes: i32,
    #[serde(default)]
    pub has_passcode: bool,
    #[serde(default)]
    pub salt_b64: String,
    #[serde(default)]
    pub hash_b64: String,
}

fn default_auto_lock_minutes() -> i32 {
    5
}

impl Default for AppLockConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            biometrics_enabled: true,
            lock_on_startup: true,
            auto_lock_minutes: default_auto_lock_minutes(),
            has_passcode: false,
            salt_b64: String::new(),
            hash_b64: String::new(),
        }
    }
}

impl AppLockConfig {
    pub fn redacted_for_ui(&self) -> Self {
        let mut copy = self.clone();
        copy.has_passcode = !self.hash_b64.is_empty();
        copy.salt_b64.clear();
        copy.hash_b64.clear();
        copy
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KnownHostEntry {
    pub host_key: String, // "host:port"
    pub host: String,
    pub port: u16,
    pub algorithm: String,
    pub fingerprint: String,
    pub public_key_base64: String,
    pub trusted_at_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SftpEntry {
    pub name: String,
    pub path: String,
    pub kind: String, // "dir" | "file" | "symlink" | "other"
    pub size: u64,
    pub permissions_octal: u32,
    pub permissions_rwx: String,
    pub modified_sec: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SftpDirListing {
    pub current_path: String,
    pub entries: Vec<SftpEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskUsageItem {
    pub mount_point: String,
    pub filesystem: String,
    pub total_bytes: u64,
    pub used_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetInterfaceRate {
    pub interface: String,
    pub rx_bytes_per_sec: u64,
    pub tx_bytes_per_sec: u64,
    pub total_rx_bytes: u64,
    pub total_tx_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerMetrics {
    pub hostname: String,
    pub os_name: String,
    pub kernel: String,
    pub uptime_secs: u64,
    pub cpu_cores: u32,
    pub cpu_percent: f64,
    pub load_1: f64,
    pub load_5: f64,
    pub load_15: f64,
    pub mem_total_bytes: u64,
    pub mem_used_bytes: u64,
    pub swap_total_bytes: u64,
    pub swap_used_bytes: u64,
    pub disks: Vec<DiskUsageItem>,
    pub networks: Vec<NetInterfaceRate>,
    pub collected_at_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebDavSyncResult {
    pub ok: bool,
    pub total_hosts: usize,
    #[serde(default)]
    pub total_snippets: usize,
    pub synced_at_ms: i64,
    pub message: String,
    pub hosts: Vec<HostProfile>,
    #[serde(default)]
    pub snippets: Vec<SnippetItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QuickConnectTarget {
    pub username: String,
    pub host: String,
    pub port: u16,
    pub display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionTestResult {
    pub ok: bool,
    pub latency_ms: u64,
    pub server_fingerprint: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SessionStatusEvent {
    Connecting {
        session_id: String,
        message: String,
    },
    Connected {
        session_id: String,
        server_fingerprint: String,
        auth_used: String,
        latency_ms: u64,
    },
    Disconnected {
        session_id: String,
        exit_code: Option<u32>,
        reason: String,
    },
    Error {
        session_id: String,
        message: String,
    },
    VerifyHostKey {
        request_id: String,
        session_id: String,
        host: String,
        port: u16,
        algorithm: String,
        fingerprint: String,
        status: String, // "unknown" | "mismatch"
        previous_fingerprint: Option<String>,
    },
    SftpProgress {
        transfer_id: String,
        session_id: String,
        direction: String, // "upload" | "download"
        file_name: String,
        transferred_bytes: u64,
        total_bytes: u64,
        done: bool,
        error: Option<String>,
    },
}

#[derive(Debug, Serialize)]
pub struct ApiResponse<T: Serialize> {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl<T: Serialize> ApiResponse<T> {
    pub fn success(data: T) -> String {
        serde_json::to_string(&Self {
            ok: true,
            data: Some(data),
            error: None,
        })
        .unwrap_or_else(|e| format!(r#"{{"ok":false,"error":"Serialization error: {e}"}}"#))
    }

    pub fn err(msg: impl Into<String>) -> String {
        serde_json::to_string(&Self {
            ok: false,
            data: None,
            error: Some(msg.into()),
        })
        .unwrap_or_else(|_| r#"{"ok":false,"error":"Unknown error"}"#.to_string())
    }
}

/// Parses quick-connect expressions such as:
/// - `root@192.168.1.10`
/// - `ubuntu@example.com:2222`
/// - `ssh -p 2200 admin@10.0.0.5`
/// - `192.168.1.20` (defaults username to `root` and port to `22`)
pub fn parse_quick_connect(raw: &str) -> Result<QuickConnectTarget, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("请输入连接地址，例如 root@192.168.1.10:22".to_string());
    }

    let tokens: Vec<&str> = trimmed.split_whitespace().collect();
    let mut port: Option<u16> = None;
    let mut user_override: Option<String> = None;
    let mut target_token: Option<&str> = None;

    let mut idx = 0;
    while idx < tokens.len() {
        let tok = tokens[idx];
        if idx == 0 && tok.eq_ignore_ascii_case("ssh") {
            idx += 1;
            continue;
        }
        if tok == "-p" {
            let next = tokens
                .get(idx + 1)
                .ok_or_else(|| "参数 -p 后缺少端口号".to_string())?;
            let parsed = next
                .parse::<u16>()
                .map_err(|_| format!("无效端口号: {next}"))?;
            if parsed == 0 {
                return Err("端口号不能为 0".to_string());
            }
            port = Some(parsed);
            idx += 2;
            continue;
        }
        if let Some(p_str) = tok.strip_prefix("-p") {
            let parsed = p_str
                .parse::<u16>()
                .map_err(|_| format!("无效端口号: {p_str}"))?;
            if parsed == 0 {
                return Err("端口号不能为 0".to_string());
            }
            port = Some(parsed);
            idx += 1;
            continue;
        }
        if tok == "-l" {
            let next = tokens
                .get(idx + 1)
                .ok_or_else(|| "参数 -l 后缺少用户名".to_string())?;
            user_override = Some((*next).to_string());
            idx += 2;
            continue;
        }
        if tok.starts_with('-') {
            idx += 1;
            continue;
        }
        target_token = Some(tok);
        idx += 1;
    }

    let target = target_token.ok_or_else(|| "未识别到目标主机地址".to_string())?;
    let (parsed_user, host_port) = match target.rsplit_once('@') {
        Some((u, hp)) => {
            if u.trim().is_empty() {
                return Err("用户名不能为空".to_string());
            }
            (Some(u.trim().to_string()), hp)
        }
        None => (None, target),
    };

    let (host, inline_port) = split_host_and_port(host_port)?;
    if host.is_empty() {
        return Err("主机地址不能为空".to_string());
    }

    let final_user = user_override
        .or(parsed_user)
        .unwrap_or_else(|| "root".to_string());
    let final_port = port.or(inline_port).unwrap_or(22);
    let display_name = if final_port == 22 {
        format!("{final_user}@{host}")
    } else {
        format!("{final_user}@{host}:{final_port}")
    };

    Ok(QuickConnectTarget {
        username: final_user,
        host,
        port: final_port,
        display_name,
    })
}

fn split_host_and_port(input: &str) -> Result<(String, Option<u16>), String> {
    if let Some(rest) = input.strip_prefix('[') {
        // IPv6 bracket notation: [::1]:2222 or [::1]
        let (ipv6, after) = rest
            .split_once(']')
            .ok_or_else(|| "IPv6 地址缺少右括号 `]`".to_string())?;
        if after.is_empty() {
            return Ok((ipv6.to_string(), None));
        }
        if let Some(port_str) = after.strip_prefix(':') {
            let parsed = port_str
                .parse::<u16>()
                .map_err(|_| format!("无效端口号: {port_str}"))?;
            if parsed == 0 {
                return Err("端口号不能为 0".to_string());
            }
            return Ok((ipv6.to_string(), Some(parsed)));
        }
        return Err(format!("无效主机地址后缀: {after}"));
    }

    // Only split on `:` when there is a single colon (otherwise treat as unbracketed IPv6)
    let colon_count = input.chars().filter(|&c| c == ':').count();
    if colon_count == 1 {
        if let Some((h, p)) = input.rsplit_once(':') {
            let parsed = p
                .parse::<u16>()
                .map_err(|_| format!("无效端口号: {p}"))?;
            if parsed == 0 {
                return Err("端口号不能为 0".to_string());
            }
            return Ok((h.trim().to_string(), Some(parsed)));
        }
    }

    Ok((input.trim().to_string(), None))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_standard_user_host_port() {
        let parsed = parse_quick_connect("ubuntu@192.168.1.50:2222").unwrap();
        assert_eq!(parsed.username, "ubuntu");
        assert_eq!(parsed.host, "192.168.1.50");
        assert_eq!(parsed.port, 2222);
        assert_eq!(parsed.display_name, "ubuntu@192.168.1.50:2222");
    }

    #[test]
    fn parses_ssh_command_syntax() {
        let parsed = parse_quick_connect("ssh -p 22022 deploy@prod.example.com").unwrap();
        assert_eq!(parsed.username, "deploy");
        assert_eq!(parsed.host, "prod.example.com");
        assert_eq!(parsed.port, 22022);
    }

    #[test]
    fn parses_bare_host_with_defaults() {
        let parsed = parse_quick_connect("10.0.0.12").unwrap();
        assert_eq!(parsed.username, "root");
        assert_eq!(parsed.host, "10.0.0.12");
        assert_eq!(parsed.port, 22);
    }

    #[test]
    fn parses_bracketed_ipv6() {
        let parsed = parse_quick_connect("admin@[fe80::1]:2222").unwrap();
        assert_eq!(parsed.username, "admin");
        assert_eq!(parsed.host, "fe80::1");
        assert_eq!(parsed.port, 2222);
    }
}
