use super::*;

#[test]
fn fake_child_transport_proves_stdin_session_id_and_concurrent_stderr_drain() {
    let dir = std::env::temp_dir().join(format!("lico-acp-fake-{}", timestamp()));
    fs::create_dir_all(&dir).unwrap();
    let source = dir.join("fake_agent.rs");
    let executable = dir.join(format!("fake-agent{}", std::env::consts::EXE_SUFFIX));
    fs::write(&source, FAKE_AGENT_SOURCE).unwrap();
    let status = Command::new("rustc")
        .args(["--edition", "2021"])
        .arg(&source)
        .arg("-o")
        .arg(&executable)
        .status()
        .unwrap();
    assert!(status.success());
    let acp_driver = AcpDriverSpec::new("test-acp", &["acp"]).with_identity("test-acp", "acp");
    let result = execute_acp(
        acp_driver,
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "private-stdin-prompt",
        "",
        Some(dir.as_path()),
        10_000,
        1024 * 1024,
        1024,
    );
    assert!(result.ok, "fake ACP failure: {:?}", result.error);
    assert_eq!(result.output, "fake final");
    assert_eq!(result.session_id, "native-fake-session");
    assert_eq!(result.turn_status, "end_turn");
    assert_eq!(result.capabilities.protocol_version, Some(1));
    assert!(result.stderr_truncated);
    let _ = fs::remove_dir_all(dir);
}
