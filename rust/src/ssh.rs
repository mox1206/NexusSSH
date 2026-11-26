use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use russh::client::{self, KeyboardInteractiveAuthResponse};
use russh::{ChannelMsg, CryptoVec, Disconnect};
use russh_keys::key::PrivateKeyWithHashAlg;
use russh_keys::{decode_secret_key, HashAlg};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

use crate::models::{
    AuthMethod, ConnectionTestResult, DiscoveredSshKey, HostProfile, KeyInspectionResult,
    SessionStatusEvent,
};
use crate::store::{self, KnownHostCheck};

pub type OutputSinkFn = fn(&str, &[u8]);
pub type StatusSinkFn = fn(SessionStatusEvent);

pub struct ClientHandler {
    host: String,
    port: u16,
    session_id_for_tofu: Option<String>,
    fingerprint: Arc<Mutex<Option<String>>>,
    tofu_rejected: Arc<AtomicBool>,
}

struct ActiveSessionEntry {
    cmd_tx: mpsc::UnboundedSender<SessionCommand>,
    handle: Option<Arc<client::Handle<ClientHandler>>>,
    sudo_password: Option<Zeroizing<String>>,
}

struct PendingHostKeyDecision {
    host: String,
    port: u16,
    algorithm: String,
    fingerprint: String,
    public_key_openssh: String,
    responder: oneshot::Sender<bool>,
}

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static SESSIONS: OnceLock<Mutex<HashMap<String, ActiveSessionEntry>>> = OnceLock::new();
static PENDING_TOFU: OnceLock<Mutex<HashMap<String, PendingHostKeyDecision>>> = OnceLock::new();
static SINKS: OnceLock<Mutex<Option<(OutputSinkFn, StatusSinkFn)>>> = OnceLock::new();
static INTERACTIVE_TOFU_ENABLED: AtomicBool = AtomicBool::new(false);

pub fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("nexus-ssh-worker")
            .build()
            .expect("Failed to initialize Tokio runtime")
    })
}

fn sessions() -> &'static Mutex<HashMap<String, ActiveSessionEntry>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn pending_tofu() -> &'static Mutex<HashMap<String, PendingHostKeyDecision>> {
    PENDING_TOFU.get_or_init(|| Mutex::new(HashMap::new()))
}

fn sinks() -> &'static Mutex<Option<(OutputSinkFn, StatusSinkFn)>> {
    SINKS.get_or_init(|| Mutex::new(None))
}

pub fn register_sinks(output_fn: OutputSinkFn, status_fn: StatusSinkFn, interactive_tofu: bool) {
    INTERACTIVE_TOFU_ENABLED.store(interactive_tofu, Ordering::Release);
    if let Ok(mut guard) = sinks().lock() {
        *guard = Some((output_fn, status_fn));
    }
}

pub fn emit_output(session_id: &str, bytes: &[u8]) {
    if bytes.is_empty() {
        return;
    }
    let cb = sinks().lock().ok().and_then(|g| g.map(|pair| pair.0));
    if let Some(f) = cb {
        f(session_id, bytes);
    }
}

pub fn emit_status(event: SessionStatusEvent) {
    let cb = sinks().lock().ok().and_then(|g| g.map(|pair| pair.1));
    if let Some(f) = cb {
        f(event);
    }
}

pub fn respond_host_key_prompt(request_id: &str, accept: bool, persist: bool) -> Result<bool, String> {
    let pending = {
        let mut guard = pending_tofu()
            .lock()
            .map_err(|_| "TOFU 验证队列锁异常".to_string())?;
        guard.remove(request_id)
    };
    let Some(decision) = pending else {
        return Ok(false);
    };
    if accept && persist {
        let _ = store::trust_known_host(
            &decision.host,
            decision.port,
            &decision.algorithm,
            &decision.fingerprint,
            &decision.public_key_openssh,
        );
    }
    let _ = decision.responder.send(accept);
    Ok(true)
}

pub fn get_session_handle(
    session_id: &str,
) -> Result<Arc<client::Handle<ClientHandler>>, String> {
    let guard = sessions()
        .lock()
        .map_err(|_| "会话管理器锁异常".to_string())?;
    let entry = guard
        .get(session_id)
        .ok_or_else(|| "当前 SSH 会话未连接或已断开".to_string())?;
    entry
        .handle
        .as_ref()
        .cloned()
        .ok_or_else(|| "SSH 会话正在握手中，请稍候".to_string())
}

#[derive(Debug)]
enum SessionCommand {
    Write(Vec<u8>),
    Resize {
        cols: u32,
        rows: u32,
        pixel_width: u32,
        pixel_height: u32,
    },
    Disconnect,
}

#[async_trait]
impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh_keys::PublicKey,
    ) -> Result<bool, Self::Error> {
        let fp = server_public_key.fingerprint(HashAlg::Sha256).to_string();
        if let Ok(mut guard) = self.fingerprint.lock() {
            *guard = Some(fp.clone());
        }

        let Some(ref sid) = self.session_id_for_tofu else {
            return Ok(true);
        };
        if !INTERACTIVE_TOFU_ENABLED.load(Ordering::Acquire) {
            return Ok(true);
        }

        let check = store::check_known_host(&self.host, self.port, &fp);
        let (status_label, prev_fp) = match check {
            KnownHostCheck::Trusted => return Ok(true),
            KnownHostCheck::Unknown => ("unknown".to_string(), None),
            KnownHostCheck::Mismatch {
                previous_fingerprint,
            } => ("mismatch".to_string(), Some(previous_fingerprint)),
        };

        let request_id = Uuid::new_v4().to_string();
        let alg = server_public_key.algorithm().to_string();
        let pk_openssh = server_public_key.to_openssh().unwrap_or_default();
        let (tx, rx) = oneshot::channel::<bool>();

        if let Ok(mut map) = pending_tofu().lock() {
            map.insert(
                request_id.clone(),
                PendingHostKeyDecision {
                    host: self.host.clone(),
                    port: self.port,
                    algorithm: alg.clone(),
                    fingerprint: fp.clone(),
                    public_key_openssh: pk_openssh,
                    responder: tx,
                },
            );
        }

        emit_status(SessionStatusEvent::VerifyHostKey {
            request_id: request_id.clone(),
            session_id: sid.clone(),
            host: self.host.clone(),
            port: self.port,
            algorithm: alg,
            fingerprint: fp,
            status: status_label,
            previous_fingerprint: prev_fp,
        });

        let accepted = match tokio::time::timeout(Duration::from_secs(90), rx).await {
            Ok(Ok(choice)) => choice,
            _ => {
                if let Ok(mut map) = pending_tofu().lock() {
                    map.remove(&request_id);
                }
                false
            }
        };

        if !accepted {
            self.tofu_rejected.store(true, Ordering::Release);
        }
        Ok(accepted)
    }

    async fn auth_banner(
        &mut self,
        banner: &str,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        if banner.is_empty() {
            return Ok(());
        }
        if let Some(ref sid) = self.session_id_for_tofu {
            let normalized = banner.replace("\r\n", "\n").replace('\n', "\r\n");
            emit_output(sid, normalized.as_bytes());
        }
        Ok(())
    }
}

struct EstablishedSshChain {
    handle: client::Handle<ClientHandler>,
    jump_handles: Vec<client::Handle<ClientHandler>>,
    server_fingerprint: String,
    auth_used: String,
    latency_ms: u64,
}

fn build_client_config() -> Arc<client::Config> {
    let mut config = client::Config::default();
    config.keepalive_interval = Some(Duration::from_secs(30));
    config.keepalive_max = 6;
    config.inactivity_timeout = Some(Duration::from_secs(3600));
    Arc::new(config)
}

fn effective_hop_timeout(connect_timeout: Duration) -> Duration {
    // Allow 95s outer timeout when interactive TOFU dialog may wait on user confirmation
    if INTERACTIVE_TOFU_ENABLED.load(Ordering::Acquire) {
        connect_timeout.max(Duration::from_secs(95))
    } else {
        connect_timeout
    }
}

async fn disconnect_jump_handles(jump_handles: Vec<client::Handle<ClientHandler>>) {
    for jh in jump_handles.into_iter().rev() {
        let _ = tokio::time::timeout(
            Duration::from_millis(500),
            jh.disconnect(Disconnect::ByApplication, "proxyjump closed", "en"),
        )
        .await;
    }
}

async fn connect_tcp_hop(
    profile: &HostProfile,
    session_id_for_tofu: Option<String>,
    connect_timeout: Duration,
) -> Result<(client::Handle<ClientHandler>, String, String, u64), String> {
    profile.validate()?;
    let config = build_client_config();
    let fingerprint_slot = Arc::new(Mutex::new(None));
    let tofu_rejected = Arc::new(AtomicBool::new(false));
    let session_id_for_auth = session_id_for_tofu.clone();
    let handler = ClientHandler {
        host: profile.host.trim().to_string(),
        port: profile.port,
        session_id_for_tofu,
        fingerprint: Arc::clone(&fingerprint_slot),
        tofu_rejected: Arc::clone(&tofu_rejected),
    };

    let target_addr = (profile.host.trim(), profile.port);
    let started = Instant::now();
    let effective_timeout = effective_hop_timeout(connect_timeout);

    let mut handle = tokio::time::timeout(
        effective_timeout,
        client::connect(config, target_addr, handler),
    )
    .await
    .map_err(|_| {
        format!(
            "连接超时 ({}:{}，超过 {} 秒)",
            profile.host,
            profile.port,
            connect_timeout.as_secs()
        )
    })?
    .map_err(|e| {
        if tofu_rejected.load(Ordering::Acquire) {
            format!(
                "已取消连接：未信任主机 {}:{} 的公钥指纹",
                profile.host, profile.port
            )
        } else {
            format!("无法连接到 {}:{}: {e}", profile.host, profile.port)
        }
    })?;

    let latency_ms = started.elapsed().as_millis() as u64;
    let auth_used =
        authenticate_session(&mut handle, profile, session_id_for_auth.as_deref()).await?;
    let server_fp = fingerprint_slot
        .lock()
        .ok()
        .and_then(|g| g.clone())
        .unwrap_or_else(|| "SHA256:unknown".to_string());

    Ok((handle, server_fp, auth_used, latency_ms))
}

async fn connect_stream_hop<S>(
    stream: S,
    profile: &HostProfile,
    session_id_for_tofu: Option<String>,
    connect_timeout: Duration,
) -> Result<(client::Handle<ClientHandler>, String, String, u64), String>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    profile.validate()?;
    let config = build_client_config();
    let fingerprint_slot = Arc::new(Mutex::new(None));
    let tofu_rejected = Arc::new(AtomicBool::new(false));
    let session_id_for_auth = session_id_for_tofu.clone();
    let handler = ClientHandler {
        host: profile.host.trim().to_string(),
        port: profile.port,
        session_id_for_tofu,
        fingerprint: Arc::clone(&fingerprint_slot),
        tofu_rejected: Arc::clone(&tofu_rejected),
    };

    let started = Instant::now();
    let effective_timeout = effective_hop_timeout(connect_timeout);

    let mut handle = tokio::time::timeout(
        effective_timeout,
        client::connect_stream(config, stream, handler),
    )
    .await
    .map_err(|_| {
        format!(
            "隧道握手超时 ({}:{}，超过 {} 秒)",
            profile.host,
            profile.port,
            connect_timeout.as_secs()
        )
    })?
    .map_err(|e| {
        if tofu_rejected.load(Ordering::Acquire) {
            format!(
                "已取消连接：未信任主机 {}:{} 的公钥指纹",
                profile.host, profile.port
            )
        } else {
            format!("经由 ProxyJump 握手 {}:{} 失败: {e}", profile.host, profile.port)
        }
    })?;

    let latency_ms = started.elapsed().as_millis() as u64;
    let auth_used =
        authenticate_session(&mut handle, profile, session_id_for_auth.as_deref()).await?;
    let server_fp = fingerprint_slot
        .lock()
        .ok()
        .and_then(|g| g.clone())
        .unwrap_or_else(|| "SHA256:unknown".to_string());

    Ok((handle, server_fp, auth_used, latency_ms))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProxyJumpTransport {
    DirectTcpip,
    StdioExec,
}

/// Builds a shell-injection-safe POSIX `exec` stdio TCP forwarder command for
/// bastions that reject SSH `direct-tcpip` channels (e.g. Tailscale SSH or
/// servers configured with `AllowTcpForwarding no`).
pub fn build_stdio_forward_command(target_host: &str, target_port: u16) -> Result<String, String> {
    let host = target_host.trim().trim_start_matches('[').trim_end_matches(']');
    if host.is_empty()
        || host.starts_with('-')
        || !host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':' | b'_'))
    {
        return Err(format!("目标主机地址包含非法字符，无法建立 stdio 转发: {target_host}"));
    }
    if target_port == 0 {
        return Err("目标端口号无效".to_string());
    }

    let socat_target = if host.contains(':') {
        format!("TCP6:[{host}]:{target_port}")
    } else {
        format!("TCP:{host}:{target_port}")
    };

    Ok(format!(
        "if command -v socat >/dev/null 2>&1; then exec socat - '{socat_target}'; \
         elif command -v ncat >/dev/null 2>&1; then exec ncat '{host}' {target_port}; \
         elif command -v nc >/dev/null 2>&1; then exec nc '{host}' {target_port}; \
         elif command -v python3 >/dev/null 2>&1; then exec python3 -u -c 'import os,select,socket,sys\n\
s=socket.create_connection((sys.argv[1],int(sys.argv[2])),12)\n\
s.settimeout(None)\n\
i=sys.stdin.fileno()\n\
w=sys.stdout.buffer\n\
while 1:\n\
 r=select.select([s,i],[],[])[0]\n\
 if s in r:\n\
  d=s.recv(65536)\n\
  if not d:break\n\
  w.write(d);w.flush()\n\
 if i in r:\n\
  d=os.read(i,65536)\n\
  if not d:break\n\
  s.sendall(d)' '{host}' {target_port}; \
         else exit 127; fi"
    ))
}

async fn open_proxy_jump_stdio_stream(
    jump_handle: &client::Handle<ClientHandler>,
    jump_label: &str,
    target_host: &str,
    target_port: u16,
    connect_timeout: Duration,
) -> Result<russh::ChannelStream<client::Msg>, String> {
    let cmd = build_stdio_forward_command(target_host, target_port)?;
    let channel = tokio::time::timeout(connect_timeout, jump_handle.channel_open_session())
        .await
        .map_err(|_| format!("ProxyJump ({jump_label}) 打开 stdio 转发会话超时"))?
        .map_err(|e| format!("ProxyJump ({jump_label}) 拒绝打开会话通道: {e}"))?;

    tokio::time::timeout(connect_timeout, channel.exec(true, cmd.as_bytes()))
        .await
        .map_err(|_| format!("ProxyJump ({jump_label}) 启动 stdio 转发命令超时"))?
        .map_err(|e| format!("ProxyJump ({jump_label}) 拒绝执行转发命令: {e}"))?;

    Ok(channel.into_stream())
}

async fn open_proxy_jump_stream(
    jump_handle: &client::Handle<ClientHandler>,
    jump_label: &str,
    target_host: &str,
    target_port: u16,
    connect_timeout: Duration,
    session_id: Option<&str>,
) -> Result<(russh::ChannelStream<client::Msg>, ProxyJumpTransport), String> {
    let direct_attempt = tokio::time::timeout(
        connect_timeout,
        jump_handle.channel_open_direct_tcpip(
            target_host.trim(),
            u32::from(target_port),
            "127.0.0.1",
            0,
        ),
    )
    .await;

    match direct_attempt {
        Ok(Ok(channel)) => Ok((channel.into_stream(), ProxyJumpTransport::DirectTcpip)),
        Err(_) => Err(format!(
            "ProxyJump ({jump_label}) 打开至 {target_host}:{target_port} 的转发隧道超时"
        )),
        Ok(Err(direct_err)) => {
            if let Some(sid) = session_id {
                let line = format!(
                    "\x1b[38;5;244m├─ direct-tcpip 不可用，已自动切换为 stdio 透明转发 → \x1b[36m{target_host}:{target_port}\x1b[0;38;5;244m ...\x1b[0m\r\n"
                );
                emit_output(sid, line.as_bytes());
            }
            match open_proxy_jump_stdio_stream(
                jump_handle,
                jump_label,
                target_host,
                target_port,
                connect_timeout,
            )
            .await
            {
                Ok(stream) => Ok((stream, ProxyJumpTransport::StdioExec)),
                Err(stdio_err) => Err(format!(
                    "ProxyJump ({jump_label}) 转发至 {target_host}:{target_port} 失败（direct-tcpip: {direct_err}；stdio 回退: {stdio_err}）"
                )),
            }
        }
    }
}

async fn establish_authenticated_chain(
    profile: &HostProfile,
    session_id_for_tofu: Option<String>,
    connect_timeout: Duration,
) -> Result<EstablishedSshChain, String> {
    profile.validate()?;
    let mut jump_chain = store::resolve_jump_chain(profile)?;

    if jump_chain.is_empty() {
        let (handle, server_fingerprint, auth_used, latency_ms) =
            connect_tcp_hop(profile, session_id_for_tofu, connect_timeout).await?;
        return Ok(EstablishedSshChain {
            handle,
            jump_handles: Vec::new(),
            server_fingerprint,
            auth_used,
            latency_ms,
        });
    }

    let total_started = Instant::now();
    let total_jumps = jump_chain.len();
    let mut jump_handles: Vec<client::Handle<ClientHandler>> = Vec::with_capacity(total_jumps);
    let mut prev_jump_name = String::new();

    for idx in 0..total_jumps {
        let mut hop = jump_chain[idx].clone();
        // Zeroize the copy still sitting in `jump_chain[idx]`
        jump_chain[idx].password.zeroize();
        jump_chain[idx].private_key.zeroize();
        jump_chain[idx].passphrase.zeroize();

        let hop_label = if hop.name.trim().is_empty() {
            format!("{}@{}", hop.username, hop.host)
        } else {
            hop.name.clone()
        };

        if let Some(ref sid) = session_id_for_tofu {
            emit_status(SessionStatusEvent::Connecting {
                session_id: sid.clone(),
                message: format!(
                    "ProxyJump [{}/{}] 正在连接 {} ...",
                    idx + 1,
                    total_jumps,
                    hop_label
                ),
            });
            let line = format!(
                "\x1b[38;5;244m├─ ProxyJump [{}/{}]: 正在连接 \x1b[36m{} ({}:{})\x1b[0;38;5;244m ...\x1b[0m\r\n",
                idx + 1,
                total_jumps,
                hop_label,
                hop.host,
                hop.port
            );
            emit_output(sid, line.as_bytes());
        }

        let hop_result = if idx == 0 {
            connect_tcp_hop(&hop, session_id_for_tofu.clone(), connect_timeout).await
        } else {
            match open_proxy_jump_stream(
                jump_handles.last().unwrap(),
                &prev_jump_name,
                &hop.host,
                hop.port,
                connect_timeout,
                session_id_for_tofu.as_deref(),
            )
            .await
            {
                Ok((stream, _transport)) => {
                    connect_stream_hop(stream, &hop, session_id_for_tofu.clone(), connect_timeout)
                        .await
                }
                Err(e) => Err(e),
            }
        };

        hop.password.zeroize();
        hop.private_key.zeroize();
        hop.passphrase.zeroize();

        let (hop_handle, _fp, _auth, hop_ms) = match hop_result {
            Ok(v) => v,
            Err(err) => {
                // Zeroize any remaining jump profiles before returning
                for rest in jump_chain.iter_mut().skip(idx + 1) {
                    rest.password.zeroize();
                    rest.private_key.zeroize();
                    rest.passphrase.zeroize();
                }
                disconnect_jump_handles(jump_handles).await;
                return Err(format!("ProxyJump ({hop_label}) 连接失败: {err}"));
            }
        };

        if let Some(ref sid) = session_id_for_tofu {
            let line = format!(
                "\x1b[38;5;244m├─ ProxyJump [{}/{}]: \x1b[32m{}\x1b[0;38;5;244m 已就绪 ({} ms)\x1b[0m\r\n",
                idx + 1,
                total_jumps,
                hop_label,
                hop_ms
            );
            emit_output(sid, line.as_bytes());
        }

        prev_jump_name = hop_label;
        jump_handles.push(hop_handle);
    }

    if let Some(ref sid) = session_id_for_tofu {
        emit_status(SessionStatusEvent::Connecting {
            session_id: sid.clone(),
            message: format!(
                "经由 {} 连接 {}@{}:{} ...",
                prev_jump_name, profile.username, profile.host, profile.port
            ),
        });
        let line = format!(
            "\x1b[38;5;244m├─ 正在建立隧道 → \x1b[36m{}:{}\x1b[0;38;5;244m ...\x1b[0m\r\n",
            profile.host, profile.port
        );
        emit_output(sid, line.as_bytes());
    }

    let (target_stream, transport) = match open_proxy_jump_stream(
        jump_handles.last().unwrap(),
        &prev_jump_name,
        &profile.host,
        profile.port,
        connect_timeout,
        session_id_for_tofu.as_deref(),
    )
    .await
    {
        Ok(pair) => pair,
        Err(err) => {
            disconnect_jump_handles(jump_handles).await;
            return Err(err);
        }
    };

    let (target_handle, server_fingerprint, auth_used, _target_ms) = match connect_stream_hop(
        target_stream,
        profile,
        session_id_for_tofu,
        connect_timeout,
    )
    .await
    {
        Ok(v) => v,
        Err(err) => {
            disconnect_jump_handles(jump_handles).await;
            if transport == ProxyJumpTransport::StdioExec {
                return Err(format!(
                    "{err}（已通过跳板机 {prev_jump_name} 尝试 stdio 转发，请确认跳板机可连通目标 {}:{} 且已安装 nc/socat/python3）",
                    profile.host, profile.port
                ));
            }
            return Err(err);
        }
    };

    let total_latency = total_started.elapsed().as_millis() as u64;
    Ok(EstablishedSshChain {
        handle: target_handle,
        jump_handles,
        server_fingerprint,
        auth_used,
        latency_ms: total_latency,
    })
}

async fn authenticate_session(
    handle: &mut client::Handle<ClientHandler>,
    profile: &HostProfile,
    session_id: Option<&str>,
) -> Result<String, String> {
    // Follow OpenSSH (RFC 4252 §5.2): always probe SSH `none` auth first.
    // Tailscale SSH (`NoClientAuth`) and ZeroTrust gateways accept `none`
    // immediately (and may display a browser check URL via banner or session).
    match handle.authenticate_none(&profile.username).await {
        Ok(true) => return Ok("none".to_string()),
        Ok(false) => {}
        Err(e) => {
            if profile.auth_method == AuthMethod::None {
                return Err(format!("免密认证失败: {e}"));
            }
        }
    }

    if handle.is_closed() {
        return Err(match profile.auth_method {
            AuthMethod::None => "免密认证被服务器拒绝或连接已关闭".to_string(),
            AuthMethod::Password => "认证被服务器关闭：请检查用户名或服务端认证方式".to_string(),
            AuthMethod::PrivateKey => {
                "服务器在认证阶段关闭了连接（请确认服务端允许公钥认证）".to_string()
            }
        });
    }

    match profile.auth_method {
        AuthMethod::None => {
            // Some gateways use 0-prompt keyboard-interactive to print an auth URL / instructions
            if let Ok(mut resp) = handle
                .authenticate_keyboard_interactive_start(&profile.username, None::<String>)
                .await
            {
                for _ in 0..4 {
                    match resp {
                        KeyboardInteractiveAuthResponse::Success => {
                            return Ok("keyboard-interactive".to_string());
                        }
                        KeyboardInteractiveAuthResponse::Failure => break,
                        KeyboardInteractiveAuthResponse::InfoRequest {
                            instructions,
                            prompts,
                            ..
                        } => {
                            if let Some(sid) = session_id {
                                if !instructions.trim().is_empty() {
                                    let normalized =
                                        instructions.replace("\r\n", "\n").replace('\n', "\r\n");
                                    emit_output(sid, format!("{normalized}\r\n").as_bytes());
                                }
                            }
                            if !prompts.is_empty() {
                                break;
                            }
                            match handle
                                .authenticate_keyboard_interactive_respond(Vec::new())
                                .await
                            {
                                Ok(next) => resp = next,
                                Err(_) => break,
                            }
                        }
                    }
                }
            }
            Err("服务器不支持免密 (none) 认证，请切换为密码或私钥认证".to_string())
        }
        AuthMethod::Password => {
            let pw_ok = handle
                .authenticate_password(&profile.username, &profile.password)
                .await
                .map_err(|e| format!("密码认证请求失败: {e}"))?;
            if pw_ok {
                return Ok("password".to_string());
            }

            if !handle.is_closed() {
                if let Ok(mut resp) = handle
                    .authenticate_keyboard_interactive_start(&profile.username, None::<String>)
                    .await
                {
                    for _ in 0..4 {
                        match resp {
                            KeyboardInteractiveAuthResponse::Success => {
                                return Ok("keyboard-interactive".to_string());
                            }
                            KeyboardInteractiveAuthResponse::Failure => break,
                            KeyboardInteractiveAuthResponse::InfoRequest {
                                instructions,
                                prompts,
                                ..
                            } => {
                                if let Some(sid) = session_id {
                                    if !instructions.trim().is_empty() {
                                        let normalized = instructions
                                            .replace("\r\n", "\n")
                                            .replace('\n', "\r\n");
                                        emit_output(sid, format!("{normalized}\r\n").as_bytes());
                                    }
                                }
                                let answers = prompts
                                    .iter()
                                    .map(|_| profile.password.clone())
                                    .collect::<Vec<_>>();
                                match handle
                                    .authenticate_keyboard_interactive_respond(answers)
                                    .await
                                {
                                    Ok(next) => resp = next,
                                    Err(_) => break,
                                }
                            }
                        }
                    }
                }
            }

            Err("认证被拒绝：用户名或密码错误".to_string())
        }
        AuthMethod::PrivateKey => {
            let pem_text = profile.resolve_private_key_pem()?;
            let passphrase = if profile.passphrase.is_empty() {
                None
            } else {
                Some(profile.passphrase.as_str())
            };
            let key = decode_secret_key(pem_text.trim(), passphrase)
                .map_err(|e| format!("私钥解析失败（请检查文件格式或密钥口令）: {e}"))?;
            let key_arc = Arc::new(key);

            let candidates: Vec<Option<HashAlg>> = if key_arc.algorithm().is_rsa() {
                vec![Some(HashAlg::Sha512), Some(HashAlg::Sha256), None]
            } else {
                vec![None]
            };

            for hash_alg in candidates {
                if handle.is_closed() {
                    break;
                }
                let Ok(key_with_alg) = PrivateKeyWithHashAlg::new(Arc::clone(&key_arc), hash_alg)
                else {
                    continue;
                };
                match handle
                    .authenticate_publickey(&profile.username, key_with_alg)
                    .await
                {
                    Ok(true) => {
                        let alg_label = key_arc.algorithm().to_string();
                        return Ok(format!("publickey ({alg_label})"));
                    }
                    Ok(false) => continue,
                    Err(e) => return Err(format!("公钥认证异常: {e}")),
                }
            }

            Err("私钥认证被服务器拒绝（请确认公钥已写入 ~/.ssh/authorized_keys）".to_string())
        }
    }
}

pub fn test_connection_blocking(mut profile: HostProfile, timeout_secs: u64) -> ConnectionTestResult {
    store::hydrate_host_secrets(&mut profile);
    let hop_timeout = Duration::from_secs(timeout_secs.clamp(3, 30));
    let has_jump = profile
        .jump_host_id
        .as_deref()
        .map(str::trim)
        .is_some_and(|s| !s.is_empty());
    let outer_timeout = if has_jump {
        Duration::from_secs((timeout_secs.clamp(3, 30) * 3).min(45))
    } else {
        hop_timeout
    };
    runtime().block_on(async move {
        let attempt = tokio::time::timeout(
            outer_timeout,
            establish_authenticated_chain(&profile, None, hop_timeout),
        )
        .await;
        let res = match attempt {
            Err(_) => ConnectionTestResult {
                ok: false,
                latency_ms: 0,
                server_fingerprint: None,
                message: "测试超时（若为 Tailscale 浏览器验证主机，请直接点「保存并连接」在终端中完成验证）".to_string(),
            },
            Ok(Ok(chain)) => {
                let jump_count = chain.jump_handles.len();
                let _ = tokio::time::timeout(
                    Duration::from_millis(500),
                    chain
                        .handle
                        .disconnect(Disconnect::ByApplication, "connection test", "en"),
                )
                .await;
                disconnect_jump_handles(chain.jump_handles).await;
                let mut msg = if jump_count > 0 {
                    format!(
                        "连接成功 · ProxyJump ({jump_count} 跳) · {} · {} ms",
                        chain.auth_used, chain.latency_ms
                    )
                } else {
                    format!("连接成功 · {} · {} ms", chain.auth_used, chain.latency_ms)
                };
                if let KnownHostCheck::Mismatch { .. } = store::check_known_host(
                    &profile.host,
                    profile.port,
                    &chain.server_fingerprint,
                ) {
                    msg.push_str("（注意：服务端指纹已变更）");
                }
                ConnectionTestResult {
                    ok: true,
                    latency_ms: chain.latency_ms,
                    server_fingerprint: Some(chain.server_fingerprint),
                    message: msg,
                }
            }
            Ok(Err(err)) => ConnectionTestResult {
                ok: false,
                latency_ms: 0,
                server_fingerprint: None,
                message: err,
            },
        };
        profile.password.zeroize();
        profile.private_key.zeroize();
        profile.passphrase.zeroize();
        res
    })
}

pub fn start_session(
    session_id: String,
    mut profile: HostProfile,
    cols: u32,
    rows: u32,
) -> Result<(), String> {
    store::hydrate_host_secrets(&mut profile);
    profile.validate()?;

    let sudo_password = if !profile.password.is_empty() {
        Some(Zeroizing::new(profile.password.clone()))
    } else {
        None
    };

    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<SessionCommand>();
    {
        let mut map = sessions()
            .lock()
            .map_err(|_| "会话管理器锁异常".to_string())?;
        if let Some(old_entry) = map.insert(
            session_id.clone(),
            ActiveSessionEntry {
                cmd_tx,
                handle: None,
                sudo_password,
            },
        ) {
            let _ = old_entry.cmd_tx.send(SessionCommand::Disconnect);
        }
    }

    let initial_cols = cols.max(20);
    let initial_rows = rows.max(8);

    runtime().spawn(async move {
        emit_status(SessionStatusEvent::Connecting {
            session_id: session_id.clone(),
            message: format!(
                "正在连接 {}@{}:{} ...",
                profile.username, profile.host, profile.port
            ),
        });

        let EstablishedSshChain {
            handle: raw_handle,
            jump_handles,
            server_fingerprint,
            auth_used,
            latency_ms,
        } = match establish_authenticated_chain(
            &profile,
            Some(session_id.clone()),
            Duration::from_secs(12),
        )
        .await
        {
            Ok(chain) => chain,
            Err(err) => {
                profile.password.zeroize();
                profile.private_key.zeroize();
                profile.passphrase.zeroize();
                cleanup_session(&session_id);
                emit_status(SessionStatusEvent::Error {
                    session_id,
                    message: err,
                });
                return;
            }
        };

        // Wipe authentication secrets from the spawned task stack immediately after handshake
        profile.password.zeroize();
        profile.private_key.zeroize();
        profile.passphrase.zeroize();

        let handle = Arc::new(raw_handle);
        if let Ok(mut map) = sessions().lock() {
            if let Some(entry) = map.get_mut(&session_id) {
                entry.handle = Some(Arc::clone(&handle));
            }
        }

        let mut channel = match handle.channel_open_session().await {
            Ok(ch) => ch,
            Err(e) => {
                cleanup_session(&session_id);
                disconnect_jump_handles(jump_handles).await;
                emit_status(SessionStatusEvent::Error {
                    session_id,
                    message: format!("打开 SSH 会话通道失败: {e}"),
                });
                return;
            }
        };

        if let Err(e) = channel
            .request_pty(
                true,
                "xterm-256color",
                initial_cols,
                initial_rows,
                0,
                0,
                &[],
            )
            .await
        {
            cleanup_session(&session_id);
            disconnect_jump_handles(jump_handles).await;
            emit_status(SessionStatusEvent::Error {
                session_id,
                message: format!("请求 PTY 终端失败: {e}"),
            });
            return;
        }

        if let Err(e) = channel.request_shell(true).await {
            cleanup_session(&session_id);
            disconnect_jump_handles(jump_handles).await;
            emit_status(SessionStatusEvent::Error {
                session_id,
                message: format!("启动远程 Shell 失败: {e}"),
            });
            return;
        }

        store::mark_host_connected(&profile.id);

        emit_status(SessionStatusEvent::Connected {
            session_id: session_id.clone(),
            server_fingerprint,
            auth_used,
            latency_ms,
        });

        let channel_id = channel.id();
        let mut exit_code: Option<u32> = None;
        let mut disconnect_reason = "远程会话已关闭".to_string();

        loop {
            tokio::select! {
                maybe_msg = channel.wait() => {
                    match maybe_msg {
                        Some(ChannelMsg::Data { ref data }) => {
                            emit_output(&session_id, data);
                        }
                        Some(ChannelMsg::ExtendedData { ref data, .. }) => {
                            emit_output(&session_id, data);
                        }
                        Some(ChannelMsg::ExitStatus { exit_status }) => {
                            exit_code = Some(exit_status);
                        }
                        Some(ChannelMsg::ExitSignal { signal_name, .. }) => {
                            disconnect_reason = format!("远程进程因信号 {:?} 退出", signal_name);
                        }
                        Some(ChannelMsg::Eof) => {}
                        Some(ChannelMsg::Close) | None => {
                            break;
                        }
                        _ => {}
                    }
                }
                maybe_cmd = cmd_rx.recv() => {
                    match maybe_cmd {
                        Some(SessionCommand::Write(bytes)) => {
                            if !bytes.is_empty()
                                && handle.data(channel_id, CryptoVec::from_slice(&bytes)).await.is_err()
                            {
                                disconnect_reason = "写入通道失败，连接已断开".to_string();
                                break;
                            }
                        }
                        Some(SessionCommand::Resize { cols, rows, pixel_width, pixel_height }) => {
                            let _ = channel
                                .window_change(cols.max(10), rows.max(4), pixel_width, pixel_height)
                                .await;
                        }
                        Some(SessionCommand::Disconnect) | None => {
                            disconnect_reason = "已主动断开连接".to_string();
                            let _ = channel.eof().await;
                            let _ = channel.close().await;
                            let _ = tokio::time::timeout(
                                Duration::from_millis(500),
                                handle.disconnect(Disconnect::ByApplication, "closed by user", "en"),
                            )
                            .await;
                            break;
                        }
                    }
                }
            }
        }

        cleanup_session(&session_id);
        drop(handle);
        disconnect_jump_handles(jump_handles).await;
        emit_status(SessionStatusEvent::Disconnected {
            session_id,
            exit_code,
            reason: disconnect_reason,
        });
    });

    Ok(())
}

pub fn write_to_session(session_id: &str, bytes: &[u8]) -> Result<(), String> {
    let guard = sessions()
        .lock()
        .map_err(|_| "会话管理器锁异常".to_string())?;
    let entry = guard
        .get(session_id)
        .ok_or_else(|| "会话不存在或已断开".to_string())?;
    entry
        .cmd_tx
        .send(SessionCommand::Write(bytes.to_vec()))
        .map_err(|_| "会话通道已关闭".to_string())
}

/// Sends the session's stored host password followed by `\r` directly inside Rust
/// so plaintext passwords never need to be held in Dart/UI memory for sudo autofill.
pub fn fill_sudo_password(session_id: &str) -> Result<bool, String> {
    let guard = sessions()
        .lock()
        .map_err(|_| "会话管理器锁异常".to_string())?;
    let entry = guard
        .get(session_id)
        .ok_or_else(|| "会话不存在或已断开".to_string())?;
    let Some(ref pass) = entry.sudo_password else {
        return Ok(false);
    };
    if pass.is_empty() {
        return Ok(false);
    }
    let mut payload = Zeroizing::new(Vec::with_capacity(pass.len() + 1));
    payload.extend_from_slice(pass.as_bytes());
    payload.push(b'\r');
    entry
        .cmd_tx
        .send(SessionCommand::Write(payload.to_vec()))
        .map_err(|_| "会话通道已关闭".to_string())?;
    Ok(true)
}

pub fn resize_session(
    session_id: &str,
    cols: u32,
    rows: u32,
    pixel_width: u32,
    pixel_height: u32,
) -> Result<(), String> {
    let guard = sessions()
        .lock()
        .map_err(|_| "会话管理器锁异常".to_string())?;
    if let Some(entry) = guard.get(session_id) {
        let _ = entry.cmd_tx.send(SessionCommand::Resize {
            cols,
            rows,
            pixel_width,
            pixel_height,
        });
    }
    Ok(())
}

pub fn disconnect_session(session_id: &str) -> Result<(), String> {
    let entry_opt = {
        let mut guard = sessions()
            .lock()
            .map_err(|_| "会话管理器锁异常".to_string())?;
        guard.remove(session_id)
    };
    crate::sftp::drop_cached_sftp(session_id);
    crate::monitor::drop_cached_metrics(session_id);
    if let Some(entry) = entry_opt {
        let _ = entry.cmd_tx.send(SessionCommand::Disconnect);
    }
    Ok(())
}

pub fn disconnect_all_sessions() {
    let drained: Vec<(String, ActiveSessionEntry)> = {
        let Ok(mut guard) = sessions().lock() else {
            return;
        };
        guard.drain().collect()
    };
    for (sid, entry) in drained {
        crate::sftp::drop_cached_sftp(&sid);
        crate::monitor::drop_cached_metrics(&sid);
        let _ = entry.cmd_tx.send(SessionCommand::Disconnect);
    }
}

fn cleanup_session(session_id: &str) {
    if let Ok(mut guard) = sessions().lock() {
        guard.remove(session_id);
    }
    crate::sftp::drop_cached_sftp(session_id);
    crate::monitor::drop_cached_metrics(session_id);
}

pub fn inspect_private_key(
    pem_content: &str,
    file_path: &str,
    passphrase: &str,
) -> KeyInspectionResult {
    let raw = if !file_path.trim().is_empty() {
        match std::fs::read_to_string(file_path.trim()) {
            Ok(s) => s,
            Err(e) => {
                if !pem_content.trim().is_empty() {
                    pem_content.to_string()
                } else {
                    return KeyInspectionResult {
                        valid: false,
                        encrypted: false,
                        algorithm: None,
                        fingerprint: None,
                        message: format!("无法读取密钥文件: {e}"),
                    };
                }
            }
        }
    } else {
        pem_content.to_string()
    };

    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return KeyInspectionResult {
            valid: false,
            encrypted: false,
            algorithm: None,
            fingerprint: None,
            message: "密钥内容为空".to_string(),
        };
    }

    if trimmed.starts_with("ssh-") || trimmed.starts_with("ecdsa-") {
        return KeyInspectionResult {
            valid: false,
            encrypted: false,
            algorithm: None,
            fingerprint: None,
            message: "检测到这是公钥文件 (.pub)，请选择对应的私钥文件".to_string(),
        };
    }

    let pass_opt = if passphrase.is_empty() {
        None
    } else {
        Some(passphrase)
    };

    match decode_secret_key(trimmed, pass_opt) {
        Ok(key) => {
            let alg = key.algorithm().to_string();
            let fp = key.public_key().fingerprint(HashAlg::Sha256).to_string();
            KeyInspectionResult {
                valid: true,
                encrypted: !passphrase.is_empty() || trimmed.contains("ENCRYPTED"),
                algorithm: Some(alg.clone()),
                fingerprint: Some(fp.clone()),
                message: format!("{alg} · {fp}"),
            }
        }
        Err(err) => {
            let is_encrypted_err = matches!(
                err,
                russh_keys::Error::KeyIsEncrypted
                    | russh_keys::Error::SshKey(russh_keys::ssh_key::Error::Encrypted)
            ) || (passphrase.is_empty() && trimmed.contains("ENCRYPTED"));

            if is_encrypted_err {
                let msg = if passphrase.is_empty() {
                    "该私钥受口令保护，请在下方输入口令".to_string()
                } else {
                    "私钥口令不正确，请重新输入".to_string()
                };
                KeyInspectionResult {
                    valid: false,
                    encrypted: true,
                    algorithm: None,
                    fingerprint: None,
                    message: msg,
                }
            } else {
                KeyInspectionResult {
                    valid: false,
                    encrypted: false,
                    algorithm: None,
                    fingerprint: None,
                    message: format!("无法识别的私钥格式: {err}"),
                }
            }
        }
    }
}

pub fn discover_local_ssh_keys() -> Vec<DiscoveredSshKey> {
    let home = std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(std::path::PathBuf::from);
    let Some(ssh_dir) = home.map(|h| h.join(".ssh")) else {
        return Vec::new();
    };
    if !ssh_dir.is_dir() {
        return Vec::new();
    }

    let Ok(entries) = std::fs::read_dir(&ssh_dir) else {
        return Vec::new();
    };

    let mut found = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let lower = name.to_ascii_lowercase();
        if lower.ends_with(".pub")
            || lower.starts_with("known_hosts")
            || lower.starts_with("authorized_keys")
            || lower.starts_with("config")
            || lower.ends_with(".bak")
            || lower.ends_with(".old")
        {
            continue;
        }

        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if meta.len() == 0 || meta.len() > 65536 {
            continue;
        }

        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        let trimmed = content.trim_start();
        if !trimmed.starts_with("-----BEGIN ") {
            continue;
        }

        let probe = inspect_private_key(trimmed, "", "");
        if probe.valid || probe.encrypted {
            found.push(DiscoveredSshKey {
                name: name.to_string(),
                path: path.to_string_lossy().to_string(),
                encrypted: probe.encrypted,
            });
        }
    }

    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

#[cfg(test)]
mod tests {
    use super::build_stdio_forward_command;

    #[test]
    fn stdio_forward_command_handles_ipv4_ipv6_and_blocks_injection() {
        let ipv4 = build_stdio_forward_command("10.0.0.5", 22).expect("valid ipv4");
        assert!(ipv4.contains("TCP:10.0.0.5:22"));
        assert!(ipv4.contains("nc '10.0.0.5' 22"));
        assert!(ipv4.contains("python3 -u -c"));

        let ipv6 = build_stdio_forward_command("[2001:db8::1]", 2222).expect("valid ipv6");
        assert!(ipv6.contains("TCP6:[2001:db8::1]:2222"));

        assert!(build_stdio_forward_command("10.0.0.5; rm -rf /", 22).is_err());
        assert!(build_stdio_forward_command("-oProxyCommand=evil", 22).is_err());
        assert!(build_stdio_forward_command("10.0.0.5", 0).is_err());
    }
}
