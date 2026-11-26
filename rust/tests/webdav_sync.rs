use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use nexus_ssh_core::models::{AuthMethod, HostProfile, SyncMode, WebDavConfig};
use nexus_ssh_core::{ssh, store, webdav};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use uuid::Uuid;

#[test]
fn webdav_encrypted_bidirectional_merge_and_tombstone_sync() {
    let files: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let listener = ssh::runtime()
        .block_on(TcpListener::bind("127.0.0.1:0"))
        .expect("bind mock webdav");
    let port = listener.local_addr().unwrap().port();

    let expected_auth = format!("Basic {}", B64.encode("davuser:davpass123"));
    let files_srv = Arc::clone(&files);

    // Lightweight RFC-compliant WebDAV mock server (PROPFIND / MKCOL / GET / PUT)
    ssh::runtime().spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let store_ref = Arc::clone(&files_srv);
            let auth_header = expected_auth.clone();
            tokio::spawn(async move {
                let mut buf = Vec::with_capacity(8192);
                let mut chunk = [0u8; 4096];
                let mut header_end = None;
                let mut content_len = 0usize;

                loop {
                    let Ok(n) = socket.read(&mut chunk).await else {
                        return;
                    };
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if header_end.is_none() {
                        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                            let hdr_str = String::from_utf8_lossy(&buf[..pos]);
                            for line in hdr_str.lines() {
                                if let Some(rest) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                                    content_len = rest.trim().parse().unwrap_or(0);
                                }
                            }
                            header_end = Some(pos + 4);
                        }
                    }
                    if let Some(h_end) = header_end {
                        if buf.len() >= h_end + content_len {
                            break;
                        }
                    }
                }

                let Some(h_end) = header_end else { return };
                let hdr_str = String::from_utf8_lossy(&buf[..h_end]);
                let first_line = hdr_str.lines().next().unwrap_or("");
                let parts: Vec<&str> = first_line.split_whitespace().collect();
                if parts.len() < 2 {
                    return;
                }
                let method = parts[0];
                let path = parts[1];

                let authed = hdr_str
                    .lines()
                    .any(|l| l.eq_ignore_ascii_case(&format!("Authorization: {auth_header}")));
                if !authed {
                    let _ = socket
                        .write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        .await;
                    return;
                }

                match method {
                    "PROPFIND" => {
                        let _ = socket
                            .write_all(b"HTTP/1.1 207 Multi-Status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            .await;
                    }
                    "MKCOL" => {
                        let _ = socket
                            .write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            .await;
                    }
                    "PUT" => {
                        let body = String::from_utf8_lossy(&buf[h_end..h_end + content_len]).to_string();
                        store_ref.lock().unwrap().insert(path.to_string(), body);
                        let _ = socket
                            .write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            .await;
                    }
                    "GET" => {
                        let maybe = store_ref.lock().unwrap().get(path).cloned();
                        if let Some(body) = maybe {
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                body.len(),
                                body
                            );
                            let _ = socket.write_all(resp.as_bytes()).await;
                        } else {
                            let _ = socket
                                .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                                .await;
                        }
                    }
                    _ => {
                        let _ = socket
                            .write_all(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            .await;
                    }
                }
            });
        }
    });

    let dav_cfg = WebDavConfig {
        url: format!("http://127.0.0.1:{port}/dav/"),
        username: "davuser".to_string(),
        password: "davpass123".to_string(),
        remote_path: "NexusSSH/hosts_sync.json".to_string(),
        encryption_password: "e2ee-master-password".to_string(),
        auto_sync: true,
        default_sync_mode: SyncMode::Merge,
        ..Default::default()
    };

    // 1. Test PROPFIND probe
    let test_ok = webdav::test_connection_blocking(dav_cfg.clone());
    assert!(test_ok.ok, "PROPFIND failed: {}", test_ok.message);

    // 2. Device A initializes, adds Host A, and syncs to WebDAV
    let dir_a = std::env::temp_dir().join(format!("nexus_dav_a_{}", Uuid::new_v4()));
    let seeded_count = store::init_store(dir_a.to_str().unwrap()).unwrap().len();
    let host_a = store::upsert_host(HostProfile {
        name: "Prod-HK".to_string(),
        host: "198.51.100.10".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        auth_method: AuthMethod::Password,
        password: "pw-a".to_string(),
        group: "Prod".to_string(),
        accent_hex: "#2AD882".to_string(),
        ..Default::default()
    })
    .unwrap();

    let sync_a = webdav::sync_blocking(Some(dav_cfg.clone()), SyncMode::Merge).unwrap();
    assert_eq!(sync_a.total_hosts, seeded_count + 1);

    // Verify stored payload on WebDAV server is encrypted (no plaintext password or IP)
    let raw_cloud = files
        .lock()
        .unwrap()
        .get("/dav/NexusSSH/hosts_sync.json")
        .cloned()
        .expect("cloud file uploaded");
    assert!(!raw_cloud.contains("198.51.100.10"));
    assert!(!raw_cloud.contains("pw-a"));

    // 3. Device B (fresh install + new Host B) merges with WebDAV!
    let dir_b = std::env::temp_dir().join(format!("nexus_dav_b_{}", Uuid::new_v4()));
    store::init_store(dir_b.to_str().unwrap()).unwrap();
    store::upsert_host(HostProfile {
        name: "NAS-Home".to_string(),
        host: "192.168.1.99".to_string(),
        port: 2222,
        username: "admin".to_string(),
        auth_method: AuthMethod::Password,
        password: "pw-b".to_string(),
        group: "Home".to_string(),
        accent_hex: "#4CC2FF".to_string(),
        ..Default::default()
    })
    .unwrap();

    let sync_b = webdav::sync_blocking(Some(dav_cfg.clone()), SyncMode::Merge).unwrap();
    assert_eq!(sync_b.total_hosts, seeded_count + 2);

    // 4. Device B deletes Prod-HK and syncs tombstone; Device A syncs and sees Prod-HK deleted!
    store::delete_host(&host_a.id).unwrap();
    let sync_b2 = webdav::sync_blocking(Some(dav_cfg.clone()), SyncMode::Merge).unwrap();
    assert_eq!(sync_b2.total_hosts, seeded_count + 1);

    store::init_store(dir_a.to_str().unwrap()).unwrap();
    let sync_a2 = webdav::sync_blocking(Some(dav_cfg), SyncMode::Merge).unwrap();
    assert_eq!(sync_a2.total_hosts, seeded_count + 1);
    assert!(sync_a2.hosts.iter().any(|h| h.name == "NAS-Home"));
    assert!(!sync_a2.hosts.iter().any(|h| h.name == "Prod-HK"));

    let _ = std::fs::remove_dir_all(dir_a);
    let _ = std::fs::remove_dir_all(dir_b);
}
