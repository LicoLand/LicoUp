use super::super::adapter::adapter_for_agent;
use super::super::dispatch::{params_with_workspace, send_message};
use super::super::params::message_param;
use super::super::{MAX_MESSAGE_BYTES, RuntimeAdapter, RuntimeAdapterError};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

struct AttachmentFixture {
    directory: PathBuf,
    png: PathBuf,
    jpeg: PathBuf,
    gif: PathBuf,
    webp: PathBuf,
}

impl AttachmentFixture {
    fn new() -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let suffix = format!(
            "{}-{sequence}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()
        );
        let directory = std::env::temp_dir().join(format!("lico-attachment-{suffix}"));
        fs::create_dir_all(&directory).unwrap();
        let png = directory.join("synthetic.png");
        let jpeg = directory.join("synthetic.jpg");
        let gif = directory.join("synthetic.gif");
        let webp = directory.join("synthetic.webp");
        fs::write(
            &png,
            [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0],
        )
        .unwrap();
        fs::write(&jpeg, [0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]).unwrap();
        fs::write(&gif, b"GIF89a-synthetic").unwrap();
        fs::write(&webp, b"RIFF\x10\x00\x00\x00WEBPVP8 ").unwrap();
        Self {
            directory,
            png,
            jpeg,
            gif,
            webp,
        }
    }

    fn attachment(&self, id: &str, path: &Path) -> serde_json::Value {
        let media_type = match path.extension().and_then(|value| value.to_str()) {
            Some("png") => "image/png",
            Some("jpg") | Some("jpeg") => "image/jpeg",
            Some("gif") => "image/gif",
            Some("webp") => "image/webp",
            _ => "image/png",
        };
        json!({
            "id": id,
            "name": path.file_name().unwrap().to_string_lossy(),
            "mediaType": media_type,
            "path": path.to_string_lossy()
        })
    }
}

impl Drop for AttachmentFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

fn codex_params(
    fixture: &AttachmentFixture,
    attachments: Vec<serde_json::Value>,
) -> serde_json::Value {
    json!({
        "agent": "codex",
        "text": "describe the images",
        "binaryPath": "/bin/sh",
        "attachments": attachments,
        "cwd": fixture.directory.to_string_lossy()
    })
}

#[test]
fn deepseek_send_is_rejected_before_launch_while_carrier_is_unverified() {
    let error = send_message(&json!({
        "agent": "deepseek-harness",
        "text": "must not launch",
        "model": "profile-authorized-model",
        "binaryPath": "must-not-run"
    }))
    .unwrap_err();

    assert_eq!(error, RuntimeAdapterError::RuntimeProfileUnavailable);
}

#[cfg(unix)]
#[test]
fn codex_attachments_pass_admission_and_reach_the_driver() {
    let fixture = AttachmentFixture::new();
    let result = send_message(&codex_params(
        &fixture,
        vec![
            fixture.attachment("sel-1", &fixture.png),
            fixture.attachment("sel-2", &fixture.jpeg),
            fixture.attachment("sel-3", &fixture.gif),
            fixture.attachment("sel-4", &fixture.webp),
        ],
    ))
    .expect("admission must accept four valid local images");

    // The shell fixture cannot speak the app-server protocol, so the turn
    // fails at the protocol stage — proving admission passed and a process
    // was actually launched (no attachment error surfaced).
    assert_eq!(result["ok"], false);
    let code = result["error"]["code"].as_str().unwrap_or_default();
    assert!(
        code.starts_with("codex_"),
        "expected a Codex protocol failure, got {code}"
    );
}

#[cfg(unix)]
#[test]
fn attachment_only_send_is_accepted_for_codex() {
    let fixture = AttachmentFixture::new();
    let params = json!({
        "agent": "codex",
        "text": "",
        "binaryPath": "/bin/sh",
        "attachments": [fixture.attachment("sel-1", &fixture.png)],
        "cwd": fixture.directory.to_string_lossy()
    });
    let result =
        send_message(&params).expect("attachment-only sends must not be rejected as missing text");
    assert_eq!(result["ok"], false);
    let code = result["error"]["code"].as_str().unwrap_or_default();
    assert!(code.starts_with("codex_"), "got {code}");
}

#[test]
fn non_codex_adapter_rejects_attachments_before_launch() {
    let fixture = AttachmentFixture::new();
    let error = send_message(&json!({
        "agent": "claude-code",
        "text": "hello",
        "attachments": [fixture.attachment("sel-1", &fixture.png)],
        "binary": "/definitely/not/a/claude-binary"
    }))
    .unwrap_err();
    assert_eq!(
        error,
        RuntimeAdapterError::AttachmentUnsupportedForAdapter {
            agent_label: "claude-code".to_string()
        }
    );
}

#[test]
fn virtual_machine_transport_rejects_attachments_before_launch() {
    let fixture = AttachmentFixture::new();
    let error = send_message(&json!({
        "agent": "openclaw",
        "text": "hello",
        "attachments": [fixture.attachment("sel-1", &fixture.png)],
        "runtimeConnection": {
            "kind": "ssh",
            "host": "guest.example.test",
            "user": "fixture",
            "remoteExecutable": "/usr/bin/openclaw",
            "workingDirectory": "/workspace/project"
        }
    }))
    .unwrap_err();
    assert_eq!(
        error,
        RuntimeAdapterError::AttachmentUnsupportedForAdapter {
            agent_label: "openclaw".to_string()
        }
    );
}

#[test]
fn excessive_attachment_list_is_rejected_before_launch() {
    let fixture = AttachmentFixture::new();
    let attachments = (0..5)
        .map(|index| fixture.attachment(&format!("sel-{index}"), &fixture.png))
        .collect();
    let error = send_message(&codex_params(&fixture, attachments)).unwrap_err();
    assert_eq!(error, RuntimeAdapterError::AttachmentListExceeded);
}

#[test]
fn malformed_attachment_shapes_are_rejected_before_launch() {
    let cases: Vec<(serde_json::Value, RuntimeAdapterError)> = vec![
        (
            json!({"agent": "codex", "text": "hello", "attachments": "not-an-array"}),
            RuntimeAdapterError::AttachmentInvalid,
        ),
        (
            json!({"agent": "codex", "text": "hello", "attachments": [{"id": "1"}]}),
            RuntimeAdapterError::AttachmentInvalid,
        ),
        (
            json!({
                "agent": "codex",
                "text": "hello",
                "attachments": [{
                    "id": "1",
                    "name": "image.png",
                    "mediaType": "image/png",
                    "path": "attachment-fixtures/image.png",
                    "unexpected": true
                }]
            }),
            RuntimeAdapterError::AttachmentInvalid,
        ),
        (
            json!({
                "agent": "codex",
                "text": "hello",
                "attachments": [{
                    "id": "1",
                    "name": "",
                    "mediaType": "image/png",
                    "path": "attachment-fixtures/image.png"
                }]
            }),
            RuntimeAdapterError::AttachmentInvalid,
        ),
        (
            json!({
                "agent": "codex",
                "text": "hello",
                "attachments": [{
                    "id": "1",
                    "name": "image.heic",
                    "mediaType": "image/heic",
                    "path": "attachment-fixtures/image.heic"
                }]
            }),
            RuntimeAdapterError::AttachmentMediaUnsupported,
        ),
        (
            json!({
                "agent": "codex",
                "text": "hello",
                "attachments": [{
                    "id": "1",
                    "name": "image.png",
                    "mediaType": "image/png",
                    "path": "https://example.test/image.png"
                }]
            }),
            RuntimeAdapterError::AttachmentRemoteUnsupported,
        ),
    ];
    for (params, expected) in cases {
        assert_eq!(send_message(&params).unwrap_err(), expected);
    }
}

#[test]
fn symlink_and_non_regular_attachments_are_rejected_before_launch() {
    let fixture = AttachmentFixture::new();
    #[cfg(unix)]
    {
        let link = fixture.directory.join("linked.png");
        std::os::unix::fs::symlink(&fixture.png, &link).unwrap();
        let error = send_message(&json!({
            "agent": "codex",
            "text": "hello",
            "attachments": [fixture.attachment("sel-1", &link)]
        }))
        .unwrap_err();
        assert_eq!(error, RuntimeAdapterError::AttachmentSymlinkRejected);
    }

    let error = send_message(&json!({
        "agent": "codex",
        "text": "hello",
        "attachments": [fixture.attachment("sel-1", &fixture.directory)]
    }))
    .unwrap_err();
    assert_eq!(error, RuntimeAdapterError::AttachmentFileUnavailable);
}

#[test]
fn missing_attachment_file_is_rejected_before_launch() {
    let fixture = AttachmentFixture::new();
    let missing = fixture.directory.join("missing.png");
    let error = send_message(&json!({
        "agent": "codex",
        "text": "hello",
        "attachments": [fixture.attachment("sel-1", &missing)]
    }))
    .unwrap_err();
    assert_eq!(error, RuntimeAdapterError::AttachmentFileUnavailable);
}

#[test]
fn mismatched_signature_is_rejected_before_launch() {
    let fixture = AttachmentFixture::new();
    let wrong = fixture.directory.join("wrong.png");
    fs::write(&wrong, b"not-an-image").unwrap();
    let error = send_message(&json!({
        "agent": "codex",
        "text": "hello",
        "attachments": [fixture.attachment("sel-1", &wrong)]
    }))
    .unwrap_err();
    assert_eq!(error, RuntimeAdapterError::AttachmentSignatureMismatch);
}

#[test]
fn oversized_attachment_file_is_rejected_before_launch() {
    let fixture = AttachmentFixture::new();
    let oversized = fixture.directory.join("oversized.png");
    fs::write(&oversized, [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]).unwrap();
    let file = fs::OpenOptions::new().write(true).open(&oversized).unwrap();
    file.set_len(4 * 1024 * 1024 + 1).unwrap();
    drop(file);
    let error = send_message(&json!({
        "agent": "codex",
        "text": "hello",
        "attachments": [fixture.attachment("sel-1", &oversized)]
    }))
    .unwrap_err();
    assert_eq!(error, RuntimeAdapterError::AttachmentSizeLimit);
}

#[test]
fn attachment_total_byte_budget_is_enforced() {
    use super::super::params::{
        MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE, MAX_IMAGE_ATTACHMENT_BYTES_TOTAL,
    };
    assert_eq!(MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE, 4 * 1024 * 1024);
    assert_eq!(
        MAX_IMAGE_ATTACHMENT_BYTES_TOTAL,
        4 * MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE
    );
}
#[test]
fn adapter_aliases_resolve_to_canonical_ids() {
    assert_eq!(
        adapter_for_agent("claude").map(RuntimeAdapter::id),
        Some("claude-code")
    );
    assert_eq!(
        adapter_for_agent("github-copilot").map(RuntimeAdapter::id),
        Some("copilot")
    );
    assert_eq!(
        adapter_for_agent("kilocode").map(RuntimeAdapter::id),
        Some("kilo-code")
    );
    assert_eq!(
        adapter_for_agent("cursor-agent").map(RuntimeAdapter::id),
        Some("cursor")
    );
}

#[test]
fn message_body_is_not_normalized() {
    let body = "\n  indented code  \n";
    assert_eq!(
        message_param(&json!({"text": body}), &["text"]),
        Some(body.to_string())
    );
}

#[test]
fn oversized_message_is_rejected_before_runtime_launch() {
    let oversized = "x".repeat(MAX_MESSAGE_BYTES + 1);
    let error = send_message(&json!({
        "agent": "codex",
        "text": oversized,
        "binaryPath": "/runtime/must-not-launch"
    }))
    .unwrap_err();

    assert_eq!(
        error.to_string(),
        "agent message request exceeds the input limit"
    );
}

#[test]
fn configured_command_fallback_has_been_removed() {
    let error = send_message(&json!({
        "agent": "claude-code",
        "text": "private prompt",
        "binary": "/definitely/not/a/claude-binary",
        "command": "/bin/echo",
        "args": ["{prompt}"]
    }))
    .unwrap_err();

    assert_eq!(error.to_string(), "native agent executable is unavailable");
}

/// Every driver reads its working directory from the request, so the resolved
/// workspace has to replace the requested one under both keys.
#[test]
fn a_local_turn_republishes_only_the_resolved_workspace() {
    let resolved = params_with_workspace(
        &json!({
            "agent": "cursor",
            "text": "hello",
            "cwd": "/fixture-root/resident",
            "workingDirectory": "/fixture-root/resident"
        }),
        Path::new("/synthetic/state/agent-workspace"),
    );

    assert_eq!(resolved["cwd"], "/synthetic/state/agent-workspace");
    assert_eq!(
        resolved["workingDirectory"],
        "/synthetic/state/agent-workspace"
    );
    assert_eq!(resolved["text"], "hello");
}

#[test]
fn unknown_runtime_adapter_is_rejected() {
    let error = send_message(&json!({"agent": "unknown", "text": "hello"})).unwrap_err();
    assert!(error.to_string().contains("unsupported runtime adapter"));
}
