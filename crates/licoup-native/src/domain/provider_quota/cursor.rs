//! Cursor quota source.
//!
//! Approach (reimplemented from CodexBar's documented behavior, no code
//! copied): read-only open of the Cursor app state database (`state.vscdb`
//! under the per-platform Cursor user-data directory, resolved through
//! home-dir APIs, never a literal absolute path), `ItemTable` key
//! `cursorAuth/accessToken`, with a JWT expiry check requiring more than 60
//! seconds of remaining validity. cursor.com's web API does not accept the
//! app token as a bearer credential; it authenticates with a WorkOS session
//! cookie derived from the token (`WorkosCursorSessionToken=<userID>%3A%3A
//! <token>`, user ID from the JWT `sub`), which is what the hosted
//! usage-summary fetch carries.

use super::contract::{
    DEFAULT_STALE_AFTER_SECONDS, ProviderQuotaSnapshot, QuotaFetchError, QuotaIdentity,
    QuotaProvider, QuotaStatus, QuotaWindow,
};
use super::credentials;
use super::http;
use anyhow::{Result, anyhow};
use serde_json::Value;
use std::path::PathBuf;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

const USAGE_SUMMARY_URL: &str = "https://cursor.com/api/usage-summary";
const AUTH_ME_URL: &str = "https://cursor.com/api/auth/me";
/// Tokens with at most this much remaining validity are treated as expired so
/// an in-flight fetch never carries a token that dies mid-request.
const MIN_TOKEN_VALIDITY_SECONDS: i64 = 60;

type HostedFetch = dyn Fn(&str, &str) -> Result<Value, QuotaFetchError> + Send + Sync;

pub(super) struct CursorSource {
    state_db_path: Option<PathBuf>,
    fetch_summary: Box<HostedFetch>,
}

impl CursorSource {
    pub(super) fn production(params: &Value) -> Self {
        Self {
            state_db_path: resolve_state_db_path(params),
            fetch_summary: Box::new(|url, cookie| {
                http::get_json_with_cookie(url, cookie, http::HOSTED_FETCH_TIMEOUT)
            }),
        }
    }

    #[cfg(test)]
    pub(super) fn for_testing(
        state_db_path: Option<PathBuf>,
        fetch_summary: Box<HostedFetch>,
    ) -> Self {
        Self {
            state_db_path,
            fetch_summary,
        }
    }

    pub(super) fn fetch_snapshot(
        &self,
        now: OffsetDateTime,
    ) -> Result<ProviderQuotaSnapshot, QuotaFetchError> {
        let captured_at = super::scheduler::format_rfc3339(now);
        let state_db_path = self
            .state_db_path
            .clone()
            .ok_or_else(|| QuotaFetchError::new("cursor_state_store_unavailable"))?;
        let token = read_access_token(&state_db_path)
            .map_err(|_| QuotaFetchError::new("cursor_auth_token_unreadable"))?
            .ok_or_else(|| QuotaFetchError::new("cursor_auth_token_absent"))?;

        // The token is dropped after the expiry check, the cookie derivation,
        // and the request build; it never enters the snapshot, retained
        // state, logs, or diagnostics.
        let expiry = credentials::jwt_expiry_epoch_seconds(&token);
        if expiry.is_some_and(|expiry| expiry <= now.unix_timestamp() + MIN_TOKEN_VALIDITY_SECONDS)
        {
            return Err(QuotaFetchError::new("cursor_auth_token_expired"));
        }
        let cookie = derive_session_cookie(&token)
            .ok_or_else(|| QuotaFetchError::new("cursor_auth_session_underivable"))?;

        let payload = (self.fetch_summary)(USAGE_SUMMARY_URL, &cookie)?;
        // Best-effort: the usage response carries no account email, so the
        // identity label comes from the identity endpoint (JWT email claim as
        // fallback); its failure never fails the snapshot.
        let account_label = (self.fetch_summary)(AUTH_ME_URL, &cookie)
            .ok()
            .and_then(|me| me.get("email").and_then(Value::as_str).map(str::to_owned))
            .or_else(|| credentials::jwt_string_claim(&token, "email"));
        normalize_usage_summary(&payload, &captured_at, account_label)
    }
}

/// cursor.com's web API authenticates with a WorkOS session cookie derived
/// from the app access token: `WorkosCursorSessionToken=<userID>%3A%3A
/// <token>`, where the user ID is the last non-empty `|`-separated segment
/// of the JWT `sub` claim. A subject that cannot yield a URL-safe user ID
/// refuses the fetch instead of sending a malformed credential.
fn derive_session_cookie(token: &str) -> Option<String> {
    let subject = credentials::jwt_string_claim(token, "sub")?;
    let user_id = subject
        .split('|')
        .filter(|segment| !segment.is_empty())
        .next_back()?;
    let url_safe = user_id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    if !url_safe {
        return None;
    }
    Some(format!("WorkosCursorSessionToken={user_id}%3A%3A{token}"))
}

fn resolve_state_db_path(params: &Value) -> Option<PathBuf> {
    if let Some(path) =
        crate::domain::conversation::parameters::text_param(params, &["cursorStateDbPath"])
    {
        return Some(PathBuf::from(path));
    }
    cursor_user_data_dir().map(|root| root.join("User").join("globalStorage").join("state.vscdb"))
}

/// The per-platform Cursor user-data directory, resolved through home-dir
/// helpers only.
fn cursor_user_data_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        crate::platform::paths::user_home_from_env().map(|home| {
            crate::platform::paths::strip_macos_data_volume(&home)
                .join("Library")
                .join("Application Support")
                .join("Cursor")
        })
    }
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("APPDATA")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .map(|root| root.join("Cursor"))
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        crate::platform::paths::user_home_from_env().map(|home| home.join(".config").join("Cursor"))
    }
}

/// Read-only token read from the app state database. The database is opened
/// with read-only flags and a bounded single-row query; nothing is written.
fn read_access_token(state_db_path: &std::path::Path) -> Result<Option<String>> {
    let connection = rusqlite::Connection::open_with_flags(
        state_db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|_| anyhow!("cursor state store is not readable"))?;
    connection
        .query_row(
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .map(Some)
        .or_else(|error| match error {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            _ => Err(anyhow!("cursor auth token query failed")),
        })
        .map(|token| token.filter(|value| !value.trim().is_empty()))
}

/// Usage-summary payload: included plan usage plus the auto/API sub-quotas
/// and the billing cycle window. The account email is not part of this
/// response; the identity label falls back to the JWT `email` claim.
fn normalize_usage_summary(
    payload: &Value,
    captured_at: &str,
    account_label: Option<String>,
) -> Result<ProviderQuotaSnapshot, QuotaFetchError> {
    let plan = payload
        .pointer("/individualUsage/plan")
        .ok_or_else(|| QuotaFetchError::new("cursor_usage_contract_invalid"))?;
    let total_percent = plan
        .get("totalPercentUsed")
        .and_then(Value::as_f64)
        .ok_or_else(|| QuotaFetchError::new("cursor_usage_contract_invalid"))?;
    let resets_at = payload
        .get("billingCycleEnd")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let window_minutes = billing_window_minutes(payload);
    let mut windows = vec![QuotaWindow {
        label: "plan".to_owned(),
        used_percent: total_percent,
        window_minutes,
        resets_at: resets_at.clone(),
        reset_description: "monthly billing cycle".to_owned(),
    }];
    // Auto (Cursor models) and API (named models) sub-quotas ride along when
    // the account reports them.
    for (label, field) in [("auto", "autoPercentUsed"), ("api", "apiPercentUsed")] {
        if let Some(used_percent) = plan.get(field).and_then(Value::as_f64) {
            windows.push(QuotaWindow {
                label: label.to_owned(),
                used_percent,
                window_minutes,
                resets_at: resets_at.clone(),
                reset_description: "monthly billing cycle".to_owned(),
            });
        }
    }
    let identity = QuotaIdentity {
        account_label,
        plan: payload
            .get("membershipType")
            .and_then(Value::as_str)
            .map(str::to_owned),
    };
    Ok(ProviderQuotaSnapshot {
        agent_id: QuotaProvider::Cursor.agent_id().to_owned(),
        provider: QuotaProvider::Cursor,
        status: QuotaStatus::Live,
        windows,
        identity,
        captured_at: captured_at.to_owned(),
        stale_after_seconds: DEFAULT_STALE_AFTER_SECONDS,
    })
}

/// Billing-cycle length in minutes, derived from the cycle bounds when both
/// are present and ordered.
fn billing_window_minutes(payload: &Value) -> Option<u64> {
    let start = payload.get("billingCycleStart")?.as_str()?;
    let end = payload.get("billingCycleEnd")?.as_str()?;
    let start = OffsetDateTime::parse(start, &Rfc3339).ok()?;
    let end = OffsetDateTime::parse(end, &Rfc3339).ok()?;
    let minutes = (end - start).whole_minutes();
    u64::try_from(minutes).ok().filter(|value| *value > 0)
}
