use super::{
    agent_id, append_activity, bool_param, collection_items_mut, find_skill, get_approved_pairing,
    is_agent_approved, is_explicitly_revealed, is_hidden, local_skill_discovery_requested,
    pairing_required, skill_id, timestamp, upsert_policy_item, visible_skills,
};
use crate::platform::client_state::ClientStateStore;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub(super) fn list(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    if !is_agent_approved(store, &agent_id)? {
        return Ok(pairing_required(&agent_id));
    }
    let mut skills = visible_skills(store, &agent_id)?;
    for discovered in if local_skill_discovery_requested(params) {
        super::discovery::discover(&agent_id, params).unwrap_or_default()
    } else {
        Vec::new()
    } {
        let discovered_id = discovered
            .get("skillId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if is_hidden(store, &agent_id, discovered_id)?
            || !is_visible_by_policy(store, &agent_id, discovered_id)?
            || skills.iter().any(|skill| {
                skill.get("skillId").and_then(Value::as_str) == Some(discovered_id)
                    && skill.get("agentId").and_then(Value::as_str) == Some(agent_id.as_str())
            })
        {
            continue;
        }
        skills.push(discovered);
    }
    skills.sort_by(|left, right| {
        left.get("skillId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .cmp(
                right
                    .get("skillId")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
    });
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "source": "local-agent-skill-roots",
        "skills": skills
    }))
}

pub(super) fn get(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    if !is_agent_approved(store, &agent_id)? {
        return Ok(pairing_required(&agent_id));
    }
    let skill_id = skill_id(params)?;
    let skill = find_skill(store, &agent_id, &skill_id)?.or_else(|| {
        if !local_skill_discovery_requested(params) {
            return None;
        }
        super::discovery::discover(&agent_id, params)
            .ok()?
            .into_iter()
            .find(|skill| skill.get("skillId").and_then(Value::as_str) == Some(skill_id.as_str()))
    });
    let Some(skill) = skill else {
        return Ok(json!({
            "ok": false,
            "error": "not_found",
            "agentId": agent_id,
            "skillId": skill_id,
            "source": "local-agent-skill-roots"
        }));
    };
    if is_hidden(store, &agent_id, &skill_id)? {
        return Ok(json!({
            "ok": false,
            "error": "hidden",
            "agentId": agent_id,
            "skillId": skill_id
        }));
    }
    if !is_visible_by_policy(store, &agent_id, &skill_id)? {
        return Ok(json!({
            "ok": false,
            "error": "visibility_denied",
            "agentId": agent_id,
            "skillId": skill_id,
            "message": "Skill visibility denied by pairing defaultVisibilityPolicy"
        }));
    }
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "skill": skill,
        "source": "local-agent-skill-roots"
    }))
}

pub(super) fn visibility(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    let skill_id = skill_id(params)?;
    let hidden = bool_param(params, "hidden").unwrap_or_else(|| {
        params
            .get("visibility")
            .and_then(Value::as_str)
            .map(|value| value == "hidden" || value == "hide")
            .unwrap_or(false)
    });
    let mut document = store.read_collection("skills")?;
    let items = collection_items_mut(&mut document)?;
    upsert_policy_item(
        items,
        &agent_id,
        &skill_id,
        json!({
            "agentId": agent_id,
            "skillId": skill_id,
            "hidden": hidden,
            "visibility": if hidden { "hidden" } else { "allowed" },
            "updatedAt": timestamp()
        }),
    );
    store.write_collection("skills", document)?;
    append_activity(
        store,
        if hidden {
            "skill.hidden"
        } else {
            "skill.revealed"
        },
        json!({"target": agent_id, "agentId": agent_id, "skillId": skill_id}),
    )?;
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "skillId": skill_id,
        "hidden": hidden
    }))
}

pub(super) fn pin(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    let skill_id = skill_id(params)?;
    let version = params
        .get("version")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("positionals")
                .and_then(Value::as_array)
                .and_then(|items| items.get(1))
                .and_then(Value::as_str)
        })
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("skill pin requires --version <version>"))?
        .to_string();
    let mut document = store.read_collection("pins")?;
    let items = collection_items_mut(&mut document)?;
    upsert_policy_item(
        items,
        &agent_id,
        &skill_id,
        json!({
            "agentId": agent_id,
            "skillId": skill_id,
            "version": version,
            "updatedAt": timestamp()
        }),
    );
    store.write_collection("pins", document)?;
    append_activity(
        store,
        "skill.pinned",
        json!({"target": agent_id, "agentId": agent_id, "skillId": skill_id, "version": version}),
    )?;
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "skillId": skill_id,
        "version": version
    }))
}

fn is_visible_by_policy(store: &ClientStateStore, agent_id: &str, skill_id: &str) -> Result<bool> {
    let pairing = get_approved_pairing(store, agent_id)?;
    let policy = pairing
        .as_ref()
        .and_then(|pairing| {
            pairing
                .get("defaultVisibilityPolicy")
                .and_then(Value::as_str)
        })
        .unwrap_or("allow-all");
    match policy {
        "deny-by-default" => Ok(is_explicitly_revealed(store, agent_id, skill_id)),
        _ => Ok(true),
    }
}
