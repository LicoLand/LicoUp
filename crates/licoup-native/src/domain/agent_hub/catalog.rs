//! Desktop Agent Hub projection. Consumes one target-discovery snapshot.

use super::capabilities::capabilities_from_params;
use super::contract::{
    AgentRecipe, DiscoveryFact, FIRST_BATCH_IDS, HOST_SCOPE, ManifestAgent, OWNERSHIP_NONE,
};
use super::ownership::{self, store_from_params};
use super::package_versions::{self, ChannelVersions};
use super::recipes;
use super::selector;
use super::version;
use super::version_check;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub fn catalog(params: &Value) -> Result<Value> {
    let store = store_from_params(params)?;
    let capabilities = capabilities_from_params(params)?;
    let warehouse = recipes::warehouse()?;
    let requested = requested_agent_id(params, &warehouse.manifest.agents)?;
    let facts = discovery_facts(params, requested.as_deref())?;
    let ownerships = ownership::load(&store)?;
    let live_lookup = requested.is_some() && params.get("discoveryCandidates").is_none();
    let package_roots = live_lookup
        .then(|| package_versions::package_roots(params))
        .unwrap_or_default();
    let cards = match requested.as_deref() {
        Some(id) => {
            let agent = recipes::agent_recipe(&warehouse.registry, id)?;
            vec![project_recipe_card(
                agent,
                &facts,
                &ownerships,
                &capabilities,
                live_lookup,
                &package_roots,
                params,
            )]
        }
        None => warehouse
            .manifest
            .agents
            .iter()
            .map(|agent| project_manifest_card(agent, &facts, &ownerships, params))
            .collect::<Vec<_>>(),
    };
    Ok(json!({
        "ok": true,
        "hostScope": HOST_SCOPE,
        "scanGeneration": capabilities.scan_generation,
        "platform": {
            "os": capabilities.os,
            "architecture": capabilities.architecture,
            "managers": capabilities.managers
        },
        "pluginManagementBoundary": warehouse.manifest.plugin_management_boundary,
        "cards": cards
    }))
}

fn project_manifest_card(
    agent: &ManifestAgent,
    facts: &[DiscoveryFact],
    ownerships: &[super::contract::InstallOwnership],
    params: &Value,
) -> Value {
    let fact = facts.iter().find(|item| item.agent_id == agent.id);
    let present = fact.map(|item| item.present).unwrap_or(false);
    let record = ownerships.iter().find(|item| item.agent_id == agent.id);
    let ownership = ownership::resolve_ownership(record, present);
    let metadata = package_versions::from_params(params, &agent.id);
    let probed = if present {
        version_check::injected_probe(params, &agent.id)
            .map(|raw| version_check::parse_output(&agent.id, &raw, ""))
            .unwrap_or_default()
    } else {
        String::new()
    };
    let installed_version =
        installed_version_of(present, probed.as_str(), fact, &metadata, "", record);
    let latest_version = first_concrete([
        fact.map(|item| item.latest_version.as_str()).unwrap_or(""),
        metadata.latest.as_str(),
        "",
    ]);
    card_json(
        agent.id.as_str(),
        agent.label.as_str(),
        agent.adaptation.as_str(),
        agent.protocol.as_str(),
        agent.license.as_str(),
        agent.summary.as_str(),
        agent.homepage.as_str(),
        &agent.connection_modes,
        agent.requires_login,
        present,
        fact,
        ownership,
        record,
        None,
        None,
        String::new(),
        primary_action(ownership, record.is_some(), false, true),
        false,
        installed_version,
        latest_version,
        Vec::new(),
    )
}

fn project_recipe_card(
    agent: &AgentRecipe,
    facts: &[DiscoveryFact],
    ownerships: &[super::contract::InstallOwnership],
    capabilities: &super::contract::PlatformInstallCapabilities,
    live_lookup: bool,
    package_roots: &[std::path::PathBuf],
    params: &Value,
) -> Value {
    let fact = facts.iter().find(|item| item.agent_id == agent.id);
    let present = fact.map(|item| item.present).unwrap_or(false);
    let record = ownerships.iter().find(|item| item.agent_id == agent.id);
    let ownership = ownership::resolve_ownership(record, present);
    let selected = selector::select_channel(agent, capabilities).ok();
    let channel_kind = selector::chip_channel_kind(agent, selected.as_ref(), record);
    let metadata = package_versions::from_params(params, &agent.id);
    let local = if live_lookup {
        selected
            .as_ref()
            .map(|item| package_versions::lookup_local(item.channel, package_roots))
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
        fact.and_then(|fact| fact.executable_binding.as_deref()),
    );
    let installed_version = installed_version_of(
        present,
        probed.as_str(),
        fact,
        &metadata,
        local.installed.as_str(),
        record,
    );
    let latest_version = first_concrete([
        fact.map(|item| item.latest_version.as_str()).unwrap_or(""),
        metadata.latest.as_str(),
        local.latest.as_str(),
    ]);
    let install_channels = selector::available_channels(agent, capabilities)
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
    card_json(
        agent.id.as_str(),
        agent.label.as_str(),
        agent.adaptation.as_str(),
        agent.protocol.as_str(),
        agent.license.as_str(),
        agent.summary.as_str(),
        agent.homepage.as_str(),
        &agent.connection_modes,
        agent.requires_login,
        present,
        fact,
        ownership,
        record,
        selected.as_ref().map(|item| item.channel.id.as_str()),
        selected.as_ref().map(|item| item.channel.kind.as_str()),
        channel_kind,
        primary_action(ownership, record.is_some(), selected.is_some(), false),
        selected.is_some() && ownership == OWNERSHIP_NONE,
        installed_version,
        latest_version,
        install_channels,
    )
}

fn card_json(
    id: &str,
    label: &str,
    adaptation: &str,
    protocol: &str,
    license: &str,
    summary: &str,
    homepage: &str,
    connection_modes: &[String],
    requires_login: bool,
    present: bool,
    fact: Option<&DiscoveryFact>,
    ownership: &str,
    record: Option<&super::contract::InstallOwnership>,
    selected_channel_id: Option<&str>,
    selected_channel_kind: Option<&str>,
    channel_kind: String,
    primary_action: &'static str,
    installable: bool,
    installed_version: String,
    latest_version: String,
    install_channels: Vec<Value>,
) -> Value {
    let update_available = version::update_available(&installed_version, &latest_version);
    json!({
        "id": id,
        "label": label,
        "adaptation": adaptation,
        "protocol": protocol,
        "license": license,
        "summary": summary,
        "homepage": homepage,
        "connectionModes": connection_modes,
        "requiresLogin": requires_login,
        "present": present,
        "location": fact.map(|item| item.location.as_str()).unwrap_or("local"),
        "ownership": ownership,
        "lifecycle": record
            .map(|item| item.lifecycle.as_str())
            .unwrap_or(if present { "discovered" } else { "absent" }),
        "selectedChannelId": selected_channel_id,
        "selectedChannelKind": selected_channel_kind,
        "channelKind": channel_kind,
        "primaryAction": primary_action,
        "installable": installable,
        "installedVersion": installed_version.clone(),
        "latestVersion": latest_version,
        "updateAvailable": update_available,
        "version": installed_version,
        "installChannels": install_channels
    })
}

fn primary_action(
    ownership: &str,
    has_record: bool,
    selected: bool,
    manifest_only: bool,
) -> &'static str {
    if ownership == OWNERSHIP_NONE {
        if manifest_only || selected {
            "install"
        } else {
            "unsupported"
        }
    } else if has_record {
        "manage"
    } else {
        "open"
    }
}

fn installed_version_of(
    present: bool,
    probed: &str,
    fact: Option<&DiscoveryFact>,
    metadata: &ChannelVersions,
    local: &str,
    record: Option<&super::contract::InstallOwnership>,
) -> String {
    if present {
        first_concrete([
            probed,
            fact.map(|item| item.installed_version.as_str())
                .unwrap_or(""),
            metadata.installed.as_str(),
            local,
            record
                .map(|item| item.installed_version.as_str())
                .unwrap_or(""),
        ])
    } else {
        String::new()
    }
}

fn requested_agent_id(params: &Value, agents: &[ManifestAgent]) -> Result<Option<String>> {
    let Some(id) = params
        .get("agentId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
    else {
        return Ok(None);
    };
    if !agents.iter().any(|agent| agent.id == id) {
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
        .map(|value| {
            let concrete = version::concrete_display(value);
            if concrete.is_empty() && version_check::is_cursor_date_hash_version(value.trim()) {
                value.trim().to_owned()
            } else {
                concrete
            }
        })
        .find(|value| !value.is_empty())
        .unwrap_or_default()
}

fn fact_from_value(item: &Value) -> Option<DiscoveryFact> {
    let agent_id = item
        .get("target")
        .or_else(|| item.get("agentId"))
        .and_then(Value::as_str)
        .filter(|value| FIRST_BATCH_IDS.contains(value))?;
    let present = item.get("present").and_then(Value::as_bool) == Some(true)
        || item
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| {
                status == "detected" || status == "configured" || status == "available"
            })
        || item
            .get("binaryPath")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty());
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
        executable_binding: item
            .get("binaryPath")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(std::path::PathBuf::from),
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
