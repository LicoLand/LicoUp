use super::super::lico_agent_driver::{self, RUNTIME_PROTOCOL};
use super::execution::execute_with_test_handshake_bound;
use serde_json::json;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The fake agent reads process-global env vars, so the tests that steer it
/// must not run concurrently or one test's env leaks into another test's
/// spawned process.
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// The fake answers synchronously, but a fully loaded test runner can delay
/// scheduling either process. Give immediate-response fixtures test-only
/// scheduling tolerance without relaxing the production handshake bound.
const FAKE_RESPONSE_BOUND: Duration = Duration::from_secs(30);

/// M12: a lico-agent that starts but never answers `get_state` must fail the
/// send within the handshake bound instead of blocking forever.
#[test]
fn readiness_handshake_hang_fails_bounded() {
    let stamp = stamp_nanos();
    let (dir, executable) = compile_fake_lico_agent(stamp);
    let _guard = ENV_LOCK.lock().unwrap();
    unsafe {
        std::env::set_var("LICO_FAKE_LICO_AGENT_HANG", "1");
    }
    let started = Instant::now();
    let result = execute_with_production_bound(executable.to_string_lossy().as_ref(), &dir);
    unsafe {
        std::env::remove_var("LICO_FAKE_LICO_AGENT_HANG");
    }
    drop(_guard);
    let _ = fs::remove_dir_all(dir);
    assert!(
        !result.ok,
        "a silent agent must fail the send: {:?}",
        result.error
    );
    assert_eq!(
        result.error.as_ref().map(|error| error.code),
        Some("lico_agent_rpc_handshake_timeout")
    );
    let elapsed = started.elapsed();
    assert!(
        elapsed >= Duration::from_secs(4),
        "handshake bound was not enforced: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_secs(8),
        "handshake exceeded its bound: {elapsed:?}"
    );
}

/// M12: a `get_state` error response must fail the send before the prompt is
/// written.
#[test]
fn rejected_readiness_handshake_fails_before_prompt() {
    let stamp = stamp_nanos();
    let (dir, executable) = compile_fake_lico_agent(stamp);
    let _guard = ENV_LOCK.lock().unwrap();
    unsafe {
        std::env::set_var("LICO_FAKE_LICO_AGENT_REJECT", "1");
    }
    let result = execute_with(executable.to_string_lossy().as_ref(), &dir);
    unsafe {
        std::env::remove_var("LICO_FAKE_LICO_AGENT_REJECT");
    }
    drop(_guard);
    let _ = fs::remove_dir_all(dir);
    assert!(
        !result.ok,
        "a rejected handshake must fail the send: {:?}",
        result.error
    );
    assert_eq!(
        result.error.as_ref().map(|error| error.code),
        Some("lico_agent_rpc_handshake_failed")
    );
}

/// The happy path still works: a successful handshake is followed by the
/// prompt and a completed turn.
#[test]
fn successful_readiness_handshake_keeps_the_turn_flow() {
    let stamp = stamp_nanos();
    let (dir, executable) = compile_fake_lico_agent(stamp);
    // Keep the parent transcript inside the temp dir.
    let portable_dir = dir.join("portable");
    fs::create_dir_all(&portable_dir).unwrap();
    let _guard = ENV_LOCK.lock().unwrap();
    unsafe {
        std::env::set_var("LICOUP_PORTABLE_DIR", &portable_dir);
    }
    let result = execute_with(executable.to_string_lossy().as_ref(), &dir);
    unsafe {
        std::env::remove_var("LICOUP_PORTABLE_DIR");
    }
    drop(_guard);
    let _ = fs::remove_dir_all(dir);
    assert!(result.ok, "happy path failed: {:?}", result.error);
    assert_eq!(result.turn_status, "completed");
    assert_eq!(RUNTIME_PROTOCOL, "lico-agent-rpc-stdio-jsonl");
}

fn execute_with(executable: &str, dir: &PathBuf) -> lico_agent_driver::RunResult {
    execute_with_test_handshake_bound(
        executable,
        &json!({"model": "test-gateway-model"}),
        "private first prompt",
        "",
        Some(dir.as_path()),
        10_000,
        Some(1024 * 1024),
        1024,
        FAKE_RESPONSE_BOUND,
    )
}

fn execute_with_production_bound(executable: &str, dir: &PathBuf) -> lico_agent_driver::RunResult {
    lico_agent_driver::execute(
        executable,
        &json!({"model": "test-gateway-model"}),
        "private first prompt",
        "",
        Some(dir.as_path()),
        10_000,
        Some(1024 * 1024),
        1024,
    )
}

/// Builds a fake lico-agent executable in a fresh temp dir (shared helper).
fn compile_fake_lico_agent(stamp: u128) -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("lico-lico-agent-fake-{stamp}"));
    fs::create_dir_all(&dir).unwrap();
    let source = dir.join("fake_lico_agent.rs");
    let executable = dir.join(format!("fake-lico-agent{}", std::env::consts::EXE_SUFFIX));
    fs::write(
        &source,
        include_str!("../../../tests/fixtures/fake_lico_agent.rs"),
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

fn stamp_nanos() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}
