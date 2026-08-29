//! Antigravity quota source.
//!
//! Approach (reimplemented from CodexBar's documented behavior, no code
//! copied): the Antigravity desktop runtime hosts a local language server that
//! answers quota summaries on a loopback HTTPS lane. The lane binding — the
//! already-running server's listen port and the CSRF token from its process
//! arguments — is discovered from bounded local process snapshots; the quota
//! summary POST then reuses the loopback discipline of LicoUp's local-service
//! lanes (loopback-only URL policy, bounded timeouts, no proxy inheritance).
//! The most-constrained bucket (lowest `remainingFraction`) drives
//! `usedPercent = (1 - remainingFraction) * 100`.

use super::contract::{
    DEFAULT_STALE_AFTER_SECONDS, ProviderQuotaSnapshot, QuotaFetchError, QuotaIdentity,
    QuotaProvider, QuotaStatus, QuotaWindow,
};
use super::http;
use serde_json::Value;
use std::process::Command;
use std::time::Duration;
use time::OffsetDateTime;

const QUOTA_SUMMARY_PATH: &str =
    "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary";
const CSRF_HEADER: &str = "x-codeium-csrf-token";
const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_DISCOVERY_BYTES: usize = 4 * 1024 * 1024;

/// Loopback lane binding for the local language server. The CSRF token is
/// credential material: it lives only in memory for the request build and is
/// never serialized, logged, or retained.
#[derive(Clone)]
pub(super) struct LoopbackBinding {
    port: u16,
    csrf_token: String,
    use_https: bool,
}

impl std::fmt::Debug for LoopbackBinding {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LoopbackBinding")
            .field("port", &self.port)
            .field("csrf_token", &"<redacted>")
            .field("use_https", &self.use_https)
            .finish()
    }
}

impl LoopbackBinding {
    #[cfg(test)]
    pub(super) fn for_testing(port: u16, csrf_token: &str, use_https: bool) -> Self {
        Self {
            port,
            csrf_token: csrf_token.to_owned(),
            use_https,
        }
    }

    fn quota_summary_url(&self) -> String {
        format!(
            "{}://127.0.0.1:{}{}",
            if self.use_https { "https" } else { "http" },
            self.port,
            QUOTA_SUMMARY_PATH
        )
    }
}

type LoopbackPost = dyn Fn(&LoopbackBinding) -> Result<Value, QuotaFetchError> + Send + Sync;
type Discovery = dyn Fn() -> Option<LoopbackBinding> + Send + Sync;

pub(super) struct AntigravitySource {
    binding: Option<LoopbackBinding>,
    discover: Box<Discovery>,
    post_summary: Box<LoopbackPost>,
}

impl AntigravitySource {
    pub(super) fn production() -> Self {
        Self {
            binding: None,
            discover: Box::new(discover_loopback_binding),
            post_summary: Box::new(post_quota_summary),
        }
    }

    #[cfg(test)]
    pub(super) fn for_testing(
        binding: Option<LoopbackBinding>,
        post_summary: Box<LoopbackPost>,
    ) -> Self {
        Self {
            binding,
            discover: Box::new(|| None),
            post_summary,
        }
    }

    pub(super) fn fetch_snapshot(
        &self,
        now: OffsetDateTime,
    ) -> Result<ProviderQuotaSnapshot, QuotaFetchError> {
        let captured_at = super::scheduler::format_rfc3339(now);
        let binding = self
            .binding
            .clone()
            .or_else(|| (self.discover)())
            .ok_or_else(|| QuotaFetchError::new("antigravity_loopback_lane_unavailable"))?;
        let payload = (self.post_summary)(&binding)?;
        normalize_quota_summary(&payload, &captured_at)
    }
}

fn post_quota_summary(binding: &LoopbackBinding) -> Result<Value, QuotaFetchError> {
    http::post_json_loopback(
        &binding.quota_summary_url(),
        &[(CSRF_HEADER, binding.csrf_token.as_str())],
        http::LOOPBACK_FETCH_TIMEOUT,
    )
}

/// Quota summary payload: buckets carry `remainingFraction` and `resetTime`.
/// The most-constrained bucket drives the single normalized window.
fn normalize_quota_summary(
    payload: &Value,
    captured_at: &str,
) -> Result<ProviderQuotaSnapshot, QuotaFetchError> {
    let buckets = payload
        .get("buckets")
        .and_then(Value::as_array)
        .ok_or_else(|| QuotaFetchError::new("antigravity_quota_contract_invalid"))?;
    let constrained = buckets
        .iter()
        .filter_map(|bucket| {
            let remaining = bucket.get("remainingFraction").and_then(Value::as_f64)?;
            Some((remaining, bucket))
        })
        .min_by(|left, right| left.0.total_cmp(&right.0))
        .map(|(_, bucket)| bucket)
        .ok_or_else(|| QuotaFetchError::new("antigravity_quota_buckets_missing"))?;
    let remaining = constrained
        .get("remainingFraction")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let label = constrained
        .get("label")
        .or_else(|| constrained.get("modelName"))
        .or_else(|| constrained.get("id"))
        .and_then(Value::as_str)
        .unwrap_or("quota")
        .to_owned();
    let resets_at = constrained
        .get("resetTime")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let identity = QuotaIdentity {
        account_label: payload
            .get("accountLabel")
            .or_else(|| payload.get("email"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        plan: payload
            .get("plan")
            .or_else(|| payload.get("planName"))
            .and_then(Value::as_str)
            .map(str::to_owned),
    };
    Ok(ProviderQuotaSnapshot {
        agent_id: QuotaProvider::Antigravity.agent_id().to_owned(),
        provider: QuotaProvider::Antigravity,
        status: QuotaStatus::Live,
        windows: vec![QuotaWindow {
            label,
            used_percent: (1.0 - remaining) * 100.0,
            window_minutes: None,
            resets_at,
            reset_description: "bucket reset".to_owned(),
        }],
        identity,
        captured_at: captured_at.to_owned(),
        stale_after_seconds: DEFAULT_STALE_AFTER_SECONDS,
    })
}

/// Discover the local language server's loopback binding from bounded process
/// and listen-port snapshots. Windows `tasklist` carries no command line, so
/// discovery reports no binding there instead of scanning further.
fn discover_loopback_binding() -> Option<LoopbackBinding> {
    if cfg!(windows) {
        return None;
    }
    let processes = capture(&["ps", "-axo", "pid=,args="])?;
    let (pid, csrf_token) = processes
        .lines()
        .filter_map(parse_language_server_entry)
        .min_by_key(|(pid, _)| *pid)?;
    let ports = capture(&[
        "lsof",
        "-nP",
        "-iTCP",
        "-sTCP:LISTEN",
        "-a",
        "-p",
        &pid.to_string(),
    ])?;
    let port = ports
        .lines()
        .find_map(|line| listen_port_for_pid(line, pid))?;
    Some(LoopbackBinding {
        port,
        csrf_token,
        use_https: true,
    })
}

fn capture(args: &[&str]) -> Option<String> {
    let (program, rest) = args.split_first()?;
    let mut command = Command::new(program);
    command.args(rest);
    let result = crate::platform::run_bounded_command_output(
        &mut command,
        DISCOVERY_TIMEOUT,
        MAX_DISCOVERY_BYTES,
    )
    .ok()?;
    if result.timed_out || result.truncated || !result.status.is_some_and(|status| status.success())
    {
        return None;
    }
    Some(String::from_utf8_lossy(&result.stdout).into_owned())
}

/// Match the language server process carrying the CSRF token argument. Only
/// the pid and the token leave the parser; the full command line does not.
fn parse_language_server_entry(line: &str) -> Option<(u32, String)> {
    let trimmed = line.trim_start();
    let split_at = trimmed.find(char::is_whitespace)?;
    let pid = trimmed[..split_at].parse::<u32>().ok()?;
    let args = trimmed[split_at..].trim();
    if !args.contains("language_server") {
        return None;
    }
    let token = csrf_token_from_args(args)?;
    Some((pid, token))
}

fn csrf_token_from_args(args: &str) -> Option<String> {
    for (index, part) in args.split_whitespace().enumerate() {
        if let Some(value) = part.strip_prefix("--csrf_token=") {
            return non_empty(value);
        }
        if part == "--csrf_token" {
            return args.split_whitespace().nth(index + 1).and_then(non_empty);
        }
    }
    None
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn listen_port_for_pid(line: &str, pid: u32) -> Option<u16> {
    let fields = line.split_whitespace().collect::<Vec<_>>();
    if fields.len() < 2 || fields[1].parse::<u32>().ok()? != pid {
        return None;
    }
    fields.iter().rev().find_map(|field| {
        let (host, port) = field.rsplit_once(':')?;
        if host.is_empty() {
            return None;
        }
        port.trim_end_matches(|ch: char| ch.is_ascii_alphabetic() || ch == '(' || ch == ')')
            .parse::<u16>()
            .ok()
    })
}
