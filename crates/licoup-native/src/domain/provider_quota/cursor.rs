//! Cursor quota source.
//!
//! Approach (reimplemented from CodexBar's documented behavior, no code
//! copied): read-only open of the Cursor app state database (`state.vscdb`
//! under the per-platform Cursor user-data directory, resolved through
//! home-dir APIs, never a literal absolute path), `ItemTable` key
//! `cursorAuth/accessToken`, with a JWT expiry check requiring more than 60
//! seconds of remaining validity, then the hosted usage-summary fetch.

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

const USAGE_SUMMARY_URL: &str = "https://cursor.com/api/usage-summary";
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
            fetch_summary: Box::new(|url, bearer| {
                http::get_json_with_bearer(url, bearer, http::HOSTED_FETCH_TIMEOUT)
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

        // The token is dropped after the expiry check and the request build;
        // it never enters the snapshot, retained state, logs, or diagnostics.
        let expiry = credentials::jwt_expiry_epoch_seconds(&token);
        if expiry.is_some_and(|expiry| expiry <= now.unix_timestamp() + MIN_TOKEN_VALIDITY_SECONDS)
        {
            return Err(QuotaFetchError::new("cursor_auth_token_expired"));
        }

        let payload = (self.fetch_summary)(USAGE_SUMMARY_URL, &token)?;
        normalize_usage_summary(&payload, &captured_at)
    }
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

/// Usage-summary payload: plan usage percent and billing cycle. The provider
/// window is normalized into a single "plan" window.
fn normalize_usage_summary(
    payload: &Value,
    captured_at: &str,
) -> Result<ProviderQuotaSnapshot, QuotaFetchError> {
    let used_percent = payload
        .pointer("/planUsage/percentUsed")
        .or_else(|| payload.get("usagePercent"))
        .or_else(|| payload.get("percentUsed"))
        .and_then(Value::as_f64)
        .ok_or_else(|| QuotaFetchError::new("cursor_usage_contract_invalid"))?;
    let resets_at = payload
        .get("billingCycleEnd")
        .or_else(|| payload.get("billingCycleEndDate"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let identity = QuotaIdentity {
        account_label: payload
            .get("email")
            .or_else(|| payload.get("accountEmail"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        plan: payload
            .get("membershipType")
            .or_else(|| payload.get("plan"))
            .and_then(Value::as_str)
            .map(str::to_owned),
    };
    Ok(ProviderQuotaSnapshot {
        agent_id: QuotaProvider::Cursor.agent_id().to_owned(),
        provider: QuotaProvider::Cursor,
        status: QuotaStatus::Live,
        windows: vec![QuotaWindow {
            label: "plan".to_owned(),
            used_percent,
            window_minutes: None,
            resets_at,
            reset_description: "monthly billing cycle".to_owned(),
        }],
        identity,
        captured_at: captured_at.to_owned(),
        stale_after_seconds: DEFAULT_STALE_AFTER_SECONDS,
    })
}
