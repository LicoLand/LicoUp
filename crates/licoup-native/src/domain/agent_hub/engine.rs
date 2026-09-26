//! Plan/apply/update/uninstall lifecycle. Argv-only after one confirmation.

use super::argv::{ArgvKind, ArgvRunner, ProcessArgvRunner, validate_program_args};
use super::capabilities::capabilities_from_params;
use super::confirmation::{self, install_argv_for};
use super::contract::{
    HubEvent, InstallChannel, InstallOwnership, LIFECYCLE_AVAILABLE, LIFECYCLE_NEEDS_LOGIN,
    OWNERSHIP_EXTERNAL, OWNERSHIP_OWNED, PlatformInstallCapabilities,
};
use super::ownership::{self, store_from_params};
use super::recipes::{self, agent_recipe};
use super::selector;
use crate::platform::client_state::ClientStateStore;
use crate::state_machines::agent_hub_operation::{
    self as operation_machine, Event as LifecycleEvent, State as LifecycleState,
};
use anyhow::{Result, anyhow, ensure};
use serde_json::{Value, json};
use std::sync::Arc;

pub struct HubContext {
    pub store: ClientStateStore,
    pub capabilities: PlatformInstallCapabilities,
    pub runner: Arc<dyn ArgvRunner>,
}

impl HubContext {
    pub fn from_params(params: &Value) -> Result<Self> {
        Ok(Self {
            store: store_from_params(params)?,
            capabilities: capabilities_from_params(params)?,
            runner: Arc::new(ProcessArgvRunner),
        })
    }

    pub fn with_runner(params: &Value, runner: Arc<dyn ArgvRunner>) -> Result<Self> {
        Ok(Self {
            store: store_from_params(params)?,
            capabilities: capabilities_from_params(params)?,
            runner,
        })
    }
}

pub fn plan(params: &Value) -> Result<Value> {
    plan_with(&HubContext::from_params(params)?, params)
}

pub fn apply(params: &Value) -> Result<Value> {
    apply_with(&HubContext::from_params(params)?, params)
}

pub fn plan_with(ctx: &HubContext, params: &Value) -> Result<Value> {
    let operation = operation_of(params, "install");
    let agent_id = agent_id(params)?;
    let registry = recipes::registry()?;
    let agent = agent_recipe(registry, &agent_id)?;
    let present = discovery_present(params, &agent_id);
    let owned = ownership::get(&ctx.store, &agent_id)?;
    let ownership = ownership::resolve_ownership(owned.as_ref(), present);

    if operation == "install" && ownership == OWNERSHIP_EXTERNAL {
        return Ok(json!({
            "ok": true,
            "status": "external_protected",
            "operation": operation,
            "agentId": agent_id,
            "ownership": OWNERSHIP_EXTERNAL,
            "requiresConfirmation": false,
            "selectedChannel": Value::Null
        }));
    }
    if operation != "install" && ownership != OWNERSHIP_OWNED {
        return Ok(json!({
            "ok": false,
            "status": "external_protected",
            "code": "external_install_protected",
            "operation": operation,
            "agentId": agent_id,
            "ownership": ownership
        }));
    }

    let requested_channel = params
        .get("channelId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let selected = if let Some(requested) = requested_channel {
        let channel = selector::channel_by_id(agent, requested)?;
        if operation == "install" {
            ensure!(
                selector::channel_matches(channel, &ctx.capabilities),
                "channel_unavailable"
            );
        } else {
            let record = owned
                .as_ref()
                .ok_or_else(|| anyhow!("external_install_protected"))?;
            ensure!(requested == record.channel_id, "channel_mismatch");
        }
        channel
    } else if operation != "install" {
        let record = owned
            .as_ref()
            .ok_or_else(|| anyhow!("external_install_protected"))?;
        selector::channel_by_id(agent, &record.channel_id)?
    } else {
        selector::select_channel(agent, &ctx.capabilities)?.channel
    };
    let argv = argv_for(&operation, &ctx.capabilities.os, selected);
    argv_guard(&argv, selected)?;
    let confirmation = confirmation::token(&operation, &agent_id, selected);
    Ok(json!({
        "ok": true,
        "status": operation_machine::INITIAL.as_str(),
        "operation": operation,
        "agentId": agent_id,
        "adaptation": agent.adaptation,
        "ownership": ownership,
        "requiresConfirmation": true,
        "confirmation": confirmation,
        "selectedChannel": {
            "id": selected.id,
            "kind": selected.kind,
            "packageCoordinate": selected.package_coordinate,
            "officialSource": selected.official_source,
            "versionPolicy": selected.version_policy,
            "argv": argv
        }
    }))
}

pub fn apply_with(ctx: &HubContext, params: &Value) -> Result<Value> {
    let planned = plan_with(ctx, params)?;
    if planned.get("status").and_then(Value::as_str) == Some("external_protected")
        || planned.get("ok") == Some(&json!(false))
    {
        return Ok(planned);
    }
    let confirmation = planned
        .get("confirmation")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    confirmation::require(params, &confirmation)?;
    let mut lifecycle = LifecycleTrace::new();
    lifecycle.advance(LifecycleEvent::Confirm)?;
    if params.get("cancel").and_then(Value::as_bool) == Some(true) {
        lifecycle.advance(LifecycleEvent::Cancel)?;
        return Ok(json!({
            "ok": true,
            "status": lifecycle.state().as_str(),
            "operation": planned["operation"],
            "agentId": planned["agentId"],
            "events": lifecycle.events()
        }));
    }
    let operation = planned
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or("install")
        .to_string();
    let agent_id = planned
        .get("agentId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let argv = planned["selectedChannel"]["argv"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|value| value.as_str().map(str::to_string))
        .map(|arg| substitute_placeholders(&arg, params))
        .collect::<Vec<_>>();
    ensure!(!argv.is_empty(), "argv_forbidden");
    let program = argv[0].clone();
    let args = argv[1..].to_vec();
    validate_program_args(&program, &args, ArgvKind::Lifecycle)?;
    lifecycle.advance(LifecycleEvent::Apply)?;
    let outcome = ctx.runner.run(&program, &args)?;
    if outcome.status != 0 {
        lifecycle.advance(LifecycleEvent::Fail)?;
        return Ok(json!({
            "ok": false,
            "status": lifecycle.state().as_str(),
            "operation": operation,
            "agentId": agent_id,
            "events": lifecycle.events(),
            "runner": super::argv::outcome_json(&outcome)
        }));
    }
    lifecycle.advance(LifecycleEvent::Verify)?;
    let registry = recipes::registry()?;
    let agent = agent_recipe(registry, &agent_id)?;
    let channel_id = planned["selectedChannel"]["id"]
        .as_str()
        .unwrap_or_default();
    let channel = selector::channel_by_id(agent, channel_id)?;
    if !channel.verify_argv.is_empty() {
        let verify = substitute_argv(&channel.verify_argv, params);
        let _ = ctx.runner.run(&verify[0], &verify[1..])?;
    }
    lifecycle.advance(LifecycleEvent::Rescan)?;
    if operation == "uninstall" {
        ownership::remove(&ctx.store, &agent_id)?;
        lifecycle.advance(LifecycleEvent::MarkAvailable)?;
        return Ok(json!({
            "ok": true,
            "status": "uninstalled",
            "operation": operation,
            "agentId": agent_id,
            "ownership": "none",
            "events": lifecycle.events()
        }));
    }
    ownership::save(
        &ctx.store,
        InstallOwnership {
            agent_id: agent_id.clone(),
            channel_id: channel.id.clone(),
            channel_kind: channel.kind.clone(),
            package_coordinate: channel.package_coordinate.clone(),
            installed_version: super::version::concrete_display(&requested_version(params)),
            ownership: OWNERSHIP_OWNED.to_string(),
            lifecycle: if agent.requires_login {
                LIFECYCLE_NEEDS_LOGIN.to_string()
            } else {
                LIFECYCLE_AVAILABLE.to_string()
            },
        },
    )?;
    let completion = if agent.requires_login {
        LifecycleEvent::RequireLogin
    } else {
        LifecycleEvent::MarkAvailable
    };
    lifecycle.advance(completion)?;
    let status = lifecycle.state().as_str();
    Ok(json!({
        "ok": true,
        "status": status,
        "operation": operation,
        "agentId": agent_id,
        "ownership": OWNERSHIP_OWNED,
        "channelId": channel.id,
        "channelKind": channel.kind,
        "events": lifecycle.events()
    }))
}

fn argv_for(operation: &str, os: &str, channel: &InstallChannel) -> Vec<String> {
    match operation {
        "update" => channel.update_argv.clone(),
        "uninstall" => channel.uninstall_argv.clone(),
        _ => install_argv_for(os, channel),
    }
}

fn argv_guard(argv: &[String], channel: &InstallChannel) -> Result<()> {
    if argv.is_empty() {
        return Err(anyhow!("argv_forbidden"));
    }
    validate_program_args(&argv[0], &argv[1..], ArgvKind::for_channel(&channel.kind))
}

fn substitute_argv(argv: &[String], params: &Value) -> Vec<String> {
    argv.iter()
        .map(|arg| substitute_placeholders(arg, params))
        .collect()
}

fn substitute_placeholders(arg: &str, params: &Value) -> String {
    let staging = params
        .get("stagingDir")
        .and_then(Value::as_str)
        .unwrap_or("staging");
    let artifact = params
        .get("artifactPath")
        .and_then(Value::as_str)
        .unwrap_or("artifact");
    let script = params
        .get("scriptPath")
        .and_then(Value::as_str)
        .unwrap_or("script");
    let install = params
        .get("installRef")
        .and_then(Value::as_str)
        .unwrap_or("install");
    let version = requested_version(params);
    arg.replace("{staging}", staging)
        .replace("{artifact}", artifact)
        .replace("{script}", script)
        .replace("{install}", install)
        .replace("{version}", &version)
}

fn requested_version(params: &Value) -> String {
    params
        .get("version")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("latest")
        .to_string()
}

fn agent_id(params: &Value) -> Result<String> {
    params
        .get("agentId")
        .or_else(|| params.get("agent"))
        .or_else(|| params.get("target"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("recipe_not_found"))
}

fn operation_of(params: &Value, default: &str) -> String {
    params
        .get("operation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(default)
        .to_string()
}

fn discovery_present(params: &Value, agent_id: &str) -> bool {
    params
        .get("discoveryCandidates")
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().find(|item| {
                item.get("target")
                    .or_else(|| item.get("agentId"))
                    .and_then(Value::as_str)
                    == Some(agent_id)
            })
        })
        .map(fact_present)
        .unwrap_or(false)
}

fn fact_present(item: &Value) -> bool {
    if let Some(present) = item.get("present").and_then(Value::as_bool) {
        return present;
    }
    item.get("binaryPath")
        .and_then(Value::as_str)
        .is_some_and(|value| !value.is_empty())
        || item
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| {
                status == "detected" || status == "configured" || status == "available"
            })
}

struct LifecycleTrace {
    state: LifecycleState,
    phases: Vec<LifecycleState>,
}

impl LifecycleTrace {
    fn new() -> Self {
        Self {
            state: operation_machine::INITIAL,
            phases: vec![operation_machine::INITIAL],
        }
    }

    fn advance(&mut self, event: LifecycleEvent) -> Result<()> {
        let next = operation_machine::transition(self.state, event).ok_or_else(|| {
            anyhow!(
                "invalid_agent_hub_lifecycle_transition:{}:{}",
                self.state.as_str(),
                event.as_str()
            )
        })?;
        self.state = next;
        self.phases.push(next);
        Ok(())
    }

    fn state(&self) -> LifecycleState {
        self.state
    }

    fn events(&self) -> Vec<HubEvent> {
        self.phases
            .iter()
            .map(|phase| HubEvent {
                phase: phase.as_str().to_string(),
                code: phase.as_str().to_string(),
            })
            .collect()
    }
}
