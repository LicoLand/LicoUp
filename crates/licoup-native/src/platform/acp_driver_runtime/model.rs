use super::errors::ProtocolFailure;
use crate::core::acp;
use serde_json::Value;
use std::time::Duration;

pub(super) const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) struct AcpDriverSpec {
    pub(in crate::platform) agent_id: &'static str,
    pub(in crate::platform) error_prefix: &'static str,
    pub(in crate::platform) runtime_protocol: &'static str,
    pub(in crate::platform) launch_args: &'static [&'static str],
    pub(in crate::platform) launch_model_arg: Option<&'static str>,
    pub(in crate::platform) launch_reasoning_env: Option<&'static str>,
    pub(in crate::platform) launch_reasoning_values: &'static [&'static str],
    pub(in crate::platform) launch_allow_all_arg: Option<&'static str>,
}

impl AcpDriverSpec {
    pub(in crate::platform) const fn new(
        runtime_protocol: &'static str,
        launch_args: &'static [&'static str],
    ) -> Self {
        Self {
            agent_id: "acp",
            error_prefix: "acp",
            runtime_protocol,
            launch_args,
            launch_model_arg: None,
            launch_reasoning_env: None,
            launch_reasoning_values: &[],
            launch_allow_all_arg: None,
        }
    }

    pub(in crate::platform) const fn with_identity(
        mut self,
        agent_id: &'static str,
        error_prefix: &'static str,
    ) -> Self {
        self.agent_id = agent_id;
        self.error_prefix = error_prefix;
        self
    }

    pub(in crate::platform) const fn with_launch_settings(
        mut self,
        model_arg: &'static str,
        reasoning_env: &'static str,
        reasoning_values: &'static [&'static str],
    ) -> Self {
        self.launch_model_arg = Some(model_arg);
        self.launch_reasoning_env = Some(reasoning_env);
        self.launch_reasoning_values = reasoning_values;
        self
    }

    pub(in crate::platform) const fn with_allow_all_argument(
        mut self,
        allow_all_arg: &'static str,
    ) -> Self {
        self.launch_allow_all_arg = Some(allow_all_arg);
        self
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(in crate::platform) struct CapabilityProbe {
    pub(in crate::platform) protocol_version: Option<u64>,
    pub(in crate::platform) load_session: bool,
    pub(in crate::platform) resume_session: bool,
    pub(in crate::platform) close_session: bool,
    pub(in crate::platform) list_sessions: bool,
    pub(in crate::platform) delete_session: bool,
    pub(in crate::platform) additional_directories: bool,
    pub(in crate::platform) image_prompts: bool,
    pub(in crate::platform) audio_prompts: bool,
    pub(in crate::platform) embedded_context: bool,
}

impl CapabilityProbe {
    pub(super) fn from_initialize(response: &acp::AcpInitializeResponse) -> Self {
        let capabilities = &response.capabilities;
        Self {
            protocol_version: Some(u64::from(response.protocol_version)),
            load_session: capabilities.load_session,
            resume_session: capabilities.resume_session,
            close_session: capabilities.close_session,
            list_sessions: capabilities.list_sessions,
            delete_session: capabilities.delete_session,
            additional_directories: capabilities.additional_directories,
            image_prompts: capabilities.image_prompts,
            audio_prompts: capabilities.audio_prompts,
            embedded_context: capabilities.embedded_context,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(in crate::platform) struct EffectiveSettings {
    pub(in crate::platform) cwd: Option<String>,
    pub(in crate::platform) model: Option<String>,
    pub(in crate::platform) reasoning_effort: Option<String>,
    pub(in crate::platform) mode: Option<String>,
    pub(in crate::platform) runtime_agent: Option<String>,
    pub(in crate::platform) allow_all: Option<bool>,
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
    pub(in crate::platform) capabilities: CapabilityProbe,
    pub(in crate::platform) status_code: Option<i32>,
    pub(in crate::platform) stdout_truncated: bool,
    pub(in crate::platform) stderr_truncated: bool,
    pub(in crate::platform) started_at: String,
    pub(in crate::platform) runtime_protocol: &'static str,
    pub(in crate::platform) driver_id: &'static str,
}

impl RunResult {
    pub(in crate::platform) fn failed(
        driver: AcpDriverSpec,
        failure: ProtocolFailure,
        started_at: String,
        status_code: Option<i32>,
        stdout_truncated: bool,
        stderr_truncated: bool,
        capabilities: CapabilityProbe,
        events: Vec<Value>,
    ) -> Self {
        let failure = failure.namespaced(driver);
        Self {
            ok: false,
            output: String::new(),
            session_id: failure.session_id.clone().unwrap_or_default(),
            thread_id: failure.thread_id.clone().unwrap_or_default(),
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            error: Some(failure),
            status_code,
            stdout_truncated,
            stderr_truncated,
            started_at,
            runtime_protocol: driver.runtime_protocol,
            driver_id: driver.agent_id,
            capabilities,
            events,
        }
    }
}
