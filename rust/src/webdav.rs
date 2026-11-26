use std::sync::OnceLock;
use std::time::{Duration, Instant};

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use pbkdf2::pbkdf2_hmac;
use rand::RngCore;
use reqwest::{Client, Method, RequestBuilder, StatusCode};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::models::{ConnectionTestResult, SyncMode, WebDavConfig, WebDavSyncResult};
use crate::ssh;
use crate::store::{self, SyncSnapshot};

const PBKDF2_ROUNDS: u32 = 100_000;

static RUSTLS_INIT: OnceLock<()> = OnceLock::new();

fn ensure_tls_provider() {
    RUSTLS_INIT.get_or_init(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

#[derive(Debug, Serialize, Deserialize)]
struct CloudSyncEnvelope {
    version: u32,
    encrypted: bool,
    updated_at_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    salt_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    nonce_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ciphertext_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    snapshot: Option<SyncSnapshot>,
}

struct WebDavEndpoints {
    probe_url: String,
    collection_urls: Vec<String>,
    file_url: String,
}

fn resolve_endpoints(config: &WebDavConfig) -> Result<WebDavEndpoints, String> {
    config.validate()?;
    let raw_url = config.url.trim();

    if raw_url.to_ascii_lowercase().ends_with(".json") {
        let probe_url = match raw_url.rsplit_once('/') {
            Some((parent, _)) => format!("{parent}/"),
            None => raw_url.to_string(),
        };
        return Ok(WebDavEndpoints {
            probe_url,
            collection_urls: Vec::new(),
            file_url: raw_url.to_string(),
        });
    }

    let base = raw_url.trim_end_matches('/');
    let rel = config.remote_path.trim().trim_matches('/');
    let rel_path = if rel.is_empty() {
        "NexusSSH/hosts_sync.json"
    } else {
        rel
    };

    let segments: Vec<&str> = rel_path.split('/').filter(|s| !s.is_empty()).collect();
    if segments.is_empty() {
        return Err("无效的远程文件路径".to_string());
    }

    let mut collection_urls = Vec::new();
    let mut accum = base.to_string();
    for dir_seg in &segments[..segments.len() - 1] {
        accum.push('/');
        accum.push_str(dir_seg);
        collection_urls.push(format!("{accum}/"));
    }

    let file_url = format!("{base}/{rel_path}");
    Ok(WebDavEndpoints {
        probe_url: format!("{base}/"),
        collection_urls,
        file_url,
    })
}

fn build_http_client(timeout_secs: u64) -> Result<Client, String> {
    ensure_tls_provider();
    Client::builder()
        .timeout(Duration::from_secs(timeout_secs.clamp(5, 60)))
        .user_agent("NexusSSH-WebDAV/0.1")
        .build()
        .map_err(|e| format!("初始化 HTTP 客户端失败: {e}"))
}

fn apply_auth(req: RequestBuilder, config: &WebDavConfig) -> RequestBuilder {
    if config.username.trim().is_empty() && config.password.is_empty() {
        req
    } else {
        req.basic_auth(config.username.trim(), Some(&config.password))
    }
}

fn derive_aes_key(password: &str, salt: &[u8]) -> [u8; 32] {
    let mut key = [0u8; 32];
    pbkdf2_hmac::<Sha256>(password.as_bytes(), salt, PBKDF2_ROUNDS, &mut key);
    key
}

fn encode_envelope(snapshot: &SyncSnapshot, encryption_password: &str) -> Result<String, String> {
    let updated_at_ms = store::now_ms();
    if encryption_password.is_empty() {
        let env = CloudSyncEnvelope {
            version: 1,
            encrypted: false,
            updated_at_ms,
            salt_b64: None,
            nonce_b64: None,
            ciphertext_b64: None,
            snapshot: Some(snapshot.clone()),
        };
        return serde_json::to_string_pretty(&env)
            .map_err(|e| format!("序列化同步数据失败: {e}"));
    }

    let plain_bytes =
        serde_json::to_vec(snapshot).map_err(|e| format!("序列化主机快照失败: {e}"))?;
    let mut salt = [0u8; 16];
    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut salt);
    rand::thread_rng().fill_bytes(&mut nonce_bytes);

    let key_bytes = derive_aes_key(encryption_password, &salt);
    let cipher =
        Aes256Gcm::new_from_slice(&key_bytes).map_err(|e| format!("初始化加密器失败: {e}"))?;
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), plain_bytes.as_ref())
        .map_err(|_| "加密同步数据失败".to_string())?;

    let env = CloudSyncEnvelope {
        version: 1,
        encrypted: true,
        updated_at_ms,
        salt_b64: Some(B64.encode(salt)),
        nonce_b64: Some(B64.encode(nonce_bytes)),
        ciphertext_b64: Some(B64.encode(ciphertext)),
        snapshot: None,
    };
    serde_json::to_string_pretty(&env).map_err(|e| format!("序列化加密信封失败: {e}"))
}

fn decode_envelope(raw: &str, encryption_password: &str) -> Result<SyncSnapshot, String> {
    let env: CloudSyncEnvelope =
        serde_json::from_str(raw).map_err(|e| format!("云端同步文件格式无效: {e}"))?;

    if !env.encrypted {
        return Ok(env.snapshot.unwrap_or_default());
    }

    if encryption_password.is_empty() {
        return Err("云端同步文件已启用端到端加密，请输入「同步加密口令」".to_string());
    }

    let salt = B64
        .decode(env.salt_b64.as_deref().unwrap_or_default())
        .map_err(|_| "云端加密盐值损坏".to_string())?;
    let nonce_bytes = B64
        .decode(env.nonce_b64.as_deref().unwrap_or_default())
        .map_err(|_| "云端加密 Nonce 损坏".to_string())?;
    if nonce_bytes.len() != 12 {
        return Err("云端加密 Nonce 长度异常".to_string());
    }
    let ciphertext = B64
        .decode(env.ciphertext_b64.as_deref().unwrap_or_default())
        .map_err(|_| "云端密文数据损坏".to_string())?;

    let key_bytes = derive_aes_key(encryption_password, &salt);
    let cipher =
        Aes256Gcm::new_from_slice(&key_bytes).map_err(|e| format!("初始化解密器失败: {e}"))?;
    let plain = cipher
        .decrypt(Nonce::from_slice(&nonce_bytes), ciphertext.as_ref())
        .map_err(|_| "解密失败：同步加密口令不正确".to_string())?;

    serde_json::from_slice::<SyncSnapshot>(&plain)
        .map_err(|e| format!("解析解密后的主机配置失败: {e}"))
}

pub fn test_connection_blocking(mut config: WebDavConfig) -> ConnectionTestResult {
    store::hydrate_webdav_secrets(&mut config);
    ssh::runtime().block_on(async move {
        let endpoints = match resolve_endpoints(&config) {
            Ok(ep) => ep,
            Err(e) => {
                return ConnectionTestResult {
                    ok: false,
                    latency_ms: 0,
                    server_fingerprint: None,
                    message: e,
                }
            }
        };

        let client = match build_http_client(12) {
            Ok(c) => c,
            Err(e) => {
                return ConnectionTestResult {
                    ok: false,
                    latency_ms: 0,
                    server_fingerprint: None,
                    message: e,
                }
            }
        };

        let propfind = Method::from_bytes(b"PROPFIND").unwrap_or(Method::GET);
        let started = Instant::now();
        let req = apply_auth(
            client
                .request(propfind, &endpoints.probe_url)
                .header("Depth", "0"),
            &config,
        );

        match req.send().await {
            Ok(resp) => {
                let latency_ms = started.elapsed().as_millis() as u64;
                let status = resp.status();
                if status.is_success() || status.as_u16() == 207 {
                    ConnectionTestResult {
                        ok: true,
                        latency_ms,
                        server_fingerprint: None,
                        message: format!("WebDAV 连接成功 ({}) · {latency_ms} ms", status.as_u16()),
                    }
                } else if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
                    ConnectionTestResult {
                        ok: false,
                        latency_ms,
                        server_fingerprint: None,
                        message: format!(
                            "认证失败 ({})：请检查用户名或应用授权密码（如坚果云需使用第三方应用密码）",
                            status.as_u16()
                        ),
                    }
                } else if status == StatusCode::NOT_FOUND {
                    ConnectionTestResult {
                        ok: false,
                        latency_ms,
                        server_fingerprint: None,
                        message: format!("目录不存在 (404)：请检查 WebDAV 根地址是否正确 ({})", endpoints.probe_url),
                    }
                } else {
                    ConnectionTestResult {
                        ok: false,
                        latency_ms,
                        server_fingerprint: None,
                        message: format!("服务器返回状态码 {}", status),
                    }
                }
            }
            Err(e) => ConnectionTestResult {
                ok: false,
                latency_ms: 0,
                server_fingerprint: None,
                message: format!("连接 WebDAV 服务器失败: {e}"),
            },
        }
    })
}

pub fn sync_blocking(config: Option<WebDavConfig>, mode: SyncMode) -> Result<WebDavSyncResult, String> {
    let active_cfg = match config {
        Some(cfg) => store::save_webdav_config(cfg)?,
        None => store::get_webdav_config()?,
    };
    active_cfg.validate()?;

    ssh::runtime().block_on(async move {
        let endpoints = resolve_endpoints(&active_cfg)?;
        let client = build_http_client(20)?;

        match mode {
            SyncMode::PushOverwrite => {
                let local_snapshot = store::export_local_snapshot()?;
                ensure_remote_collections(&client, &active_cfg, &endpoints.collection_urls).await?;
                upload_snapshot(&client, &active_cfg, &endpoints.file_url, &local_snapshot).await?;

                let hosts = store::list_hosts()?;
                let snippets = store::list_snippets()?;
                let ts = store::now_ms();
                let msg = format!(
                    "已上传覆盖云端（{} 台主机 · {} 条片段）",
                    hosts.len(),
                    snippets.len()
                );
                store::record_webdav_sync_status(ts, msg.clone());
                Ok(WebDavSyncResult {
                    ok: true,
                    total_hosts: hosts.len(),
                    total_snippets: snippets.len(),
                    synced_at_ms: ts,
                    message: msg,
                    hosts,
                    snippets,
                })
            }
            SyncMode::PullOverwrite => {
                let Some(remote_snapshot) =
                    download_snapshot(&client, &active_cfg, &endpoints.file_url).await?
                else {
                    return Err("云端尚未找到同步配置文件，请先执行一次「立即同步」或「上传」".to_string());
                };
                let (hosts, snippets) = store::replace_with_snapshot(remote_snapshot)?;
                let ts = store::now_ms();
                let msg = format!(
                    "已从云端拉取覆盖本地（{} 台主机 · {} 条片段）",
                    hosts.len(),
                    snippets.len()
                );
                store::record_webdav_sync_status(ts, msg.clone());
                Ok(WebDavSyncResult {
                    ok: true,
                    total_hosts: hosts.len(),
                    total_snippets: snippets.len(),
                    synced_at_ms: ts,
                    message: msg,
                    hosts,
                    snippets,
                })
            }
            SyncMode::Merge => {
                let remote_opt =
                    download_snapshot(&client, &active_cfg, &endpoints.file_url).await?;
                let (merged_snapshot, hosts, snippets) = match remote_opt {
                    Some(remote_snapshot) => store::merge_with_remote_snapshot(remote_snapshot)?,
                    None => {
                        let snap = store::export_local_snapshot()?;
                        let listed_h = store::list_hosts()?;
                        let listed_s = store::list_snippets()?;
                        (snap, listed_h, listed_s)
                    }
                };

                ensure_remote_collections(&client, &active_cfg, &endpoints.collection_urls).await?;
                upload_snapshot(&client, &active_cfg, &endpoints.file_url, &merged_snapshot)
                    .await?;

                let ts = store::now_ms();
                let msg = format!(
                    "WebDAV 同步完成（{} 台主机 · {} 条片段）",
                    hosts.len(),
                    snippets.len()
                );
                store::record_webdav_sync_status(ts, msg.clone());
                Ok(WebDavSyncResult {
                    ok: true,
                    total_hosts: hosts.len(),
                    total_snippets: snippets.len(),
                    synced_at_ms: ts,
                    message: msg,
                    hosts,
                    snippets,
                })
            }
        }
    })
}

async fn ensure_remote_collections(
    client: &Client,
    config: &WebDavConfig,
    collection_urls: &[String],
) -> Result<(), String> {
    let mkcol = Method::from_bytes(b"MKCOL").map_err(|e| e.to_string())?;
    for dir_url in collection_urls {
        let resp = apply_auth(client.request(mkcol.clone(), dir_url), config)
            .send()
            .await
            .map_err(|e| format!("创建远程目录失败 ({dir_url}): {e}"))?;
        let code = resp.status().as_u16();
        // RFC 4918: 201 Created, or 405 / 301 / 200 / 409 if collection already exists
        if code == 401 || code == 403 {
            return Err(format!("WebDAV 权限不足 ({code})：请检查账号密码或目录写权限"));
        }
    }
    Ok(())
}

async fn download_snapshot(
    client: &Client,
    config: &WebDavConfig,
    file_url: &str,
) -> Result<Option<SyncSnapshot>, String> {
    let resp = apply_auth(client.get(file_url), config)
        .send()
        .await
        .map_err(|e| format!("下载云端配置失败: {e}"))?;

    let status = resp.status();
    if status == StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
        return Err(format!("WebDAV 认证被拒绝 ({})", status.as_u16()));
    }
    if !status.is_success() {
        return Err(format!("读取云端配置失败，HTTP 状态码: {status}"));
    }

    let body = resp
        .text()
        .await
        .map_err(|e| format!("读取响应内容失败: {e}"))?;
    if body.trim().is_empty() {
        return Ok(None);
    }
    let snapshot = decode_envelope(&body, &config.encryption_password)?;
    Ok(Some(snapshot))
}

async fn upload_snapshot(
    client: &Client,
    config: &WebDavConfig,
    file_url: &str,
    snapshot: &SyncSnapshot,
) -> Result<(), String> {
    let payload = encode_envelope(snapshot, &config.encryption_password)?;
    let resp = apply_auth(
        client
            .put(file_url)
            .header("Content-Type", "application/json; charset=utf-8")
            .body(payload),
        config,
    )
    .send()
    .await
    .map_err(|e| format!("上传配置到 WebDAV 失败: {e}"))?;

    let status = resp.status();
    if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
        return Err(format!("上传被拒绝 ({})：请检查账号密码或写入权限", status.as_u16()));
    }
    if !status.is_success() {
        return Err(format!("上传失败，WebDAV 返回状态码: {status}"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AuthMethod, HostProfile};
    use std::collections::HashMap;

    #[test]
    fn encrypted_envelope_roundtrip_and_wrong_password_rejected() {
        let snap = SyncSnapshot {
            hosts: vec![HostProfile {
                id: "h1".to_string(),
                name: "Test".to_string(),
                host: "10.0.0.1".to_string(),
                port: 22,
                username: "root".to_string(),
                auth_method: AuthMethod::Password,
                password: "top_secret_pw".to_string(),
                group: "Default".to_string(),
                accent_hex: "#2AD882".to_string(),
                created_at_ms: 100,
                updated_at_ms: 200,
                ..Default::default()
            }],
            deleted_tombstones: HashMap::new(),
            snippets: Vec::new(),
            deleted_snippet_tombstones: HashMap::new(),
        };

        let encoded = encode_envelope(&snap, "my-sync-pass!").unwrap();
        assert!(!encoded.contains("top_secret_pw"));

        let err = decode_envelope(&encoded, "wrong-pass").unwrap_err();
        assert!(err.contains("口令不正确"));

        let decoded = decode_envelope(&encoded, "my-sync-pass!").unwrap();
        assert_eq!(decoded.hosts.len(), 1);
        assert_eq!(decoded.hosts[0].password, "top_secret_pw");
    }
}
