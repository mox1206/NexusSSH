use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use async_trait::async_trait;
use nexus_ssh_core::models::{AuthMethod, HostProfile, SessionStatusEvent};
use nexus_ssh_core::{monitor, sftp, ssh, store};
use russh::server::{self, Auth, Msg, Session};
use russh::{Channel, ChannelId, CryptoVec, Pty};
use russh_keys::ssh_key::rand_core::OsRng;
use russh_keys::{Algorithm, PrivateKey};
use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle, Name, OpenFlags, Status, StatusCode, Version,
};
use tokio::net::TcpListener;
use tokio::sync::Mutex as AsyncMutex;

#[derive(Clone)]
struct MemNode {
    is_dir: bool,
    mode: u32,
    bytes: Vec<u8>,
}

#[derive(Default)]
struct MemFs {
    nodes: HashMap<String, MemNode>,
}

impl MemFs {
    fn new_with_root() -> Self {
        let mut nodes = HashMap::new();
        nodes.insert(
            "/".to_string(),
            MemNode {
                is_dir: true,
                mode: 0o040755,
                bytes: Vec::new(),
            },
        );
        nodes.insert(
            "/readme.txt".to_string(),
            MemNode {
                is_dir: false,
                mode: 0o100644,
                bytes: b"hello nexus sftp".to_vec(),
            },
        );
        Self { nodes }
    }

    fn norm(path: &str) -> String {
        let trimmed = path.trim();
        if trimmed.is_empty() || trimmed == "." || trimmed == "/" {
            return "/".to_string();
        }
        let mut s = if trimmed.starts_with('/') {
            trimmed.to_string()
        } else {
            format!("/{trimmed}")
        };
        while s.len() > 1 && s.ends_with('/') {
            s.pop();
        }
        s
    }

    fn attrs_for(node: &MemNode) -> FileAttributes {
        let mut a = FileAttributes::empty();
        a.size = Some(node.bytes.len() as u64);
        a.permissions = Some(node.mode);
        a.mtime = Some(1_700_000_000);
        a
    }
}

struct LoopbackSftpHandler {
    fs: Arc<Mutex<MemFs>>,
    dir_read_done: HashMap<String, bool>,
    open_files: HashMap<String, String>,
    next_handle: u64,
}

impl LoopbackSftpHandler {
    fn new(fs: Arc<Mutex<MemFs>>) -> Self {
        Self {
            fs,
            dir_read_done: HashMap::new(),
            open_files: HashMap::new(),
            next_handle: 1,
        }
    }

    fn ok_status(id: u32) -> Status {
        Status {
            id,
            status_code: StatusCode::Ok,
            error_message: "Ok".to_string(),
            language_tag: "en-US".to_string(),
        }
    }
}

impl russh_sftp::server::Handler for LoopbackSftpHandler {
    type Error = StatusCode;

    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }

    async fn init(
        &mut self,
        _version: u32,
        _extensions: HashMap<String, String>,
    ) -> Result<Version, Self::Error> {
        Ok(Version::new())
    }

    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        let norm = MemFs::norm(&path);
        Ok(Name {
            id,
            files: vec![File::dummy(norm)],
        })
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let norm = MemFs::norm(&path);
        let guard = self.fs.lock().unwrap();
        let node = guard.nodes.get(&norm).ok_or(StatusCode::NoSuchFile)?;
        Ok(Attrs {
            id,
            attrs: MemFs::attrs_for(node),
        })
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        self.stat(id, path).await
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, Self::Error> {
        let norm = MemFs::norm(&path);
        {
            let guard = self.fs.lock().unwrap();
            let node = guard.nodes.get(&norm).ok_or(StatusCode::NoSuchFile)?;
            if !node.is_dir {
                return Err(StatusCode::Failure);
            }
        }
        self.next_handle += 1;
        let h = format!("dir:{}:{norm}", self.next_handle);
        self.dir_read_done.insert(h.clone(), false);
        Ok(Handle { id, handle: h })
    }

    async fn readdir(&mut self, id: u32, handle: String) -> Result<Name, Self::Error> {
        let done = self
            .dir_read_done
            .get(&handle)
            .copied()
            .unwrap_or(true);
        if done {
            return Err(StatusCode::Eof);
        }
        self.dir_read_done.insert(handle.clone(), true);
        let dir_path = handle.splitn(3, ':').nth(2).unwrap_or("/");

        let guard = self.fs.lock().unwrap();
        let mut files = Vec::new();
        for (p, node) in &guard.nodes {
            if p == "/" || p == dir_path {
                continue;
            }
            let parent = match p.rfind('/') {
                Some(0) => "/",
                Some(idx) => &p[..idx],
                None => "/",
            };
            if parent == dir_path {
                let name = p.rsplit('/').next().unwrap_or(p);
                files.push(File::new(name, MemFs::attrs_for(node)));
            }
        }
        Ok(Name { id, files })
    }

    async fn mkdir(
        &mut self,
        id: u32,
        path: String,
        _attrs: FileAttributes,
    ) -> Result<Status, Self::Error> {
        let norm = MemFs::norm(&path);
        let mut guard = self.fs.lock().unwrap();
        guard.nodes.insert(
            norm,
            MemNode {
                is_dir: true,
                mode: 0o040755,
                bytes: Vec::new(),
            },
        );
        Ok(Self::ok_status(id))
    }

    async fn rmdir(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        let norm = MemFs::norm(&path);
        let mut guard = self.fs.lock().unwrap();
        guard.nodes.remove(&norm).ok_or(StatusCode::NoSuchFile)?;
        Ok(Self::ok_status(id))
    }

    async fn remove(&mut self, id: u32, filename: String) -> Result<Status, Self::Error> {
        let norm = MemFs::norm(&filename);
        let mut guard = self.fs.lock().unwrap();
        guard.nodes.remove(&norm).ok_or(StatusCode::NoSuchFile)?;
        Ok(Self::ok_status(id))
    }

    async fn rename(
        &mut self,
        id: u32,
        oldpath: String,
        newpath: String,
    ) -> Result<Status, Self::Error> {
        let from = MemFs::norm(&oldpath);
        let to = MemFs::norm(&newpath);
        let mut guard = self.fs.lock().unwrap();
        let node = guard.nodes.remove(&from).ok_or(StatusCode::NoSuchFile)?;
        guard.nodes.insert(to, node);
        Ok(Self::ok_status(id))
    }

    async fn setstat(
        &mut self,
        id: u32,
        path: String,
        attrs: FileAttributes,
    ) -> Result<Status, Self::Error> {
        let norm = MemFs::norm(&path);
        let mut guard = self.fs.lock().unwrap();
        let node = guard.nodes.get_mut(&norm).ok_or(StatusCode::NoSuchFile)?;
        if let Some(perm) = attrs.permissions {
            let kind_bits = if node.is_dir { 0o040000 } else { 0o100000 };
            node.mode = kind_bits | (perm & 0o7777);
        }
        Ok(Self::ok_status(id))
    }

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        pflags: OpenFlags,
        _attrs: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        let norm = MemFs::norm(&filename);
        {
            let mut guard = self.fs.lock().unwrap();
            if pflags.contains(OpenFlags::CREATE) {
                let entry = guard.nodes.entry(norm.clone()).or_insert(MemNode {
                    is_dir: false,
                    mode: 0o100644,
                    bytes: Vec::new(),
                });
                if pflags.contains(OpenFlags::TRUNCATE) {
                    entry.bytes.clear();
                }
            } else if !guard.nodes.contains_key(&norm) {
                return Err(StatusCode::NoSuchFile);
            }
        }
        self.next_handle += 1;
        let h = format!("file:{}", self.next_handle);
        self.open_files.insert(h.clone(), norm);
        Ok(Handle { id, handle: h })
    }

    async fn read(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, Self::Error> {
        let path = self.open_files.get(&handle).ok_or(StatusCode::BadMessage)?;
        let guard = self.fs.lock().unwrap();
        let node = guard.nodes.get(path).ok_or(StatusCode::NoSuchFile)?;
        let start = offset as usize;
        if start >= node.bytes.len() {
            return Err(StatusCode::Eof);
        }
        let end = (start + len as usize).min(node.bytes.len());
        Ok(Data {
            id,
            data: node.bytes[start..end].to_vec(),
        })
    }

    async fn write(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        let path = self
            .open_files
            .get(&handle)
            .cloned()
            .ok_or(StatusCode::BadMessage)?;
        let mut guard = self.fs.lock().unwrap();
        let node = guard.nodes.get_mut(&path).ok_or(StatusCode::NoSuchFile)?;
        let start = offset as usize;
        if start + data.len() > node.bytes.len() {
            node.bytes.resize(start + data.len(), 0);
        }
        node.bytes[start..start + data.len()].copy_from_slice(&data);
        Ok(Self::ok_status(id))
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, Self::Error> {
        self.open_files.remove(&handle);
        self.dir_read_done.remove(&handle);
        Ok(Self::ok_status(id))
    }
}

struct FullLoopbackSshServer {
    channels: Arc<AsyncMutex<HashMap<ChannelId, Channel<Msg>>>>,
    fs: Arc<Mutex<MemFs>>,
}

impl FullLoopbackSshServer {
    fn new(fs: Arc<Mutex<MemFs>>) -> Self {
        Self {
            channels: Arc::new(AsyncMutex::new(HashMap::new())),
            fs,
        }
    }
}

#[async_trait]
impl server::Handler for FullLoopbackSshServer {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == "ops" && password == "pass123" {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
            })
        }
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<Msg>,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        self.channels.lock().await.insert(channel.id(), channel);
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
        session.data(channel, CryptoVec::from_slice(b"OPS_SHELL_READY$ "))?;
        Ok(())
    }

    async fn subsystem_request(
        &mut self,
        channel_id: ChannelId,
        name: &str,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if name == "sftp" {
            if let Some(ch) = self.channels.lock().await.remove(&channel_id) {
                session.channel_success(channel_id)?;
                let handler = LoopbackSftpHandler::new(Arc::clone(&self.fs));
                russh_sftp::server::run(ch.into_stream(), handler).await;
                return Ok(());
            }
        }
        session.channel_failure(channel_id)?;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel_id: ChannelId,
        _data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel_id)?;
        let mock_probe = "\
===STAT0===\ncpu  1000 0 500 8500 0 0 0 0 0 0\n\
===NET0===\n  eth0: 100000 100 0 0 0 0 0 0 50000 80 0 0 0 0 0 0\n\
===HOST===\nprod-node-01\nLinux 6.8.0-generic\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\n\
===UPTIME===\n86400.50 170000.00\n\
===CORES===\n4\n\
===LOAD===\n0.42 0.35 0.28 1/250 1234\n\
===STAT===\ncpu  1050 0 530 8620 0 0 0 0 0 0\n\
===MEM===\nMemTotal:        8388608 kB\nMemAvailable:    5242880 kB\nSwapTotal:       2097152 kB\nSwapFree:        2097152 kB\n\
===DISK===\nFilesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 104857600 41943040 62914560 40% /\n\
===NET===\n  eth0: 120480 120 0 0 0 0 0 0 60240 90 0 0 0 0 0 0\n";
        session.data(channel_id, CryptoVec::from_slice(mock_probe.as_bytes()))?;
        session.exit_status_request(channel_id, 0)?;
        session.eof(channel_id)?;
        session.close(channel_id)?;
        Ok(())
    }
}

static EVENTS: OnceLock<Mutex<Vec<SessionStatusEvent>>> = OnceLock::new();

fn on_out(_sid: &str, _bytes: &[u8]) {}

fn on_ev(ev: SessionStatusEvent) {
    if let Ok(mut guard) = EVENTS.get_or_init(|| Mutex::new(Vec::new())).lock() {
        guard.push(ev);
    }
}

#[test]
fn interactive_tofu_sftp_operations_and_server_telemetry() {
    let store_dir = std::env::temp_dir().join(format!(
        "nexus_sftp_tofu_test_{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&store_dir);
    store::init_store(store_dir.to_str().unwrap()).expect("init temp store");

    let listener = ssh::runtime()
        .block_on(TcpListener::bind("127.0.0.1:0"))
        .expect("bind loopback");
    let port = listener.local_addr().unwrap().port();

    let host_key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).expect("gen host key");
    let mut server_cfg = server::Config::default();
    server_cfg.auth_rejection_time = Duration::from_millis(10);
    server_cfg.keys.push(host_key);
    let server_cfg = Arc::new(server_cfg);

    let mem_fs = Arc::new(Mutex::new(MemFs::new_with_root()));
    let fs_for_srv = Arc::clone(&mem_fs);
    ssh::runtime().spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let cfg = Arc::clone(&server_cfg);
            let fs_clone = Arc::clone(&fs_for_srv);
            tokio::spawn(async move {
                if let Ok(s) =
                    server::run_stream(cfg, stream, FullLoopbackSshServer::new(fs_clone)).await
                {
                    let _ = s.await;
                }
            });
        }
    });

    let profile = HostProfile {
        name: "SftpNode".to_string(),
        host: "127.0.0.1".to_string(),
        port,
        username: "ops".to_string(),
        auth_method: AuthMethod::Password,
        password: "pass123".to_string(),
        group: "Prod".to_string(),
        accent_hex: "#2AD882".to_string(),
        ..Default::default()
    };

    // Enable interactive TOFU verification!
    ssh::register_sinks(on_out, on_ev, true);
    ssh::start_session("sftp_sess".to_string(), profile, 100, 30).expect("start session");

    // 1. Wait for VerifyHostKey event and approve it
    let mut tofu_req_id = None;
    for _ in 0..60 {
        let guard = EVENTS.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap();
        for ev in guard.iter() {
            if let SessionStatusEvent::VerifyHostKey {
                request_id,
                status,
                fingerprint,
                ..
            } = ev
            {
                assert_eq!(status, "unknown");
                assert!(fingerprint.starts_with("SHA256:"));
                tofu_req_id = Some(request_id.clone());
                break;
            }
        }
        if tofu_req_id.is_some() {
            break;
        }
        drop(guard);
        std::thread::sleep(Duration::from_millis(30));
    }
    let req_id = tofu_req_id.expect("expected VerifyHostKey event");
    assert!(
        ssh::respond_host_key_prompt(&req_id, true, true).expect("respond tofu"),
        "expected pending TOFU prompt to resolve"
    );

    // Wait for Connected phase
    let mut connected = false;
    for _ in 0..60 {
        let guard = EVENTS.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap();
        if guard.iter().any(|ev| {
            matches!(
                ev,
                SessionStatusEvent::Connected { session_id, .. } if session_id == "sftp_sess"
            )
        }) {
            connected = true;
            break;
        }
        drop(guard);
        std::thread::sleep(Duration::from_millis(30));
    }
    assert!(connected, "session did not enter Connected phase after TOFU accept");

    let known = store::list_known_hosts().expect("list known hosts");
    assert_eq!(known.len(), 1);
    assert_eq!(known[0].port, port);

    // 2. SFTP operations over multiplexed channel
    let root = sftp::list_dir_blocking("sftp_sess", "/").expect("list /");
    assert_eq!(root.entries.len(), 1);
    assert_eq!(root.entries[0].name, "readme.txt");

    sftp::create_dir_blocking("sftp_sess", "/releases").expect("mkdir /releases");

    // Create a 90 KiB local file to test multi-chunk streaming upload & download
    let local_src = store_dir.join("payload_upload.bin");
    let local_dst = store_dir.join("payload_download.bin");
    let payload: Vec<u8> = (0..92_160).map(|i| (i % 251) as u8).collect();
    std::fs::write(&local_src, &payload).expect("write local upload source");

    let uploaded = sftp::upload_file_blocking(
        "sftp_sess",
        "tx_up_1",
        local_src.to_str().unwrap(),
        "/releases/app.bin",
    )
    .expect("upload 90KiB file");
    assert_eq!(uploaded, payload.len() as u64);

    sftp::chmod_blocking("sftp_sess", "/releases/app.bin", 0o750).expect("chmod 750");
    sftp::rename_blocking("sftp_sess", "/releases/app.bin", "/releases/app_v2.bin")
        .expect("rename");

    let rel_listing = sftp::list_dir_blocking("sftp_sess", "/releases").expect("list /releases");
    assert_eq!(rel_listing.entries.len(), 1);
    assert_eq!(rel_listing.entries[0].name, "app_v2.bin");
    assert_eq!(rel_listing.entries[0].permissions_octal, 0o750);
    assert_eq!(rel_listing.entries[0].size, payload.len() as u64);

    let downloaded = sftp::download_file_blocking(
        "sftp_sess",
        "tx_dl_1",
        "/releases/app_v2.bin",
        local_dst.to_str().unwrap(),
    )
    .expect("download 90KiB file");
    assert_eq!(downloaded, payload.len() as u64);
    assert_eq!(std::fs::read(&local_dst).unwrap(), payload);

    // Recursive directory delete
    sftp::delete_blocking("sftp_sess", "/releases", true).expect("recursive delete /releases");
    let after_del = sftp::list_dir_blocking("sftp_sess", "/").expect("list / after delete");
    assert_eq!(after_del.entries.len(), 1);

    // 3. Server Telemetry Monitor over multiplexed exec channel
    let metrics = monitor::fetch_metrics_blocking("sftp_sess").expect("fetch telemetry");
    assert_eq!(metrics.hostname, "prod-node-01");
    assert_eq!(metrics.cpu_cores, 4);
    assert!(metrics.cpu_percent > 30.0 && metrics.cpu_percent < 50.0);
    assert_eq!(metrics.disks.len(), 1);
    assert_eq!(metrics.disks[0].mount_point, "/");
    assert_eq!(metrics.networks.len(), 1);
    assert_eq!(metrics.networks[0].interface, "eth0");

    ssh::disconnect_session("sftp_sess").expect("disconnect");
    let _ = std::fs::remove_dir_all(&store_dir);
}
