//! Gateway Runtime CLI: service + Communication Channel (Telegram).

use super::{AdmittedCommand, CliExecution};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::io::Write as _;

pub(super) fn handle_client_token(command: AdmittedCommand) -> Result<CliExecution> {
    crate::domain::llm_gateway_agent_config::GatewayAgentTarget::parse(
        command.required_text("agent"),
    )?;
    let token = crate::platform::llm_gateway_client_auth::ensure_default_token()?;
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(token.expose_bytes())?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(CliExecution::Streamed)
}

pub(super) fn handle_help(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(json!({
        "ok": true,
        "schemaVersion": "licoup.gateway-runtime-help.v1",
        "layers": ["llm-gateway", "communication-channel"],
        "commands": [
            "gateway client-token --agent <agent-id>",
            "gateway service status|start|stop|initialize",
            "gateway inventory reload --stdin-json true",
            "gateway channel status",
            "gateway channel telegram credentials status|set|clear",
            "gateway channel telegram credentials set --stdin-json true",
            "gateway channel telegram pairing list|approve|revoke",
            "llm-gateway …  # alias for lower LLM layer + unified service lifecycle",
        ],
        "chatCommands": ["/help", "/start", "/status", "/agent", "/session", "/new"],
        "notes": [
            "One Gateway Runtime process hosts LLM Gateway and Communication Channels.",
            "Telegram is a Communication Channel, not a separate gateway.",
            "Telegram can read message content sent through the bot.",
            "Verified readiness uses partial hot-reload via gateway inventory reload; in-use sessions are preserved."
        ]
    })))
}

pub(super) fn handle_service_status(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::service_status(service_port(&command)?)?,
    ))
}

pub(super) fn handle_service_start(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::service_start(service_port(&command)?)?,
    ))
}

pub(super) fn handle_service_stop(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::service_stop(service_port(&command)?)?,
    ))
}

pub(super) fn handle_service_initialize(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::service_initialize(service_port(&command)?)?,
    ))
}

pub(super) fn handle_inventory_reload(mut command: AdmittedCommand) -> Result<CliExecution> {
    let readiness = command
        .take_option_json("stdin-json")
        .ok_or_else(|| anyhow!("gateway_inventory_reload_private_input_invalid"))?;
    let readiness_json = match readiness {
        Value::Object(_) | Value::Array(_) => serde_json::to_string(&readiness)
            .map_err(|_| anyhow!("gateway_inventory_reload_private_input_invalid"))?,
        Value::String(text) => text,
        _ => return Err(anyhow!("gateway_inventory_reload_private_input_invalid")),
    };
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::reload_conversation_inventory(&readiness_json)?,
    ))
}

pub(super) fn handle_channel_status(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::channel_layer_status()?,
    ))
}

pub(super) fn handle_telegram_credentials_status(
    _command: AdmittedCommand,
) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::telegram::credentials_status()?,
    ))
}

pub(super) fn handle_telegram_credentials_set(
    mut command: AdmittedCommand,
) -> Result<CliExecution> {
    let token = match command.take_option_json("stdin-json") {
        Some(Value::Object(mut input)) => input
            .remove("botToken")
            .or_else(|| input.remove("token"))
            .and_then(|value| match value {
                Value::String(token) => Some(token),
                _ => None,
            })
            .ok_or_else(|| anyhow!("telegram_channel_token_invalid"))?,
        Some(Value::String(token)) => token,
        _ => return Err(anyhow!("telegram_channel_private_input_invalid")),
    };
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::telegram::set_bot_token(&token)?,
    ))
}

pub(super) fn handle_telegram_credentials_clear(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::telegram::clear_bot_token()?,
    ))
}

pub(super) fn handle_telegram_pairing_list(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::telegram::list_pairings()?,
    ))
}

pub(super) fn handle_telegram_pairing_approve(command: AdmittedCommand) -> Result<CliExecution> {
    let code = command.required_text("code");
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::telegram::approve_pairing(code)?,
    ))
}

pub(super) fn handle_telegram_pairing_revoke(command: AdmittedCommand) -> Result<CliExecution> {
    let chat_id = command
        .required_text("chat-id")
        .parse::<i64>()
        .map_err(|_| anyhow!("telegram_channel_chat_id_invalid"))?;
    Ok(CliExecution::Json(
        crate::platform::gateway_runtime::telegram::revoke_pairing(chat_id)?,
    ))
}

fn service_port(command: &AdmittedCommand) -> Result<u16> {
    match command.option_text("port") {
        Some(value) => value
            .parse::<u16>()
            .ok()
            .filter(|port| *port != 0)
            .ok_or_else(|| anyhow!("gateway_port_invalid")),
        None => Ok(crate::platform::gateway_runtime::service::DEFAULT_PORT),
    }
}
