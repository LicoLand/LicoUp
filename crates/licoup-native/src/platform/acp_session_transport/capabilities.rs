use super::errors::ProtocolFailure;
use serde_json::Value;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub(in crate::platform) const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
pub(super) const CONTROL_ACK_TIMEOUT: Duration = Duration::from_secs(1);
pub(in crate::platform) const CONTROL_QUEUE_CAPACITY: usize = 4;
pub(in crate::platform) const MAX_POOLED_TRANSPORTS: usize = 8;
pub(in crate::platform) const MAX_TRACKED_SESSIONS: usize = 1024;
pub(in crate::platform) const MAX_PARKED_PERMISSIONS: usize = 32;
pub(in crate::platform) const APPROVAL_WAIT_TIMEOUT: Duration = Duration::from_secs(300);
pub(in crate::platform) const APPROVAL_POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(in crate::platform) struct AcpSessionDriverSpec {
    pub(in crate::platform) driver_id: &'static str,
    pub(in crate::platform) runtime_id: &'static str,
    pub(in crate::platform) launch_args: &'static [&'static str],
}

impl AcpSessionDriverSpec {
    pub(in crate::platform) const fn new(
        driver_id: &'static str,
        launch_args: &'static [&'static str],
    ) -> Self {
        Self {
            driver_id,
            runtime_id: driver_id,
            launch_args,
        }
    }

    pub(in crate::platform) const fn with_runtime_id(mut self, runtime_id: &'static str) -> Self {
        self.runtime_id = runtime_id;
        self
    }
}

#[derive(Clone, Debug, Default)]
pub(in crate::platform) struct EffectiveSettings {
    pub(in crate::platform) cwd: Option<String>,
    pub(in crate::platform) model: Option<String>,
    pub(in crate::platform) reasoning_effort: Option<String>,
    pub(in crate::platform) sandbox: Option<Value>,
    pub(in crate::platform) approval_policy: Option<Value>,
}

#[derive(Debug)]
pub(in crate::platform) struct RunResult {
    pub(in crate::platform) ok: bool,
    pub(in crate::platform) output: String,
    pub(in crate::platform) events: Vec<Value>,
    pub(in crate::platform) error: Option<ProtocolFailure>,
    pub(in crate::platform) session_id: String,
    pub(in crate::platform) thread_id: String,
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) turn_status: String,
    pub(in crate::platform) effective: EffectiveSettings,
    pub(in crate::platform) status_code: Option<i32>,
    pub(in crate::platform) stdout_truncated: bool,
    pub(in crate::platform) stderr_truncated: bool,
    pub(in crate::platform) started_at: String,
}

impl RunResult {
    pub(super) fn failed(
        failure: ProtocolFailure,
        started_at: String,
        status_code: Option<i32>,
        stdout_truncated: bool,
        stderr_truncated: bool,
    ) -> Self {
        let session_id = failure.session_id.clone().unwrap_or_default();
        Self {
            ok: false,
            output: String::new(),
            events: Vec::new(),
            error: Some(failure.clone()),
            thread_id: session_id.clone(),
            session_id,
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            status_code,
            stdout_truncated,
            stderr_truncated,
            started_at,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(in crate::platform) struct CapabilityProbe {
    pub(in crate::platform) available: bool,
    pub(in crate::platform) supported: bool,
    pub(in crate::platform) version: Option<String>,
    pub(in crate::platform) error_code: Option<&'static str>,
    pub(in crate::platform) supports_streaming: bool,
    pub(in crate::platform) supports_tools: bool,
    pub(in crate::platform) supports_approvals: bool,
    pub(in crate::platform) supports_model_override: bool,
    pub(in crate::platform) supports_reasoning_override: bool,
}

pub(super) fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
