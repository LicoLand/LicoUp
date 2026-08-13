use super::super::cursor_driver::{self, ControlDisposition, DRIVER_ID, RUNTIME_PROTOCOL};
use serde_json::json;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[test]
fn cli_exact_resume_places_session_and_prompt_in_argv() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (dir, executable) = compile_fake_cursor(stamp);

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
        Some(1024 * 1024),
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
        Some(1024 * 1024),
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
    // The NDJSON stream arrives through the pty transport (unix): the raw-mode
    // slave keeps `\n`-only line endings, so the parsed chunks must surface
    // the assistant text intact.
    assert!(events.iter().any(|event| {
        event["event"] == "agent.message.chunk"
            && event["payload"]["text"]
                .as_str()
                .is_some_and(|text| text.contains("first response"))
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

/// Builds a fake cursor-agent executable in a fresh temp dir (shared helper).
fn compile_fake_cursor(stamp: u128) -> (PathBuf, PathBuf) {
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
    (dir, executable)
}

#[cfg(unix)]
#[test]
fn auto_update_lock_and_staging_are_surfaced_as_runtime_events() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (dir, executable) = compile_fake_cursor(stamp);

    // Isolate the watcher's install root and hold the turn open.
    let install_root = std::env::temp_dir().join(format!("lico-cursor-install-fake-{stamp}"));
    fs::create_dir_all(install_root.join("versions")).unwrap();
    // Safe in the single-threaded test body; restored before the assertions.
    unsafe {
        std::env::set_var("LICO_CURSOR_AGENT_INSTALL_DIR", &install_root);
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_UPDATE_DELAY_MS", "5000");
    }

    let captured = Arc::new(Mutex::new(Vec::new()));
    let sink_target = Arc::clone(&captured);
    super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _guard = super::super::turn_event_emit::StreamSinkGuard;

    // The stream sink is thread-local: `execute` must run on this thread.
    // Drive the lock/staging timeline from a helper thread instead.
    let timeline_root = install_root.clone();
    let timeline = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(400));
        fs::write(timeline_root.join(".install.lock"), b"").unwrap();
        std::thread::sleep(Duration::from_millis(1400));
        fs::create_dir_all(timeline_root.join("versions").join(".2026.08.04-aaa8809")).unwrap();
        std::thread::sleep(Duration::from_millis(1600));
        fs::remove_file(timeline_root.join(".install.lock")).unwrap();
        fs::remove_dir_all(timeline_root.join("versions").join(".2026.08.04-aaa8809")).unwrap();
    });

    let result = cursor_driver::execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "private first prompt",
        "",
        Some(dir.as_path()),
        10_000,
        Some(1024 * 1024),
        1024,
    );
    timeline.join().unwrap();
    unsafe {
        std::env::remove_var("LICO_CURSOR_AGENT_INSTALL_DIR");
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_UPDATE_DELAY_MS");
    }
    let _ = fs::remove_dir_all(install_root);
    let _ = fs::remove_dir_all(dir);

    assert!(result.ok, "turn failed: {:?}", result.error);
    assert_eq!(result.output, "first response");
    let events = captured.lock().unwrap().clone();
    let updating = events.iter().filter(|event| {
        event["event"] == "agent.runtime.updating" && event["payload"]["artifact"] == "cursor-agent"
    });
    let updating: Vec<_> = updating.collect();
    assert!(
        !updating.is_empty(),
        "expected runtime updating events: {events:?}"
    );
    assert!(
        updating.iter().any(|event| {
            event["payload"]["phase"] == "downloading" || event["payload"]["phase"] == "installing"
        }),
        "expected a download/install phase: {events:?}"
    );
    let completed = events.iter().any(|event| {
        event["event"] == "agent.runtime.update.completed"
            && event["payload"]["version"] == "2026.08.04-aaa8809"
    });
    assert!(completed, "expected update completion event: {events:?}");
}
