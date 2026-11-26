#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
use crate::models::LocalShellOption;

#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
mod desktop_pty {
    use std::collections::{HashMap, HashSet};
    use std::io::{Read, Write};
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex, OnceLock};

    use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};

    use crate::models::{LocalShellOption, SessionStatusEvent};
    use crate::ssh;

    struct LocalSessionEntry {
        master: Mutex<Box<dyn MasterPty + Send>>,
        writer: Mutex<Box<dyn Write + Send>>,
        killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
        last_size: Mutex<(u16, u16)>,
    }

    static LOCAL_SESSIONS: OnceLock<Mutex<HashMap<String, Arc<LocalSessionEntry>>>> =
        OnceLock::new();

    fn local_sessions() -> &'static Mutex<HashMap<String, Arc<LocalSessionEntry>>> {
        LOCAL_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
    }

    fn find_in_path(binary: &str) -> Option<PathBuf> {
        let path_var = std::env::var_os("PATH")?;
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join(binary);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        None
    }

    fn default_home_dir() -> Option<PathBuf> {
        #[cfg(windows)]
        {
            std::env::var_os("USERPROFILE")
                .map(PathBuf::from)
                .filter(|p| p.is_dir())
        }
        #[cfg(not(windows))]
        {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|p| p.is_dir())
        }
    }

    #[cfg(windows)]
    pub fn discover_local_shells() -> Vec<LocalShellOption> {
        let mut shells = Vec::new();
        let mut seen = HashSet::new();

        let mut push_if_exists = |id: &str, name: &str, path: PathBuf, args: Vec<String>| {
            let key = path.to_string_lossy().to_lowercase();
            if path.is_file() && seen.insert(key) {
                shells.push(LocalShellOption {
                    id: id.to_string(),
                    name: name.to_string(),
                    program: path.to_string_lossy().to_string(),
                    args,
                    is_default: false,
                });
            }
        };

        // 1. PowerShell 7+ (pwsh)
        if let Some(p) = find_in_path("pwsh.exe").or_else(|| {
            let p = PathBuf::from(r"C:\Program Files\PowerShell\7\pwsh.exe");
            p.is_file().then_some(p)
        }) {
            push_if_exists("pwsh", "PowerShell 7", p, vec!["-NoLogo".to_string()]);
        }

        // 2. Windows PowerShell 5.1
        if let Some(p) = find_in_path("powershell.exe").or_else(|| {
            let sys_root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".to_string());
            let p = PathBuf::from(sys_root)
                .join("System32")
                .join("WindowsPowerShell")
                .join("v1.0")
                .join("powershell.exe");
            p.is_file().then_some(p)
        }) {
            push_if_exists(
                "powershell",
                "Windows PowerShell",
                p,
                vec!["-NoLogo".to_string()],
            );
        }

        // 3. Command Prompt (CMD)
        let cmd_path = std::env::var_os("COMSPEC")
            .map(PathBuf::from)
            .filter(|p| p.is_file())
            .or_else(|| find_in_path("cmd.exe"))
            .unwrap_or_else(|| PathBuf::from(r"C:\Windows\System32\cmd.exe"));
        push_if_exists("cmd", "命令提示符 (CMD)", cmd_path, Vec::new());

        // 4. Git Bash (optional)
        let git_bash_candidates = [
            PathBuf::from(r"C:\Program Files\Git\bin\bash.exe"),
            PathBuf::from(r"C:\Program Files (x86)\Git\bin\bash.exe"),
        ];
        if let Some(p) = git_bash_candidates.into_iter().find(|p| p.is_file()) {
            push_if_exists(
                "git-bash",
                "Git Bash",
                p,
                vec!["-l".to_string(), "-i".to_string()],
            );
        }

        // 5. WSL (detect installed distros via Windows Lxss Registry first — matching
        // Windows Terminal — with a System32 wsl.exe fallback so we never depend on
        // fragile WindowsApps aliases or cold WslService subprocess calls).
        if let Some(p) = find_wsl_executable() {
            let distros = discover_usable_wsl_distros(&p);
            if let Some(primary) = distros.first() {
                let label = if distros.len() == 1 {
                    format!("WSL ({primary})")
                } else {
                    format!("WSL ({primary} +{})", distros.len() - 1)
                };
                push_if_exists(
                    "wsl",
                    &label,
                    p,
                    vec!["-d".to_string(), primary.clone()],
                );
            }
        }

        if let Some(first) = shells.first_mut() {
            first.is_default = true;
        }
        shells
    }

    #[cfg(windows)]
    fn find_wsl_executable() -> Option<PathBuf> {
        let sys_root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".to_string());
        let candidates = [
            PathBuf::from(&sys_root).join("System32").join("wsl.exe"),
            PathBuf::from(r"C:\Program Files\WSL\wsl.exe"),
        ];
        for cand in candidates {
            if cand.is_file() {
                return Some(cand);
            }
        }
        find_in_path("wsl.exe")
    }

    #[cfg(windows)]
    fn is_usable_wsl_distro_name(raw: &str) -> Option<String> {
        let cleaned = raw
            .trim()
            .trim_matches('\0')
            .trim_start_matches('\u{feff}')
            .trim();
        if cleaned.is_empty()
            || cleaned.eq_ignore_ascii_case("docker-desktop")
            || cleaned.eq_ignore_ascii_case("docker-desktop-data")
            || cleaned.eq_ignore_ascii_case("rancher-desktop")
            || cleaned.eq_ignore_ascii_case("rancher-desktop-data")
        {
            return None;
        }
        // Guard against localized usage/help output ever being misinterpreted as a distro name
        if cleaned.contains(':') || cleaned.contains("--") || cleaned.len() > 64 {
            return None;
        }
        Some(cleaned.to_string())
    }

    #[cfg(windows)]
    fn decode_wsl_output(bytes: &[u8]) -> String {
        if bytes.is_empty() {
            return String::new();
        }
        let looks_utf16le = bytes.len() >= 2
            && (bytes.starts_with(&[0xFF, 0xFE])
                || bytes.iter().skip(1).step_by(2).take(16).any(|&b| b == 0));
        if looks_utf16le {
            let slice = if bytes.starts_with(&[0xFF, 0xFE]) {
                &bytes[2..]
            } else {
                bytes
            };
            let u16s: Vec<u16> = slice
                .chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();
            return String::from_utf16_lossy(&u16s);
        }
        String::from_utf8_lossy(bytes)
            .trim_start_matches('\u{feff}')
            .to_string()
    }

    #[cfg(windows)]
    fn to_wide_null(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    #[cfg(windows)]
    fn read_reg_sz(hkey: windows_sys::Win32::System::Registry::HKEY, name: &str) -> Option<String> {
        use windows_sys::Win32::Foundation::ERROR_SUCCESS;
        use windows_sys::Win32::System::Registry::{RegQueryValueExW, REG_EXPAND_SZ, REG_SZ};

        let value_name = to_wide_null(name);
        let mut reg_type: u32 = 0;
        let mut byte_len: u32 = 0;
        let status = unsafe {
            RegQueryValueExW(
                hkey,
                value_name.as_ptr(),
                std::ptr::null_mut(),
                &mut reg_type,
                std::ptr::null_mut(),
                &mut byte_len,
            )
        };
        if status != ERROR_SUCCESS || byte_len < 2 || (reg_type != REG_SZ && reg_type != REG_EXPAND_SZ)
        {
            return None;
        }
        let mut buf = vec![0u16; (byte_len as usize).div_ceil(2)];
        let status = unsafe {
            RegQueryValueExW(
                hkey,
                value_name.as_ptr(),
                std::ptr::null_mut(),
                &mut reg_type,
                buf.as_mut_ptr() as *mut u8,
                &mut byte_len,
            )
        };
        if status != ERROR_SUCCESS {
            return None;
        }
        let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        Some(String::from_utf16_lossy(&buf[..len]))
    }

    #[cfg(windows)]
    fn read_reg_dword(hkey: windows_sys::Win32::System::Registry::HKEY, name: &str) -> Option<u32> {
        use windows_sys::Win32::Foundation::ERROR_SUCCESS;
        use windows_sys::Win32::System::Registry::{RegQueryValueExW, REG_DWORD};

        let value_name = to_wide_null(name);
        let mut reg_type: u32 = 0;
        let mut value: u32 = 0;
        let mut byte_len: u32 = std::mem::size_of::<u32>() as u32;
        let status = unsafe {
            RegQueryValueExW(
                hkey,
                value_name.as_ptr(),
                std::ptr::null_mut(),
                &mut reg_type,
                (&mut value as *mut u32) as *mut u8,
                &mut byte_len,
            )
        };
        if status == ERROR_SUCCESS && reg_type == REG_DWORD {
            Some(value)
        } else {
            None
        }
    }

    /// Reads registered WSL distributions from `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`
    /// (the exact registry source used by Windows Terminal), placing the default distro first.
    #[cfg(windows)]
    fn discover_wsl_distros_from_registry() -> Vec<String> {
        use windows_sys::Win32::Foundation::{ERROR_NO_MORE_ITEMS, ERROR_SUCCESS};
        use windows_sys::Win32::System::Registry::{
            RegCloseKey, RegEnumKeyExW, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_READ,
        };

        let subkey_path = to_wide_null(r"Software\Microsoft\Windows\CurrentVersion\Lxss");
        let mut lxss_key: HKEY = 0;
        let open_status = unsafe {
            RegOpenKeyExW(
                HKEY_CURRENT_USER,
                subkey_path.as_ptr(),
                0,
                KEY_READ,
                &mut lxss_key,
            )
        };
        if open_status != ERROR_SUCCESS || lxss_key == 0 {
            return Vec::new();
        }

        let default_guid = read_reg_sz(lxss_key, "DefaultDistribution").unwrap_or_default();
        let mut default_distro: Option<String> = None;
        let mut others: Vec<String> = Vec::new();

        let mut index: u32 = 0;
        loop {
            let mut name_buf = [0u16; 256];
            let mut name_len: u32 = name_buf.len() as u32;
            let status = unsafe {
                RegEnumKeyExW(
                    lxss_key,
                    index,
                    name_buf.as_mut_ptr(),
                    &mut name_len,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            };
            if status == ERROR_NO_MORE_ITEMS {
                break;
            }
            index += 1;
            if status != ERROR_SUCCESS {
                continue;
            }

            let guid_name = String::from_utf16_lossy(&name_buf[..name_len as usize]);
            let guid_wide = to_wide_null(&guid_name);
            let mut distro_key: HKEY = 0;
            let sub_status = unsafe {
                RegOpenKeyExW(
                    lxss_key,
                    guid_wide.as_ptr(),
                    0,
                    KEY_READ,
                    &mut distro_key,
                )
            };
            if sub_status != ERROR_SUCCESS || distro_key == 0 {
                continue;
            }

            // State == 0 indicates a distro being installed or removed; 1 (or absent) is usable
            let state_ok = read_reg_dword(distro_key, "State").map_or(true, |s| s != 0);
            let distro_name = if state_ok {
                read_reg_sz(distro_key, "DistributionName")
                    .and_then(|n| is_usable_wsl_distro_name(&n))
            } else {
                None
            };
            unsafe {
                RegCloseKey(distro_key);
            }

            if let Some(name) = distro_name {
                if !default_guid.is_empty() && guid_name.eq_ignore_ascii_case(&default_guid) {
                    default_distro = Some(name);
                } else {
                    others.push(name);
                }
            }
        }

        unsafe {
            RegCloseKey(lxss_key);
        }

        others.sort_by_key(|s| s.to_ascii_lowercase());
        let mut result = Vec::new();
        if let Some(def) = default_distro {
            result.push(def);
        }
        for name in others {
            if !result.iter().any(|existing| existing.eq_ignore_ascii_case(&name)) {
                result.push(name);
            }
        }
        result
    }

    #[cfg(windows)]
    fn discover_usable_wsl_distros(wsl_exe: &Path) -> Vec<String> {
        // 1. Primary: HKCU\...\Lxss registry (instant, no subprocess/ASR/WindowsApps failure modes)
        let reg_distros = discover_wsl_distros_from_registry();
        if !reg_distros.is_empty() {
            return reg_distros;
        }

        // 2. Fallback: `wsl.exe -l -q` with null stdin & CREATE_NO_WINDOW
        use std::os::windows::process::CommandExt;
        use std::process::Stdio;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;

        let Ok(output) = std::process::Command::new(wsl_exe)
            .args(["-l", "-q"])
            .env("WSL_UTF8", "1")
            .stdin(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .output()
        else {
            return Vec::new();
        };
        if !output.status.success() {
            return Vec::new();
        }
        let text = decode_wsl_output(&output.stdout);
        let mut found = Vec::new();
        for line in text.lines() {
            if let Some(name) = is_usable_wsl_distro_name(line) {
                if !found.iter().any(|e: &String| e.eq_ignore_ascii_case(&name)) {
                    found.push(name);
                }
            }
        }
        found
    }

    #[cfg(not(windows))]
    pub fn discover_local_shells() -> Vec<LocalShellOption> {
        let mut shells = Vec::new();
        let mut seen = HashSet::new();

        let mut push_unix_shell = |path_str: &str| {
            let p = Path::new(path_str);
            if !p.is_file() {
                return;
            }
            let canon = p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
            let key = canon.to_string_lossy().to_string();
            if !seen.insert(key) {
                return;
            }
            let bin = p
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("sh")
                .to_string();
            let (name, args) = match bin.as_str() {
                "zsh" => ("Zsh", vec!["-l".to_string()]),
                "bash" => ("Bash", vec!["-l".to_string()]),
                "fish" => ("Fish", vec!["-l".to_string()]),
                "sh" => ("POSIX sh", Vec::new()),
                other => (other, Vec::new()),
            };
            shells.push(LocalShellOption {
                id: bin,
                name: name.to_string(),
                program: path_str.to_string(),
                args,
                is_default: false,
            });
        };

        if let Ok(env_shell) = std::env::var("SHELL") {
            let trimmed = env_shell.trim();
            if !trimmed.is_empty() {
                push_unix_shell(trimmed);
            }
        }
        for candidate in [
            "/bin/zsh",
            "/usr/bin/zsh",
            "/opt/homebrew/bin/zsh",
            "/bin/bash",
            "/usr/bin/bash",
            "/usr/bin/fish",
            "/opt/homebrew/bin/fish",
            "/bin/sh",
        ] {
            push_unix_shell(candidate);
        }

        if let Some(first) = shells.first_mut() {
            first.is_default = true;
        }
        shells
    }

    pub fn start_local_session(
        session_id: String,
        shell_program: String,
        args: Vec<String>,
        cwd: String,
        cols: u32,
        rows: u32,
    ) -> Result<String, String> {
        let _ = disconnect_session(&session_id);

        let discovered = discover_local_shells();
        let (program, launch_args, display_name) = if shell_program.trim().is_empty() {
            let def = discovered
                .into_iter()
                .next()
                .ok_or_else(|| "未检测到可用的本地 Shell".to_string())?;
            (def.program, def.args, def.name)
        } else {
            let prog = shell_program.trim().to_string();
            let matched = discovered
                .into_iter()
                .find(|s| s.program.eq_ignore_ascii_case(&prog) || s.id.eq_ignore_ascii_case(&prog));
            if let Some(m) = matched {
                let final_args = if args.is_empty() { m.args } else { args };
                (m.program, final_args, m.name)
            } else {
                let label = Path::new(&prog)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("Local Shell")
                    .to_string();
                (prog, args, label)
            }
        };

        let pty_size = PtySize {
            rows: rows.clamp(5, 500) as u16,
            cols: cols.clamp(10, 500) as u16,
            pixel_width: 0,
            pixel_height: 0,
        };

        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(pty_size)
            .map_err(|e| format!("初始化本地 PTY 失败: {e}"))?;

        let mut cmd = CommandBuilder::new(&program);
        for a in &launch_args {
            cmd.arg(a);
        }
        if !cwd.trim().is_empty() && Path::new(cwd.trim()).is_dir() {
            cmd.cwd(cwd.trim());
        } else if let Some(home) = default_home_dir() {
            cmd.cwd(home);
        }
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");

        let mut child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| format!("启动本地终端 ({program}) 失败: {e}"))?;
        // Drop slave end immediately so EOF is observed cleanly when the child exits.
        drop(pair.slave);

        let killer = child.clone_killer();
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("创建 PTY 输出流失败: {e}"))?;
        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("创建 PTY 输入流失败: {e}"))?;

        let entry = Arc::new(LocalSessionEntry {
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            killer: Mutex::new(killer),
            last_size: Mutex::new((pty_size.cols, pty_size.rows)),
        });

        {
            let mut guard = local_sessions()
                .lock()
                .map_err(|_| "本地会话注册表锁异常".to_string())?;
            guard.insert(session_id.clone(), entry);
        }

        ssh::emit_status(SessionStatusEvent::Connected {
            session_id: session_id.clone(),
            server_fingerprint: display_name.clone(),
            auth_used: "local-pty".to_string(),
            latency_ms: 0,
        });

        let sid_for_reader = session_id.clone();
        std::thread::Builder::new()
            .name(format!("nexus-pty-read-{session_id}"))
            .spawn(move || {
                let mut buf = [0u8; 4096];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => ssh::emit_output(&sid_for_reader, &buf[..n]),
                        Err(_) => break,
                    }
                }
                let exit_code = child.wait().ok().map(|s| s.exit_code());
                let removed = local_sessions()
                    .lock()
                    .ok()
                    .and_then(|mut g| g.remove(&sid_for_reader))
                    .is_some();
                if removed {
                    ssh::emit_status(SessionStatusEvent::Disconnected {
                        session_id: sid_for_reader,
                        reason: "本地终端会话已结束".to_string(),
                        exit_code,
                    });
                }
            })
            .map_err(|e| format!("创建 PTY 读取线程失败: {e}"))?;

        Ok(display_name)
    }

    pub fn write_to_session(session_id: &str, bytes: &[u8]) -> Result<bool, String> {
        let entry = {
            let guard = local_sessions()
                .lock()
                .map_err(|_| "本地会话表锁异常".to_string())?;
            guard.get(session_id).cloned()
        };
        let Some(entry) = entry else {
            return Ok(false);
        };
        let mut writer = entry
            .writer
            .lock()
            .map_err(|_| "本地 PTY 写锁异常".to_string())?;
        writer
            .write_all(bytes)
            .and_then(|_| writer.flush())
            .map_err(|e| format!("写入本地终端失败: {e}"))?;
        Ok(true)
    }

    pub fn resize_session(
        session_id: &str,
        cols: u32,
        rows: u32,
        pixel_width: u32,
        pixel_height: u32,
    ) -> Result<bool, String> {
        let entry = {
            let guard = local_sessions()
                .lock()
                .map_err(|_| "本地会话表锁异常".to_string())?;
            guard.get(session_id).cloned()
        };
        let Some(entry) = entry else {
            return Ok(false);
        };
        let next_cols = cols.clamp(10, 500) as u16;
        let next_rows = rows.clamp(5, 500) as u16;
        {
            let mut last = entry
                .last_size
                .lock()
                .map_err(|_| "本地 PTY 尺寸状态锁异常".to_string())?;
            if *last == (next_cols, next_rows) {
                return Ok(true);
            }
            *last = (next_cols, next_rows);
        }
        let master = entry
            .master
            .lock()
            .map_err(|_| "本地 PTY 尺寸锁异常".to_string())?;
        master
            .resize(PtySize {
                rows: next_rows,
                cols: next_cols,
                pixel_width: pixel_width.min(u16::MAX as u32) as u16,
                pixel_height: pixel_height.min(u16::MAX as u32) as u16,
            })
            .map_err(|e| format!("调整本地终端尺寸失败: {e}"))?;
        Ok(true)
    }

    pub fn disconnect_session(session_id: &str) -> Result<bool, String> {
        let entry = {
            let mut guard = local_sessions()
                .lock()
                .map_err(|_| "本地会话表锁异常".to_string())?;
            guard.remove(session_id)
        };
        let Some(entry) = entry else {
            return Ok(false);
        };
        // Move kill() + drop(entry) (Windows ClosePseudoConsole) off the UI thread
        // so closing a local terminal tab or exiting never stalls Flutter.
        let _ = std::thread::Builder::new()
            .name("nexus-pty-close".to_string())
            .spawn(move || {
                if let Ok(mut killer) = entry.killer.lock() {
                    let _ = killer.kill();
                }
                drop(entry);
            });
        Ok(true)
    }

    pub fn disconnect_all_sessions() {
        let entries: Vec<Arc<LocalSessionEntry>> = {
            let Ok(mut guard) = local_sessions().lock() else {
                return;
            };
            guard.drain().map(|(_, v)| v).collect()
        };
        if entries.is_empty() {
            return;
        }
        let _ = std::thread::Builder::new()
            .name("nexus-pty-shutdown".to_string())
            .spawn(move || {
                for entry in entries {
                    if let Ok(mut killer) = entry.killer.lock() {
                        let _ = killer.kill();
                    }
                    drop(entry);
                }
            });
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::Mutex as StdMutex;
        use std::time::{Duration, Instant};

        static CAPTURED_OUT: OnceLock<StdMutex<String>> = OnceLock::new();

        fn test_out_sink(_sid: &str, bytes: &[u8]) {
            let buf = CAPTURED_OUT.get_or_init(|| StdMutex::new(String::new()));
            if let Ok(mut g) = buf.lock() {
                g.push_str(&String::from_utf8_lossy(bytes));
            }
        }

        fn test_status_sink(_ev: SessionStatusEvent) {}

        #[test]
        fn discovers_shells_and_runs_interactive_local_pty() {
            let shells = discover_local_shells();
            assert!(!shells.is_empty(), "Expected at least one local shell");
            assert!(shells.iter().any(|s| s.is_default));

            ssh::register_sinks(test_out_sink, test_status_sink, false);
            if let Ok(mut g) = CAPTURED_OUT.get_or_init(|| StdMutex::new(String::new())).lock() {
                g.clear();
            }

            // Pick a fast shell (cmd on Windows, sh/bash/zsh on Unix)
            let target = shells
                .iter()
                .find(|s| s.id == "cmd" || s.id == "sh" || s.id == "bash" || s.id == "zsh")
                .unwrap_or(&shells[0]);

            let sid = "local-pty-unit-test".to_string();
            start_local_session(
                sid.clone(),
                target.program.clone(),
                target.args.clone(),
                String::new(),
                80,
                24,
            )
            .unwrap();

            assert!(resize_session(&sid, 100, 30, 0, 0).unwrap());
            assert!(write_to_session(&sid, b"echo NEXUS_LOCAL_PTY_OK\r\n").unwrap());

            let deadline = Instant::now() + Duration::from_secs(6);
            let mut found = false;
            while Instant::now() < deadline {
                if let Ok(g) = CAPTURED_OUT.get_or_init(|| StdMutex::new(String::new())).lock() {
                    if g.contains("NEXUS_LOCAL_PTY_OK") {
                        found = true;
                        break;
                    }
                }
                std::thread::sleep(Duration::from_millis(60));
            }

            assert!(disconnect_session(&sid).unwrap());
            assert!(found, "Did not observe echoed marker from local PTY");
        }

        #[cfg(windows)]
        #[test]
        fn decodes_wsl_utf16le_and_utf8_and_filters_internal_distros() {
            let mut utf16 = vec![0xFF, 0xFE];
            for ch in "Ubuntu-22.04\r\ndocker-desktop\r\nDebian\r\n".encode_utf16() {
                utf16.extend_from_slice(&ch.to_le_bytes());
            }
            let decoded = decode_wsl_output(&utf16);
            let parsed: Vec<String> = decoded
                .lines()
                .filter_map(is_usable_wsl_distro_name)
                .collect();
            assert_eq!(parsed, vec!["Ubuntu-22.04".to_string(), "Debian".to_string()]);

            let utf8 = "\u{feff}Ubuntu\r\ndocker-desktop-data\r\n--install <Options>\r\n".as_bytes();
            let decoded_utf8 = decode_wsl_output(utf8);
            let parsed_utf8: Vec<String> = decoded_utf8
                .lines()
                .filter_map(is_usable_wsl_distro_name)
                .collect();
            assert_eq!(parsed_utf8, vec!["Ubuntu".to_string()]);
        }
    }
}

#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
pub use desktop_pty::{
    disconnect_all_sessions, disconnect_session, discover_local_shells, resize_session,
    start_local_session, write_to_session,
};

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
pub fn disconnect_all_sessions() {}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
pub fn discover_local_shells() -> Vec<LocalShellOption> {
    Vec::new()
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
pub fn start_local_session(
    _session_id: String,
    _shell_program: String,
    _args: Vec<String>,
    _cwd: String,
    _cols: u32,
    _rows: u32,
) -> Result<String, String> {
    Err("当前平台暂不支持本地终端".to_string())
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
pub fn write_to_session(_session_id: &str, _bytes: &[u8]) -> Result<bool, String> {
    Ok(false)
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
pub fn resize_session(
    _session_id: &str,
    _cols: u32,
    _rows: u32,
    _pixel_width: u32,
    _pixel_height: u32,
) -> Result<bool, String> {
    Ok(false)
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
pub fn disconnect_session(_session_id: &str) -> Result<bool, String> {
    Ok(false)
}
