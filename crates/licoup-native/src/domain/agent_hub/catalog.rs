//! Desktop Agent Hub projection. Consumes one target-discovery snapshot.

use super::capabilities::capabilities_from_params;
use super::contract::{DiscoveryFact, FIRST_BATCH_IDS, HOST_SCOPE, OWNERSHIP_NONE};
use super::ownership::{self, store_from_params};
use super::recipes;
use super::selector;
use anyhow::Result;
use serde_json::{json, Value};

pub fn catalog(params: &Value) -> Result<Value> {
    let store = store_from_params(params)?;
    let capabilities = capabilities_from_params(params)?;
    let registry = recipes::registry()?;
    let facts = discovery_facts(params)?;
    let ownerships = ownership::load(&store)?;
    let cards = FIRST_BATCH_IDS
        .iter()
        .filter_map(|id| registry.agents.iter().find(|agent| agent.id == *id))
        .map(|agent| {
            let fact = facts.iter().find(|item| item.agent_id == agent.id);
            let present = fact.map(|item| item.present).unwrap_or(false);
            let record = ownerships.iter().find(|item| item.agent_id == agent.id);
            let ownership = ownership::resolve_ownership(record, present);
            let selected = selector::select_channel(agent, &capabilities).ok();
            let channel_kind = selector::chip_channel_kind(agent, selected.as_ref(), record);
            let primary_action = if ownership == OWNERSHIP_NONE {
                if selected.is_some() {
                    "install"
                } else {
                    "unsupported"
                }
            } else if record.is_some() {
                "manage"
            } else {
                "open"
            };
            json!({
                "id": agent.id,
                "label": agent.label,
                "adaptation": agent.adaptation,
                "protocol": agent.protocol,
                "license": agent.license,
                "summary": agent.summary,
                "homepage": agent.homepage,
                "connectionModes": agent.connection_modes,
                "requiresLogin": agent.requires_login,
                "present": present,
                "location": fact.map(|item| item.location.as_str()).unwrap_or("local"),
                "ownership": ownership,
                "lifecycle": record
                    .map(|item| item.lifecycle.as_str())
                    .unwrap_or(if present { "discovered" } else { "absent" }),
                "selectedChannelId": selected.as_ref().map(|item| item.channel.id.as_str()),
                "selectedChannelKind": selected.as_ref().map(|item| item.channel.kind.as_str()),
                "channelKind": channel_kind,
                "primaryAction": primary_action,
                "installable": selected.is_some() && ownership == OWNERSHIP_NONE
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "ok": true,
        "hostScope": HOST_SCOPE,
        "scanGeneration": capabilities.scan_generation,
        "platform": {
            "os": capabilities.os,
            "architecture": capabilities.architecture,
            "managers": capabilities.managers
        },
        "pluginManagementBoundary": registry.plugin_management_boundary,
        "cards": cards
    }))
}

pub fn discovery_facts(params: &Value) -> Result<Vec<DiscoveryFact>> {
    if let Some(items) = params.get("discoveryCandidates").and_then(Value::as_array) {
        return Ok(items.iter().filter_map(fact_from_value).collect());
    }
    let scan = crate::domain::targets::scan_targets_with_params(params)?;
    let candidates = scan
        .get("candidates")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    Ok(candidates.iter().filter_map(fact_from_value).collect())
}

fn fact_from_value(item: &Value) -> Option<DiscoveryFact> {
    let agent_id = item
        .get("target")
        .or_else(|| item.get("agentId"))
        .and_then(Value::as_str)
        .filter(|value| FIRST_BATCH_IDS.contains(value))?;
    let present = item
        .get("present")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            item.get("status")
                .and_then(Value::as_str)
                .is_some_and(|status| {
                    status == "detected" || status == "configured" || status == "available"
                })
                || item
                    .get("binaryPath")
                    .and_then(Value::as_str)
                    .is_some_and(|value| !value.is_empty())
        });
    Some(DiscoveryFact {
        agent_id: agent_id.to_string(),
        present,
        location: item
            .get("location")
            .and_then(Value::as_str)
            .unwrap_or("local")
            .to_string(),
        scan_source: item
            .get("scanSource")
            .and_then(Value::as_str)
            .unwrap_or("target-adapters")
            .to_string(),
    })
}
