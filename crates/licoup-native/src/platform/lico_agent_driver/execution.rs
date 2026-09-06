use super::errors::ProtocolFailure;
use super::model::{EffectiveSettings, RunResult};
use crate::domain::lico_agent::{Agent, AgentProfileKind};
use crate::platform::agent_workspace::{
    default_local_agent_workspace, resolve_local_agent_workspace,
};
use crate::platform::file_security::ensure_private_dir;
use crate::platform::native_agent_parser::adapters::NativeLineParser;
use crate::platform::native_agent_parser::adapters::lico_agent::{
    RpcEffect, RpcParser, encode_request,
};
use crate::platform::paths::portable_data_dir;
use crate::platform::process_sandbox::lico_agent_plan_command;
use crate::platform::process_supervisor::{IO_THREAD_EXIT_GRACE, SupervisedChild, join_bounded};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

/// Upper bound for the `get_state` readiness handshake. Lico Agent is expected
/// to answer immediately after start; a hang (auto-update, gateway startup)
/// must fail visibly instead of blocking the send forever.
const HANDSHAKE_BOUND: Duration = Duration::from_secs(5);

pub(in crate::platform) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> RunResult {
    execute_with_handshake_bound(
        executable,
        params,
        prompt,
        session_id,
        cwd,
        timeout_ms,
        max_stdout,
        max_stderr,
        HANDSHAKE_BOUND,
    )
}

#[cfg(test)]
pub(super) fn execute_with_test_handshake_bound(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
    handshake_bound: Duration,
) -> RunResult {
    execute_with_handshake_bound(
        executable,
        params,
        prompt,
        session_id,
        cwd,
        timeout_ms,
        max_stdout,
        max_stderr,
        handshake_bound,
    )
}

fn execute_with_handshake_bound(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
    handshake_bound: Duration,
) -> RunResult {
    let started_at = timestamp();
    if params
        .get("privateInstructions")
        .and_then(Value::as_str)
        .is_some_and(|value| !value.trim().is_empty())
    {
        return RunResult::failed(
            ProtocolFailure::new(
                "lico_agent_private_instructions_unsupported",
                "Lico Agent RPC does not expose a separate private-instruction channel.",
                "params/privateInstructions",
            ),
            started_at,
        );
    }
    let workspace = match resolve_workspace(params, cwd) {
        Ok(workspace) => workspace,
        Err(failure) => return RunResult::failed(failure, started_at),
    };
    let (native_session_id, resume, _transcript_path) = match prepare_session(session_id) {
        Ok(session) => session,
        Err(failure) => {
            let mut result = RunResult::failed(failure, started_at);
            if !session_id.trim().is_empty() {
                if let Some(error) = result.error.as_mut() {
                    error.session_id = Some(session_id.trim().to_string());
                }
                result.session_id = session_id.trim().to_string();
                result.thread_id = result.session_id.clone();
            }
            return result;
        }
    };
    if workspace.as_os_str().is_empty() {
        return failed_for_session(
            ProtocolFailure::new(
                "lico_agent_workspace_rejected",
                "Lico Agent requires a bounded, present project workspace.",
                "params/cwd",
            ),
            started_at,
            &native_session_id,
        );
    }
    let model = params
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if model.is_empty() {
        return failed_for_session(
            ProtocolFailure::new(
                "lico_agent_model_required",
                "Lico Agent requires a Gateway model id.",
                "params/model",
            ),
            started_at,
            &native_session_id,
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
        &native_session_id,
        resume,
    ) {
        Ok(child) => child,
        Err(failure) => return failed_for_session(failure, started_at, &native_session_id),
    };

    let Some(mut stdin) = child.stdin() else {
        let _ = child.terminate_tree();
        return failed_for_session(
            ProtocolFailure::new(
                "lico_agent_rpc_start_failed",
                "Lico Agent stdin is unavailable.",
                "process/start",
            ),
            started_at,
            &native_session_id,
        );
    };
    let Some(stdout) = child.stdout() else {
        let _ = child.terminate_tree();
        return failed_for_session(
            ProtocolFailure::new(
                "lico_agent_rpc_start_failed",
                "Lico Agent stdout is unavailable.",
                "process/start",
            ),
            started_at,
            &native_session_id,
        );
    };
    let Some(stderr) = child.stderr() else {
        let _ = child.terminate_tree();
        return failed_for_session(
            ProtocolFailure::new(
                "lico_agent_rpc_start_failed",
                "Lico Agent stderr is unavailable.",
                "process/start",
            ),
            started_at,
            &native_session_id,
        );
    };
    let mut stderr_handle = Some(thread::spawn(move || {
        drain_nonprojecting_stderr(stderr, max_stderr)
    }));

    let reader = BufReader::new(stdout);
    if write_line(&mut stdin, &json!({"id":"lico-1","type":"get_state"})).is_err() {
        cleanup_process(&mut child, &mut stderr_handle);
        return failed_for_session(
            ProtocolFailure::new(
                "lico_agent_rpc_write_failed",
                "Lico Agent stopped accepting protocol messages.",
                "protocol/write",
            ),
            started_at,
            &native_session_id,
        );
    }
    let (mut reader, observed_session_id) = match handshake(reader, handshake_bound) {
        Ok(handshake) => handshake,
        Err(HandshakeFailure::TimedOut) => {
            cleanup_process(&mut child, &mut stderr_handle);
            return failed_for_session(
                ProtocolFailure::new(
                    "lico_agent_rpc_handshake_timeout",
                    "Lico Agent did not answer the readiness handshake in time.",
                    "protocol/handshake",
                ),
                started_at,
                &native_session_id,
            );
        }
        Err(
            HandshakeFailure::Unavailable | HandshakeFailure::Rejected | HandshakeFailure::Invalid,
        ) => {
            cleanup_process(&mut child, &mut stderr_handle);
            return failed_for_session(
                ProtocolFailure::new(
                    "lico_agent_rpc_handshake_failed",
                    "Lico Agent rejected the readiness handshake.",
                    "protocol/handshake",
                ),
                started_at,
                &native_session_id,
            );
        }
    };
    if observed_session_id.as_deref() != Some(native_session_id.as_str()) {
        cleanup_process(&mut child, &mut stderr_handle);
        return failed_for_session(
            ProtocolFailure::new(
                "lico_agent_session_identity_mismatch",
                "Lico Agent reported a different native session identity.",
                "protocol/handshake",
            ),
            started_at,
            &native_session_id,
        );
    }

    if write_line(
        &mut stdin,
        &json!({"id":"lico-2","type":"prompt","message":prompt}),
    )
    .is_err()
    {
        cleanup_process(&mut child, &mut stderr_handle);
        return failed_for_session(
            ProtocolFailure::new(
                "lico_agent_rpc_write_failed",
                "Lico Agent stopped accepting prompt.",
                "protocol/write",
            ),
            started_at,
            &native_session_id,
        );
    }

    // timeoutMs 0 opts out of any turn deadline (see runtime_adapters/dispatch),
    // so only a non-zero window gets a concrete deadline.
    let deadline = (timeout_ms != 0).then(|| Instant::now() + Duration::from_millis(timeout_ms));
    let mut output = String::new();
    let mut saw_processing = false;
    let mut controls = Vec::new();
    loop {
        if deadline.is_some_and(|deadline| Instant::now() > deadline) {
            cleanup_process(&mut child, &mut stderr_handle);
            return failed_for_session(
                ProtocolFailure::new(
                    "lico_agent_timeout",
                    "Lico Agent turn timed out.",
                    "protocol/timeout",
                ),
                started_at,
                &native_session_id,
            );
        }
        let effect = match read_effect(&mut reader) {
            Ok(Some(effect)) => effect,
            Ok(None) => {
                cleanup_process(&mut child, &mut stderr_handle);
                return failed_for_session(
                    ProtocolFailure::new(
                        "lico_agent_rpc_ended_early",
                        "Lico Agent ended before completing the turn.",
                        "protocol/read",
                    ),
                    started_at,
                    &native_session_id,
                );
            }
            Err(()) => {
                cleanup_process(&mut child, &mut stderr_handle);
                return failed_for_session(
                    ProtocolFailure::new(
                        "lico_agent_rpc_invalid_frame",
                        "Lico Agent returned a malformed protocol line.",
                        "protocol/read",
                    ),
                    started_at,
                    &native_session_id,
                );
            }
        };
        match effect {
            RpcEffect::Text { delta } => {
                if max_stdout.is_some_and(|limit| output.len().saturating_add(delta.len()) > limit)
                {
                    cleanup_process(&mut child, &mut stderr_handle);
                    return failed_for_session(
                        ProtocolFailure::new(
                            "lico_agent_output_limit_exceeded",
                            "Lico Agent output exceeded the caller-requested bound.",
                            "protocol/output",
                        ),
                        started_at,
                        &native_session_id,
                    );
                }
                saw_processing = true;
                output.push_str(&delta);
            }
            RpcEffect::Processing => saw_processing = true,
            RpcEffect::Control { method } => {
                saw_processing = true;
                controls.push(method);
            }
            RpcEffect::Completed => break,
            RpcEffect::Failed { code } => {
                cleanup_process(&mut child, &mut stderr_handle);
                let failure = if code.as_deref() == Some("lico_agent_transcript_persist_failed") {
                    ProtocolFailure::new(
                        "lico_agent_transcript_persist_failed",
                        "Lico Agent could not persist the completed turn.",
                        "session/persist",
                    )
                } else {
                    ProtocolFailure::new(
                        "lico_agent_turn_failed",
                        "Lico Agent reported an error.",
                        "protocol/error",
                    )
                };
                return failed_for_session(failure, started_at, &native_session_id);
            }
            RpcEffect::Ignored => {}
            RpcEffect::Handshake { .. } => {}
        }
    }
    let stderr_truncated = cleanup_process(&mut child, &mut stderr_handle);
    let sid = native_session_id;
    RunResult {
        ok: true,
        transitions:
            crate::platform::native_agent_parser::adapters::lico_agent::success_transitions(
                &output,
                saw_processing,
                &controls,
            ),
        output,
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
        stderr_truncated,
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
    session_id: &str,
    resume: bool,
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
        "--session-id".into(),
        session_id.into(),
    ];
    if resume {
        args.push("--resume".into());
    }
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
        super::super::user_shell_environment::apply_to_command(&mut command);
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

fn resolve_workspace(params: &Value, cwd: Option<&Path>) -> Result<PathBuf, ProtocolFailure> {
    let requested = cwd.map(Path::to_path_buf).or_else(|| {
        params
            .get("cwd")
            .or_else(|| params.get("workingDirectory"))
            .and_then(Value::as_str)
            .map(PathBuf::from)
    });
    let Some(requested) = requested else {
        return Err(workspace_failure());
    };
    let resolved = resolve_local_agent_workspace("lico-agent", Some(&requested))
        .ok_or_else(workspace_failure)?;
    let fallback = default_local_agent_workspace("lico-agent");
    if resolved != requested
        || fallback
            .as_deref()
            .is_some_and(|fallback| resolved.starts_with(fallback))
    {
        return Err(workspace_failure());
    }
    Ok(resolved)
}

fn workspace_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "lico_agent_workspace_rejected",
        "Lico Agent requires a bounded, present project workspace.",
        "params/cwd",
    )
}

fn prepare_session(session_id: &str) -> Result<(String, bool, PathBuf), ProtocolFailure> {
    let sessions_dir = portable_data_dir()
        .map_err(|_| session_store_failure())?
        .join("client-state")
        .join("lico-agent")
        .join("sessions");
    ensure_private_dir(&sessions_dir).map_err(|_| session_store_failure())?;
    if !session_id.trim().is_empty() {
        let session_id = canonical_session_id(session_id)?;
        let path = sessions_dir.join(format!("{session_id}.jsonl"));
        Agent::load_persisted_history(&path, &session_id).map_err(transcript_failure)?;
        return Ok((session_id, true, path));
    }
    for _ in 0..8 {
        let session_id = Uuid::new_v4().to_string();
        let path = sessions_dir.join(format!("{session_id}.jsonl"));
        if !path.exists() {
            return Ok((session_id, false, path));
        }
    }
    Err(ProtocolFailure::new(
        "lico_agent_session_id_unavailable",
        "Lico Agent could not allocate a new native session identity.",
        "session/create",
    ))
}

fn canonical_session_id(session_id: &str) -> Result<String, ProtocolFailure> {
    let trimmed = session_id.trim();
    let canonical = Uuid::parse_str(trimmed)
        .map_err(|_| {
            ProtocolFailure::new(
                "lico_agent_session_id_invalid",
                "Lico Agent requires a valid native session identity.",
                "session/resume",
            )
        })?
        .to_string();
    if canonical != trimmed {
        return Err(ProtocolFailure::new(
            "lico_agent_session_id_invalid",
            "Lico Agent requires a valid native session identity.",
            "session/resume",
        ));
    }
    Ok(canonical)
}

fn transcript_failure(code: &'static str) -> ProtocolFailure {
    match code {
        "lico_agent_transcript_missing" => ProtocolFailure::new(
            "lico_agent_transcript_missing",
            "The requested Lico Agent conversation does not exist.",
            "session/resume",
        ),
        "lico_agent_transcript_identity_mismatch" => ProtocolFailure::new(
            "lico_agent_transcript_identity_mismatch",
            "The persisted Lico Agent conversation has a different native identity.",
            "session/resume",
        ),
        _ => ProtocolFailure::new(
            "lico_agent_transcript_invalid",
            "The persisted Lico Agent conversation is malformed.",
            "session/resume",
        ),
    }
}

fn session_store_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "lico_agent_session_store_unavailable",
        "Lico Agent session storage is unavailable.",
        "session/store",
    )
}

fn failed_for_session(
    mut failure: ProtocolFailure,
    started_at: String,
    session_id: &str,
) -> RunResult {
    failure.session_id = Some(session_id.to_string());
    let mut result = RunResult::failed(failure, started_at);
    result.session_id = session_id.to_string();
    result.thread_id = session_id.to_string();
    result
}

fn write_line(stdin: &mut impl Write, value: &Value) -> std::io::Result<()> {
    let encoded = encode_request(value).map_err(std::io::Error::other)?;
    stdin.write_all(&encoded)?;
    stdin.flush()
}

fn read_effect(reader: &mut impl BufRead) -> Result<Option<RpcEffect>, ()> {
    let mut line = String::new();
    let read = reader.read_line(&mut line).map_err(|_| ())?;
    if read == 0 {
        return Ok(None);
    }
    RpcParser
        .parse_line(line.as_bytes())
        .map(Some)
        .map_err(|_| ())
}

fn read_handshake(reader: &mut impl BufRead) -> Result<Option<(bool, Option<String>)>, ()> {
    for _ in 0..32 {
        let Some(effect) = read_effect(reader)? else {
            return Ok(None);
        };
        if let RpcEffect::Handshake {
            accepted,
            session_id,
        } = effect
        {
            return Ok(Some((accepted, session_id)));
        }
    }
    Ok(None)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HandshakeFailure {
    /// The agent stayed silent past the configured handshake bound.
    TimedOut,
    /// The agent closed the stream before answering.
    Unavailable,
    /// The agent answered without `"success": true`.
    Rejected,
    /// The agent returned a malformed handshake frame.
    Invalid,
}

/// Bounded `get_state` readiness handshake. The agent is expected to answer
/// immediately; a silent or failing start fails the send instead of letting
/// the prompt ride on top of a broken session.
///
/// The read itself happens on a helper thread because a hung agent would
/// otherwise block `BufReader::read_line` forever; the bound is enforced by
/// the caller-side join.
fn handshake<R: Read + Send + 'static>(
    mut reader: BufReader<R>,
    bound: Duration,
) -> Result<(BufReader<R>, Option<String>), HandshakeFailure> {
    let handle = thread::spawn(move || {
        let response = read_handshake(&mut reader);
        (response, reader)
    });
    match join_bounded(handle, bound) {
        Ok((Ok(Some((accepted, session_id))), reader)) => {
            if accepted {
                Ok((reader, session_id))
            } else {
                Err(HandshakeFailure::Rejected)
            }
        }
        Ok((Ok(None), _)) => Err(HandshakeFailure::Unavailable),
        Ok((Err(()), _)) => Err(HandshakeFailure::Invalid),
        Err(_) => Err(HandshakeFailure::TimedOut),
    }
}

fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis().to_string())
        .unwrap_or_else(|_| "0".into())
}

fn drain_nonprojecting_stderr(mut stderr: impl Read, max_bytes: usize) -> bool {
    let mut buffer = [0_u8; 8192];
    let mut total = 0_usize;
    loop {
        match stderr.read(&mut buffer) {
            Ok(0) => return total > max_bytes,
            Ok(read) => total = total.saturating_add(read),
            Err(_) => return total > max_bytes,
        }
    }
}

fn cleanup_process(
    child: &mut SupervisedChild,
    stderr_handle: &mut Option<thread::JoinHandle<bool>>,
) -> bool {
    let _ = child.terminate_tree();
    stderr_handle
        .take()
        .and_then(|handle| join_bounded(handle, IO_THREAD_EXIT_GRACE).ok())
        .unwrap_or(false)
}
