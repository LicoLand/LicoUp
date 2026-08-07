use super::errors::ProtocolFailure;
use super::model::{EffectiveSettings, RunResult};
use crate::domain::lico_agent::AgentProfileKind;
use crate::platform::file_security::{append_private_line, ensure_private_dir};
use crate::platform::paths::portable_data_dir;
use crate::platform::process_sandbox::lico_agent_plan_command;
use crate::platform::process_supervisor::SupervisedChild;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

pub(in crate::platform) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    _max_stdout: Option<usize>,
    _max_stderr: usize,
) -> RunResult {
    let started_at = timestamp();
    let workspace = cwd
        .map(Path::to_path_buf)
        .or_else(|| {
            params
                .get("cwd")
                .or_else(|| params.get("workingDirectory"))
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .filter(|p| p.is_absolute());
    let Some(workspace) = workspace else {
        return RunResult::failed(
            ProtocolFailure::new(
                "lico_agent_absolute_cwd_required",
                "Lico Agent requires an absolute workspace directory.",
                "params/cwd",
            ),
            started_at,
        );
    };
    let model = params
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if model.is_empty() {
        return RunResult::failed(
            ProtocolFailure::new(
                "lico_agent_model_required",
                "Lico Agent requires a Gateway model id.",
                "params/model",
            ),
            started_at,
        );
    }
    let profile = params
        .get("profile")
        .or_else(|| params.get("licoProfile"))
        .and_then(Value::as_str)
        .and_then(AgentProfileKind::parse)
        .unwrap_or(AgentProfileKind::Base);
    let gateway_port = params
        .get("gatewayPort")
        .and_then(Value::as_u64)
        .unwrap_or(15_722) as u16;
    let gateway_base_url = format!("http://127.0.0.1:{gateway_port}");
    let plan_path = resolve_plan_path(params);

    let mut child = match spawn_agent(
        executable,
        profile,
        &gateway_base_url,
        &model,
        &workspace,
        plan_path.as_deref(),
        gateway_port,
    ) {
        Ok(child) => child,
        Err(failure) => return RunResult::failed(failure, started_at),
    };

    let Some(mut stdin) = child.stdin() else {
        let _ = child.terminate_tree();
        return RunResult::failed(
            ProtocolFailure::new(
                "lico_agent_rpc_start_failed",
                "Lico Agent stdin is unavailable.",
                "process/start",
            ),
            started_at,
        );
    };
    let Some(stdout) = child.stdout() else {
        let _ = child.terminate_tree();
        return RunResult::failed(
            ProtocolFailure::new(
                "lico_agent_rpc_start_failed",
                "Lico Agent stdout is unavailable.",
                "process/start",
            ),
            started_at,
        );
    };

    let mut reader = BufReader::new(stdout);
    if write_line(&mut stdin, &json!({"id":"lico-1","type":"get_state"})).is_err() {
        let _ = child.terminate_tree();
        return RunResult::failed(
            ProtocolFailure::new(
                "lico_agent_rpc_write_failed",
                "Lico Agent stopped accepting protocol messages.",
                "protocol/write",
            ),
            started_at,
        );
    }
    let _ = read_until(&mut reader, |v| {
        v.get("type").and_then(Value::as_str) == Some("response")
    });

    if write_line(
        &mut stdin,
        &json!({"id":"lico-2","type":"prompt","message":prompt}),
    )
    .is_err()
    {
        let _ = child.terminate_tree();
        return RunResult::failed(
            ProtocolFailure::new(
                "lico_agent_rpc_write_failed",
                "Lico Agent stopped accepting prompt.",
                "protocol/write",
            ),
            started_at,
        );
    }

    let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1_000));
    let mut output = String::new();
    let mut events = Vec::new();
    loop {
        if Instant::now() > deadline {
            let _ = child.terminate_tree();
            return RunResult::failed(
                ProtocolFailure::new(
                    "lico_agent_timeout",
                    "Lico Agent turn timed out.",
                    "protocol/timeout",
                ),
                started_at,
            );
        }
        let Some(event) = read_line_value(&mut reader) else {
            break;
        };
        events.push(event.clone());
        if let Some(delta) = event
            .pointer("/assistantMessageEvent/delta")
            .and_then(Value::as_str)
        {
            output.push_str(delta);
        }
        if event.get("type").and_then(Value::as_str) == Some("agent_end") {
            break;
        }
        if event.get("type").and_then(Value::as_str) == Some("error") {
            let _ = child.terminate_tree();
            return RunResult::failed(
                ProtocolFailure::new(
                    "lico_agent_turn_failed",
                    "Lico Agent reported an error.",
                    "protocol/error",
                ),
                started_at,
            );
        }
    }
    let _ = child.terminate_tree();
    let sid = if session_id.trim().is_empty() {
        format!("lico-agent-{}", started_at)
    } else {
        session_id.to_string()
    };
    append_parent_transcript(&sid, prompt, &output, &workspace);
    RunResult {
        ok: true,
        output,
        events,
        error: None,
        session_id: sid.clone(),
        thread_id: sid,
        turn_id: format!("turn-{}", started_at),
        turn_status: "completed".into(),
        effective: EffectiveSettings {
            cwd: Some(workspace.to_string_lossy().into_owned()),
            model: Some(model),
            permission_mode: Some(profile.as_str().into()),
            ..EffectiveSettings::default()
        },
        status_code: Some(0),
        stdout_truncated: false,
        stderr_truncated: false,
        started_at,
    }
}

fn spawn_agent(
    executable: &str,
    profile: AgentProfileKind,
    gateway_base_url: &str,
    model: &str,
    workspace: &Path,
    plan_path: Option<&Path>,
    gateway_port: u16,
) -> Result<SupervisedChild, ProtocolFailure> {
    let exe = PathBuf::from(executable);
    let mut args = vec![
        "--mode".into(),
        "rpc".into(),
        "--profile".into(),
        profile.as_str().into(),
        "--gateway-base-url".into(),
        gateway_base_url.into(),
        "--model".into(),
        model.into(),
        "--workspace".into(),
        workspace.to_string_lossy().into_owned(),
    ];
    if let Some(plan) = plan_path {
        args.push("--plan-path".into());
        args.push(plan.to_string_lossy().into_owned());
    }

    let mut command = if profile == AgentProfileKind::Plan {
        let plan = plan_path.ok_or_else(|| {
            ProtocolFailure::new(
                "lico_agent_plan_path_required",
                "Plan profile requires an absolute plan path.",
                "params/planPath",
            )
        })?;
        lico_agent_plan_command(&exe, plan, workspace, gateway_port, &args).map_err(|_| {
            ProtocolFailure::new(
                "lico_agent_plan_reliable_sandbox_unavailable",
                "Plan mode requires a reliable OS sandbox on this platform.",
                "sandbox/unavailable",
            )
        })?
    } else {
        let mut command = Command::new(&exe);
        command.args(&args);
        command
    };
    command
        .current_dir(workspace)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    SupervisedChild::spawn(&mut command).map_err(|_| {
        ProtocolFailure::new(
            "lico_agent_rpc_start_failed",
            "Lico Agent process could not be started.",
            "process/start",
        )
    })
}

fn resolve_plan_path(params: &Value) -> Option<PathBuf> {
    if let Some(path) = params
        .get("planPath")
        .or_else(|| params.get("plan_path"))
        .and_then(Value::as_str)
    {
        let path = PathBuf::from(path);
        if path.is_absolute() {
            return Some(path);
        }
    }
    portable_data_dir().ok().map(|root| {
        let dir = root.join("client-state").join("plans");
        let _ = std::fs::create_dir_all(&dir);
        let plan = dir.join("active-plan.md");
        if !plan.exists() {
            let _ = std::fs::write(&plan, b"");
        }
        plan
    })
}

fn write_line(stdin: &mut impl Write, value: &Value) -> std::io::Result<()> {
    let mut line = serde_json::to_string(value)?;
    line.push('\n');
    stdin.write_all(line.as_bytes())?;
    stdin.flush()
}

fn read_line_value(reader: &mut impl BufRead) -> Option<Value> {
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    if line.trim().is_empty() {
        return None;
    }
    serde_json::from_str(line.trim()).ok()
}

fn read_until(reader: &mut impl BufRead, pred: impl Fn(&Value) -> bool) -> Option<Value> {
    for _ in 0..32 {
        let value = read_line_value(reader)?;
        if pred(&value) {
            return Some(value);
        }
    }
    None
}

fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis().to_string())
        .unwrap_or_else(|_| "0".into())
}

fn append_parent_transcript(session_id: &str, prompt: &str, output: &str, workspace: &Path) {
    let Ok(portable) = portable_data_dir() else {
        return;
    };
    let sessions_dir = portable
        .join("client-state")
        .join("lico-agent")
        .join("sessions");
    if ensure_private_dir(&sessions_dir).is_err() {
        return;
    }
    let path = sessions_dir.join(format!("{session_id}.jsonl"));
    let is_new = !path.is_file();
    let timestamp = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string());
    if is_new {
        let header = json!({
            "type": "session",
            "id": session_id,
            "cwd": workspace.to_string_lossy(),
            "timestamp": timestamp,
        });
        if append_private_line(&path, &header.to_string()).is_err() {
            return;
        }
    }
    let user_line = json!({
        "type": "message",
        "role": "user",
        "text": prompt,
        "timestamp": timestamp,
    });
    let assistant_line = json!({
        "type": "message",
        "role": "assistant",
        "text": output,
        "timestamp": timestamp,
    });
    let _ = append_private_line(&path, &user_line.to_string());
    let _ = append_private_line(&path, &assistant_line.to_string());
}
