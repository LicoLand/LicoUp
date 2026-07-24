//! Deterministic governed ConversationLane adapter for synthetic acceptance.
//! It supplies downstream effects only and never stores policy or workflow state.

use crate::domain::agent_orchestration::{DispatchOutcome, DispatchPort, DispatchRequest};
use sha2::{Digest, Sha256};
use std::sync::{Arc, LazyLock, Mutex};

static REGISTRATION: LazyLock<Mutex<Option<Registration>>> = LazyLock::new(|| Mutex::new(None));

#[derive(Clone)]
struct Registration {
    agent_id: String,
    model_id: String,
}

pub struct DeterministicGovernedDispatchRegistration;

impl DeterministicGovernedDispatchRegistration {
    pub fn install(agent_id: &str, model_id: &str) -> Result<Self, &'static str> {
        if !valid_id(agent_id) || !valid_id(model_id) {
            return Err("invalid_test_registration");
        }
        let mut registration = REGISTRATION
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if registration.is_some() {
            return Err("test_registration_exists");
        }
        *registration = Some(Registration {
            agent_id: agent_id.into(),
            model_id: model_id.into(),
        });
        Ok(Self)
    }
}

impl Drop for DeterministicGovernedDispatchRegistration {
    fn drop(&mut self) {
        *REGISTRATION
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = None;
    }
}

pub(super) fn registered_dispatch_port() -> Option<Arc<dyn DispatchPort>> {
    REGISTRATION
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .as_ref()?;
    Some(Arc::new(DeterministicConversationLane))
}

pub(super) fn adapter_decision() -> &'static str {
    if REGISTRATION
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .is_some()
    {
        "acp"
    } else {
        "unavailable"
    }
}

struct DeterministicConversationLane;
impl DispatchPort for DeterministicConversationLane {
    fn dispatch(&self, request: DispatchRequest) -> DispatchOutcome {
        let registration = REGISTRATION
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone();
        let Some(registration) = registration else {
            return DispatchOutcome::KnownFailure {
                reason_code: "test_registration_absent".into(),
                retryable: false,
            };
        };
        if request.agent_id.as_deref() != Some(registration.agent_id.as_str())
            || request.model_id.as_deref() != Some(registration.model_id.as_str())
        {
            return DispatchOutcome::KnownFailure {
                reason_code: "target_not_registered".into(),
                retryable: false,
            };
        }
        let digest = format!(
            "{:x}",
            Sha256::digest(format!("{}:{}", request.workflow_id, request.step_id))
        );
        DispatchOutcome::Succeeded {
            summary: "synthetic governed completion".into(),
            digest,
        }
    }
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}
