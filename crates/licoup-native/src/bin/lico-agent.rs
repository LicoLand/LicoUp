//! Lico-owned agent process: stdio JSONL RPC, Gateway models, base|plan profiles.

use licoup_native::domain::lico_agent::{
    Agent, AgentConfig, AgentEvent, AgentProfileKind, GatewayChatTransport, LlmTransport,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::{env, process::ExitCode};

fn main() -> ExitCode {
    match run(env::args().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(code) => {
            let _ = writeln!(std::io::stderr(), "{}", json!({"type":"error","code":code}));
            ExitCode::FAILURE
        }
    }
}

struct Args {
    profile: AgentProfileKind,
    gateway_base_url: String,
    model: String,
    workspace: PathBuf,
    plan_path: Option<PathBuf>,
}

fn run(raw: Vec<String>) -> Result<(), &'static str> {
    if raw.iter().any(|a| a == "--help" || a == "-h") {
        println!(
            "lico-agent --mode rpc --profile base|plan --gateway-base-url http://127.0.0.1:PORT --model ID --workspace ABS [--plan-path ABS]"
        );
        return Ok(());
    }
    let args = parse_args(&raw)?;
    let transport = GatewayChatTransport::from_base_url(&args.gateway_base_url)
        .map_err(|_| "gateway_base_url_must_be_loopback")?;
    let transport: Arc<dyn LlmTransport> = Arc::new(transport);
    let agent = Agent::new(
        AgentConfig {
            profile: args.profile,
            model: args.model,
            workspace: args.workspace,
            plan_path: args.plan_path,
        },
        transport,
    )
    .map_err(|_| "agent_config_invalid")?;
    let agent = Arc::new(Mutex::new(agent));
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let reader = BufReader::new(stdin.lock());
    for line in reader.lines() {
        let line = line.map_err(|_| "stdin_read_failed")?;
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = serde_json::from_str(&line).map_err(|_| "rpc_request_invalid")?;
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let req_type = request.get("type").and_then(Value::as_str).unwrap_or("");
        match req_type {
            "get_state" => {
                let profile = agent.lock().unwrap().profile().as_str();
                write_json(
                    &mut stdout,
                    &json!({
                        "id": id,
                        "type": "response",
                        "success": true,
                        "data": {
                            "isRunning": false,
                            "profile": profile,
                        }
                    }),
                )?;
            }
            "prompt" => {
                let message = request
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                write_json(
                    &mut stdout,
                    &json!({"id": id, "type": "response", "success": true}),
                )?;
                let agent = Arc::clone(&agent);
                let mut out = std::io::stdout();
                let result = {
                    let mut guard = agent.lock().unwrap();
                    guard.prompt(&message, |event| {
                        let _ = emit_event(&mut out, &event);
                    })
                };
                if let Err(err) = result {
                    write_json(
                        &mut stdout,
                        &json!({"type":"error","code":"prompt_failed","message":err}),
                    )?;
                }
            }
            "abort" => {
                agent.lock().unwrap().abort();
                write_json(
                    &mut stdout,
                    &json!({"id": id, "type": "response", "success": true}),
                )?;
            }
            "steer" => {
                // v1: treat steer as a follow-up prompt when idle.
                let message = request
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                write_json(
                    &mut stdout,
                    &json!({"id": id, "type": "response", "success": true}),
                )?;
                let mut out = std::io::stdout();
                let mut guard = agent.lock().unwrap();
                let _ = guard.prompt(&message, |event| {
                    let _ = emit_event(&mut out, &event);
                });
            }
            _ => {
                write_json(
                    &mut stdout,
                    &json!({
                        "id": id,
                        "type": "response",
                        "success": false,
                        "error": "unsupported_request"
                    }),
                )?;
            }
        }
    }
    Ok(())
}

fn emit_event(out: &mut impl Write, event: &AgentEvent) -> Result<(), &'static str> {
    let value = match event {
        AgentEvent::AgentStart => json!({"type":"agent_start"}),
        AgentEvent::AgentEnd => json!({"type":"agent_end"}),
        AgentEvent::TurnStart => json!({"type":"turn_start"}),
        AgentEvent::TurnEnd => json!({"type":"turn_end"}),
        AgentEvent::MessageUpdate { role, delta } if role == "assistant" => json!({
            "type": "message_update",
            "assistantMessageEvent": { "type": "text_delta", "delta": delta }
        }),
        AgentEvent::MessageEnd { role, content } if role == "assistant" => json!({
            "type": "message_end",
            "message": { "role": "assistant", "content": content }
        }),
        AgentEvent::ToolExecutionStart { name, call_id } => json!({
            "type": "tool_execution_start",
            "toolName": name,
            "toolCallId": call_id
        }),
        AgentEvent::ToolExecutionEnd {
            name,
            call_id,
            ok,
            output,
        } => json!({
            "type": "tool_execution_end",
            "toolName": name,
            "toolCallId": call_id,
            "ok": ok,
            "output": output
        }),
        AgentEvent::Error { code, message } => {
            json!({"type":"error","code":code,"message":message})
        }
        _ => return Ok(()),
    };
    write_json(out, &value)
}

fn write_json(out: &mut impl Write, value: &Value) -> Result<(), &'static str> {
    let mut line = serde_json::to_string(value).map_err(|_| "json_encode_failed")?;
    line.push('\n');
    out.write_all(line.as_bytes())
        .map_err(|_| "stdout_write_failed")?;
    out.flush().map_err(|_| "stdout_flush_failed")?;
    Ok(())
}

fn parse_args(raw: &[String]) -> Result<Args, &'static str> {
    let mut profile = AgentProfileKind::Base;
    let mut gateway_base_url = "http://127.0.0.1:15722".to_string();
    let mut model = String::new();
    let mut workspace = env::current_dir().map_err(|_| "workspace_invalid")?;
    let mut plan_path = None;
    let mut i = 0;
    while i < raw.len() {
        match raw[i].as_str() {
            "--mode" => {
                i += 1;
                // rpc is the only supported mode
            }
            "--profile" => {
                i += 1;
                profile = AgentProfileKind::parse(raw.get(i).map(String::as_str).unwrap_or(""))
                    .ok_or("profile_invalid")?;
            }
            "--gateway-base-url" => {
                i += 1;
                gateway_base_url = raw.get(i).cloned().ok_or("gateway_base_url_missing")?;
            }
            "--model" => {
                i += 1;
                model = raw.get(i).cloned().ok_or("model_missing")?;
            }
            "--workspace" => {
                i += 1;
                workspace = PathBuf::from(raw.get(i).ok_or("workspace_missing")?);
            }
            "--plan-path" => {
                i += 1;
                plan_path = Some(PathBuf::from(raw.get(i).ok_or("plan_path_missing")?));
            }
            _ => {}
        }
        i += 1;
    }
    if model.trim().is_empty() {
        return Err("model_required");
    }
    if !workspace.is_absolute() {
        return Err("workspace_must_be_absolute");
    }
    if profile == AgentProfileKind::Plan {
        let path = plan_path.ok_or("plan_path_required")?;
        if !path.is_absolute() {
            return Err("plan_path_must_be_absolute");
        }
        plan_path = Some(path);
    }
    Ok(Args {
        profile,
        gateway_base_url,
        model,
        workspace,
        plan_path,
    })
}
