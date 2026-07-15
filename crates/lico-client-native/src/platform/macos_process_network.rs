//! macOS per-process network byte sampler for agent-usage metering.
//!
//! Uses `nettop` when available. Returns `None` (platform-unavailable) on
//! denial or failure — never fabricates zero counters as live evidence.

use serde_json::{Value, json};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const NETTOP_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Clone, Debug)]
pub struct LiveProcessNetworkSample {
    pub pid: u64,
    pub process_name: String,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// Sample cumulative network bytes for the given PIDs via `nettop`.
///
/// Returns `None` when the sampler is unavailable or produces no usable rows.
pub fn sample_process_network_bytes(pids: &[u64]) -> Option<Vec<LiveProcessNetworkSample>> {
    if pids.is_empty() {
        return None;
    }
    let mut samples = Vec::new();
    for pid in pids.iter().copied() {
        if let Some(sample) = sample_one_pid(pid) {
            samples.push(sample);
        }
    }
    if samples.is_empty() {
        None
    } else {
        Some(samples)
    }
}

fn sample_one_pid(pid: u64) -> Option<LiveProcessNetworkSample> {
    let started = Instant::now();
    let output = Command::new("nettop")
        .args([
            "-P",
            "-L",
            "1",
            "-J",
            "bytes_in,bytes_out",
            "-p",
            &pid.to_string(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if started.elapsed() > NETTOP_TIMEOUT {
        return None;
    }
    if !output.status.success() {
        return None;
    }
    parse_nettop_bytes(&String::from_utf8_lossy(&output.stdout), pid)
}

fn parse_nettop_bytes(stdout: &str, pid: u64) -> Option<LiveProcessNetworkSample> {
    // nettop -J bytes_in,bytes_out typically emits CSV-like rows after a header.
    let mut lines = stdout.lines().filter(|line| !line.trim().is_empty());
    let _header = lines.next()?;
    let mut best: Option<LiveProcessNetworkSample> = None;
    for line in lines {
        let parts: Vec<&str> = line.split(',').map(str::trim).collect();
        if parts.len() < 2 {
            continue;
        }
        // Formats vary; accept trailing numeric columns as bytes_in/bytes_out.
        let rx = parse_bytes(parts[parts.len().saturating_sub(2)])?;
        let tx = parse_bytes(parts[parts.len().saturating_sub(1)])?;
        let process_name = parts
            .first()
            .map(|value| value.trim_matches('"').to_string())
            .unwrap_or_else(|| format!("pid-{pid}"));
        let candidate = LiveProcessNetworkSample {
            pid,
            process_name,
            rx_bytes: rx,
            tx_bytes: tx,
        };
        best = Some(match best {
            Some(existing)
                if existing.rx_bytes + existing.tx_bytes
                    >= candidate.rx_bytes + candidate.tx_bytes =>
            {
                existing
            }
            _ => candidate,
        });
    }
    best
}

fn parse_bytes(raw: &str) -> Option<u64> {
    let trimmed = raw.trim().trim_matches('"');
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("bytes_in") {
        return None;
    }
    if let Ok(value) = trimmed.parse::<u64>() {
        return Some(value);
    }
    // Human units from some nettop builds: 1.2K / 3M
    let (number, scale) = if let Some(prefix) = trimmed.strip_suffix(['K', 'k']) {
        (prefix, 1024f64)
    } else if let Some(prefix) = trimmed.strip_suffix(['M', 'm']) {
        (prefix, 1024f64 * 1024f64)
    } else if let Some(prefix) = trimmed.strip_suffix(['G', 'g']) {
        (prefix, 1024f64 * 1024f64 * 1024f64)
    } else {
        return None;
    };
    let value = number.parse::<f64>().ok()?;
    Some((value * scale) as u64)
}

/// Build injectible `processSamples` JSON values from live macOS samples.
pub fn process_samples_json(
    agent_id: &str,
    samples: &[LiveProcessNetworkSample],
    started_at: &str,
    sampled_at: &str,
) -> Vec<Value> {
    samples
        .iter()
        .map(|sample| {
            json!({
                "agentId": agent_id,
                "pid": sample.pid,
                "processName": sample.process_name,
                "startedAt": started_at,
                "sampledAt": sampled_at,
                "rxBytes": sample.rx_bytes,
                "txBytes": sample.tx_bytes,
                "meterSource": "macos-nettop",
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_nettop_csv_rows() {
        let stdout = "process,bytes_in,bytes_out\nhermes,1200,3400\n";
        let sample = parse_nettop_bytes(stdout, 42).unwrap();
        assert_eq!(sample.pid, 42);
        assert_eq!(sample.rx_bytes, 1200);
        assert_eq!(sample.tx_bytes, 3400);
        assert_eq!(sample.process_name, "hermes");
    }

    #[test]
    fn parse_human_units() {
        assert_eq!(parse_bytes("1.5K"), Some(1536));
        assert_eq!(parse_bytes("2M"), Some(2 * 1024 * 1024));
    }
}
