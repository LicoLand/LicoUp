use super::model::{Selection, UpdateJob};
use super::schedule::{claim_jobs, complete_job, job_is_still_authorized, try_scheduler_lock};
use crate::domain::skill_hub::{ClientStateStore, Result, Value, json, skill_install_apply_in};
use anyhow::{Result as AnyResult, anyhow};
use time::OffsetDateTime;

pub(super) fn execute(
    store: &ClientStateStore,
    now: OffsetDateTime,
    selection: Selection<'_>,
    execution_mode: &str,
) -> Result<Value> {
    let Some(_lock) = try_scheduler_lock(store)? else {
        return Ok(json!({
            "ok": true,
            "status": "busy",
            "selectedCount": 0,
            "updatedCount": 0,
            "executionMode": execution_mode,
            "results": []
        }));
    };
    let (jobs, deferred_count) = claim_jobs(store, now, selection)?;
    let mut results = Vec::with_capacity(jobs.len());
    let mut updated_count = 0_usize;
    for job in jobs {
        if !job_is_still_authorized(store, &job)? {
            results.push(json!({
                "agentId": job.agent_id,
                "skillId": job.skill_id,
                "ok": true,
                "status": "skipped_policy_changed"
            }));
            continue;
        }
        let request = update_request(&job);
        let succeeded = matches!(
            request.and_then(|request| skill_install_apply_in(store, &request)),
            Ok(result) if result.get("ok").and_then(Value::as_bool) == Some(true)
        );
        complete_job(store, &job, now, succeeded)?;
        if succeeded {
            updated_count += 1;
        }
        results.push(json!({
            "agentId": job.agent_id,
            "skillId": job.skill_id,
            "ok": succeeded,
            "status": if succeeded { "updated" } else { "update_failed" }
        }));
    }
    let all_succeeded = results
        .iter()
        .all(|result| result.get("ok").and_then(Value::as_bool) == Some(true));
    Ok(json!({
        "ok": all_succeeded,
        "status": if all_succeeded { "completed" } else { "partial_failure" },
        "selectedCount": results.len(),
        "updatedCount": updated_count,
        "deferredCount": deferred_count,
        "executionMode": execution_mode,
        "results": results
    }))
}

fn update_request(job: &UpdateJob) -> AnyResult<Value> {
    let source = job
        .source
        .as_ref()
        .ok_or_else(|| anyhow!("automatic skill update source is missing"))?;
    let mut request = json!({
        "agent": job.agent_id,
        "skill": job.skill_id,
        "name": job.skill_id,
        "overwrite": true
    });
    if let Some(install_root) = job.install_root.as_deref() {
        request["installRoot"] = json!(install_root);
    }
    match source.get("kind").and_then(Value::as_str) {
        Some("github") => {
            request["url"] = source
                .get("url")
                .cloned()
                .ok_or_else(|| anyhow!("automatic GitHub source is missing url"))?;
            if let Some(value) = source.get("ref") {
                request["ref"] = value.clone();
            }
            if let Some(value) = source.get("path") {
                request["path"] = value.clone();
            }
        }
        Some("local-directory") => {
            request["sourcePath"] = source
                .get("path")
                .cloned()
                .ok_or_else(|| anyhow!("automatic mirror source is missing path"))?;
        }
        _ => return Err(anyhow!("automatic skill update source is unsupported")),
    }
    Ok(request)
}
