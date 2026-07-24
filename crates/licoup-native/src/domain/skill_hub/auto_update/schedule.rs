use super::model::{
    CLAIM_LEASE_SECONDS, DEFAULT_INTERVAL_SECONDS, LOCK_FILE, MAX_BATCH,
    MAX_FAILURE_BACKOFF_SECONDS, MAX_INTERVAL_SECONDS, MIN_INTERVAL_SECONDS, Selection, UpdateJob,
};
use crate::domain::skill_hub::{
    ClientStateStore, Result, SKILL_INSTALLER_PROTOCOL, Value, collection_items_mut,
    is_agent_approved, json,
};
use crate::platform::file_security::open_private_lock_file;
use anyhow::{anyhow, ensure};
use fs2::FileExt;
use std::collections::HashMap;
use std::fs::File;
use std::io::ErrorKind;
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};

pub(super) fn claim_jobs(
    store: &ClientStateStore,
    now: OffsetDateTime,
    selection: Selection<'_>,
) -> Result<(Vec<UpdateJob>, usize)> {
    let mut document = store.read_collection("skills")?;
    let items = collection_items_mut(&mut document)?;
    let mut approval_cache = HashMap::<String, bool>::new();
    let mut candidates = Vec::<(String, String, usize)>::new();
    for (index, record) in items.iter().enumerate() {
        if record.get("kind").and_then(Value::as_str) != Some("skill")
            || record
                .pointer("/autoUpdate/enabled")
                .and_then(Value::as_bool)
                != Some(true)
        {
            continue;
        }
        let Some(agent_id) = record.get("agentId").and_then(Value::as_str) else {
            continue;
        };
        let Some(skill_id) = record.get("skillId").and_then(Value::as_str) else {
            continue;
        };
        let selected = match &selection {
            Selection::Due => {
                let approved = match approval_cache.get(agent_id) {
                    Some(approved) => *approved,
                    None => {
                        let approved = is_agent_approved(store, agent_id)?;
                        approval_cache.insert(agent_id.to_string(), approved);
                        approved
                    }
                };
                approved && policy_is_due(record, now)
            }
            Selection::UserRunNow {
                agent_id: selected_agent,
                skill_filter,
            } => {
                agent_id == *selected_agent
                    && skill_filter.is_none_or(|selected_skill| skill_id == selected_skill)
            }
        };
        if selected {
            candidates.push((agent_id.to_string(), skill_id.to_string(), index));
        }
    }
    candidates.sort_by(|left, right| (&left.0, &left.1).cmp(&(&right.0, &right.1)));
    let deferred_count = candidates.len().saturating_sub(MAX_BATCH);
    candidates.truncate(MAX_BATCH);

    let lease_until = format_time(now + Duration::seconds(CLAIM_LEASE_SECONDS))?;
    let attempted_at = format_time(now)?;
    let mut jobs = Vec::with_capacity(candidates.len());
    for (agent_id, skill_id, index) in candidates {
        let record = &mut items[index];
        let interval_seconds = record
            .pointer("/autoUpdate/intervalSeconds")
            .and_then(Value::as_i64)
            .filter(|value| (MIN_INTERVAL_SECONDS..=MAX_INTERVAL_SECONDS).contains(value))
            .unwrap_or(DEFAULT_INTERVAL_SECONDS);
        let source = record
            .pointer("/autoUpdate/source")
            .or_else(|| record.get("source"))
            .cloned();
        let install_root = record
            .get("installRoot")
            .and_then(Value::as_str)
            .map(str::to_owned);
        record["autoUpdate"]["nextRunAt"] = json!(lease_until);
        record["autoUpdate"]["lastAttemptAt"] = json!(attempted_at);
        jobs.push(UpdateJob {
            agent_id,
            skill_id,
            source,
            install_root,
            interval_seconds,
        });
    }
    if !jobs.is_empty() {
        store.write_collection("skills", document)?;
    }
    Ok((jobs, deferred_count))
}

pub(super) fn complete_job(
    store: &ClientStateStore,
    job: &UpdateJob,
    now: OffsetDateTime,
    succeeded: bool,
) -> Result<()> {
    let mut document = store.read_collection("skills")?;
    let record = collection_items_mut(&mut document)?
        .iter_mut()
        .find(|record| {
            record.get("kind").and_then(Value::as_str) == Some("skill")
                && record.get("agentId").and_then(Value::as_str) == Some(job.agent_id.as_str())
                && record.get("skillId").and_then(Value::as_str) == Some(job.skill_id.as_str())
        })
        .ok_or_else(|| anyhow!("automatic skill update record disappeared during execution"))?;
    let previous_failures = record
        .pointer("/autoUpdate/consecutiveFailures")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let failures = if succeeded {
        0
    } else {
        previous_failures.saturating_add(1).min(32)
    };
    let delay_seconds = if succeeded {
        job.interval_seconds
    } else {
        failure_backoff_seconds(failures)
    };
    record["autoUpdate"]["consecutiveFailures"] = json!(failures);
    record["autoUpdate"]["nextRunAt"] = json!(format_time(now + Duration::seconds(delay_seconds))?);
    if succeeded {
        record["autoUpdate"]["lastSuccessAt"] = json!(format_time(now)?);
        record["autoUpdate"]["lastFailureAt"] = Value::Null;
    } else {
        record["autoUpdate"]["lastFailureAt"] = json!(format_time(now)?);
    }
    store.write_collection("skills", document)?;
    Ok(())
}

/// Re-check direct-user policy immediately before source access. A disable or
/// source change that races a previously claimed job cancels that job safely.
pub(super) fn job_is_still_authorized(store: &ClientStateStore, job: &UpdateJob) -> Result<bool> {
    if !is_agent_approved(store, &job.agent_id)? {
        return Ok(false);
    }
    let document = store.read_collection("skills")?;
    Ok(document
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().find(|record| {
                record.get("kind").and_then(Value::as_str) == Some("skill")
                    && record.get("agentId").and_then(Value::as_str) == Some(job.agent_id.as_str())
                    && record.get("skillId").and_then(Value::as_str) == Some(job.skill_id.as_str())
            })
        })
        .is_some_and(|record| {
            record
                .pointer("/autoUpdate/enabled")
                .and_then(Value::as_bool)
                == Some(true)
                && record.get("installer").and_then(Value::as_str) == Some(SKILL_INSTALLER_PROTOCOL)
                && record.pointer("/autoUpdate/source") == job.source.as_ref()
                && record
                    .pointer("/autoUpdate/intervalSeconds")
                    .and_then(Value::as_i64)
                    .filter(|value| (MIN_INTERVAL_SECONDS..=MAX_INTERVAL_SECONDS).contains(value))
                    .unwrap_or(DEFAULT_INTERVAL_SECONDS)
                    == job.interval_seconds
                && record.get("installRoot").and_then(Value::as_str) == job.install_root.as_deref()
        }))
}

pub(super) fn try_scheduler_lock(store: &ClientStateStore) -> Result<Option<File>> {
    let lock = open_private_lock_file(&store.root().join(LOCK_FILE))?;
    match lock.try_lock_exclusive() {
        Ok(()) => Ok(Some(lock)),
        Err(error) if error.kind() == ErrorKind::WouldBlock => Ok(None),
        Err(error) => Err(error.into()),
    }
}

pub(super) fn interval_seconds(params: &Value) -> Result<i64> {
    let interval = params
        .get("intervalSeconds")
        .or_else(|| params.get("interval-seconds"))
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_str()?.trim().parse::<i64>().ok())
        })
        .unwrap_or(DEFAULT_INTERVAL_SECONDS);
    ensure!(
        (MIN_INTERVAL_SECONDS..=MAX_INTERVAL_SECONDS).contains(&interval),
        "automatic skill update interval must be between 900 and 604800 seconds"
    );
    Ok(interval)
}

pub(super) fn ensure_supported_source(source: Option<&Value>) -> Result<()> {
    ensure!(
        source
            .and_then(|source| source.get("kind"))
            .and_then(Value::as_str)
            .is_some_and(|kind| matches!(kind, "github" | "local-directory")),
        "automatic skill update requires a configured GitHub or local mirror source"
    );
    Ok(())
}

fn failure_backoff_seconds(failures: u64) -> i64 {
    let exponent = failures.saturating_sub(1).min(8) as u32;
    MIN_INTERVAL_SECONDS
        .saturating_mul(1_i64 << exponent)
        .min(MAX_FAILURE_BACKOFF_SECONDS)
}

fn policy_is_due(record: &Value, now: OffsetDateTime) -> bool {
    record
        .pointer("/autoUpdate/nextRunAt")
        .and_then(Value::as_str)
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
        .is_none_or(|next| next <= now)
}

pub(super) fn format_time(value: OffsetDateTime) -> Result<String> {
    value.format(&Rfc3339).map_err(Into::into)
}
