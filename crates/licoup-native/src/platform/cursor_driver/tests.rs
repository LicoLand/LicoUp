use super::super::cursor_driver::{self, ControlDisposition, DRIVER_ID, RUNTIME_PROTOCOL};
use serde_json::json;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The fake agent reads process-global env vars, so the tests that steer it
/// must not run concurrently: one test's env mutation would leak into another
/// test's spawned process and change its behavior.
static ENV_LOCK: Mutex<()> = Mutex::new(());
static FAKE_BUILD_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn env_lock() -> std::sync::MutexGuard<'static, ()> {
    // A panicking test must not poison the lock for every later test.
    ENV_LOCK.lock().unwrap_or_else(|poison| poison.into_inner())
}

fn wait_for_captured_event(
    events: &Arc<Mutex<Vec<serde_json::Value>>>,
    deadline: Instant,
    label: &str,
    predicate: impl Fn(&serde_json::Value) -> bool,
) {
    loop {
        if events.lock().unwrap().iter().any(&predicate) {
            return;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {label}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn cli_exact_resume_places_session_and_prompt_in_argv() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (dir, executable) = compile_fake_cursor(stamp);
    // The fake reads process-global env vars; serialize with the other fake
    // tests so no concurrent test's vars leak into this spawned process.
    let _guard = env_lock();

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
    assert!(matches!(
        first.transitions.last(),
        Some(crate::platform::native_agent_parser::Transition::Lifecycle(
            crate::platform::native_agent_parser::LifecycleStage::Completed
        ))
    ));

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

#[test]
fn pty_controls_are_isolated_before_strict_ndjson_decoding() {
    use super::io::isolate_pty_protocol_line;
    use crate::platform::cursor_driver::model::EffectiveSettings;
    use crate::platform::native_agent_parser::adapters::cursor::{
        CursorParseFailure, CursorParser,
    };

    let isolated = isolate_pty_protocol_line(
        b"\x1b[?25l{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\"}\x1b[0m\r\n",
    );
    let mut parser = CursorParser::new("synthetic-session", EffectiveSettings::default());
    assert!(parser.parse_line(&isolated).is_ok());

    let prose = isolate_pty_protocol_line(b"diagnostic prose\r\n");
    assert!(matches!(
        parser.parse_line(&prose),
        Err(CursorParseFailure::InvalidJson)
    ));
    assert!(
        isolate_pty_protocol_line(b"\x1b[?25l\x1b[0m\r\n")
            .iter()
            .all(|byte| byte.is_ascii_whitespace())
    );
}

#[test]
fn private_instructions_fail_before_process_launch() {
    let result = cursor_driver::execute(
        "definitely-not-a-real-cursor-agent",
        &json!({"privateInstructions": "synthetic private instruction"}),
        "exact user prompt",
        "",
        Some(std::env::temp_dir().as_path()),
        0,
        None,
        1024,
    );
    assert_eq!(
        result.error.as_ref().map(|failure| failure.code),
        Some("cursor_cli_private_instructions_unsupported")
    );
}

/// Builds a fake cursor-agent executable in a fresh temp dir (shared helper).
fn compile_fake_cursor(stamp: u128) -> (PathBuf, PathBuf) {
    let sequence = FAKE_BUILD_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("lico-cursor-cli-fake-{stamp}-{sequence}"));
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
    // The fake reads process-global env vars; serialize with the other fake
    // tests so no concurrent test's vars leak into this spawned process.
    let _guard = env_lock();

    // Isolate the watcher's install root and hold the turn open.
    let install_root = std::env::temp_dir().join(format!("lico-cursor-install-fake-{stamp}"));
    fs::create_dir_all(install_root.join("versions")).unwrap();
    let release_path = install_root.join("update-test-release");
    // Safe in the single-threaded test body; restored before the assertions.
    unsafe {
        std::env::set_var("LICO_CURSOR_AGENT_INSTALL_DIR", &install_root);
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_UPDATE_RELEASE_PATH", &release_path);
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
    let timeline_events = Arc::clone(&captured);
    let timeline = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(12);
        wait_for_captured_event(
            &timeline_events,
            deadline,
            "native session binding",
            |event| event["event"] == "dispatch.turn.bound",
        );
        fs::write(timeline_root.join(".install.lock"), b"").unwrap();
        wait_for_captured_event(
            &timeline_events,
            deadline,
            "runtime update start",
            |event| event["event"] == "agent.runtime.updating",
        );
        fs::create_dir_all(timeline_root.join("versions").join(".2026.08.04-aaa8809")).unwrap();
        wait_for_captured_event(
            &timeline_events,
            deadline,
            "runtime installing phase",
            |event| {
                event["event"] == "agent.runtime.updating"
                    && event["payload"]["phase"] == "installing"
            },
        );
        fs::remove_file(timeline_root.join(".install.lock")).unwrap();
        fs::remove_dir_all(timeline_root.join("versions").join(".2026.08.04-aaa8809")).unwrap();
        wait_for_captured_event(
            &timeline_events,
            deadline,
            "runtime update completion",
            |event| event["event"] == "agent.runtime.update.completed",
        );
        fs::write(timeline_root.join("update-test-release"), b"").unwrap();
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
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_UPDATE_RELEASE_PATH");
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

/// M10: the turn deadline must span the whole turn, including the
/// session-creation phase. A create-chat that consumes most of the window
/// leaves the turn with the remainder — not with a fresh full window.
///
/// The margins are deliberately generous: this sandbox inflates child-process
/// lifecycle timing by hundreds of milliseconds, so sub-second windows are
/// not reliable here. With a 6s window, a create-chat that takes ~2s leaves
/// the turn ~3.5s of budget while the turn needs ~5s to answer: the turn must
/// time out at the caller's deadline. (Before the fix the turn would get a
/// fresh 6s window and complete.)
#[test]
fn create_chat_time_is_charged_against_the_turn_deadline() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (dir, executable) = compile_fake_cursor(stamp);
    let _guard = env_lock();
    unsafe {
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_CREATE_CHAT_DELAY_MS", "2000");
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_TURN_DELAY_MS", "5000");
    }
    let started = std::time::Instant::now();
    let result = cursor_driver::execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "private first prompt __lico_test__",
        "",
        Some(dir.as_path()),
        6000,
        Some(1024 * 1024),
        1024,
    );
    unsafe {
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_CREATE_CHAT_DELAY_MS");
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_TURN_DELAY_MS");
    }
    drop(_guard);
    let _ = fs::remove_dir_all(dir);
    assert!(
        !result.ok,
        "a turn slower than the remaining window must time out: {:?}",
        result.error
    );
    assert_eq!(
        result.error.as_ref().map(|error| error.code),
        Some("cursor_cli_timeout")
    );
    // The wall clock stays near the caller's deadline instead of deadline
    // plus a fresh create-chat window.
    assert!(
        started.elapsed() < Duration::from_millis(9000),
        "wall clock exceeded the deadline by too much"
    );
}

/// timeoutMs 0 keeps its contract: no synthetic deadline in either session
/// creation or turn execution.
#[test]
fn timeout_zero_keeps_the_turn_deadline_free() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (dir, executable) = compile_fake_cursor(stamp);
    let _guard = env_lock();
    unsafe {
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_CREATE_CHAT_DELAY_MS", "300");
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_TURN_DELAY_MS", "300");
    }
    let result = cursor_driver::execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "private first prompt __lico_test__",
        "",
        Some(dir.as_path()),
        0,
        Some(1024 * 1024),
        1024,
    );
    unsafe {
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_CREATE_CHAT_DELAY_MS");
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_TURN_DELAY_MS");
    }
    drop(_guard);
    let _ = fs::remove_dir_all(dir);
    assert!(
        result.ok,
        "timeoutMs 0 must not time out: {:?}",
        result.error
    );
    assert_eq!(result.output, "first response");
}

/// M11: a CLI crash after streaming partial output must not be reported as a
/// completed turn.
#[test]
fn crashed_cli_after_partial_output_is_reported_as_failed() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (dir, executable) = compile_fake_cursor(stamp);
    let _guard = env_lock();
    unsafe {
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_CRASH_AFTER_CHUNK", "1");
    }
    let result = cursor_driver::execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "private first prompt __lico_crash__",
        "",
        Some(dir.as_path()),
        10_000,
        Some(1024 * 1024),
        1024,
    );
    unsafe {
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_CRASH_AFTER_CHUNK");
    }
    drop(_guard);
    let _ = fs::remove_dir_all(dir);
    assert!(
        !result.ok,
        "a crashed CLI must not report success: {:?}",
        result.error
    );
    assert_eq!(
        result.error.as_ref().map(|error| error.code),
        Some("cursor_cli_turn_failed")
    );
    assert_ne!(result.turn_status, "completed");
}

/// M11: a user-cancelled turn must be reported as cancelled, never as
/// completed with truncated output.
#[cfg(unix)]
#[test]
fn cancelled_turn_is_reported_as_cancelled_not_completed() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (dir, executable) = compile_fake_cursor(stamp);
    let _guard = env_lock();
    // A per-test session tag keeps this turn's session id unique: the
    // active-turn registry is global and keyed by session id, and the fake's
    // default id is deterministic, so a concurrent test could otherwise be
    // cancelled by mistake.
    let session_tag = stamp.to_string();
    unsafe {
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_TURN_DELAY_MS", "20000");
        std::env::set_var("LICO_FAKE_CURSOR_AGENT_SESSION_TAG", &session_tag);
    }
    let executable = executable.to_string_lossy().into_owned();
    let turn_dir = dir.clone();
    let handle = std::thread::spawn(move || {
        cursor_driver::execute(
            &executable,
            &json!({}),
            "private first prompt __lico_test__",
            "",
            Some(turn_dir.as_path()),
            30_000,
            Some(1024 * 1024),
            1024,
        )
    });
    // create-chat answers with the tagged fake session id; poll until this
    // turn is registered and cancelled.
    let session_id = format!("fake-cursor-session-{session_tag}-000000000001");
    // The sandbox can inflate child startup by seconds, so the poll window
    // is far wider than the fake's hold time.
    let mut accepted = false;
    for _ in 0..160 {
        if cursor_driver::cancel(&session_id) == ControlDisposition::Accepted {
            accepted = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let result = handle.join().unwrap();
    assert!(
        accepted,
        "cancel was never accepted for {session_id}; turn result: {:?}",
        result.error
    );
    unsafe {
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_TURN_DELAY_MS");
        std::env::remove_var("LICO_FAKE_CURSOR_AGENT_SESSION_TAG");
    }
    drop(_guard);
    let _ = fs::remove_dir_all(dir);
    assert!(
        !result.ok,
        "a cancelled turn must not report success: {:?}",
        result.error
    );
    assert_eq!(
        result.error.as_ref().map(|error| error.code),
        Some("cursor_cli_cancelled")
    );
    assert_eq!(result.turn_status, "cancelled");
}
