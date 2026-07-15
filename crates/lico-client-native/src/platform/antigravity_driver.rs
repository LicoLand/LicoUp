use super::process_supervisor::{IO_THREAD_EXIT_GRACE, SupervisedChild, join_bounded};
use serde_json::Value;
use std::io::{self, Read};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// No CLI message transport is claimed here. Google's public `agy` contract
/// currently accepts non-interactive prompts and exact conversation IDs only as
/// process arguments, while its stdin surface is an interactive TUI rather than
/// a structured protocol. Neither surface preserves Lico Arc's requirement that
/// message text and native conversation identifiers stay out of argv while
/// returning typed incremental events.
///
/// Google also publishes an Antigravity Python SDK with a separate bundled
/// `localharness`, typed streams, resumable SDK conversation IDs, cancellation,
/// and cleanup. That SDK is a distinct distribution, authentication boundary,
/// storage root, and conversation domain; there is no public contract proving
/// that it can attach an existing `agy` CLI conversation. It therefore belongs
/// in a separately identified adapter and must never be used as a silent CLI
/// fallback.
pub(super) const RUNTIME_PROTOCOL: &str = "antigravity-cli-structured-transport-unavailable";

const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(25);
const TRANSPORT_BLOCKER_CODE: &str = "antigravity_cli_structured_transport_unavailable";

#[derive(Clone, Debug, Default)]
pub(super) struct EffectiveSettings {
    pub(super) cwd: Option<String>,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) permission_mode: Option<String>,
    pub(super) sandbox: Option<Value>,
    pub(super) approval_policy: Option<Value>,
}

#[derive(Clone, Debug)]
pub(super) struct ProtocolFailure {
    pub(super) code: &'static str,
    pub(super) message: &'static str,
    pub(super) stage: &'static str,
    pub(super) user_interaction_required: bool,
    pub(super) request_method: Option<String>,
    pub(super) session_id: Option<String>,
    pub(super) thread_id: Option<String>,
    pub(super) turn_id: Option<String>,
    pub(super) turn_status: Option<String>,
}

impl ProtocolFailure {
    fn new(code: &'static str, message: &'static str, stage: &'static str) -> Self {
        Self {
            code,
            message,
            stage,
            user_interaction_required: false,
            request_method: None,
            session_id: None,
            thread_id: None,
            turn_id: None,
            turn_status: None,
        }
    }

    fn with_session(mut self, session_id: &str) -> Self {
        let session_id = session_id.trim();
        if !session_id.is_empty() {
            self.session_id = Some(session_id.to_string());
            self.thread_id = self.session_id.clone();
        }
        self
    }

    fn public_transport_unavailable(session_id: &str) -> Self {
        let (code, message, stage) = if session_id.trim().is_empty() {
            (
                TRANSPORT_BLOCKER_CODE,
                "Antigravity CLI does not expose a structured conversation transport that keeps messages outside process arguments.",
                "capability/transport",
            )
        } else {
            (
                "antigravity_cli_secure_resume_unavailable",
                "Antigravity CLI does not expose a structured resume transport that keeps the native conversation identifier and message outside process arguments.",
                "session/resume",
            )
        };
        Self::new(code, message, stage).with_session(session_id)
    }
}

#[derive(Debug)]
pub(super) struct RunResult {
    pub(super) ok: bool,
    pub(super) output: String,
    pub(super) error: Option<ProtocolFailure>,
    pub(super) session_id: String,
    pub(super) thread_id: String,
    pub(super) turn_id: String,
    pub(super) turn_status: String,
    pub(super) effective: EffectiveSettings,
    pub(super) status_code: Option<i32>,
    pub(super) stdout_truncated: bool,
    pub(super) stderr_truncated: bool,
    pub(super) started_at: String,
}

impl RunResult {
    fn failed(failure: ProtocolFailure, started_at: String) -> Self {
        Self {
            ok: false,
            output: String::new(),
            session_id: failure.session_id.clone().unwrap_or_default(),
            thread_id: failure.thread_id.clone().unwrap_or_default(),
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            error: Some(failure),
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at,
        }
    }
}

/// Privacy-safe availability and parity probe.
///
/// `available` only means that an executable answered one of the two fixed,
/// non-sensitive probe commands. `supported` remains false until the CLI ships
/// a structured transport that can carry prompt, cwd, and native conversation
/// ID without argv. Availability of the separate SDK cannot promote this CLI
/// adapter.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct CapabilityProbe {
    pub(super) available: bool,
    pub(super) supported: bool,
    pub(super) version_command_ok: bool,
    pub(super) help_command_ok: bool,
    pub(super) stdin_prompt: bool,
    pub(super) structured_stream: bool,
    pub(super) new_session: bool,
    pub(super) resume_session: bool,
    pub(super) model: bool,
    pub(super) reasoning_effort: bool,
    pub(super) permission_mode: bool,
    pub(super) interactive_approval_events: bool,
    pub(super) error_code: Option<&'static str>,
}

impl CapabilityProbe {
    fn unavailable() -> Self {
        Self {
            available: false,
            supported: false,
            version_command_ok: false,
            help_command_ok: false,
            stdin_prompt: false,
            structured_stream: false,
            new_session: false,
            resume_session: false,
            model: false,
            reasoning_effort: false,
            permission_mode: false,
            interactive_approval_events: false,
            error_code: Some("antigravity_executable_unavailable"),
        }
    }

    fn installed(version_command_ok: bool, help_command_ok: bool) -> Self {
        Self {
            available: true,
            supported: false,
            version_command_ok,
            help_command_ok,
            stdin_prompt: false,
            structured_stream: false,
            new_session: false,
            resume_session: false,
            model: false,
            reasoning_effort: false,
            permission_mode: false,
            interactive_approval_events: false,
            error_code: Some(TRANSPORT_BLOCKER_CODE),
        }
    }
}

/// Detects the installed public CLI without printing or retaining command
/// output. The only argv values are the fixed `--version` and `--help` flags.
pub(super) fn probe(executable: &str, timeout_ms: u64, _max_output: usize) -> CapabilityProbe {
    let version_command_ok = run_probe_command(executable, ProbeArgument::Version, timeout_ms);
    let help_command_ok = run_probe_command(executable, ProbeArgument::Help, timeout_ms);
    if version_command_ok.is_none() && help_command_ok.is_none() {
        CapabilityProbe::unavailable()
    } else {
        CapabilityProbe::installed(
            version_command_ok == Some(true),
            help_command_ok == Some(true),
        )
    }
}

/// Fails before process creation. The documented `agy --print` and
/// `agy --conversation` contracts require prompt or conversation data in argv;
/// TUI key injection, private protocols, and the separate SDK conversation
/// domain are deliberately not treated as CLI transports.
#[allow(clippy::too_many_arguments)]
pub(super) fn execute(
    _executable: &str,
    _params: &Value,
    prompt: &str,
    session_id: &str,
    _cwd: Option<&Path>,
    _timeout_ms: u64,
    _max_stdout: usize,
    _max_stderr: usize,
) -> RunResult {
    let started_at = timestamp();
    if prompt.trim().is_empty() {
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_empty_prompt",
                "Antigravity requires a non-empty message.",
                "request/validate",
            )
            .with_session(session_id),
            started_at,
        );
    }
    RunResult::failed(
        ProtocolFailure::public_transport_unavailable(session_id),
        started_at,
    )
}

#[derive(Clone, Copy)]
enum ProbeArgument {
    Version,
    Help,
}

impl ProbeArgument {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Version => "--version",
            Self::Help => "--help",
        }
    }
}

fn run_probe_command(executable: &str, argument: ProbeArgument, timeout_ms: u64) -> Option<bool> {
    let mut command = Command::new(executable);
    command
        .arg(argument.as_str())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = SupervisedChild::spawn(&mut command).ok()?;
    let Some(mut stdout) = child.stdout() else {
        child.terminate_tree().ok()?;
        return None;
    };
    let stdout_handle = thread::spawn(move || {
        let mut buffer = [0_u8; 256];
        loop {
            match stdout.read(&mut buffer) {
                Ok(0) => return true,
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return false,
            }
        }
    });
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    while !stdout_handle.is_finished() && Instant::now() < deadline {
        thread::sleep(
            PROCESS_POLL_INTERVAL.min(deadline.saturating_duration_since(Instant::now())),
        );
    }
    let timed_out = !stdout_handle.is_finished();
    let status = child.terminate_tree().ok()?;
    let stdout_ok = join_bounded(stdout_handle, IO_THREAD_EXIT_GRACE).ok()?;
    Some(!timed_out && status.is_some_and(|value| value.success()) && stdout_ok)
}

fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn missing_executable_is_unavailable_and_never_supported() {
        let capability = probe("lico-antigravity-driver-definitely-not-installed", 50, 1024);
        assert!(!capability.available);
        assert!(!capability.supported);
        assert_eq!(
            capability.error_code,
            Some("antigravity_executable_unavailable")
        );
        assert!(!capability.stdin_prompt);
        assert!(!capability.structured_stream);
    }

    #[test]
    fn new_and_resumed_messages_return_specific_structured_blockers() {
        let fresh = execute(
            "agy",
            &json!({}),
            "private message",
            "",
            Some(Path::new("/workspace/private-project")),
            1_000,
            1_024,
            1_024,
        );
        assert!(!fresh.ok);
        let fresh_error = fresh.error.unwrap();
        assert_eq!(fresh_error.code, TRANSPORT_BLOCKER_CODE);
        assert_eq!(fresh_error.stage, "capability/transport");
        assert!(!fresh_error.user_interaction_required);

        let resumed = execute(
            "agy",
            &json!({}),
            "private follow-up",
            "native-conversation-id",
            Some(Path::new("/workspace/private-project")),
            1_000,
            1_024,
            1_024,
        );
        assert!(!resumed.ok);
        let resumed_error = resumed.error.unwrap();
        assert_eq!(
            resumed_error.code,
            "antigravity_cli_secure_resume_unavailable"
        );
        assert_eq!(resumed_error.stage, "session/resume");
        assert_eq!(
            resumed_error.session_id.as_deref(),
            Some("native-conversation-id")
        );
        assert_eq!(resumed_error.thread_id, resumed_error.session_id);
    }

    #[test]
    fn blocker_messages_never_echo_request_data() {
        let prompt = "message-secret-sentinel";
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
        let message = result.error.unwrap().message;
        assert!(!message.contains(prompt));
        assert!(!message.contains(cwd));
        assert!(!message.contains(session_id));
    }

    #[cfg(unix)]
    #[test]
    fn execute_never_starts_an_argv_based_transport() {
        let fixture = FakeExecutable::new("execute");
        let result = execute(
            fixture.executable.to_string_lossy().as_ref(),
            &json!({"model": "model-secret-sentinel"}),
            "prompt-secret-sentinel",
            "conversation-secret-sentinel",
            Some(Path::new("/workspace/cwd-secret-sentinel")),
            1_000,
            1_024,
            1_024,
        );
        assert!(!result.ok);
        assert!(!fixture.invocations.exists());
    }

    #[cfg(unix)]
    #[test]
    fn probe_uses_only_fixed_non_sensitive_arguments() {
        let fixture = FakeExecutable::new("probe");
        // Process-group startup can be delayed on a saturated CI host. Keep
        // the probe bounded while avoiding a scheduler-dependent false
        // negative for this immediate fixed-argv fixture.
        let capability = probe(fixture.executable.to_string_lossy().as_ref(), 5_000, 1_024);
        assert!(capability.available);
        assert!(!capability.supported);
        assert!(capability.version_command_ok);
        assert!(capability.help_command_ok);
        assert_eq!(capability.error_code, Some(TRANSPORT_BLOCKER_CODE));
        assert_eq!(
            fs::read_to_string(&fixture.invocations).unwrap(),
            "--version\n--help\n"
        );
    }

    #[cfg(unix)]
    struct FakeExecutable {
        root: PathBuf,
        executable: PathBuf,
        invocations: PathBuf,
    }

    #[cfg(unix)]
    impl FakeExecutable {
        fn new(label: &str) -> Self {
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
            let invocations = root.join("invocations");
            let script = format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '{}'\nexit 0\n",
                invocations.display()
            );
            fs::write(&executable, script).unwrap();
            let mut permissions = fs::metadata(&executable).unwrap().permissions();
            permissions.set_mode(0o700);
            fs::set_permissions(&executable, permissions).unwrap();
            Self {
                root,
                executable,
                invocations,
            }
        }
    }

    #[cfg(unix)]
    impl Drop for FakeExecutable {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}
