//! User-enabled, locally scheduled skill updates.
//!
//! Enabling a policy is a direct user action and binds one managed skill to an
//! explicit GitHub repository or local mirror. After that consent, the desktop
//! lifecycle may call [`tick`] periodically. A tick performs no discovery and
//! contacts only the configured source of a due policy. A private process lock
//! and a persisted lease make overlapping or crash-restarted ticks safe.

use super::{
    ClientStateStore, Result, Value, agent_id, bool_param, collection_items_mut,
    find_installed_skill_record, is_agent_approved, json, sanitize_skill_id, skill_id,
    skill_source, string_param, timestamp,
};
use anyhow::{anyhow, ensure};
use time::OffsetDateTime;

mod execution;
mod model;
mod schedule;
#[cfg(test)]
mod tests;

use execution::execute;
use model::Selection;
use schedule::{ensure_supported_source, interval_seconds, try_scheduler_lock};

pub(super) fn configure(store: &ClientStateStore, params: &Value) -> Result<Value> {
    require_direct_user_action(params)?;
    let Some(_lock) = try_scheduler_lock(store)? else {
        return Err(anyhow!(
            "automatic skill update is currently running; retry the policy change"
        ));
    };
    let agent_id = agent_id(params)?;
    let skill_id = sanitize_skill_id(&skill_id(params)?)?;
    ensure!(
        is_agent_approved(store, &agent_id)?,
        "automatic skill updates require an approved agent pairing"
    );
    let enabled = bool_param(params, "enabled")
        .ok_or_else(|| anyhow!("automatic skill update policy requires --enabled true|false"))?;
    let current = find_installed_skill_record(store, &agent_id, &skill_id)?
        .ok_or_else(|| anyhow!("automatic skill update requires a managed local skill"))?;
    let configured_source = if has_source(params) {
        Some(skill_source(params)?.public_summary())
    } else {
        current
            .pointer("/autoUpdate/source")
            .or_else(|| current.get("source"))
            .cloned()
    };
    if enabled {
        ensure_supported_source(configured_source.as_ref())?;
    }
    let interval_seconds = interval_seconds(params)?;
    let updated_at = timestamp();

    let mut document = store.read_collection("skills")?;
    let record = collection_items_mut(&mut document)?
        .iter_mut()
        .find(|item| {
            item.get("kind").and_then(Value::as_str) == Some("skill")
                && item.get("agentId").and_then(Value::as_str) == Some(agent_id.as_str())
                && item.get("skillId").and_then(Value::as_str) == Some(skill_id.as_str())
        })
        .ok_or_else(|| anyhow!("automatic skill update record disappeared"))?;
    let previous = record.get("autoUpdate").cloned().unwrap_or(Value::Null);
    record["autoUpdate"] = json!({
        "enabled": enabled,
        "source": configured_source,
        "intervalSeconds": interval_seconds,
        "nextRunAt": if enabled { json!(updated_at.clone()) } else { Value::Null },
        "updatedAt": updated_at,
        "lastAttemptAt": previous.get("lastAttemptAt").cloned().unwrap_or(Value::Null),
        "lastSuccessAt": previous.get("lastSuccessAt").cloned().unwrap_or(Value::Null),
        "lastFailureAt": previous.get("lastFailureAt").cloned().unwrap_or(Value::Null),
        "consecutiveFailures": previous
            .get("consecutiveFailures")
            .and_then(Value::as_u64)
            .unwrap_or(0)
    });
    store.write_collection("skills", document)?;
    Ok(json!({
        "ok": true,
        "status": "configured",
        "agentId": agent_id,
        "skillId": skill_id,
        "enabled": enabled,
        "sourceConfigured": configured_source.is_some(),
        "intervalSeconds": interval_seconds,
        "executionMode": "background-periodic"
    }))
}

/// Run enabled policies immediately after an explicit user action.
pub(super) fn run_now(store: &ClientStateStore, params: &Value) -> Result<Value> {
    require_direct_user_action(params)?;
    let agent_id = agent_id(params)?;
    ensure!(
        is_agent_approved(store, &agent_id)?,
        "automatic skill updates require an approved agent pairing"
    );
    let skill_filter = string_param(params, &["skill", "skillId"], usize::MAX)
        .map(|value| sanitize_skill_id(&value))
        .transpose()?;
    execute(
        store,
        OffsetDateTime::now_utc(),
        Selection::UserRunNow {
            agent_id: &agent_id,
            skill_filter: skill_filter.as_deref(),
        },
        "direct-user-run-now",
    )
}

/// Execute only due, previously user-enabled policies across approved agents.
pub(super) fn tick(store: &ClientStateStore) -> Result<Value> {
    execute(
        store,
        OffsetDateTime::now_utc(),
        Selection::Due,
        "background-periodic",
    )
}

fn has_source(params: &Value) -> bool {
    ["url", "githubUrl", "sourcePath", "localPath"]
        .iter()
        .any(|key| params.get(*key).is_some())
}

fn require_direct_user_action(params: &Value) -> Result<()> {
    ensure!(
        bool_param(params, "directUserAction") == Some(true),
        "automatic skill update configuration requires a direct user action"
    );
    Ok(())
}

#[cfg(test)]
fn tick_at(store: &ClientStateStore, now: OffsetDateTime) -> Result<Value> {
    execute(store, now, Selection::Due, "background-periodic")
}
