use super::*;
use serde_json::json;
use std::fs;
#[cfg(unix)]
use std::io::Write;
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::process::{Command, Stdio};
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

#[test]
fn private_instructions_fail_before_process_launch() {
    let result = execute(
        "definitely-not-a-real-antigravity",
        &json!({"privateInstructions":"private sentinel"}),
        "exact user prompt",
        "session-secret-sentinel",
        Some(std::env::temp_dir().as_path()),
        1_000,
        None,
        1_024,
    );
    assert_eq!(
        result.error.as_ref().map(|error| error.code),
        Some("antigravity_private_instructions_unsupported")
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
        Some(8_192),
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
        Some(1_024),
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
        Some(8_192),
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
    assert!(!result.transitions.is_empty());
}

#[cfg(unix)]
#[test]
fn execute_streams_pty_chunks_before_completion() {
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

    let captured = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink_target = std::sync::Arc::clone(&captured);
    crate::platform::turn_event_emit::install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _guard = crate::platform::turn_event_emit::StreamSinkGuard;

    let fixture = FakeExecutable::new_streaming("streaming");
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    let result = execute(
        fixture.executable.to_string_lossy().as_ref(),
        &json!({}),
        "hello-from-lico",
        "",
        Some(&workspace),
        5_000,
        Some(8_192),
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
    assert_eq!(result.output, "first\nsecond");

    let events = captured.lock().unwrap().clone();
    let accepted_at = events
        .iter()
        .position(|event| event["event"] == "agent.turn.accepted");
    let first_chunk_at = events
        .iter()
        .position(|event| event["event"] == "agent.message.chunk");
    assert!(
        accepted_at.is_some_and(|accepted| first_chunk_at.is_some_and(|chunk| accepted < chunk)),
        "accepted must precede the first chunk: {events:?}"
    );
    let chunks: Vec<_> = events
        .iter()
        .filter(|event| event["event"] == "agent.message.chunk")
        .collect();
    assert!(chunks.len() >= 2, "expected progressive chunks: {events:?}");
    let joined: String = chunks
        .iter()
        .map(|event| event["payload"]["text"].as_str().unwrap_or_default())
        .collect();
    assert_eq!(joined, "first\nsecond\n");
    assert!(
        chunks
            .iter()
            .all(|event| event["sessionId"].as_str() == Some("")),
        "new-session chunks carry the requested (empty) session id"
    );
    let completed_at = events.iter().position(|value| {
        value["event"] == "agent.message.completed"
            && value["sessionId"].as_str() == Some("11111111-2222-3333-4444-555555555555")
    });
    assert!(
        completed_at.is_some_and(|completed_at| {
            first_chunk_at.is_some_and(|chunk_at| chunk_at < completed_at)
        }),
        "completed must follow the chunks (the fake only exits after 'second'): {events:?}"
    );
}

#[cfg(unix)]
#[test]
fn execute_with_zero_timeout_runs_to_completion() {
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

    let fixture = FakeExecutable::new("zero-timeout", true);
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    let result = execute(
        fixture.executable.to_string_lossy().as_ref(),
        &json!({}),
        "hello-from-lico",
        "",
        Some(&workspace),
        0,
        Some(8_192),
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
    assert_eq!(result.output, "PONG");
}

#[cfg(unix)]
#[test]
fn execute_resume_binds_exact_requested_conversation() {
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

    let requested = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    let fixture =
        FakeExecutable::with_receipt_style("resume", true, ReceiptStyle::Direct, requested);
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    let result = execute(
        fixture.executable.to_string_lossy().as_ref(),
        &json!({}),
        "hello-from-lico",
        requested,
        Some(&workspace),
        5_000,
        Some(8_192),
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
    assert_eq!(result.session_id, requested);
}

#[cfg(unix)]
#[test]
fn execute_resume_rejects_receipt_drift() {
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

    let requested = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    let fixture =
        FakeExecutable::with_receipt_style("drift", true, ReceiptStyle::Direct, DEFAULT_RECEIPT_ID);
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    let result = execute(
        fixture.executable.to_string_lossy().as_ref(),
        &json!({}),
        "hello-from-lico",
        requested,
        Some(&workspace),
        5_000,
        Some(8_192),
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
    assert!(!result.ok);
    assert_eq!(result.error.unwrap().code, "antigravity_cli_session_drift");
}

#[cfg(unix)]
#[test]
fn execute_reads_legacy_wrapped_receipt_for_compatibility() {
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

    let fixture = FakeExecutable::with_receipt_style(
        "wrapped",
        true,
        ReceiptStyle::Wrapped,
        DEFAULT_RECEIPT_ID,
    );
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    let result = execute(
        fixture.executable.to_string_lossy().as_ref(),
        &json!({}),
        "hello-from-lico",
        "",
        Some(&workspace),
        5_000,
        Some(8_192),
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
    assert_eq!(result.session_id, DEFAULT_RECEIPT_ID);
}

#[cfg(unix)]
#[test]
fn hook_script_encodes_one_direct_object_from_stdin() {
    let _environment_guard = environment_lock();
    let gemini = std::env::temp_dir().join(format!(
        "lico-agy-hook-gemini-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    fs::create_dir_all(&gemini).unwrap();
    let previous_gemini = std::env::var_os("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
    unsafe {
        std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", &gemini);
    }

    ensure_hook_bridge().unwrap();
    let script = gemini
        .join("lico-up-antigravity")
        .join("session-receipt-hook.sh");
    let receipt = gemini.join("receipt.json");
    run_hook_script(
        &script,
        &receipt,
        r#"{"conversationId":"11111111-2222-3333-4444-555555555555","transcriptPath":"/workspace/transcript","cwd":"/workspace"}"#,
        None,
    );
    let text = fs::read_to_string(&receipt).unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&text).unwrap(),
        json!({"conversationId": DEFAULT_RECEIPT_ID}),
        "the hook must write one direct JSON object, not a wrapped payload"
    );
    let hooks_json = fs::read_to_string(gemini.join("hooks.json")).unwrap();
    let hook_entry = hooks_json
        .split("lico-up-antigravity-session")
        .nth(1)
        .expect("hook namespace registered");
    assert!(
        hook_entry.contains("\"Stop\""),
        "only Stop must be installed"
    );
    assert!(!hook_entry.contains("SessionStart"));

    if let Some(value) = previous_gemini {
        unsafe {
            std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", value);
        }
    } else {
        unsafe {
            std::env::remove_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
        }
    }
}

#[cfg(unix)]
#[test]
fn hook_script_uses_vendor_environment_identifier_as_fallback() {
    let _environment_guard = environment_lock();
    let gemini = std::env::temp_dir().join(format!(
        "lico-agy-hook-env-gemini-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    fs::create_dir_all(&gemini).unwrap();
    let previous_gemini = std::env::var_os("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
    unsafe {
        std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", &gemini);
    }

    ensure_hook_bridge().unwrap();
    let script = gemini
        .join("lico-up-antigravity")
        .join("session-receipt-hook.sh");
    let receipt = gemini.join("receipt.json");
    run_hook_script(
        &script,
        &receipt,
        r#"{"transcriptPath":"/workspace/transcript","cwd":"/workspace"}"#,
        Some(DEFAULT_RECEIPT_ID),
    );
    let text = fs::read_to_string(&receipt).unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&text).unwrap(),
        json!({"conversationId": DEFAULT_RECEIPT_ID})
    );

    if let Some(value) = previous_gemini {
        unsafe {
            std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", value);
        }
    } else {
        unsafe {
            std::env::remove_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
        }
    }
}

#[cfg(unix)]
#[test]
fn hook_script_preserves_vendor_first_receipt_when_input_carries_no_id() {
    let _environment_guard = environment_lock();
    let gemini = std::env::temp_dir().join(format!(
        "lico-agy-hook-order-gemini-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    fs::create_dir_all(&gemini).unwrap();
    let previous_gemini = std::env::var_os("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
    unsafe {
        std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", &gemini);
    }

    ensure_hook_bridge().unwrap();
    let script = gemini
        .join("lico-up-antigravity")
        .join("session-receipt-hook.sh");
    let receipt = gemini.join("receipt.json");
    // The vendor/another Stop-hook writer ran first with an accepted alias key.
    fs::write(
        &receipt,
        r#"{"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#,
    )
    .unwrap();
    run_hook_script(
        &script,
        &receipt,
        r#"{"transcriptPath":"/workspace/transcript","cwd":"/workspace"}"#,
        None,
    );
    let text = fs::read_to_string(&receipt).unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&text).unwrap(),
        json!({"conversationId": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}),
        "the LicoUp hook must not erase a vendor receipt written first"
    );
    assert_eq!(
        crate::platform::native_agent_parser::adapters::antigravity::parse_hook_receipt(&text)
            .as_deref(),
        Some("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    );

    if let Some(value) = previous_gemini {
        unsafe {
            std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", value);
        }
    } else {
        unsafe {
            std::env::remove_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
        }
    }
}

#[cfg(unix)]
fn run_hook_script(script: &Path, receipt: &Path, stdin_text: &str, environment_id: Option<&str>) {
    let mut command = Command::new(script);
    command
        .env("LICO_ANTIGRAVITY_SESSION_RECEIPT", receipt)
        .stdin(Stdio::piped())
        .stdout(Stdio::null());
    match environment_id {
        Some(environment_id) => {
            command.env("ANTIGRAVITY_CONVERSATION_ID", environment_id);
        }
        None => {
            command.env_remove("ANTIGRAVITY_CONVERSATION_ID");
        }
    }
    let mut child = command.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin_text.as_bytes())
        .unwrap();
    assert!(child.wait().unwrap().success());
}

#[cfg(unix)]
const DEFAULT_RECEIPT_ID: &str = "11111111-2222-3333-4444-555555555555";

#[cfg(unix)]
#[derive(Clone, Copy)]
enum ReceiptStyle {
    /// One direct JSON object `{"conversationId": "<id>"}` — the format the
    /// vendor CLI and the installed LicoUp Stop-hook write today.
    Direct,
    /// Legacy LicoUp hook wrapper (`hookPayload` + `environmentConversationId`),
    /// retained as a compatible input only.
    Wrapped,
}

#[cfg(unix)]
impl ReceiptStyle {
    fn writer_body(self, receipt_id: &str) -> String {
        match self {
            ReceiptStyle::Direct => format!(
                r#"import json, sys
json.dump({{"conversationId": "{receipt_id}"}}, open(sys.argv[1], "w"))
"#
            ),
            ReceiptStyle::Wrapped => format!(
                r#"import json, sys
json.dump({{"hookPayload": json.dumps({{"conversationId": "{receipt_id}"}}), "environmentConversationId": ""}}, open(sys.argv[1], "w"))
"#
            ),
        }
    }
}

#[cfg(unix)]
struct FakeExecutable {
    root: PathBuf,
    executable: PathBuf,
}

#[cfg(unix)]
impl FakeExecutable {
    fn new(label: &str, emit_receipt: bool) -> Self {
        Self::with_receipt_style(
            label,
            emit_receipt,
            ReceiptStyle::Direct,
            DEFAULT_RECEIPT_ID,
        )
    }

    fn with_receipt_style(
        label: &str,
        emit_receipt: bool,
        style: ReceiptStyle,
        receipt_id: &str,
    ) -> Self {
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
            let writer = style.writer_body(receipt_id);
            format!(
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
receipt="${{LICO_ANTIGRAVITY_SESSION_RECEIPT:?}}"
python3 - "$receipt" <<'PY'
{writer}
PY
printf '%s\n' 'PONG'
exit 0
"#
            )
        } else {
            r#"#!/bin/sh
printf '%s\n' "$@"
exit 0
"#
            .to_string()
        };
        fs::write(&executable, script).unwrap();
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions).unwrap();
        Self { root, executable }
    }

    /// Writes the receipt, then prints `first`, sleeps, and prints `second`
    /// before exiting — proving the pty lane delivers progressive chunks
    /// before the process completes.
    fn new_streaming(label: &str) -> Self {
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
        let writer = ReceiptStyle::Direct.writer_body(DEFAULT_RECEIPT_ID);
        let script = format!(
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
receipt="${{LICO_ANTIGRAVITY_SESSION_RECEIPT:?}}"
python3 - "$receipt" <<'PY'
{writer}
PY
printf '%s\n' 'first'
sleep 0.4
printf '%s\n' 'second'
exit 0
"#
        );
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

#[cfg(unix)]
struct AuthFakeExecutable {
    root: PathBuf,
    executable: PathBuf,
    print_marker: PathBuf,
}

#[cfg(unix)]
impl AuthFakeExecutable {
    /// `mode`: `logged_out` (models exit 1), `authorized` (models exit 0),
    /// `authorize_flow` (models fails until a print turn creates the login
    /// flag), or `authorize_incomplete` (print never completes the login).
    fn new(label: &str, mode: &str) -> Self {
        use std::os::unix::fs::PermissionsExt;

        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lico-antigravity-auth-{label}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
        let executable = root.join("fake-agy");
        let print_marker = root.join("print-invocations.log");
        let login_flag = root.join("login-complete.flag");
        let writer = ReceiptStyle::Direct.writer_body(DEFAULT_RECEIPT_ID);
        let script = format!(
            r#"#!/bin/sh
set -eu
mode="{mode}"
marker="{marker}"
login_flag="{login_flag}"
for arg in "$@"; do
  case "$arg" in
    models)
      if [ "$mode" = "authorized" ]; then
        printf '%s\n' 'gemini-test-model'
        exit 0
      fi
      if [ "$mode" = "authorize_flow" ] && [ -f "$login_flag" ]; then
        printf '%s\n' 'gemini-test-model'
        exit 0
      fi
      printf '%s\n' 'Error: Please sign in to view available models. Launch the CLI without arguments to sign in.'
      exit 1
      ;;
    --print=*)
      printf '%s\n' invoked >> "$marker"
      if [ "$mode" = "authorize_flow" ]; then
        : > "$login_flag"
      fi
      if [ -n "${{LICO_ANTIGRAVITY_SESSION_RECEIPT:-}}" ]; then
        python3 - "$LICO_ANTIGRAVITY_SESSION_RECEIPT" <<'PY'
{writer}
PY
      fi
      printf '%s\n' 'PONG'
      exit 0
      ;;
    --help)
      printf '%s\n' '--print --conversation --model --effort --dangerously-skip-permissions'
      exit 0
      ;;
    --version)
      printf '%s\n' '1.1.8'
      exit 0
      ;;
  esac
done
receipt="${{LICO_ANTIGRAVITY_SESSION_RECEIPT:?}}"
python3 - "$receipt" <<'PY'
{writer}
PY
printf '%s\n' 'PONG'
exit 0
"#,
            mode = mode,
            marker = print_marker.display(),
            login_flag = login_flag.display(),
        );
        fs::write(&executable, script).unwrap();
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions).unwrap();
        Self {
            root,
            executable,
            print_marker,
        }
    }

    fn executable_str(&self) -> &str {
        self.executable.to_str().unwrap()
    }

    fn print_invoked(&self) -> bool {
        self.print_marker.exists()
    }
}

#[cfg(unix)]
impl Drop for AuthFakeExecutable {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[cfg(unix)]
fn scoped_gemini_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "lico-agy-auth-gemini-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[cfg(unix)]
#[test]
fn logged_out_send_returns_auth_required_without_spawning_a_turn() {
    let _environment_guard = environment_lock();
    let gemini = scoped_gemini_dir("logged-out");
    let portable = scoped_gemini_dir("logged-out-portable");
    let previous_gemini = std::env::var_os("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
    unsafe {
        std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", &gemini);
    }
    let previous_portable = crate::platform::paths::set_portable_data_dir_override(Some(portable));
    let fixture = AuthFakeExecutable::new("logged-out", "logged_out");
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();

    let result = execute(
        fixture.executable_str(),
        &json!({}),
        "hello",
        "",
        Some(&workspace),
        5_000,
        Some(8_192),
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
    assert!(!result.ok);
    let failure = result.error.unwrap();
    assert_eq!(failure.code, "antigravity_auth_required");
    assert!(failure.user_interaction_required);
    assert!(
        !fixture.print_invoked(),
        "a logged-out send must never spawn the OAuth-opening turn"
    );
    assert!(
        !gemini.join("hooks.json").exists(),
        "the hook bridge must not be installed before authorization"
    );
}

#[cfg(unix)]
#[test]
fn authorized_send_proceeds_past_the_probe() {
    let _environment_guard = environment_lock();
    let gemini = scoped_gemini_dir("authorized");
    let portable = scoped_gemini_dir("authorized-portable");
    let previous_gemini = std::env::var_os("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR");
    unsafe {
        std::env::set_var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR", &gemini);
    }
    let previous_portable = crate::platform::paths::set_portable_data_dir_override(Some(portable));
    let fixture = AuthFakeExecutable::new("authorized", "authorized");
    let workspace = fixture.root.join("workspace");
    fs::create_dir_all(&workspace).unwrap();

    let result = execute(
        fixture.executable_str(),
        &json!({}),
        "hello-from-lico",
        "",
        Some(&workspace),
        5_000,
        Some(8_192),
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
    assert_eq!(result.output, "PONG");
    assert!(fixture.print_invoked());
}

#[cfg(unix)]
#[test]
fn authorize_runs_the_explicit_vendor_flow_and_reprobes() {
    let fixture = AuthFakeExecutable::new("authorize", "authorize_flow");
    let report = authorize(Some(fixture.executable_str())).unwrap();
    assert_eq!(report["ok"], true);
    assert_eq!(report["action"], "authorize");
    assert_eq!(report["authorized"], true);
    assert_eq!(report["status"], "authorized");
    assert!(
        fixture.print_invoked(),
        "the explicit authorize action must run the vendor OAuth trigger"
    );
    let serialized = report.to_string();
    assert!(!serialized.contains(&fixture.root.display().to_string()));
}

#[cfg(unix)]
#[test]
fn authorize_reports_incomplete_when_login_does_not_finish() {
    let fixture = AuthFakeExecutable::new("incomplete", "authorize_incomplete");
    let report = authorize(Some(fixture.executable_str())).unwrap();
    assert_eq!(report["ok"], true);
    assert_eq!(report["authorized"], false);
    assert_eq!(report["status"], "authorization_incomplete");
    assert!(fixture.print_invoked());
}

#[cfg(unix)]
#[test]
fn authorize_missing_executable_is_a_typed_failure() {
    let result = authorize(Some("/definitely/missing/lico-antigravity-agy"));
    assert_eq!(result, Err("antigravity_authorize_unavailable"));
}
