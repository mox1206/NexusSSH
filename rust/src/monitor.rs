use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use russh::ChannelMsg;

use crate::models::{DiskUsageItem, NetInterfaceRate, ServerMetrics};
use crate::ssh;
use crate::store;

struct PrevSessionSample {
    sampled_at: Instant,
    cpu_total: u64,
    cpu_idle: u64,
    net_totals: HashMap<String, (u64, u64)>, // iface -> (rx, tx)
}

static PREV_SAMPLES: OnceLock<Mutex<HashMap<String, PrevSessionSample>>> = OnceLock::new();

fn prev_samples() -> &'static Mutex<HashMap<String, PrevSessionSample>> {
    PREV_SAMPLES.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn drop_cached_metrics(session_id: &str) {
    if let Ok(mut guard) = prev_samples().lock() {
        guard.remove(session_id);
    }
}

const PROBE_SINGLE_CMD: &str = concat!(
    "LC_ALL=C; ",
    "echo '===HOST==='; uname -n 2>/dev/null; uname -sr 2>/dev/null; ",
    "grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null; ",
    "echo '===UPTIME==='; cat /proc/uptime 2>/dev/null; ",
    "echo '===CORES==='; nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null; ",
    "echo '===LOAD==='; cat /proc/loadavg 2>/dev/null; ",
    "echo '===STAT==='; head -n 1 /proc/stat 2>/dev/null; ",
    "echo '===MEM==='; grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null; ",
    "echo '===DISK==='; df -P -k 2>/dev/null; ",
    "echo '===NET==='; cat /proc/net/dev 2>/dev/null"
);

// Used on the very first poll so CPU % and Network B/s have an immediate 200ms baseline!
const PROBE_INITIAL_DUAL_CMD: &str = concat!(
    "LC_ALL=C; ",
    "echo '===STAT0==='; head -n 1 /proc/stat 2>/dev/null; ",
    "echo '===NET0==='; cat /proc/net/dev 2>/dev/null; ",
    "sleep 0.2 2>/dev/null || sleep 1; ",
    "echo '===HOST==='; uname -n 2>/dev/null; uname -sr 2>/dev/null; ",
    "grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null; ",
    "echo '===UPTIME==='; cat /proc/uptime 2>/dev/null; ",
    "echo '===CORES==='; nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null; ",
    "echo '===LOAD==='; cat /proc/loadavg 2>/dev/null; ",
    "echo '===STAT==='; head -n 1 /proc/stat 2>/dev/null; ",
    "echo '===MEM==='; grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null; ",
    "echo '===DISK==='; df -P -k 2>/dev/null; ",
    "echo '===NET==='; cat /proc/net/dev 2>/dev/null"
);

const READ_REMOTE_HISTORY_CMD: &str = concat!(
    "LC_ALL=C; ",
    "for f in \"$HOME/.zsh_history\" \"$HOME/.bash_history\" \"$HOME/.ash_history\"; do ",
    "[ -r \"$f\" ] && tail -n 350 \"$f\" 2>/dev/null; ",
    "done"
);

pub fn fetch_remote_history_blocking(
    session_id: &str,
    max_entries: usize,
) -> Result<Vec<String>, String> {
    let sid = session_id.to_string();
    let limit = max_entries.clamp(10, 1000);
    ssh::runtime().block_on(async move {
        let raw_out = exec_readonly_command(&sid, READ_REMOTE_HISTORY_CMD).await?;
        Ok(parse_shell_history_lines(&raw_out, limit))
    })
}

pub fn parse_shell_history_lines(raw: &str, max_entries: usize) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();

    for line in raw.lines().rev() {
        let mut s = line.trim();
        if s.is_empty() || s.starts_with('#') || s.starts_with("==> ") {
            continue;
        }
        // Strip zsh extended history prefix: `: 1700000000:0;actual command`
        if let Some(rest) = s.strip_prefix(": ") {
            if let Some(idx) = rest.find(';') {
                let meta = &rest[..idx];
                if meta.contains(':')
                    && meta
                        .chars()
                        .all(|c| c.is_ascii_digit() || c == ':' || c == ' ')
                {
                    s = rest[idx + 1..].trim();
                }
            }
        }
        // Skip trivial 1-char commands, multiline continuations, or ultra-long blobs
        if s.len() < 2 || s.len() > 260 || s.ends_with('\\') {
            continue;
        }
        if seen.insert(s.to_string()) {
            result.push(s.to_string());
            if result.len() >= max_entries {
                break;
            }
        }
    }

    result
}

pub fn fetch_metrics_blocking(session_id: &str) -> Result<ServerMetrics, String> {
    let sid = session_id.to_string();
    ssh::runtime().block_on(async move {
        let has_prev = prev_samples()
            .lock()
            .ok()
            .map(|g| g.contains_key(&sid))
            .unwrap_or(false);

        let cmd = if has_prev {
            PROBE_SINGLE_CMD
        } else {
            PROBE_INITIAL_DUAL_CMD
        };

        let raw_out = exec_readonly_command(&sid, cmd).await?;
        Ok(parse_and_update_metrics(&sid, &raw_out))
    })
}

async fn exec_readonly_command(session_id: &str, command: &str) -> Result<String, String> {
    let handle = ssh::get_session_handle(session_id)?;
    let mut channel = tokio::time::timeout(Duration::from_secs(8), handle.channel_open_session())
        .await
        .map_err(|_| "打开监控探测通道超时".to_string())?
        .map_err(|e| format!("打开监控探测通道失败: {e}"))?;

    channel
        .exec(true, command)
        .await
        .map_err(|e| format!("发送监控采集指令失败: {e}"))?;

    let mut output = Vec::with_capacity(4096);
    let _ = tokio::time::timeout(Duration::from_secs(8), async {
        while let Some(msg) = channel.wait().await {
            match msg {
                ChannelMsg::Data { ref data } => output.extend_from_slice(data),
                ChannelMsg::Close | ChannelMsg::Eof => break,
                _ => {}
            }
        }
    })
    .await;

    Ok(String::from_utf8_lossy(&output).to_string())
}

fn parse_and_update_metrics(session_id: &str, raw: &str) -> ServerMetrics {
    let mut sections: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut current_sec = "";

    for line in raw.lines() {
        let trimmed = line.trim();
        if let Some(sec_name) = trimmed
            .strip_prefix("===")
            .and_then(|s| s.strip_suffix("==="))
        {
            current_sec = sec_name;
            continue;
        }
        if !current_sec.is_empty() && !trimmed.is_empty() {
            sections.entry(current_sec).or_default().push(trimmed);
        }
    }

    // Seed baseline if `STAT0` / `NET0` were collected in initial dual-sample
    if let Some(stat0_lines) = sections.get("STAT0") {
        let (t0, idle0) = stat0_lines
            .first()
            .map(|l| parse_proc_stat_line(l))
            .unwrap_or((0, 0));
        let net0 = sections
            .get("NET0")
            .map(|lines| parse_proc_net_dev(lines))
            .unwrap_or_default();
        if t0 > 0 {
            if let Ok(mut guard) = prev_samples().lock() {
                guard.insert(
                    session_id.to_string(),
                    PrevSessionSample {
                        sampled_at: Instant::now() - Duration::from_millis(210),
                        cpu_total: t0,
                        cpu_idle: idle0,
                        net_totals: net0,
                    },
                );
            }
        }
    }

    // Host / OS / Kernel
    let host_lines = sections.get("HOST").cloned().unwrap_or_default();
    let hostname = host_lines.first().copied().unwrap_or("unknown").to_string();
    let kernel = host_lines.get(1).copied().unwrap_or("Linux").to_string();
    let os_name = host_lines
        .iter()
        .find_map(|l| l.strip_prefix("PRETTY_NAME="))
        .map(|s| s.trim_matches('"').to_string())
        .unwrap_or_else(|| kernel.clone());

    // Uptime
    let uptime_secs = sections
        .get("UPTIME")
        .and_then(|v| v.first())
        .and_then(|l| l.split_whitespace().next())
        .and_then(|s| s.parse::<f64>().ok())
        .map(|f| f as u64)
        .unwrap_or(0);

    // Cores & LoadAvg
    let cpu_cores = sections
        .get("CORES")
        .and_then(|v| v.first())
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(1)
        .max(1);

    let (load_1, load_5, load_15) = sections
        .get("LOAD")
        .and_then(|v| v.first())
        .map(|l| {
            let mut parts = l.split_whitespace();
            let l1 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
            let l5 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
            let l15 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
            (l1, l5, l15)
        })
        .unwrap_or((0.0, 0.0, 0.0));

    // CPU & Network Delta Calculation
    let (cur_total, cur_idle) = sections
        .get("STAT")
        .and_then(|v| v.first())
        .map(|l| parse_proc_stat_line(l))
        .unwrap_or((0, 0));
    let cur_net = sections
        .get("NET")
        .map(|lines| parse_proc_net_dev(lines))
        .unwrap_or_default();

    let now_inst = Instant::now();
    let (cpu_percent, networks) = {
        let mut guard = prev_samples().lock().unwrap();
        let prev_opt = guard.get(session_id);

        let cpu_pct = if let Some(prev) = prev_opt {
            let dt_total = cur_total.saturating_sub(prev.cpu_total);
            let dt_idle = cur_idle.saturating_sub(prev.cpu_idle);
            if dt_total > 0 {
                let busy = dt_total.saturating_sub(dt_idle) as f64;
                ((busy / dt_total as f64) * 100.0).clamp(0.0, 100.0)
            } else {
                0.0
            }
        } else {
            0.0
        };

        let elapsed_secs = prev_opt
            .map(|p| now_inst.duration_since(p.sampled_at).as_secs_f64().max(0.15))
            .unwrap_or(1.0);

        let mut net_rates: Vec<NetInterfaceRate> = Vec::new();
        for (iface, &(rx, tx)) in &cur_net {
            let (rx_rate, tx_rate) = if let Some(prev) = prev_opt {
                if let Some(&(prev_rx, prev_tx)) = prev.net_totals.get(iface) {
                    (
                        ((rx.saturating_sub(prev_rx)) as f64 / elapsed_secs) as u64,
                        ((tx.saturating_sub(prev_tx)) as f64 / elapsed_secs) as u64,
                    )
                } else {
                    (0, 0)
                }
            } else {
                (0, 0)
            };
            net_rates.push(NetInterfaceRate {
                interface: iface.clone(),
                rx_bytes_per_sec: rx_rate,
                tx_bytes_per_sec: tx_rate,
                total_rx_bytes: rx,
                total_tx_bytes: tx,
            });
        }
        net_rates.sort_by(|a, b| {
            (b.total_rx_bytes + b.total_tx_bytes)
                .cmp(&(a.total_rx_bytes + a.total_tx_bytes))
                .then_with(|| a.interface.cmp(&b.interface))
        });

        guard.insert(
            session_id.to_string(),
            PrevSessionSample {
                sampled_at: now_inst,
                cpu_total: cur_total,
                cpu_idle: cur_idle,
                net_totals: cur_net,
            },
        );
        (cpu_pct, net_rates)
    };

    // Memory & Swap (/proc/meminfo values are in KiB)
    let mut mem_kb: HashMap<&str, u64> = HashMap::new();
    if let Some(mem_lines) = sections.get("MEM") {
        for line in mem_lines {
            if let Some((k, rest)) = line.split_once(':') {
                let val = rest
                    .split_whitespace()
                    .next()
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(0);
                mem_kb.insert(k.trim(), val);
            }
        }
    }
    let mem_total_kb = mem_kb.get("MemTotal").copied().unwrap_or(0);
    let mem_avail_kb = mem_kb.get("MemAvailable").copied().unwrap_or_else(|| {
        mem_kb.get("MemFree").copied().unwrap_or(0)
            + mem_kb.get("Buffers").copied().unwrap_or(0)
            + mem_kb.get("Cached").copied().unwrap_or(0)
    });
    let mem_used_kb = mem_total_kb.saturating_sub(mem_avail_kb);
    let swap_total_kb = mem_kb.get("SwapTotal").copied().unwrap_or(0);
    let swap_free_kb = mem_kb.get("SwapFree").copied().unwrap_or(0);
    let swap_used_kb = swap_total_kb.saturating_sub(swap_free_kb);

    // Disks (`df -P -k`)
    let mut disks: Vec<DiskUsageItem> = Vec::new();
    if let Some(disk_lines) = sections.get("DISK") {
        for line in disk_lines.iter().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 6 {
                continue;
            }
            let fs_name = cols[0];
            let mount = cols[5];
            if fs_name.starts_with("tmpfs")
                || fs_name.starts_with("devtmpfs")
                || fs_name.starts_with("squashfs")
                || fs_name.starts_with("overlay")
                || fs_name == "efivarfs"
                || mount.starts_with("/snap/")
                || mount.starts_with("/run")
                || mount.starts_with("/sys")
                || mount.starts_with("/proc")
                || mount.starts_with("/dev")
            {
                continue;
            }
            let total_kb = cols[1].parse::<u64>().unwrap_or(0);
            let used_kb = cols[2].parse::<u64>().unwrap_or(0);
            if total_kb == 0 {
                continue;
            }
            if disks.iter().any(|d| d.mount_point == mount) {
                continue;
            }
            disks.push(DiskUsageItem {
                mount_point: mount.to_string(),
                filesystem: fs_name.to_string(),
                total_bytes: total_kb * 1024,
                used_bytes: used_kb * 1024,
            });
        }
    }

    ServerMetrics {
        hostname,
        os_name,
        kernel,
        uptime_secs,
        cpu_cores,
        cpu_percent,
        load_1,
        load_5,
        load_15,
        mem_total_bytes: mem_total_kb * 1024,
        mem_used_bytes: mem_used_kb * 1024,
        swap_total_bytes: swap_total_kb * 1024,
        swap_used_bytes: swap_used_kb * 1024,
        disks,
        networks,
        collected_at_ms: store::now_ms(),
    }
}

fn parse_proc_stat_line(line: &str) -> (u64, u64) {
    let vals: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|s| s.parse::<u64>().ok())
        .collect();
    if vals.len() < 4 {
        return (0, 0);
    }
    let total: u64 = vals.iter().sum();
    let idle = vals[3] + vals.get(4).copied().unwrap_or(0); // idle + iowait
    (total, idle)
}

fn parse_proc_net_dev(lines: &[&str]) -> HashMap<String, (u64, u64)> {
    let mut map = HashMap::new();
    for line in lines {
        let Some((iface_raw, rest)) = line.split_once(':') else {
            continue;
        };
        let iface = iface_raw.trim();
        if iface == "lo"
            || iface.starts_with("veth")
            || iface.starts_with("br-")
            || iface.starts_with("docker")
        {
            continue;
        }
        let nums: Vec<u64> = rest
            .split_whitespace()
            .filter_map(|v| v.parse::<u64>().ok())
            .collect();
        if nums.len() >= 9 {
            map.insert(iface.to_string(), (nums[0], nums[8]));
        }
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bash_and_zsh_history_deduplicated_newest_first() {
        let raw = "\
#1700000001
docker ps -a
: 1700000010:0;systemctl status nginx
ls -la
: 1700000020:0;docker ps -a
==> /home/u/.bash_history <==
a
tail -n 100 /var/log/syslog
";
        let items = parse_shell_history_lines(raw, 10);
        assert_eq!(
            items,
            vec![
                "tail -n 100 /var/log/syslog",
                "docker ps -a",
                "ls -la",
                "systemctl status nginx",
            ]
        );
    }
}
