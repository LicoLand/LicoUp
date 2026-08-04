use super::{AdmittedCommand, CliExecution};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::domain::llm_api_key_vault::{
    GatewayCredentialLeaseDays, LlmApiKeyCredentialUpdate, LlmApiKeyProvider, NewLlmApiKey,
};

pub(super) fn handle_status(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(json!({
        "ok": true,
        "schemaVersion": "licoup.llm-api-key-status.v1",
        "supported": crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::platform_supported(),
        "locked": true,
        "providers": ["kimi", "deepseek", "kilo"],
        "leaseDayOptions": [7, 30, 60, 90, 180, 365]
    })))
}

pub(super) fn handle_list(_command: AdmittedCommand) -> Result<CliExecution> {
    let inventory =
        crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::production()?.list()?;
    Ok(CliExecution::Json(serde_json::to_value(inventory)?))
}

pub(super) fn handle_authorize(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::llm_gateway_service::credentials_authorize()?,
    ))
}

pub(super) fn handle_create(mut command: AdmittedCommand) -> Result<CliExecution> {
    let mut input = match command.take_option_json("stdin-json") {
        Some(Value::Object(input)) => input,
        _ => return Err(anyhow!("llm_api_key_private_input_invalid")),
    };
    let provider = provider(input.remove("provider").as_ref().and_then(Value::as_str))?;
    let label = input
        .remove("label")
        .and_then(|value| value.as_str().map(str::to_owned))
        .ok_or_else(|| anyhow!("llm_api_key_label_invalid"))?;
    let api_key = input
        .remove("apiKey")
        .and_then(|value| match value {
            Value::String(value) => Some(value),
            _ => None,
        })
        .ok_or_else(|| anyhow!("llm_api_key_secret_invalid"))?;
    let validity = lease_days(input.remove("leaseDays"))?.unwrap_or_default();
    let inventory = crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::production()?
        .create(NewLlmApiKey::new(provider, label, api_key, validity)?)?;
    Ok(CliExecution::Json(serde_json::to_value(inventory)?))
}

pub(super) fn handle_update(mut command: AdmittedCommand) -> Result<CliExecution> {
    let id = command.required_text("credential-id").to_owned();
    let mut input = match command.take_option_json("stdin-json") {
        Some(Value::Object(input)) => input,
        _ => return Err(anyhow!("llm_api_key_private_input_invalid")),
    };
    let label = input
        .remove("label")
        .and_then(|value| value.as_str().map(str::to_owned));
    let extension = lease_days(input.remove("extendDays"))?;
    let update = LlmApiKeyCredentialUpdate::new(label, extension)?;
    let inventory = crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::production()?
        .update(&id, update)?;
    Ok(CliExecution::Json(serde_json::to_value(inventory)?))
}

pub(super) fn handle_delete(command: AdmittedCommand) -> Result<CliExecution> {
    let id = command.required_text("credential-id");
    let inventory =
        crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::production()?.delete(id)?;
    Ok(CliExecution::Json(serde_json::to_value(inventory)?))
}

pub(super) fn handle_lease(command: AdmittedCommand) -> Result<CliExecution> {
    let days = command
        .required_text("days")
        .parse::<u16>()
        .map_err(|_| anyhow!("llm_api_key_lease_days_invalid"))?;
    let days = GatewayCredentialLeaseDays::try_from(days).map_err(|code| anyhow!(code))?;
    let inventory = crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::production()?
        .set_lease_days(days)?;
    Ok(CliExecution::Json(serde_json::to_value(inventory)?))
}

pub(super) fn handle_agent_plan(command: AdmittedCommand) -> Result<CliExecution> {
    let target = crate::domain::llm_gateway_agent_config::GatewayAgentTarget::parse(
        command.required_text("agent"),
    )?;
    let root = std::path::Path::new(command.required_text("config-root"));
    let port = command
        .option_text("port")
        .unwrap_or("15722")
        .parse::<u16>()?;
    let helper = std::path::Path::new("/usr/bin/printf");
    let plan =
        crate::domain::llm_gateway_agent_config::plan_agent_config(target, root, port, helper)?;
    Ok(CliExecution::Json(serde_json::to_value(plan)?))
}

pub(super) fn handle_agent_apply(command: AdmittedCommand) -> Result<CliExecution> {
    let target = crate::domain::llm_gateway_agent_config::GatewayAgentTarget::parse(
        command.required_text("agent"),
    )?;
    let root = std::path::Path::new(command.required_text("config-root"));
    let port = command
        .option_text("port")
        .unwrap_or("15722")
        .parse::<u16>()?;
    let plan = crate::domain::llm_gateway_agent_config::plan_agent_config(
        target,
        root,
        port,
        std::path::Path::new("/usr/bin/printf"),
    )?;
    let confirmation = command
        .option_text("confirmation")
        .ok_or_else(|| anyhow!("llm_gateway_agent_config_confirmation_required"))?;
    if !command.option_flag("confirmed") || confirmation != plan.confirmation_digest {
        return Err(anyhow!("llm_gateway_agent_config_confirmation_invalid"));
    }
    let parent = plan
        .destination
        .parent()
        .ok_or_else(|| anyhow!("llm_gateway_agent_config_path_invalid"))?;
    crate::platform::file_security::ensure_private_dir(parent)?;
    crate::platform::file_security::atomic_write_private_text(&plan.destination, &plan.content)?;
    Ok(CliExecution::Json(
        json!({"ok": true, "agentId": plan.agent_id,
        "configured": true, "destination": plan.destination, "containsUpstreamSecret": false}),
    ))
}

pub(super) fn handle_service_status(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::llm_gateway_service::service_status(service_port(&command)?)?,
    ))
}

pub(super) fn handle_service_usage(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::llm_gateway_service::service_usage()?,
    ))
}

pub(super) fn handle_service_initialize(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::llm_gateway_service::service_initialize(service_port(&command)?)?,
    ))
}

pub(super) fn handle_service_start(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::llm_gateway_service::service_start(service_port(&command)?)?,
    ))
}

pub(super) fn handle_service_stop(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::llm_gateway_service::service_stop(service_port(&command)?)?,
    ))
}

fn service_port(command: &AdmittedCommand) -> Result<u16> {
    match command.option_text("port") {
        Some(value) => value
            .parse::<u16>()
            .ok()
            .filter(|port| *port != 0)
            .ok_or_else(|| anyhow!("llm_gateway_port_invalid")),
        None => Ok(crate::platform::llm_gateway_service::DEFAULT_PORT),
    }
}

fn provider(value: Option<&str>) -> Result<LlmApiKeyProvider> {
    match value {
        Some("kimi") => Ok(LlmApiKeyProvider::Kimi),
        Some("deepseek") => Ok(LlmApiKeyProvider::DeepSeek),
        Some("kilo") => Ok(LlmApiKeyProvider::Kilo),
        _ => Err(anyhow!("llm_api_key_provider_invalid")),
    }
}

fn lease_days(value: Option<Value>) -> Result<Option<GatewayCredentialLeaseDays>> {
    let Some(value) = value else {
        return Ok(None);
    };
    let days = value
        .as_u64()
        .and_then(|raw| u16::try_from(raw).ok())
        .ok_or_else(|| anyhow!("llm_api_key_lease_days_invalid"))?;
    GatewayCredentialLeaseDays::try_from(days)
        .map(Some)
        .map_err(|code| anyhow!(code))
}
