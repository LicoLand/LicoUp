//! Cursor Agent ACP conversation driver.
//!
//! Cursor's public headless CLI can stream structured output, but exact resume
//! requires the native chat identifier in `--resume` argv.  That is not an
//! acceptable process boundary for Lico Arc.  The canonical lane is therefore
//! the Cursor Agent ACP server: prompts and native session identifiers travel
//! only in JSON-RPC messages on stdin, while a bounded supervised process is
//! retained per executable/workspace so `session/load` addresses the same ACP
//! server that created the session.
//!
//! There is deliberately no CLI fallback.  Falling back would silently change
//! both the privacy and exact-continuation guarantees of this driver.

use super::acp_driver_runtime::{
    AcpDriverSpec, CapabilityProbe, EffectiveSettings, ProtocolFailure, RunResult, probe_acp,
};
use super::acp_session_transport::{self, AcpSessionDriverSpec, ControlDisposition};
use serde_json::Value;
use std::path::Path;

pub(super) const RUNTIME_PROTOCOL: &str = "cursor-acp-v1-stdio-jsonrpc";
const DRIVER_ID: &str = "cursor-acp";
const ACP_DRIVER: AcpDriverSpec =
    AcpDriverSpec::new(RUNTIME_PROTOCOL, &["acp"]).with_identity(DRIVER_ID, "cursor_acp");
const SESSION_DRIVER: AcpSessionDriverSpec = AcpSessionDriverSpec::new(DRIVER_ID, &["acp"]);

pub(super) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    probe_acp(
        ACP_DRIVER, executable, cwd, timeout_ms, max_stdout, max_stderr,
    )
}

pub(super) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> RunResult {
    let result = acp_session_transport::execute(
        SESSION_DRIVER,
        executable,
        params,
        prompt,
        session_id,
        cwd,
        timeout_ms,
        max_stdout,
        max_stderr,
    );

    let capabilities = CapabilityProbe {
        protocol_version: Some(1),
        load_session: true,
        // Cursor continues exact conversations with ACP `session/load`; it
        // does not advertise the distinct optional `session/resume` method.
        resume_session: false,
        // Cursor ACP must advertise these during a live probe before a release
        // harness may claim scripted persistent-state cleanup.
        close_session: false,
        list_sessions: false,
        delete_session: false,
        additional_directories: false,
        image_prompts: false,
        audio_prompts: false,
        embedded_context: false,
    };
    let effective = EffectiveSettings {
        cwd: result.effective.cwd,
        model: result.effective.model,
        reasoning_effort: result.effective.reasoning_effort,
        sandbox: result.effective.sandbox,
        approval_policy: result.effective.approval_policy,
        ..EffectiveSettings::default()
    };
    let error = result.error.map(translate_failure);

    RunResult {
        ok: result.ok,
        output: result.output,
        events: result.events,
        error,
        session_id: result.session_id,
        thread_id: result.thread_id,
        turn_id: result.turn_id,
        turn_status: result.turn_status,
        effective,
        capabilities,
        status_code: result.status_code,
        stdout_truncated: result.stdout_truncated,
        stderr_truncated: result.stderr_truncated,
        started_at: result.started_at,
        runtime_protocol: RUNTIME_PROTOCOL,
        driver_id: DRIVER_ID,
    }
}

pub(super) fn cancel(session_id: &str) -> ControlDisposition {
    acp_session_transport::cancel(SESSION_DRIVER, session_id)
}

pub(super) fn cleanup_session(session_id: &str) -> ControlDisposition {
    acp_session_transport::cleanup_session(SESSION_DRIVER, session_id)
}

fn translate_failure(failure: acp_session_transport::ProtocolFailure) -> ProtocolFailure {
    let suffix = failure.code.strip_prefix("hermes_").unwrap_or(failure.code);
    ProtocolFailure {
        code: format!("cursor_{suffix}"),
        message: "Cursor ACP could not complete the native conversation request.",
        stage: failure.stage,
        user_interaction_required: failure.user_interaction_required,
        request_method: failure.request_method,
        session_id: failure.session_id.clone(),
        thread_id: failure.session_id,
        turn_id: failure.turn_id,
        turn_status: failure.turn_status,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn canonical_protocol_is_acp_only() {
        assert_eq!(RUNTIME_PROTOCOL, "cursor-acp-v1-stdio-jsonrpc");
        assert_eq!(DRIVER_ID, "cursor-acp");
        assert_eq!(ACP_DRIVER.launch_args, &["acp"]);
    }

    #[test]
    fn persistent_acp_exact_resume_never_places_native_data_in_argv() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let dir = std::env::temp_dir().join(format!("lico-cursor-acp-fake-{stamp}"));
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("fake_cursor_acp.rs");
        let executable = dir.join(format!("fake-cursor-acp{}", std::env::consts::EXE_SUFFIX));
        fs::write(&source, FAKE_CURSOR_ACP_SOURCE).unwrap();
        let status = Command::new("rustc")
            .args(["--edition", "2021"])
            .arg(&source)
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap();
        assert!(status.success());

        let first = execute(
            executable.to_string_lossy().as_ref(),
            &json!({}),
            "private first prompt",
            "",
            Some(dir.as_path()),
            10_000,
            1024 * 1024,
            1024,
        );
        assert!(first.ok, "first Cursor ACP failure: {:?}", first.error);
        assert_eq!(first.session_id, "cursor-native-session");
        assert_eq!(first.output, "first response");

        let second = execute(
            executable.to_string_lossy().as_ref(),
            &json!({}),
            "private follow-up prompt",
            &first.session_id,
            Some(dir.as_path()),
            10_000,
            1024 * 1024,
            1024,
        );
        assert!(second.ok, "resume Cursor ACP failure: {:?}", second.error);
        assert_eq!(second.session_id, first.session_id);
        assert_eq!(second.output, "second response");
        assert_eq!(second.runtime_protocol, RUNTIME_PROTOCOL);
        assert_eq!(second.driver_id, DRIVER_ID);
        assert_eq!(
            // This reclaims only the fixture transport. Cursor exposes no
            // supported persistent-session cleanup operation.
            cleanup_session(&second.session_id),
            ControlDisposition::Accepted
        );
        let _ = fs::remove_dir_all(dir);
    }

    const FAKE_CURSOR_ACP_SOURCE: &str = r#"
use std::io::{self, BufRead};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    assert_eq!(args, vec!["acp"]);
    let stdin = io::stdin();
    let mut turn = 0usize;
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        if line.contains("private first prompt") || line.contains("private follow-up prompt") {
            assert!(line.contains("session/prompt"));
        }
        if line.contains("\"method\":\"initialize\"") {
            println!("{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true}},\"authMethods\":[]}}}}");
        } else if line.contains("\"method\":\"session/new\"") {
            println!("{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{{\"sessionId\":\"cursor-native-session\"}}}}");
        } else if line.contains("\"method\":\"session/load\"") {
            assert!(line.contains("cursor-native-session"));
            println!("{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}}");
        } else if line.contains("\"method\":\"session/prompt\"") {
            turn += 1;
            let (chunk, response) = if turn == 1 {
                ("first response", "first response")
            } else {
                ("second response", "second response")
            };
            println!("{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"cursor-native-session\",\"update\":{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"text\",\"text\":\"{}\"}}}}}}}}", chunk);
            println!("{{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{{\"stopReason\":\"end_turn\",\"response\":\"{}\"}}}}", response);
        }
    }
}
"#;
}
