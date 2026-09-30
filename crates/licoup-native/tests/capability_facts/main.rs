//! Public-entry evidence for Agent capability facts.
//!
//! Every case runs through the conversation dispatch entry from outside the
//! crate, so it proves the refusal a client actually meets: an image action an
//! Agent's own owner does not declare is refused before any driver runs, a
//! Profile requirement no declared fact satisfies names the fact it could not
//! satisfy, and the arranged text and native session identity stay unchanged.
//! The projection's three states are asserted in the crate's own test module,
//! which is where the projection is reachable.

use licoup_native::domain::target_port::agent_target_port;
use licoup_native::platform::runtime_adapters::{RuntimeAdapterError, send_message};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// One synthetic image and one synthetic executable that records its launch.
struct DispatchFixture {
    directory: PathBuf,
    png: PathBuf,
}

impl DispatchFixture {
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
        let directory = std::env::temp_dir().join(format!("lico-capability-facts-{suffix}"));
        fs::create_dir_all(&directory).unwrap();
        let png = directory.join("synthetic.png");
        fs::write(
            &png,
            [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0],
        )
        .unwrap();
        Self { directory, png }
    }

    fn attachment(&self) -> Value {
        json!({
            "id": "sel-1",
            "name": "synthetic.png",
            "mediaType": "image/png",
            "path": self.png.to_string_lossy(),
        })
    }

    /// A synthetic driver that records its own launch and its own arguments.
    fn recording_executable(&self, name: &str) -> (PathBuf, PathBuf) {
        let marker = self.directory.join(format!("{name}.launched"));
        let capture = self.directory.join(format!("{name}.argv"));
        let binary = self.directory.join(name);
        let body = format!(
            "#!/bin/sh\ntouch {}\nfor argument in \"$@\"; do printf '%s\\0' \"$argument\"; done > {}\n",
            marker.display(),
            capture.display()
        );
        fs::write(&binary, body).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&binary).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&binary, permissions).unwrap();
        }
        (binary, marker)
    }
}

impl Drop for DispatchFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

fn recorded_arguments(capture: &Path) -> Vec<String> {
    fs::read(capture)
        .expect("the driver must have been launched")
        .split(|byte| *byte == 0)
        .filter(|argument| !argument.is_empty())
        .map(|argument| String::from_utf8_lossy(argument).into_owned())
        .collect()
}

#[cfg(unix)]
#[test]
fn an_image_action_the_agent_does_not_declare_is_refused_before_any_launch() {
    let fixture = DispatchFixture::new();
    let (binary, marker) = fixture.recording_executable("claude");
    let text = "  exact synthetic prompt  \n";
    let params = json!({
        "agent": "claude-code",
        "text": text,
        "sessionId": "native-session:exact-1",
        "binary": binary.to_string_lossy(),
        "attachments": [fixture.attachment()],
    });
    let arranged = serde_json::to_string(&params).unwrap();

    let error = send_message(&agent_target_port(), &params).unwrap_err();
    assert_eq!(
        error,
        RuntimeAdapterError::AttachmentUnsupportedForAdapter {
            agent_label: "claude-code".to_owned()
        }
    );
    assert!(
        !marker.exists(),
        "an undeclared image action must not launch a driver"
    );
    assert_eq!(
        serde_json::to_string(&params).unwrap(),
        arranged,
        "the refusal must not rewrite the request"
    );
    assert_eq!(params["text"], json!(text));
    assert_eq!(params["sessionId"], json!("native-session:exact-1"));
}

#[cfg(unix)]
#[test]
fn an_unsatisfied_requirement_names_the_fact_before_any_launch() {
    let fixture = DispatchFixture::new();
    let (binary, marker) = fixture.recording_executable("claude");
    let params = json!({
        "agent": "claude-code",
        "text": "  exact synthetic prompt  \n",
        "sessionId": "native-session:exact-1",
        "binary": binary.to_string_lossy(),
        "requiredCapabilities": ["image-input"],
    });
    let arranged = serde_json::to_string(&params).unwrap();

    let error = send_message(&agent_target_port(), &params).unwrap_err();
    assert_eq!(
        error,
        RuntimeAdapterError::CapabilityRequirementUnsatisfied {
            capability: "image-input".to_owned()
        }
    );
    assert!(
        !marker.exists(),
        "an unsatisfied requirement must not launch a driver"
    );
    assert_eq!(serde_json::to_string(&params).unwrap(), arranged);
}

#[test]
fn a_declared_requirement_admits_the_turn_over_the_public_entry() {
    // Codex's own owner declares image input and conversation support, so the
    // requirement is satisfied and the turn proceeds to executable resolution.
    let error = send_message(&agent_target_port(), &json!({
        "agent": "codex",
        "text": "hello",
        "requiredCapabilities": ["image-input", "conversationDriver:supported"],
        "binaryPath": "/runtime/must-not-launch",
    }))
    .unwrap_err();
    assert_eq!(error, RuntimeAdapterError::ExecutableUnavailable);

    // The identical requirement on an Agent that does not declare the fact is
    // refused by name instead of being attempted.
    let error = send_message(&agent_target_port(), &json!({
        "agent": "claude-code",
        "text": "hello",
        "requiredCapabilities": ["image-input"],
        "binary": "/runtime/must-not-launch",
    }))
    .unwrap_err();
    assert_eq!(
        error,
        RuntimeAdapterError::CapabilityRequirementUnsatisfied {
            capability: "image-input".to_owned()
        }
    );
}

#[cfg(unix)]
#[test]
fn an_admitted_turn_dispatches_the_arranged_text_and_native_identity() {
    let fixture = DispatchFixture::new();
    let (binary, _) = fixture.recording_executable("cursor-agent");
    let capture = fixture.directory.join("cursor-agent.argv");
    let text = "  exact synthetic prompt  \n";
    let session = "native-session:exact-1";
    let _ = send_message(&agent_target_port(), &json!({
        "agent": "cursor",
        "text": text,
        "sessionId": session,
        "binary": binary.to_string_lossy(),
        "cwd": fixture.directory.to_string_lossy(),
        "timeoutMs": 5_000,
    }));

    let arguments = recorded_arguments(&capture);
    assert!(
        arguments.iter().any(|argument| argument == text),
        "the dispatched text must match the arranged text byte for byte: {arguments:?}"
    );
    assert!(
        arguments.iter().any(|argument| argument == session),
        "the bound native session identity must be dispatched unchanged: {arguments:?}"
    );
}
