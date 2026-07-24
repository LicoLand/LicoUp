use crate::platform::codex_app_server::{
    active_control::{ControlDisposition, steer},
    execute,
};
use serde_json::json;
use std::fs as test_fs;
use std::path::Path;
use std::process::Command as TestCommand;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn fake_child_proves_spawn_stdin_concurrent_drain_and_completion() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("fake_codex_app_server.rs");
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let temp_dir = std::env::temp_dir().join(format!("lico-codex-fake-{suffix}"));
    test_fs::create_dir_all(&temp_dir).unwrap();
    let executable = temp_dir.join(format!("fake-codex{}", std::env::consts::EXE_SUFFIX));
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
    let compile = TestCommand::new(rustc)
        .arg("--edition=2024")
        .arg(&fixture)
        .arg("-o")
        .arg(&executable)
        .status()
        .expect("fake Codex fixture should compile with the active Rust toolchain");
    assert!(compile.success());

    let result = execute(
        &executable.to_string_lossy(),
        &json!({"model": "fake-explicit", "reasoningEffort": "high"}),
        "fake-child-private-prompt",
        "",
        Some(&temp_dir),
        10_000,
        1024 * 1024,
        1024,
    );

    assert!(result.ok, "fake child protocol failed: {:?}", result.error);
    assert_eq!(result.output, "fake child final answer");
    assert_eq!(result.session_id, "fake-thread");
    assert_eq!(result.thread_id, "fake-thread");
    assert_eq!(result.turn_id, "fake-turn");
    assert_eq!(result.turn_status, "completed");
    assert_eq!(result.effective.model.as_deref(), Some("fake-explicit"));
    assert_eq!(result.effective.reasoning_effort.as_deref(), Some("high"));
    assert!(result.stderr_truncated);

    let _ = test_fs::remove_dir_all(temp_dir);
}

#[test]
fn fake_child_acknowledges_native_guidance_during_the_active_turn() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("fake_codex_app_server.rs");
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp_dir = std::env::temp_dir().join(format!("lico-codex-steer-{suffix}"));
    test_fs::create_dir_all(&temp_dir).unwrap();
    let executable = temp_dir.join(format!("fake-codex{}", std::env::consts::EXE_SUFFIX));
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
    let compile = TestCommand::new(rustc)
        .arg("--edition=2024")
        .arg(&fixture)
        .arg("-o")
        .arg(&executable)
        .status()
        .expect("fake Codex fixture should compile with the active Rust toolchain");
    assert!(compile.success());
    let mut steer_marker = executable.clone();
    steer_marker.set_extension("steer-mode");
    test_fs::write(&steer_marker, b"").unwrap();

    let executable_text = executable.to_string_lossy().to_string();
    let cwd = temp_dir.clone();
    let run = std::thread::spawn(move || {
        execute(
            &executable_text,
            &json!({"model": "fake-steer"}),
            "fake-codex-steer-prompt",
            "",
            Some(&cwd),
            10_000,
            1024 * 1024,
            1024,
        )
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let disposition = loop {
        let disposition = steer(
            "fake-steer-thread",
            "fake-steer-turn",
            "fake-codex-steer-guidance",
        );
        if disposition == ControlDisposition::Accepted || std::time::Instant::now() >= deadline {
            break disposition;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    };
    assert_eq!(disposition, ControlDisposition::Accepted);
    let result = run.join().unwrap();
    assert!(result.ok, "fake child protocol failed: {:?}", result.error);
    assert_eq!(result.output, "fake child guided answer");
    assert_eq!(result.session_id, "fake-steer-thread");
    assert_eq!(result.turn_id, "fake-steer-turn");

    let _ = test_fs::remove_dir_all(temp_dir);
}
