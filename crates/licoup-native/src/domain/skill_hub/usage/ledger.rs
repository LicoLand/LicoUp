use crate::domain::skill_hub::{
    ClientStateStore, Result, SKILL_INSTALLER_PROTOCOL, Value, collection_items_mut,
    is_agent_approved, json,
};
use crate::platform::file_security::open_private_lock_file;
use anyhow::{anyhow, ensure};
use fs2::FileExt;
use std::collections::{BTreeMap, BTreeSet};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub(super) const COLLECTION: &str = "skill-usage";
const LOCK_FILE: &str = ".skill-usage.lock";
const MAX_DAY_COUNT: u64 = 1_000_000_000;

pub(super) fn record_counts(
    store: &ClientStateStore,
    agent_id: &str,
    counts: BTreeMap<String, u64>,
    occurred_at: OffsetDateTime,
) -> Result<Value> {
    if counts.is_empty() {
        return Ok(receipt(agent_id, 0, 0));
    }
    ensure!(
        is_agent_approved(store, agent_id)?,
        "runtime skill usage requires an approved agent pairing"
    );
    let managed = managed_skills(store, agent_id)?;
    let selected = counts
        .into_iter()
        .filter(|(skill_id, _)| managed.contains(skill_id))
        .collect::<BTreeMap<_, _>>();
    if selected.is_empty() {
        return Ok(receipt(agent_id, 0, 0));
    }

    let lock = open_private_lock_file(&store.root().join(LOCK_FILE))?;
    lock.lock_exclusive()?;
    let day = format_date(occurred_at)?;
    let mut document = store.read_collection(COLLECTION)?;
    let items = collection_items_mut(&mut document)?;
    let mut buckets = items
        .drain(..)
        .filter_map(|item| {
            let key = item.get("bucketKey")?.as_str()?.to_string();
            Some((key, item))
        })
        .collect::<BTreeMap<_, _>>();
    let mut recorded = 0_u64;
    for (skill_id, count) in selected {
        let bucket_key = bucket_key(agent_id, &skill_id, &day);
        let previous = buckets
            .get(&bucket_key)
            .and_then(|item| item.get("count"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let next = previous
            .checked_add(count)
            .filter(|next| *next <= MAX_DAY_COUNT)
            .ok_or_else(|| anyhow!("skill usage counter overflow"))?;
        recorded = recorded
            .checked_add(count)
            .ok_or_else(|| anyhow!("skill usage counter overflow"))?;
        buckets.insert(
            bucket_key.clone(),
            json!({
                "kind": "skill-usage-day",
                "bucketKey": bucket_key,
                "agentId": agent_id,
                "skillId": skill_id,
                "date": day,
                "count": next,
                "lastUsedAt": occurred_at.format(&Rfc3339)?
            }),
        );
    }
    *items = buckets.into_values().collect();
    store.write_collection(COLLECTION, document)?;
    Ok(receipt(agent_id, recorded, managed.len()))
}

fn managed_skills(store: &ClientStateStore, agent_id: &str) -> Result<BTreeSet<String>> {
    let document = store.read_collection("skills")?;
    Ok(document
        .get("items")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter(|item| {
            item.get("kind").and_then(Value::as_str) == Some("skill")
                && item.get("agentId").and_then(Value::as_str) == Some(agent_id)
                && item.get("installer").and_then(Value::as_str) == Some(SKILL_INSTALLER_PROTOCOL)
        })
        .filter_map(|item| {
            item.get("skillId")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect())
}

fn receipt(agent_id: &str, recorded: u64, managed_count: usize) -> Value {
    json!({
        "ok": true,
        "status": if recorded == 0 { "no_managed_invocations" } else { "recorded" },
        "agentId": agent_id,
        "recordedCount": recorded,
        "managedSkillCount": managed_count,
        "source": "runtime-skill-invocation-events",
        "privacy": "aggregate-only"
    })
}

fn bucket_key(agent_id: &str, skill_id: &str, day: &str) -> String {
    format!("{day}\u{1f}{agent_id}\u{1f}{skill_id}")
}

fn format_date(value: OffsetDateTime) -> Result<String> {
    let format = time::format_description::parse_borrowed::<2>("[year]-[month]-[day]")?;
    Ok(value.date().format(&format)?)
}
