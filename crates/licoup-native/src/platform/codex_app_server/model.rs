use serde_json::Value;

#[derive(Clone, Debug, Default)]
pub(in crate::platform) struct EffectiveSettings {
    pub(in crate::platform) cwd: Option<String>,
    pub(in crate::platform) model: Option<String>,
    pub(in crate::platform) reasoning_effort: Option<String>,
    pub(in crate::platform) sandbox: Option<Value>,
    pub(in crate::platform) approval_policy: Option<Value>,
}

#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolFailure(Box<ProtocolFailurePayload>);

#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolFailurePayload {
    pub(in crate::platform) code: &'static str,
    pub(in crate::platform) message: &'static str,
    pub(in crate::platform) stage: &'static str,
    pub(in crate::platform) component: Option<&'static str>,
    pub(in crate::platform) retryable: Option<bool>,
    pub(in crate::platform) recovery: Option<&'static str>,
    pub(in crate::platform) user_interaction_required: bool,
    pub(in crate::platform) request_method: Option<String>,
    pub(in crate::platform) session_id: Option<String>,
    pub(in crate::platform) thread_id: Option<String>,
    pub(in crate::platform) turn_id: Option<String>,
    pub(in crate::platform) turn_status: Option<String>,
}

impl ProtocolFailure {
    pub(in crate::platform) fn into_payload(self) -> ProtocolFailurePayload {
        *self.0
    }

    pub(super) fn from_payload(payload: ProtocolFailurePayload) -> Self {
        Self(Box::new(payload))
    }
}

impl std::ops::Deref for ProtocolFailure {
    type Target = ProtocolFailurePayload;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for ProtocolFailure {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

#[derive(Debug)]
pub(in crate::platform) struct RunResult {
    pub(in crate::platform) ok: bool,
    pub(in crate::platform) output: String,
    pub(in crate::platform) transitions: Vec<crate::platform::native_agent_parser::Transition>,
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

#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolOutcome {
    pub(in crate::platform) output: String,
    pub(in crate::platform) session_id: String,
    pub(in crate::platform) thread_id: String,
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) turn_status: String,
    pub(in crate::platform) effective: EffectiveSettings,
}

#[derive(Debug)]
pub(in crate::platform) enum ProtocolEffect {
    Send(Value),
    Complete(Box<ProtocolOutcome>),
    Fail(ProtocolFailure),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ProtocolPhase {
    AwaitInitialize,
    AwaitThread,
    AwaitThreadUnarchive,
    AwaitTurnStart,
    AwaitTurnCompleted,
    Finished,
}
