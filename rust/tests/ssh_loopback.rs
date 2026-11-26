use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use async_trait::async_trait;
use nexus_ssh_core::models::{AuthMethod, HostProfile, SessionStatusEvent};
use nexus_ssh_core::ssh;
use russh::server::{self, Auth, Msg, Session};
use russh::{Channel, ChannelId, CryptoVec, Pty};
use russh_keys::ssh_key::rand_core::OsRng;
use russh_keys::{Algorithm, PrivateKey};
use tokio::net::TcpListener;

struct EchoSshHandler;

#[async_trait]
impl server::Handler for EchoSshHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == "tester" && password == "s3cr3t!" {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
            })
        }
    }

    async fn auth_publickey(
        &mut self,
        user: &str,
        _public_key: &russh_keys::PublicKey,
    ) -> Result<Auth, Self::Error> {
        if user == "keyuser" {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
            })
        }
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _term: &str,
        _col_width: u32,
        _row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        session.data(channel, CryptoVec::from_slice(b"NEXUS_READY$ "))?;
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        channel: ChannelId,
        col_width: u32,
        row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let msg = format!("[RESIZE:{col_width}x{row_height}]");
        session.data(channel, CryptoVec::from_slice(msg.as_bytes()))?;
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let mut reply = b"ECHO:".to_vec();
        reply.extend_from_slice(data);
        session.data(channel, CryptoVec::from_slice(&reply))?;
        Ok(())
    }
}

static CAPTURED_OUTPUT: OnceLock<Mutex<Vec<u8>>> = OnceLock::new();
static CAPTURED_EVENTS: OnceLock<Mutex<Vec<SessionStatusEvent>>> = OnceLock::new();

fn on_test_output(_sid: &str, bytes: &[u8]) {
    if let Ok(mut buf) = CAPTURED_OUTPUT.get_or_init(|| Mutex::new(Vec::new())).lock() {
        buf.extend_from_slice(bytes);
    }
}

fn on_test_status(ev: SessionStatusEvent) {
    if let Ok(mut list) = CAPTURED_EVENTS.get_or_init(|| Mutex::new(Vec::new())).lock() {
        list.push(ev);
    }
}

#[test]
fn end_to_end_ssh_handshake_pty_echo_and_resize() {
    let listener = ssh::runtime()
        .block_on(TcpListener::bind("127.0.0.1:0"))
        .expect("bind loopback");
    let port = listener.local_addr().unwrap().port();

    let host_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).expect("generate ed25519");
    let mut server_cfg = server::Config::default();
    server_cfg.auth_rejection_time = Duration::from_millis(20);
    server_cfg.keys.push(host_key);
    let server_cfg = Arc::new(server_cfg);

    ssh::runtime().spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let cfg = Arc::clone(&server_cfg);
            tokio::spawn(async move {
                if let Ok(session) = server::run_stream(cfg, stream, EchoSshHandler).await {
                    let _ = session.await;
                }
            });
        }
    });

    let profile = HostProfile {
        name: "Loopback".to_string(),
        host: "127.0.0.1".to_string(),
        port,
        username: "tester".to_string(),
        auth_method: AuthMethod::Password,
        password: "s3cr3t!".to_string(),
        group: "Test".to_string(),
        accent_hex: "#10B981".to_string(),
        ..Default::default()
    };

    // 1. Verify connection tester
    let probe = ssh::test_connection_blocking(profile.clone(), 5);
    assert!(probe.ok, "probe failed: {}", probe.message);
    assert!(probe
        .server_fingerprint
        .as_deref()
        .unwrap_or_default()
        .starts_with("SHA256:"));

    // 2. Verify interactive PTY session streaming, write, resize, and disconnect
    ssh::register_sinks(on_test_output, on_test_status, false);
    ssh::start_session("loopback_sess".to_string(), profile, 80, 24).expect("start session");

    // Wait for shell greeting
    for _ in 0..50 {
        let text = {
            let guard = CAPTURED_OUTPUT.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap();
            String::from_utf8_lossy(&guard).to_string()
        };
        if text.contains("NEXUS_READY$") {
            break;
        }
        std::thread::sleep(Duration::from_millis(40));
    }

    ssh::write_to_session("loopback_sess", b"uname -a\n").expect("write command");
    ssh::resize_session("loopback_sess", 132, 42, 0, 0).expect("resize pty");

    let mut final_output = String::new();
    for _ in 0..50 {
        final_output = {
            let guard = CAPTURED_OUTPUT.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap();
            String::from_utf8_lossy(&guard).to_string()
        };
        if final_output.contains("ECHO:uname -a") && final_output.contains("[RESIZE:132x42]") {
            break;
        }
        std::thread::sleep(Duration::from_millis(40));
    }

    assert!(
        final_output.contains("NEXUS_READY$"),
        "missing prompt in: {final_output}"
    );
    assert!(
        final_output.contains("ECHO:uname -a"),
        "missing echo in: {final_output}"
    );
    assert!(
        final_output.contains("[RESIZE:132x42]"),
        "missing resize confirmation in: {final_output}"
    );

    ssh::disconnect_session("loopback_sess").expect("disconnect");

    // 3. Verify file-based SSH PrivateKey authentication (private_key_path on disk, empty private_key text)
    let client_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).expect("gen client key");
    let openssh_pem = client_key
        .to_openssh(russh_keys::ssh_key::LineEnding::LF)
        .expect("encode openssh")
        .to_string();
    let key_file_path = std::env::temp_dir().join(format!(
        "nexus_test_id_ed25519_{}",
        std::process::id()
    ));
    std::fs::write(&key_file_path, &openssh_pem).expect("write temp key file");

    let inspect_ok = ssh::inspect_private_key("", key_file_path.to_str().unwrap(), "");
    assert!(inspect_ok.valid, "expected valid key file: {:?}", inspect_ok);
    assert_eq!(inspect_ok.algorithm.as_deref(), Some("ssh-ed25519"));

    let pub_warn = ssh::inspect_private_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test@host", "", "");
    assert!(!pub_warn.valid);
    assert!(pub_warn.message.contains(".pub"));

    let key_profile = HostProfile {
        name: "KeyFileHost".to_string(),
        host: "127.0.0.1".to_string(),
        port,
        username: "keyuser".to_string(),
        auth_method: AuthMethod::PrivateKey,
        private_key_path: key_file_path.to_str().unwrap().to_string(),
        private_key_label: "id_ed25519".to_string(),
        group: "Test".to_string(),
        accent_hex: "#2AD882".to_string(),
        ..Default::default()
    };
    let key_probe = ssh::test_connection_blocking(key_profile, 5);
    let _ = std::fs::remove_file(&key_file_path);
    assert!(key_probe.ok, "file-based key auth failed: {}", key_probe.message);
}

struct TailscaleLikeNoneAuthHandler;

#[async_trait]
impl server::Handler for TailscaleLikeNoneAuthHandler {
    type Error = russh::Error;

    async fn auth_none(&mut self, _user: &str) -> Result<Auth, Self::Error> {
        Ok(Auth::Accept)
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _term: &str,
        _col_width: u32,
        _row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        session.data(
            channel,
            CryptoVec::from_slice(
                b"# Tailscale SSH requires an additional check.\r\n# To authenticate, visit: https://login.tailscale.com/a/testcheck123\r\n",
            ),
        )?;
        Ok(())
    }
}

struct TailscaleServerFactory;

impl server::Server for TailscaleServerFactory {
    type Handler = TailscaleLikeNoneAuthHandler;

    fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self::Handler {
        TailscaleLikeNoneAuthHandler
    }
}

#[test]
fn tailscale_style_none_auth_works_for_both_none_and_private_key_profiles() {
    let host_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).expect("gen host key");
    let mut srv_cfg = server::Config::default();
    srv_cfg.keys.push(host_key);
    let srv_cfg = Arc::new(srv_cfg);

    let port = ssh::runtime().block_on(async move {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let mut factory = TailscaleServerFactory;
            loop {
                if let Ok((stream, addr)) = listener.accept().await {
                    let handler = server::Server::new_client(&mut factory, Some(addr));
                    let cfg = Arc::clone(&srv_cfg);
                    tokio::spawn(async move {
                        let _ = server::run_stream(cfg, stream, handler).await;
                    });
                }
            }
        });
        port
    });

    // 1. Explicit AuthMethod::None succeeds immediately
    let none_profile = HostProfile {
        name: "Tailscale None".to_string(),
        host: "127.0.0.1".to_string(),
        port,
        username: "ubuntu".to_string(),
        auth_method: AuthMethod::None,
        ..Default::default()
    };
    let probe1 = ssh::test_connection_blocking(none_profile, 5);
    assert!(probe1.ok, "none auth failed: {}", probe1.message);

    // 2. Existing host profile that still has a PrivateKey configured ALSO succeeds
    // via `none` probe first (no more `Channel send error`!)
    let dummy_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).expect("gen dummy key");
    let dummy_pem = dummy_key
        .to_openssh(russh_keys::ssh_key::LineEnding::LF)
        .unwrap()
        .to_string();
    let legacy_key_profile = HostProfile {
        name: "Tailscale Legacy Key".to_string(),
        host: "127.0.0.1".to_string(),
        port,
        username: "ubuntu".to_string(),
        auth_method: AuthMethod::PrivateKey,
        private_key: dummy_pem,
        ..Default::default()
    };
    let probe2 = ssh::test_connection_blocking(legacy_key_profile, 5);
    assert!(probe2.ok, "tailscale none fallback with legacy key failed: {}", probe2.message);
}

struct BastionTcpipHandler {
    forward_hits: Arc<std::sync::atomic::AtomicUsize>,
}

#[async_trait]
impl server::Handler for BastionTcpipHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == "bastion" && password == "jump-pass!" {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
            })
        }
    }

    async fn channel_open_direct_tcpip(
        &mut self,
        channel: Channel<Msg>,
        host_to_connect: &str,
        port_to_connect: u32,
        _originator_address: &str,
        _originator_port: u32,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        let mut upstream =
            tokio::net::TcpStream::connect((host_to_connect, port_to_connect as u16))
                .await
                .map_err(|_| russh::Error::Disconnect)?;
        self.forward_hits
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        tokio::spawn(async move {
            let mut ch_stream = channel.into_stream();
            let _ = tokio::io::copy_bidirectional(&mut ch_stream, &mut upstream).await;
        });
        Ok(true)
    }
}

struct BastionServerFactory {
    forward_hits: Arc<std::sync::atomic::AtomicUsize>,
}

impl server::Server for BastionServerFactory {
    type Handler = BastionTcpipHandler;

    fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self::Handler {
        BastionTcpipHandler {
            forward_hits: Arc::clone(&self.forward_hits),
        }
    }
}

struct NoDirectTcpipBastionHandler {
    target_port: u16,
    stdio_hits: Arc<std::sync::atomic::AtomicUsize>,
    channels: std::collections::HashMap<ChannelId, Channel<Msg>>,
}

#[async_trait]
impl server::Handler for NoDirectTcpipBastionHandler {
    type Error = russh::Error;

    async fn auth_none(&mut self, _user: &str) -> Result<Auth, Self::Error> {
        Ok(Auth::Accept)
    }

    async fn channel_open_direct_tcpip(
        &mut self,
        _channel: Channel<Msg>,
        _host_to_connect: &str,
        _port_to_connect: u32,
        _originator_address: &str,
        _originator_port: u32,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        // Simulate Tailscale SSH / `AllowTcpForwarding no` rejecting direct-tcpip
        Ok(false)
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<Msg>,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        self.channels.insert(channel.id(), channel);
        Ok(true)
    }

    async fn exec_request(
        &mut self,
        channel_id: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let cmd = String::from_utf8_lossy(data);
        assert!(
            cmd.contains(&format!("127.0.0.1' {}", self.target_port)),
            "unexpected stdio forwarder command: {cmd}"
        );
        let Some(channel) = self.channels.remove(&channel_id) else {
            return Err(russh::Error::Disconnect);
        };
        let mut upstream = tokio::net::TcpStream::connect(("127.0.0.1", self.target_port))
            .await
            .map_err(|_| russh::Error::Disconnect)?;
        self.stdio_hits
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        session.channel_success(channel_id)?;
        tokio::spawn(async move {
            let mut ch_stream = channel.into_stream();
            let _ = tokio::io::copy_bidirectional(&mut ch_stream, &mut upstream).await;
        });
        Ok(())
    }
}

#[test]
fn proxy_jump_direct_tcpip_tunnel_and_cycle_guard() {
    let temp_dir = std::env::temp_dir().join(format!(
        "nexus_proxyjump_test_{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&temp_dir);
    nexus_ssh_core::store::init_store(temp_dir.to_str().unwrap()).expect("init temp store");

    let forward_hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let hits_for_srv = Arc::clone(&forward_hits);
    let stdio_hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let stdio_hits_for_srv = Arc::clone(&stdio_hits);

    let (bastion_port, tailscale_bastion_port, target_port) = ssh::runtime().block_on(async move {
        // 1. Target SSH server (accepts tester / s3cr3t!)
        let target_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).unwrap();
        let mut target_cfg = server::Config::default();
        target_cfg.keys.push(target_key);
        let target_cfg = Arc::new(target_cfg);
        let target_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target_port = target_listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((stream, _)) = target_listener.accept().await {
                let cfg = Arc::clone(&target_cfg);
                tokio::spawn(async move {
                    if let Ok(session) = server::run_stream(cfg, stream, EchoSshHandler).await {
                        let _ = session.await;
                    }
                });
            }
        });

        // 2. Standard Bastion SSH server (accepts bastion / jump-pass!, forwards direct-tcpip)
        let bastion_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).unwrap();
        let mut bastion_cfg = server::Config::default();
        bastion_cfg.auth_rejection_time = Duration::from_millis(20);
        bastion_cfg.keys.push(bastion_key);
        let bastion_cfg = Arc::new(bastion_cfg);
        let bastion_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let bastion_port = bastion_listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let mut factory = BastionServerFactory {
                forward_hits: hits_for_srv,
            };
            while let Ok((stream, addr)) = bastion_listener.accept().await {
                let handler = server::Server::new_client(&mut factory, Some(addr));
                let cfg = Arc::clone(&bastion_cfg);
                tokio::spawn(async move {
                    if let Ok(session) = server::run_stream(cfg, stream, handler).await {
                        let _ = session.await;
                    }
                });
            }
        });

        // 3. Tailscale-style Bastion (none auth, rejects direct-tcpip, allows exec stdio forward)
        let ts_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).unwrap();
        let mut ts_cfg = server::Config::default();
        ts_cfg.keys.push(ts_key);
        let ts_cfg = Arc::new(ts_cfg);
        let ts_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let ts_port = ts_listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((stream, _)) = ts_listener.accept().await {
                let handler = NoDirectTcpipBastionHandler {
                    target_port,
                    stdio_hits: Arc::clone(&stdio_hits_for_srv),
                    channels: std::collections::HashMap::new(),
                };
                let cfg = Arc::clone(&ts_cfg);
                tokio::spawn(async move {
                    if let Ok(session) = server::run_stream(cfg, stream, handler).await {
                        let _ = session.await;
                    }
                });
            }
        });

        (bastion_port, ts_port, target_port)
    });

    // Save bastion & target (pointing jump_host_id -> bastion.id) into vault
    let bastion = nexus_ssh_core::store::upsert_host(HostProfile {
        name: "Edge Bastion".to_string(),
        host: "127.0.0.1".to_string(),
        port: bastion_port,
        username: "bastion".to_string(),
        auth_method: AuthMethod::Password,
        password: "jump-pass!".to_string(),
        ..Default::default()
    })
    .expect("save bastion");

    let target = nexus_ssh_core::store::upsert_host(HostProfile {
        name: "Internal App".to_string(),
        host: "127.0.0.1".to_string(),
        port: target_port,
        username: "tester".to_string(),
        auth_method: AuthMethod::Password,
        password: "s3cr3t!".to_string(),
        jump_host_id: Some(bastion.id.clone()),
        ..Default::default()
    })
    .expect("save target with ProxyJump");

    // Verify cycle guard blocks Bastion -> Target loop
    let mut cyclic_bastion = bastion.clone();
    cyclic_bastion.jump_host_id = Some(target.id.clone());
    let cycle_err = nexus_ssh_core::store::upsert_host(cyclic_bastion).unwrap_err();
    assert!(
        cycle_err.contains("循环引用"),
        "expected cycle rejection error, got: {cycle_err}"
    );

    // 1) Connect target through standard bastion (direct-tcpip)
    let probe = ssh::test_connection_blocking(target.redacted_for_ui(), 8);
    assert!(probe.ok, "ProxyJump test failed: {}", probe.message);
    assert!(
        probe.message.contains("ProxyJump (1 跳)"),
        "expected ProxyJump badge in probe message: {}",
        probe.message
    );
    assert_eq!(
        forward_hits.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "expected target connection to tunnel through bastion direct-tcpip"
    );

    // 2) Connect target through Tailscale-style bastion (direct-tcpip rejected -> auto stdio exec fallback)
    let ts_bastion = nexus_ssh_core::store::upsert_host(HostProfile {
        name: "Tailscale Bastion".to_string(),
        host: "127.0.0.1".to_string(),
        port: tailscale_bastion_port,
        username: "ubuntu".to_string(),
        auth_method: AuthMethod::None,
        ..Default::default()
    })
    .expect("save tailscale bastion");

    let target_via_ts = nexus_ssh_core::store::upsert_host(HostProfile {
        name: "Target via Tailscale".to_string(),
        host: "127.0.0.1".to_string(),
        port: target_port,
        username: "tester".to_string(),
        auth_method: AuthMethod::Password,
        password: "s3cr3t!".to_string(),
        jump_host_id: Some(ts_bastion.id.clone()),
        ..Default::default()
    })
    .expect("save target via tailscale bastion");

    let ts_probe = ssh::test_connection_blocking(target_via_ts.redacted_for_ui(), 8);
    let _ = std::fs::remove_dir_all(&temp_dir);

    assert!(
        ts_probe.ok,
        "ProxyJump stdio fallback test failed: {}",
        ts_probe.message
    );
    assert_eq!(
        stdio_hits.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "expected target connection to fall back to exec stdio forwarding"
    );
}
