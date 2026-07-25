use super::*;
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(unix)]
fn environment_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[test]
fn missing_executable_is_unavailable_and_never_supported() {
    let capability = probe("lico-antigravity-driver-definitely-not-installed", 50, 1024);
    assert!(!capability.available);
    assert!(!capability.supported);
    assert_eq!(
        capability.error_code,
        Some("antigravity_executable_unavailable")
    );
}

#[cfg(unix)]
#[test]
fn uninstall_removes_only_lico_hook_namespace() {
    let _environment_guard = environment_lock();
    let gemini = std::env::temp_dir().join(format!(
        "lico-agy-gemini-uninstall-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    fs::create_dir_all(&gemini).unwrap();
    let previous = std::env::var_os("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
    unsafe {
        std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", &gemini);
    }
    let portable = std::env::temp_dir().join(format!(
        "lico-agy-portable-uninstall-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    fs::create_dir_all(&portable).unwrap();
    let previous_portable = crate::platform::paths::set_portable_data_dir_override(Some(portable));
    let fixture = FakeExecutable::new("uninstall", true);
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    let _ = execute(
        fixture.executable.to_string_lossy().as_ref(),
        &json!({}),
        "hello",
        "",
        Some(&workspace),
        5_000,
        8_192,
        8_192,
    );
    let hooks_path = gemini.join("hooks.json");
    let before = fs::read_to_string(&hooks_path).unwrap();
    assert!(before.contains("lico-up-antigravity-session"));
    // Preserve an unrelated user hook entry.
    let mut root: serde_json::Value = serde_json::from_str(&before).unwrap();
    root.as_object_mut().unwrap().insert(
        "user-hook".to_string(),
        json!({"enabled": true, "Stop": []}),
    );
    fs::write(&hooks_path, serde_json::to_vec_pretty(&root).unwrap()).unwrap();
    uninstall_hook_bridge().unwrap();
    let after = fs::read_to_string(&hooks_path).unwrap();
    assert!(!after.contains("lico-up-antigravity-session"));
    assert!(after.contains("user-hook"));
    crate::platform::paths::set_portable_data_dir_override(previous_portable);
    if let Some(value) = previous {
        unsafe {
            std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", value);
        }
    } else {
        unsafe {
            std::env::remove_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
        }
    }
}

#[test]
fn empty_prompt_fails_closed_without_echoing_secrets() {
    let prompt = "";
    let cwd = "/workspace/path-secret-sentinel";
    let session_id = "session-secret-sentinel";
    let result = execute(
        "agy",
        &json!({}),
        prompt,
        session_id,
        Some(Path::new(cwd)),
        1_000,
        1_024,
        1_024,
    );
    assert!(!result.ok);
    let message = result.error.unwrap().message;
    assert!(!message.contains(cwd));
    assert!(!message.contains(session_id));
}

#[cfg(unix)]
#[test]
fn probe_detects_official_print_and_conversation_surface() {
    let fixture = FakeExecutable::new("probe", true);
    let capability = probe(fixture.executable.to_string_lossy().as_ref(), 5_000, 8_192);
    assert!(capability.available);
    assert!(capability.supported);
    assert!(capability.new_session);
    assert!(capability.resume_session);
    assert_eq!(capability.error_code, None);
}

#[cfg(unix)]
#[test]
fn execute_reads_hook_receipt_and_returns_session_output() {
    let _environment_guard = environment_lock();
    let portable = std::env::temp_dir().join(format!(
        "lico-agy-portable-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let gemini = std::env::temp_dir().join(format!(
        "lico-agy-gemini-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    fs::create_dir_all(&portable).unwrap();
    fs::create_dir_all(&gemini).unwrap();
    let previous_portable = crate::platform::paths::set_portable_data_dir_override(Some(portable));
    let previous_gemini = std::env::var_os("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
    unsafe {
        std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", &gemini);
    }

    let fixture = FakeExecutable::new("execute", true);
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    let result = execute(
        fixture.executable.to_string_lossy().as_ref(),
        &json!({"model": "gemini-test"}),
        "hello-from-lico",
        "",
        Some(&workspace),
        5_000,
        8_192,
        8_192,
    );
    crate::platform::paths::set_portable_data_dir_override(previous_portable);
    if let Some(value) = previous_gemini {
        unsafe {
            std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", value);
        }
    } else {
        unsafe {
            std::env::remove_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
        }
    }
    assert!(result.ok, "{:?}", result.error);
    assert_eq!(result.session_id, "11111111-2222-3333-4444-555555555555");
    assert_eq!(result.output, "PONG");
    assert!(!result.events.is_empty());
}

#[cfg(unix)]
struct FakeExecutable {
    root: PathBuf,
    executable: PathBuf,
}

#[cfg(unix)]
impl FakeExecutable {
    fn new(label: &str, emit_receipt: bool) -> Self {
        use std::os::unix::fs::PermissionsExt;

        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lico-antigravity-driver-{label}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
        let executable = root.join("fake-agy");
        let script = if emit_receipt {
            r#"#!/bin/sh
set -eu
for arg in "$@"; do
  case "$arg" in
    --help)
      printf '%s\n' '--print --conversation --model --effort --dangerously-skip-permissions'
      exit 0
      ;;
    --version)
      printf '%s\n' '1.1.5'
      exit 0
      ;;
  esac
done
receipt="${LICO_ANTIGRAVITY_SESSION_RECEIPT:?}"
python3 - "$receipt" <<'PY'
import json, os, sys
json.dump({"conversationId": "11111111-2222-3333-4444-555555555555"}, open(sys.argv[1], "w"))
PY
printf '%s\n' 'PONG'
exit 0
"#
        } else {
            r#"#!/bin/sh
printf '%s\n' "$@"
exit 0
"#
        };
        fs::write(&executable, script).unwrap();
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions).unwrap();
        Self { root, executable }
    }
}

#[cfg(unix)]
impl Drop for FakeExecutable {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
