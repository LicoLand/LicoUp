//! Desktop Agent Hub projection. Consumes one target-discovery snapshot.

use super::capabilities::capabilities_from_params;
use super::contract::{DiscoveryFact, FIRST_BATCH_IDS, HOST_SCOPE, OWNERSHIP_NONE};
use super::ownership::{self, store_from_params};
use super::package_versions::{self, ChannelVersions};
use super::recipes;
use super::selector;
use super::version;
use super::version_check;
use anyhow::{anyhow, Result};
use serde_json::{json, Value};

pub fn catalog(params: &Value) -> Result<Value> {
    let store = store_from_params(params)?;
    let capabilities = capabilities_from_params(params)?;
    let registry = recipes::registry()?;
    let requested = requested_agent_id(params)?;
    let facts = discovery_facts(params, requested.as_deref())?;
    let ownerships = ownership::load(&store)?;
    let live_lookup = requested.is_some() && params.get("discoveryCandidates").is_none();
    let package_roots = live_lookup
        .then(|| package_versions::package_roots(params))
        .unwrap_or_default();
    let card_ids: Vec<&str> = match requested.as_deref() {
        Some(id) => vec![id],
        None => FIRST_BATCH_IDS.to_vec(),
    };
    let cards = card_ids
        .iter()
        .filter_map(|id| registry.agents.iter().find(|agent| agent.id == *id))
        .map(|agent| {
            let fact = facts.iter().find(|item| item.agent_id == agent.id);
            let present = fact.map(|item| item.present).unwrap_or(false);
            let record = ownerships.iter().find(|item| item.agent_id == agent.id);
            let ownership = ownership::resolve_ownership(record, present);
            let selected = selector::select_channel(agent, &capabilities).ok();
            let channel_kind = selector::chip_channel_kind(agent, selected.as_ref(), record);
            let metadata = package_versions::from_params(params, &agent.id);
            let local = if live_lookup {
                selected
                    .as_ref()
                    .map(|item| package_versions::lookup_local(item.channel, &package_roots))
                    .unwrap_or_default()
            } else {
                ChannelVersions::default()
            };
            let probed = version_check::installed_version(
                agent,
                selected.as_ref().map(|item| item.channel),
                present,
                live_lookup,
                params,
            );
            let installed_version = if present {
                first_concrete([
                    probed.as_str(),
                    fact.map(|item| item.installed_version.as_str())
                        .unwrap_or(""),
                    metadata.installed.as_str(),
                    local.installed.as_str(),
                    record
                        .map(|item| item.installed_version.as_str())
                        .unwrap_or(""),
                ])
            } else {
                String::new()
            };
            let latest_version = first_concrete([
                fact.map(|item| item.latest_version.as_str()).unwrap_or(""),
                metadata.latest.as_str(),
                local.latest.as_str(),
            ]);
            let update_available = version::update_available(&installed_version, &latest_version);
            let install_channels = selector::available_channels(agent, &capabilities)
                .into_iter()
                .map(|channel| {
                    json!({
                        "id": channel.id,
                        "kind": channel.kind,
                        "versionPolicy": channel.version_policy,
                        "officialSource": channel.official_source,
                        "commandPreview": command_preview(&capabilities.os, channel)
                    })
                })
                .collect::<Vec<_>>();
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
                "installable": selected.is_some() && ownership == OWNERSHIP_NONE,
                "installedVersion": installed_version.clone(),
                "latestVersion": latest_version,
                "updateAvailable": update_available,
                "version": installed_version,
                "installChannels": install_channels
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

fn requested_agent_id(params: &Value) -> Result<Option<String>> {
    let Some(id) = params
        .get("agentId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
    else {
        return Ok(None);
    };
    if !FIRST_BATCH_IDS.contains(&id.as_str()) {
        return Err(anyhow!("recipe_not_found"));
    }
    Ok(Some(id))
}

pub fn discovery_facts(params: &Value, agent_id: Option<&str>) -> Result<Vec<DiscoveryFact>> {
    if let Some(items) = params.get("discoveryCandidates").and_then(Value::as_array) {
        return Ok(items
            .iter()
            .filter_map(fact_from_value)
            .filter(|fact| agent_id.is_none_or(|id| fact.agent_id == id))
            .collect());
    }
    let Some(agent_id) = agent_id else {
        return Ok(Vec::new());
    };
    live_fact(params, agent_id).map(|fact| fact.into_iter().collect())
}

fn live_fact(params: &Value, agent_id: &str) -> Result<Option<DiscoveryFact>> {
    let mut inspect_params = params.clone();
    inspect_params["target"] = json!(agent_id);
    let inspected = crate::domain::targets::inspect_target_with_params(&inspect_params)?;
    Ok(inspected.get("target").and_then(fact_from_value))
}

fn command_preview(os: &str, channel: &super::contract::InstallChannel) -> String {
    super::confirmation::install_argv_for(os, channel)
        .into_iter()
        .filter(|arg| !arg.trim().is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn first_concrete<const N: usize>(values: [&str; N]) -> String {
    values
        .into_iter()
        .map(version::concrete_display)
        .find(|value| !value.is_empty())
        .unwrap_or_default()
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
        installed_version: text_field(item, &["installedVersion", "version"]),
        latest_version: text_field(item, &["latestVersion"]),
    })
}

fn text_field(item: &Value, keys: &[&str]) -> String {
    keys.iter()
        .filter_map(|key| item.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .find(|value| !value.is_empty())
        .unwrap_or_default()
        .to_string()
}
