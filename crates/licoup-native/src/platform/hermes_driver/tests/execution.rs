use super::*;

#[cfg(unix)]
#[test]
fn fake_child_e2e_streams_final_and_drains_stderr() {
    let root = unique_temp_dir("hermes-acp-e2e");
    let _portable_data = PortableDataDirGuard::isolate_under(&root);
    let executable = root.join("fake-hermes");
    write_executable(
        &executable,
        r#"#!/bin/sh
if [ "$1" = "acp" ] && [ "$2" = "--check" ]; then
  printf '%s\n' 'Hermes ACP check OK'
  exit 0
fi
if [ "$1" = "acp" ] && [ "$2" = "--version" ]; then
  printf '%s\n' 'Hermes test-version'
  exit 0
fi
if [ "$#" -ne 1 ] || [ "$1" != "acp" ]; then
  exit 40
fi
dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\000' x >&2 &
IFS= read -r init
case "$init" in *private-hermes-prompt*|*workspace/project*) exit 41;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"hermes-agent","version":"test"}}}'
IFS= read -r session
case "$session" in *private-hermes-prompt*) exit 42;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"native-hermes-session","models":{"currentModelId":"native-model","availableModels":[]},"modes":{"currentModeId":"default","availableModes":[]}}}'
IFS= read -r model
printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{}}'
IFS= read -r prompt
case "$prompt" in *private-hermes-prompt*) :;; *) exit 43;; esac
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"native-hermes-session","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"hidden thought"}}}}'
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"native-hermes-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"native answer"}}}}'
printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
wait
"#,
    );
    let result = execute(
        executable.to_str().unwrap(),
        &json!({"model": "requested-model"}),
        "private-hermes-prompt",
        "",
        Some(&root),
        5_000,
        Some(128 * 1024),
        8 * 1024,
    );
    assert!(
        result.ok,
        "Hermes fake child failed: {:?}",
        result
            .error
            .as_ref()
            .map(|failure| (failure.code, failure.stage))
    );
    assert_eq!(result.output, "native answer");
    assert_eq!(result.session_id, "native-hermes-session");
    assert_eq!(result.turn_status, "end_turn");
    assert_eq!(result.events.len(), 2);
    assert_eq!(result.effective.model.as_deref(), Some("requested-model"));
    assert_eq!(result.effective.approval_policy, Some(json!("default")));
    assert_eq!(
        cleanup_session(&result.session_id),
        ControlDisposition::Accepted
    );

    let probe = probe_driver(executable.to_str().unwrap(), 10_000, 16 * 1024);
    assert!(probe.available);
    assert!(probe.supported);
    assert!(probe.supports_streaming);
    assert!(probe.supports_model_override);
    assert!(!probe.supports_reasoning_override);
    let _ = fs::remove_dir_all(root);
}
