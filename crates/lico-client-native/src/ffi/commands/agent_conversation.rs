use super::{CliExecution, CommandTable, cli_params};
use anyhow::{Result, anyhow};
use serde_json::Value;
use std::io::Read;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["agent", "conversation"],
        handle_agent_conversation,
        "Agent conversation open|send|steer|cancel|capabilities|stream",
    );
    table.register_rest(
        &["agents", "pair"],
        handle_agents_pair,
        "Agent pair request|approve|revoke|list",
    );
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
        control.clone()
    };
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
                .and_then(Value::as_str)
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
        observe_skill_invocations(&params, &result);
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

    let result = match crate::platform::dispatch_lane_operation(operation, &params) {
        Ok(result) => result,
        Err(error) => agent_conversation_failure(&error),
    };
    if operation == "send" {
        observe_skill_invocations(&params, &result);
    }
    Ok(CliExecution::Json(result))
}

fn observe_skill_invocations(params: &Value, result: &Value) {
    let Some(agent_id) = params
        .get("agent")
        .or_else(|| params.get("agentId"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return;
    };
    // Metering is observational and local-only. A damaged ledger or revoked
    // pairing must never change the outcome of the user's conversation.
    let _ = crate::domain::skill_hub::observe_agent_skill_invocations(agent_id, result);
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
    use crate::platform::client_state::ClientStateStore;
    use serde_json::json;
    use std::fs;
    use uuid::Uuid;

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

    #[test]
    fn successful_runtime_skill_event_is_aggregated_through_the_send_observer() {
        let root =
            std::env::temp_dir().join(format!("lico-agent-skill-observer-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root));
        let store = ClientStateStore::portable().unwrap();
        crate::domain::skill_hub::pair_request(&json!({"agent": "codex"})).unwrap();
        crate::domain::skill_hub::pair_approve(&json!({"agent": "codex"})).unwrap();
        let mut skills = store.read_collection("skills").unwrap();
        skills["items"].as_array_mut().unwrap().push(json!({
            "kind": "skill",
            "agentId": "codex",
            "skillId": "review-helper",
            "installer": "github-skill-installer"
        }));
        store.write_collection("skills", skills).unwrap();

        observe_skill_invocations(
            &json!({"agent": "codex"}),
            &json!({
                "ok": true,
                "events": [{"event": "skill.invoked", "skillId": "review-helper"}],
                "output": "must not enter usage storage"
            }),
        );
        let report = crate::domain::skill_hub::skill_usage_report(&json!({"days": 1})).unwrap();
        assert_eq!(report["totalInvocations"], 1);
        assert!(
            !store
                .read_collection("skill-usage")
                .unwrap()
                .to_string()
                .contains("must not enter usage storage")
        );
        crate::platform::paths::set_portable_data_dir_override(previous);
    }
}
