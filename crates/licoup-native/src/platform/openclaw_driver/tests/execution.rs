use super::*;

#[test]
fn fake_child_streams_redacted_events_and_drains_stderr() {
    let (directory, executable) = compile_fake_openclaw("lico-openclaw-execution");
    let result = execute(
        executable.to_string_lossy().as_ref(),
        &json!({
            "reasoningEffort": "medium",
            "gatewayWsUrl": "ws://127.0.0.1:9"
        }),
        "private-openclaw-prompt",
        "",
        Some(directory.as_path()),
        10_000,
        Some(128 * 1024),
        8 * 1024,
    );
    assert!(result.ok, "OpenClaw fake failure: {:?}", result.error);
    assert_eq!(result.output, "native answer");
    assert_eq!(result.session_id, "agent:main:acp:native-session");
    assert_eq!(result.turn_status, "end_turn");
    assert_eq!(result.events.len(), 2);
    assert!(
        result
            .events
            .iter()
            .all(|event| event.get("_meta").is_none())
    );
    assert!(result.events.iter().all(|event| {
        event.pointer("/content/text").and_then(Value::as_str) != Some("must-not-project")
    }));
    assert!(result.stderr_truncated);
    let _ = fs::remove_dir_all(directory);
}

#[test]
fn active_gateway_session_accepts_acp_cancel_before_exact_resume() {
    let (directory, executable) =
        compile_fake_openclaw_source("lico-openclaw-cancel", FAKE_OPENCLAW_CANCEL_SOURCE);
    let (bound_sender, bound_receiver) = mpsc::sync_channel(1);
    let run_directory = directory.clone();
    let run_executable = executable.clone();
    let run = std::thread::spawn(move || {
        crate::platform::turn_event_emit::install_stream_sink(Box::new(move |event| {
            if event.get("event").and_then(Value::as_str) == Some("dispatch.turn.bound") {
                let _ = bound_sender.try_send(());
            }
        }));
        let _sink = crate::platform::turn_event_emit::StreamSinkGuard;
        execute(
            run_executable.to_string_lossy().as_ref(),
            &json!({"gatewayWsUrl": "ws://127.0.0.1:9"}),
            "cancel active gateway turn",
            "",
            Some(run_directory.as_path()),
            30_000,
            Some(128 * 1024),
            8 * 1024,
        )
    });
    bound_receiver
        .recv_timeout(std::time::Duration::from_secs(15))
        .unwrap();
    assert_eq!(
        super::super::cancel("agent:main:acp:cancel-session"),
        crate::platform::acp_driver_runtime::ControlDisposition::Accepted,
    );
    let result = run.join().unwrap();
    assert!(!result.ok);
    assert_eq!(result.session_id, "agent:main:acp:cancel-session");
    assert_eq!(result.turn_status, "cancelled");
    let _ = fs::remove_dir_all(directory);
}

const FAKE_OPENCLAW_CANCEL_SOURCE: &str = r###"
use std::io::{self, BufRead, Write};

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    assert_eq!(args, ["acp", "--url", "ws://127.0.0.1:9"]);
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();

    let initialize = lines.next().unwrap().unwrap();
    assert!(initialize.contains("\"method\":\"initialize\""));
    println!(r#"{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":1,"agentCapabilities":{{"loadSession":true}},"agentInfo":{{"name":"openclaw-acp","version":"test"}}}}}}"#);
    io::stdout().flush().unwrap();

    let session = lines.next().unwrap().unwrap();
    assert!(session.contains("\"method\":\"session/new\""));
    println!(r#"{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"protocol-cancel-session","update":{{"sessionUpdate":"session_info_update","_meta":{{"sessionKey":"agent:main:acp:cancel-session"}}}}}}}}"#);
    println!(r#"{{"jsonrpc":"2.0","id":2,"result":{{"sessionId":"protocol-cancel-session"}}}}"#);
    io::stdout().flush().unwrap();

    let prompt = lines.next().unwrap().unwrap();
    assert!(prompt.contains("\"method\":\"session/prompt\""));
    assert!(prompt.contains("\"sessionId\":\"protocol-cancel-session\""));
    let cancel = lines.next().unwrap().unwrap();
    assert!(cancel.contains("\"method\":\"session/cancel\""));
    assert!(cancel.contains("\"sessionId\":\"protocol-cancel-session\""));
    println!(r#"{{"jsonrpc":"2.0","id":4,"result":{{"stopReason":"cancelled"}}}}"#);
    io::stdout().flush().unwrap();
}
"###;

#[test]
fn fresh_session_stream_events_always_carry_bound_identity() {
    let (directory, executable) = compile_fake_openclaw("lico-openclaw-stream-identity");
    let captured = Arc::new(std::sync::Mutex::new(Vec::<Value>::new()));
    let sink_target = Arc::clone(&captured);
    crate::platform::turn_event_emit::install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _sink = crate::platform::turn_event_emit::StreamSinkGuard;
    let result = execute(
        executable.to_string_lossy().as_ref(),
        &json!({
            "reasoningEffort": "medium",
            "gatewayWsUrl": "ws://127.0.0.1:9"
        }),
        "private-openclaw-prompt",
        "",
        Some(directory.as_path()),
        10_000,
        Some(128 * 1024),
        8 * 1024,
    );
    assert!(result.ok, "OpenClaw fake failure: {:?}", result.error);
    let events = captured.lock().unwrap().clone();
    assert!(!events.is_empty());
    // The stdio RPC conversation server drops the whole turn to
    // `stream_protocol_failed` when any single event lacks a non-empty
    // sessionId, turnId, or event kind. Every driver emission must stay
    // writable, including before the native session identity is known.
    for event in &events {
        let session_id = event
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let turn_id = event
            .get("turnId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let kind = event
            .get("event")
            .and_then(Value::as_str)
            .unwrap_or_default();
        assert!(!session_id.is_empty(), "event missing sessionId: {event}");
        assert!(!turn_id.is_empty(), "event missing turnId: {event}");
        assert!(!kind.is_empty(), "event missing kind: {event}");
    }
    let _ = fs::remove_dir_all(directory);
}
