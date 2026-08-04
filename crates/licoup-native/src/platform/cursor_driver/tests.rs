use super::super::cursor_driver::{self, ControlDisposition, DRIVER_ID, RUNTIME_PROTOCOL};
use serde_json::json;
use std::fs;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn cli_exact_resume_places_session_and_prompt_in_argv() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let dir = std::env::temp_dir().join(format!("lico-cursor-cli-fake-{stamp}"));
    fs::create_dir_all(&dir).unwrap();
    let source = dir.join("fake_cursor_agent.rs");
    let executable = dir.join(format!("fake-cursor-agent{}", std::env::consts::EXE_SUFFIX));
    fs::write(
        &source,
        include_str!("../../../tests/fixtures/fake_cursor_agent.rs"),
    )
    .unwrap();
    let status = Command::new("rustc")
        .args(["--edition", "2021"])
        .arg(&source)
        .arg("-o")
        .arg(&executable)
        .status()
        .unwrap();
    assert!(status.success());

    let captured = Arc::new(Mutex::new(Vec::new()));
    let sink_target = Arc::clone(&captured);
    super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _guard = super::super::turn_event_emit::StreamSinkGuard;

    let first = cursor_driver::execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "private first prompt",
        "",
        Some(dir.as_path()),
        10_000,
        1024 * 1024,
        1024,
    );
    assert!(first.ok, "first Cursor CLI failure: {:?}", first.error);
    assert!(!first.session_id.is_empty());
    assert_eq!(first.output, "first response");

    let second = cursor_driver::execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "private follow-up prompt",
        &first.session_id,
        Some(dir.as_path()),
        10_000,
        1024 * 1024,
        1024,
    );
    assert!(second.ok, "resume Cursor CLI failure: {:?}", second.error);
    assert_eq!(second.session_id, first.session_id);
    assert_eq!(second.output, "second response");
    let events = captured.lock().unwrap().clone();
    assert!(events.iter().any(|event| {
        event["event"] == "agent.turn.accepted"
            && event["sessionId"].as_str() == Some(first.session_id.as_str())
    }));
    assert_eq!(RUNTIME_PROTOCOL, "cursor-agent-cli-v1");
    assert_eq!(DRIVER_ID, "cursor-cli");
    assert_eq!(
        cursor_driver::cleanup_session(&second.session_id),
        ControlDisposition::NotPersisted
    );
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn canonical_protocol_is_cli_only() {
    assert_eq!(cursor_driver::RUNTIME_PROTOCOL, "cursor-agent-cli-v1");
    assert_eq!(cursor_driver::DRIVER_ID, "cursor-cli");
}
