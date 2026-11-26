use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use russh_sftp::client::SftpSession;
use russh_sftp::protocol::{FileAttributes, FileType};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex as AsyncMutex;

use crate::models::{SessionStatusEvent, SftpDirListing, SftpEntry};
use crate::ssh;

static SFTP_CACHE: OnceLock<Mutex<HashMap<String, Arc<AsyncMutex<SftpSession>>>>> =
    OnceLock::new();

fn sftp_cache() -> &'static Mutex<HashMap<String, Arc<AsyncMutex<SftpSession>>>> {
    SFTP_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn drop_cached_sftp(session_id: &str) {
    if let Ok(mut guard) = sftp_cache().lock() {
        guard.remove(session_id);
    }
}

async fn open_fresh_sftp(session_id: &str) -> Result<Arc<AsyncMutex<SftpSession>>, String> {
    let handle = ssh::get_session_handle(session_id)?;
    let channel = handle
        .channel_open_session()
        .await
        .map_err(|e| format!("打开 SFTP 通道失败: {e}"))?;
    channel
        .request_subsystem(true, "sftp")
        .await
        .map_err(|e| format!("服务端拒绝启动 SFTP 子系统: {e}"))?;

    let sftp = SftpSession::new(channel.into_stream())
        .await
        .map_err(|e| format!("初始化 SFTP 会话失败: {e}"))?;
    sftp.set_timeout(30);

    let arc = Arc::new(AsyncMutex::new(sftp));
    if let Ok(mut guard) = sftp_cache().lock() {
        guard.insert(session_id.to_string(), Arc::clone(&arc));
    }
    Ok(arc)
}

async fn get_or_open_sftp(session_id: &str) -> Result<Arc<AsyncMutex<SftpSession>>, String> {
    let cached = sftp_cache()
        .lock()
        .ok()
        .and_then(|g| g.get(session_id).cloned());
    if let Some(existing) = cached {
        return Ok(existing);
    }
    open_fresh_sftp(session_id).await
}

pub fn list_dir_blocking(session_id: &str, path: &str) -> Result<SftpDirListing, String> {
    let sid = session_id.to_string();
    let requested = path.trim().to_string();

    ssh::runtime().block_on(async move {
        let sftp_arc = get_or_open_sftp(&sid).await?;
        let attempt = list_dir_inner(&sftp_arc, &requested).await;
        match attempt {
            Ok(listing) => Ok(listing),
            Err(_) => {
                // Retry once with a fresh SFTP channel in case subsystem timed out
                drop_cached_sftp(&sid);
                let fresh = open_fresh_sftp(&sid).await?;
                list_dir_inner(&fresh, &requested).await
            }
        }
    })
}

async fn list_dir_inner(
    sftp_arc: &Arc<AsyncMutex<SftpSession>>,
    requested: &str,
) -> Result<SftpDirListing, String> {
    let sftp = sftp_arc.lock().await;
    let resolved_path = if requested.is_empty() || requested == "." {
        sftp.canonicalize(".")
            .await
            .unwrap_or_else(|_| "/".to_string())
    } else {
        sftp.canonicalize(requested)
            .await
            .unwrap_or_else(|_| requested.to_string())
    };

    let read_dir = sftp
        .read_dir(&resolved_path)
        .await
        .map_err(|e| format!("无法读取目录 ({resolved_path}): {e}"))?;

    let mut entries: Vec<SftpEntry> = Vec::new();
    for entry in read_dir {
        let name = entry.file_name();
        if name == "." || name == ".." {
            continue;
        }
        let meta = entry.metadata();
        let file_type = entry.file_type();
        let (kind, type_char) = match file_type {
            FileType::Dir => ("dir", 'd'),
            FileType::File => ("file", '-'),
            FileType::Symlink => ("symlink", 'l'),
            FileType::Other => ("other", '?'),
        };
        let raw_perm = meta.permissions.unwrap_or(0);
        let octal = raw_perm & 0o7777;
        let rwx = format!("{type_char}{}", meta.permissions());

        entries.push(SftpEntry {
            name,
            path: entry.path(),
            kind: kind.to_string(),
            size: meta.len(),
            permissions_octal: octal,
            permissions_rwx: rwx,
            modified_sec: meta.mtime.map(u64::from),
        });
    }

    entries.sort_by(|a, b| {
        let a_is_dir = a.kind == "dir";
        let b_is_dir = b.kind == "dir";
        b_is_dir
            .cmp(&a_is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(SftpDirListing {
        current_path: resolved_path,
        entries,
    })
}

pub fn create_dir_blocking(session_id: &str, path: &str) -> Result<(), String> {
    let sid = session_id.to_string();
    let target = path.trim().to_string();
    ssh::runtime().block_on(async move {
        let sftp_arc = get_or_open_sftp(&sid).await?;
        let sftp = sftp_arc.lock().await;
        sftp.create_dir(&target)
            .await
            .map_err(|e| format!("创建目录失败: {e}"))
    })
}

pub fn rename_blocking(session_id: &str, old_path: &str, new_path: &str) -> Result<(), String> {
    let sid = session_id.to_string();
    let from = old_path.trim().to_string();
    let to = new_path.trim().to_string();
    ssh::runtime().block_on(async move {
        let sftp_arc = get_or_open_sftp(&sid).await?;
        let sftp = sftp_arc.lock().await;
        sftp.rename(&from, &to)
            .await
            .map_err(|e| format!("重命名失败: {e}"))
    })
}

pub fn delete_blocking(session_id: &str, path: &str, is_dir: bool) -> Result<(), String> {
    let sid = session_id.to_string();
    let target = path.trim().to_string();
    ssh::runtime().block_on(async move {
        let sftp_arc = get_or_open_sftp(&sid).await?;
        let sftp = sftp_arc.lock().await;
        if is_dir {
            delete_dir_recursive(&sftp, &target).await
        } else {
            sftp.remove_file(&target)
                .await
                .map_err(|e| format!("删除文件失败: {e}"))
        }
    })
}

fn delete_dir_recursive<'a>(
    sftp: &'a SftpSession,
    dir_path: &'a str,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), String>> + Send + 'a>> {
    Box::pin(async move {
        let entries = sftp
            .read_dir(dir_path)
            .await
            .map_err(|e| format!("读取待删除目录失败: {e}"))?;
        for entry in entries {
            let child_path = entry.path();
            if entry.file_type().is_dir() {
                delete_dir_recursive(sftp, &child_path).await?;
            } else {
                sftp.remove_file(&child_path)
                    .await
                    .map_err(|e| format!("删除子文件失败 ({child_path}): {e}"))?;
            }
        }
        sftp.remove_dir(dir_path)
            .await
            .map_err(|e| format!("删除目录失败 ({dir_path}): {e}"))
    })
}

pub fn chmod_blocking(session_id: &str, path: &str, mode_octal: u32) -> Result<(), String> {
    let sid = session_id.to_string();
    let target = path.trim().to_string();
    ssh::runtime().block_on(async move {
        let sftp_arc = get_or_open_sftp(&sid).await?;
        let sftp = sftp_arc.lock().await;
        let mut attrs = FileAttributes::empty();
        attrs.permissions = Some(mode_octal & 0o7777);
        sftp.set_metadata(&target, attrs)
            .await
            .map_err(|e| format!("修改权限失败: {e}"))
    })
}

pub fn download_file_blocking(
    session_id: &str,
    transfer_id: &str,
    remote_path: &str,
    local_path: &str,
) -> Result<u64, String> {
    let sid = session_id.to_string();
    let tid = transfer_id.to_string();
    let r_path = remote_path.trim().to_string();
    let l_path = local_path.trim().to_string();

    let file_name = r_path
        .rsplit('/')
        .next()
        .unwrap_or(&r_path)
        .to_string();

    ssh::runtime().block_on(async move {
        // Open a dedicated SFTP channel for large file transfers so directory browsing never stalls!
        let handle = ssh::get_session_handle(&sid)?;
        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("打开下载通道失败: {e}"))?;
        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|e| format!("启动下载 SFTP 子系统失败: {e}"))?;
        let sftp = SftpSession::new(channel.into_stream())
            .await
            .map_err(|e| format!("初始化下载会话失败: {e}"))?;
        sftp.set_timeout(60);

        let total_bytes = sftp
            .metadata(&r_path)
            .await
            .map(|m| m.len())
            .unwrap_or(0);

        let mut remote_file = sftp
            .open(&r_path)
            .await
            .map_err(|e| format!("打开远程文件失败: {e}"))?;

        if let Some(parent) = Path::new(&l_path).parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        let mut local_file = tokio::fs::File::create(&l_path)
            .await
            .map_err(|e| format!("创建本地文件失败: {e}"))?;

        let mut buf = vec![0u8; 65536];
        let mut transferred = 0u64;
        let mut last_emit = Instant::now();

        ssh::emit_status(SessionStatusEvent::SftpProgress {
            transfer_id: tid.clone(),
            session_id: sid.clone(),
            direction: "download".to_string(),
            file_name: file_name.clone(),
            transferred_bytes: 0,
            total_bytes,
            done: false,
            error: None,
        });

        loop {
            let n = match remote_file.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) => {
                    let msg = format!("读取远程文件中断: {e}");
                    ssh::emit_status(SessionStatusEvent::SftpProgress {
                        transfer_id: tid,
                        session_id: sid,
                        direction: "download".to_string(),
                        file_name,
                        transferred_bytes: transferred,
                        total_bytes,
                        done: true,
                        error: Some(msg.clone()),
                    });
                    return Err(msg);
                }
            };

            if let Err(e) = local_file.write_all(&buf[..n]).await {
                let msg = format!("写入本地磁盘失败: {e}");
                ssh::emit_status(SessionStatusEvent::SftpProgress {
                    transfer_id: tid,
                    session_id: sid,
                    direction: "download".to_string(),
                    file_name,
                    transferred_bytes: transferred,
                    total_bytes,
                    done: true,
                    error: Some(msg.clone()),
                });
                return Err(msg);
            }

            transferred += n as u64;
            if last_emit.elapsed() >= Duration::from_millis(80) {
                last_emit = Instant::now();
                ssh::emit_status(SessionStatusEvent::SftpProgress {
                    transfer_id: tid.clone(),
                    session_id: sid.clone(),
                    direction: "download".to_string(),
                    file_name: file_name.clone(),
                    transferred_bytes: transferred,
                    total_bytes: total_bytes.max(transferred),
                    done: false,
                    error: None,
                });
            }
        }

        let _ = local_file.flush().await;
        let _ = sftp.close().await;

        ssh::emit_status(SessionStatusEvent::SftpProgress {
            transfer_id: tid,
            session_id: sid,
            direction: "download".to_string(),
            file_name,
            transferred_bytes: transferred,
            total_bytes: total_bytes.max(transferred),
            done: true,
            error: None,
        });

        Ok(transferred)
    })
}

pub fn upload_file_blocking(
    session_id: &str,
    transfer_id: &str,
    local_path: &str,
    remote_path: &str,
) -> Result<u64, String> {
    let sid = session_id.to_string();
    let tid = transfer_id.to_string();
    let l_path = local_path.trim().to_string();
    let r_path = remote_path.trim().to_string();

    let file_name = Path::new(&l_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("upload.bin")
        .to_string();

    ssh::runtime().block_on(async move {
        let meta = tokio::fs::metadata(&l_path)
            .await
            .map_err(|e| format!("读取本地文件信息失败: {e}"))?;
        let total_bytes = meta.len();

        let mut local_file = tokio::fs::File::open(&l_path)
            .await
            .map_err(|e| format!("打开本地文件失败: {e}"))?;

        let handle = ssh::get_session_handle(&sid)?;
        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("打开上传通道失败: {e}"))?;
        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|e| format!("启动上传 SFTP 子系统失败: {e}"))?;
        let sftp = SftpSession::new(channel.into_stream())
            .await
            .map_err(|e| format!("初始化上传会话失败: {e}"))?;
        sftp.set_timeout(60);

        let mut remote_file = sftp
            .create(&r_path)
            .await
            .map_err(|e| format!("创建远程文件失败 ({r_path}): {e}"))?;

        let mut buf = vec![0u8; 65536];
        let mut transferred = 0u64;
        let mut last_emit = Instant::now();

        ssh::emit_status(SessionStatusEvent::SftpProgress {
            transfer_id: tid.clone(),
            session_id: sid.clone(),
            direction: "upload".to_string(),
            file_name: file_name.clone(),
            transferred_bytes: 0,
            total_bytes,
            done: false,
            error: None,
        });

        loop {
            let n = local_file
                .read(&mut buf)
                .await
                .map_err(|e| format!("读取本地文件失败: {e}"))?;
            if n == 0 {
                break;
            }
            if let Err(e) = remote_file.write_all(&buf[..n]).await {
                let msg = format!("上传写入中断: {e}");
                ssh::emit_status(SessionStatusEvent::SftpProgress {
                    transfer_id: tid,
                    session_id: sid,
                    direction: "upload".to_string(),
                    file_name,
                    transferred_bytes: transferred,
                    total_bytes,
                    done: true,
                    error: Some(msg.clone()),
                });
                return Err(msg);
            }

            transferred += n as u64;
            if last_emit.elapsed() >= Duration::from_millis(80) {
                last_emit = Instant::now();
                ssh::emit_status(SessionStatusEvent::SftpProgress {
                    transfer_id: tid.clone(),
                    session_id: sid.clone(),
                    direction: "upload".to_string(),
                    file_name: file_name.clone(),
                    transferred_bytes: transferred,
                    total_bytes,
                    done: false,
                    error: None,
                });
            }
        }

        let _ = remote_file.flush().await;
        let _ = remote_file.shutdown().await;
        let _ = sftp.close().await;

        ssh::emit_status(SessionStatusEvent::SftpProgress {
            transfer_id: tid,
            session_id: sid,
            direction: "upload".to_string(),
            file_name,
            transferred_bytes: transferred,
            total_bytes,
            done: true,
            error: None,
        });

        Ok(transferred)
    })
}
