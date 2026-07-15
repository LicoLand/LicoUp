// connectors commands: connectors list|sync|status, connectors mirror inspect,
// knowledge-cache, mail, source-queue, mcp-local-bridge, agent conversation, agents pair

use super::{CliExecution, CommandTable, cli_params};
use anyhow::{Result, anyhow};
use serde_json::Value;
use std::io::Read;

pub fn register_commands(table: &mut CommandTable) {
    // Exact path first, then rest-capture for sub-action dispatch
    table.register_rest(
        &["connectors", "mirror", "inspect"],
        handle_connectors_mirror,
        "Inspect connector mirror",
    );
    table.register_rest(
        &["connectors"],
        handle_connectors,
        "Connector list|sync|status",
    );
    table.register_rest(
        &["knowledge-cache"],
        handle_knowledge_cache,
        "Knowledge cache sync|search|evidence|get|status",
    );
    table.register_rest(&["mail"], handle_mail, "Mail preview|enqueue|status|cancel");
    table.register_rest(
        &["source-queue"],
        handle_source_queue,
        "Source queue add|list|status|pause|resume|retry|cancel|drain",
    );
    table.register_rest(
        &["mcp-local-bridge"],
        handle_mcp_local_bridge,
        "MCP local bridge plan|start|stop|status|register",
    );
    table.register_rest(
        &["agent", "conversation"],
        handle_agent_conversation,
        "Agent conversation open|send|cancel|capabilities|stream",
    );
    table.register_rest(
        &["agents", "pair"],
        handle_agents_pair,
        "Agent pair request|approve|revoke|list",
    );
}

fn handle_connectors(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "list" => crate::domain::connectors::list(&params)?,
        "sync" => crate::domain::connectors::sync(&params)?,
        "status" => crate::domain::connectors::status(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_connectors_mirror(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::connectors::mirror_inspect(&params)?,
    ))
}

fn handle_knowledge_cache(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "sync" => crate::domain::knowledge_cache::sync(&params)?,
        "search" => crate::domain::knowledge_cache::search(&params)?,
        "evidence" => crate::domain::knowledge_cache::evidence(&params)?,
        "get" => crate::domain::knowledge_cache::get(&params)?,
        "status" => crate::domain::knowledge_cache::status(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_mail(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "preview" => crate::domain::mail::preview(&params)?,
        "enqueue" => crate::domain::mail::enqueue(&params)?,
        "status" => crate::domain::mail::status(&params)?,
        "cancel" => crate::domain::mail::cancel(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_source_queue(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "add" => crate::domain::source_queue::add(&params)?,
        "list" => crate::domain::source_queue::list(&params)?,
        "status" => crate::domain::source_queue::status(&params)?,
        "pause" => crate::domain::source_queue::pause(&params)?,
        "resume" => crate::domain::source_queue::resume(&params)?,
        "retry" => crate::domain::source_queue::retry(&params)?,
        "cancel" => crate::domain::source_queue::cancel(&params)?,
        "drain" => crate::domain::source_queue::drain(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_mcp_local_bridge(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "plan" => crate::domain::mcp_local_bridge::plan(&params)?,
        "start" => crate::domain::mcp_local_bridge::start(&params)?,
        "stop" => crate::domain::mcp_local_bridge::stop(&params)?,
        "status" => crate::domain::mcp_local_bridge::status(&params)?,
        "register" => crate::domain::mcp_local_bridge::register(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_agent_conversation(args: &[String]) -> Result<CliExecution> {
    if args.len() < 3 {
        return Ok(CliExecution::Usage);
    }
    let operation = args[2].as_str();
    let control = cli_params(&args[3..]);
    let mut params = if stdin_json_enabled(&control) {
        let mut request_json = String::new();
        std::io::stdin().read_to_string(&mut request_json)?;
        parse_agent_message_stdin_json(&request_json)?
    } else {
        // Allow non-send ops with CLI flags only (agentId required).
        let mut params = control.clone();
        if let Some(object) = params.as_object_mut() {
            if let Some(agent) = object.remove("agent") {
                object.insert("agent".to_string(), agent);
            }
        }
        params
    };
    // CLI flag / control overlay for progressive NDJSON during send.
    if stream_events_enabled(&control) || stream_events_enabled(&params) {
        if let Some(object) = params.as_object_mut() {
            object.insert("streamEvents".to_string(), serde_json::json!(true));
        }
    }

    if operation == "send" && stream_events_enabled(&params) {
        if let Err(error) = crate::platform::enforce_send_readiness(&params) {
            let mut failure = agent_conversation_failure(&error);
            failure["event"] = serde_json::json!("done");
            write_stdout_json_line(&failure)?;
            return Ok(CliExecution::Streamed);
        }
        let _guard = crate::platform::install_stdout_ndjson_sink();
        crate::platform::emit_turn_event(
            "dispatch.turn.started",
            params
                .get("sessionId")
                .or_else(|| params.get("nativeSessionId"))
                .and_then(|v| v.as_str())
                .unwrap_or(""),
            "",
            serde_json::json!({
                "agentId": params.get("agent").or_else(|| params.get("agentId")).cloned().unwrap_or(serde_json::json!("")),
                "streamTransport": "stdio_ndjson_on_send"
            }),
        );
        let result = match crate::platform::dispatch_lane_operation(operation, &params) {
            Ok(result) => result,
            Err(error) => agent_conversation_failure(&error),
        };
        let mut done = result;
        if let Some(object) = done.as_object_mut() {
            object.insert("event".to_string(), serde_json::json!("done"));
        }
        write_stdout_json_line(&done)?;
        return Ok(CliExecution::Streamed);
    }

    if operation == "send" {
        if let Err(error) = crate::platform::enforce_send_readiness(&params) {
            return Ok(CliExecution::Json(agent_conversation_failure(&error)));
        }
    }

    Ok(CliExecution::Json(
        match crate::platform::dispatch_lane_operation(operation, &params) {
            Ok(result) => result,
            Err(error) => agent_conversation_failure(&error),
        },
    ))
}

fn agent_conversation_failure(error: &anyhow::Error) -> Value {
    let message = error.to_string();
    let code = if message.contains("send_not_ready") {
        "agent_conversation_send_not_ready"
    } else if message.contains("runtime profile is unavailable") {
        "native_agent_runtime_profile_unavailable"
    } else if message.contains("requires an agent identifier") {
        "agent_identifier_missing"
    } else if message.contains("requires message text") {
        "agent_message_missing"
    } else if message.contains("exceeds the input limit") {
        "agent_message_input_limit"
    } else if message.contains("unsupported runtime adapter") {
        "agent_runtime_unsupported"
    } else if message.contains("evidence binding is unavailable") {
        "native_agent_runtime_evidence_unavailable"
    } else {
        "agent_conversation_dispatch_failed"
    };
    serde_json::json!({
        "ok": false,
        "error": {
            "code": code,
            "stage": "conversation/dispatch",
            "message": "The native conversation request failed closed."
        }
    })
}

fn stream_events_enabled(params: &Value) -> bool {
    params
        .get("streamEvents")
        .or_else(|| params.get("stream-events"))
        .and_then(|value| {
            value.as_bool().or_else(|| match value.as_str()?.trim() {
                "true" | "1" | "yes" => Some(true),
                _ => Some(false),
            })
        })
        == Some(true)
}

fn write_stdout_json_line(value: &Value) -> Result<()> {
    use std::io::Write;
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn stdin_json_enabled(params: &Value) -> bool {
    params.get("stdinJson").and_then(|value| {
        value.as_bool().or_else(|| match value.as_str()?.trim() {
            "true" | "1" | "yes" => Some(true),
            _ => Some(false),
        })
    }) == Some(true)
}

fn parse_agent_message_stdin_json(input: &str) -> Result<Value> {
    let request: Value = serde_json::from_str(input)
        .map_err(|_| anyhow!("agent conversation stdin must be valid JSON"))?;
    if !request.is_object() {
        return Err(anyhow!("agent conversation stdin must be a JSON object"));
    }
    Ok(request)
}

fn handle_agents_pair(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "request" => crate::domain::skill_hub::pair_request(&params)?,
        "approve" => crate::domain::skill_hub::pair_approve(&params)?,
        "revoke" => crate::domain::skill_hub::pair_revoke(&params)?,
        "list" => crate::domain::skill_hub::pair_list(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn agent_conversation_request_is_read_from_json_stdin_contract() {
        let control = cli_params(&["--stdin-json".into(), "true".into()]);
        assert!(stdin_json_enabled(&control));

        let parsed = parse_agent_message_stdin_json(
            r#"{"agent":"codex","text":"private prompt","sessionId":"thread-1"}"#,
        )
        .unwrap();
        assert_eq!(parsed["agent"], json!("codex"));
        assert_eq!(parsed["text"], json!("private prompt"));
        assert_eq!(parsed["sessionId"], json!("thread-1"));
    }

    #[test]
    fn agent_conversation_request_rejects_non_object_stdin() {
        assert!(parse_agent_message_stdin_json(r#"["prompt"]"#).is_err());
        assert!(parse_agent_message_stdin_json("not-json").is_err());
    }
}
