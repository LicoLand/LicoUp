//! Production DispatchPort over the governed Conversation Lane.
//!
//! Resolves private submit input and forwards through the shared conversation
//! lane. The selected adapter reports the exact execution-stage failure.

use crate::domain::agent_orchestration::{
    DispatchOutcome, DispatchPort, DispatchRequest, StepPurpose,
};
use crate::platform::conversation_lane;
use crate::platform::turn_event_emit::{StreamSinkGuard, install_stream_sink};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::sync::Arc;

use super::artifact_store::PrivateArtifactStore;
use super::local_bridge::{LocalBridge, NativeTurnBinding};

pub struct GovernedDispatchPort {
    artifacts: Arc<PrivateArtifactStore>,
    bridge: Arc<LocalBridge>,
}

impl GovernedDispatchPort {
    pub fn new(artifacts: Arc<PrivateArtifactStore>, bridge: Arc<LocalBridge>) -> Self {
        Self { artifacts, bridge }
    }
}

pub fn native_steer_supported(agent_id: &str) -> bool {
    conversation_lane::native_steer_supported(agent_id)
}

pub fn native_interrupt_supported(agent_id: &str) -> bool {
    conversation_lane::native_interrupt_supported(agent_id)
}

pub fn steer_active_turn(binding: &NativeTurnBinding, text: &str) -> bool {
    accepted_control("steer", binding, Some(text))
}

pub fn interrupt_active_turn(binding: &NativeTurnBinding) -> bool {
    accepted_control("cancel", binding, None)
}

fn accepted_control(operation: &str, binding: &NativeTurnBinding, text: Option<&str>) -> bool {
    let mut params = json!({
        "agentId": binding.agent_id,
        "sessionId": binding.session_id,
    });
    if !binding.turn_id.is_empty() {
        params["turnId"] = json!(binding.turn_id);
    }
    if let Some(text) = text {
        params["text"] = json!(text);
    }
    conversation_lane::dispatch_lane_operation(operation, &params)
        .ok()
        .and_then(|value| value.get("ok").and_then(serde_json::Value::as_bool))
        == Some(true)
}

impl DispatchPort for GovernedDispatchPort {
    fn dispatch(&self, request: DispatchRequest) -> DispatchOutcome {
        let Some(agent_id) = request
            .agent_id
            .as_deref()
            .filter(|value| !value.is_empty())
        else {
            return DispatchOutcome::KnownFailure {
                reason_code: "target_unspecified".into(),
                retryable: false,
            };
        };
        let Some(input) = request.input_artifact.as_ref() else {
            return DispatchOutcome::KnownFailure {
                reason_code: "input_artifact_unavailable".into(),
                retryable: false,
            };
        };
        let bytes = match self
            .artifacts
            .read_verified(&input.opaque_handle, &input.digest)
        {
            Ok(bytes) => bytes,
            Err(_) => {
                return DispatchOutcome::KnownFailure {
                    reason_code: "input_artifact_unavailable".into(),
                    retryable: false,
                };
            }
        };
        let Ok(text) = String::from_utf8(bytes) else {
            return DispatchOutcome::KnownFailure {
                reason_code: "input_artifact_invalid".into(),
                retryable: false,
            };
        };
        if text.trim().is_empty() {
            return DispatchOutcome::KnownFailure {
                reason_code: "input_artifact_empty".into(),
                retryable: false,
            };
        }
        let mut params = json!({
            "agentId": agent_id,
            "text": text,
            "predecessorArtifactCount": request.predecessor_artifacts.len(),
        });
        if let Some(model_id) = request
            .model_id
            .as_deref()
            .filter(|value| !value.is_empty())
        {
            params["model"] = json!(model_id);
        }
        self.bridge
            .begin_dispatch(&request.workflow_id, &request.step_id, agent_id);
        let bridge = Arc::clone(&self.bridge);
        let workflow_id = request.workflow_id.clone();
        install_stream_sink(Box::new(move |event| {
            bridge.observe_driver_event(&workflow_id, &event);
        }));
        let _sink_guard = StreamSinkGuard;

        let mut value = match conversation_lane::dispatch_lane_operation("send", &params) {
            Ok(value) => value,
            Err(_) => {
                self.bridge.close_dispatch(&request.workflow_id, "unknown");
                return DispatchOutcome::Unknown {
                    reason_code: "adapter_outcome_unknown".into(),
                };
            }
        };
        loop {
            self.bridge
                .observe_turn_result(&request.workflow_id, &value);
            let prior_turn_succeeded =
                value.get("ok").and_then(|value| value.as_bool()) == Some(true);
            let Some(message) = self
                .bridge
                .next_follow_up_or_close(&request.workflow_id, prior_turn_succeeded)
            else {
                return map_lane_result(&request, &value);
            };
            let message_id = message.message_id.clone();
            let delivery_mode = message.delivery_mode;
            let bytes = match self
                .artifacts
                .read_verified(&message.artifact.opaque_handle, &message.artifact.digest)
            {
                Ok(bytes) => bytes,
                Err(_) => {
                    self.bridge.close_dispatch(&request.workflow_id, "failed");
                    return DispatchOutcome::KnownFailure {
                        reason_code: "bridge_message_artifact_unavailable".into(),
                        retryable: false,
                    };
                }
            };
            let Ok(follow_up) = String::from_utf8(bytes) else {
                self.bridge.close_dispatch(&request.workflow_id, "failed");
                return DispatchOutcome::KnownFailure {
                    reason_code: "bridge_message_artifact_invalid".into(),
                    retryable: false,
                };
            };
            let session_id = message.resume_session_id.as_deref().or_else(|| {
                value
                    .get("nativeSessionId")
                    .or_else(|| value.get("sessionId"))
                    .and_then(|value| value.as_str())
                    .filter(|value| !value.is_empty())
            });
            let Some(session_id) = session_id else {
                self.bridge.close_dispatch(&request.workflow_id, "failed");
                return DispatchOutcome::KnownFailure {
                    reason_code: "bridge_session_continuity_unavailable".into(),
                    retryable: false,
                };
            };
            params["text"] = json!(follow_up);
            params["sessionId"] = json!(session_id);
            value = match conversation_lane::dispatch_lane_operation("send", &params) {
                Ok(value) => value,
                Err(_) => {
                    self.bridge.close_dispatch(&request.workflow_id, "unknown");
                    return DispatchOutcome::Unknown {
                        reason_code: "adapter_outcome_unknown".into(),
                    };
                }
            };
            if value.get("ok").and_then(|value| value.as_bool()) == Some(true) {
                self.bridge.observe_follow_up_delivered(
                    &request.workflow_id,
                    &message_id,
                    delivery_mode,
                );
            }
        }
    }
}

fn map_lane_result(request: &DispatchRequest, value: &serde_json::Value) -> DispatchOutcome {
    if value.get("ok").and_then(|value| value.as_bool()) != Some(true) {
        let code = value
            .pointer("/error/code")
            .and_then(|value| value.as_str())
            .unwrap_or("adapter_failure");
        let retryable = matches!(
            code,
            "timeout" | "temporary_unavailable" | "rate_limited" | "busy"
        );
        return if looks_unknown(code) {
            DispatchOutcome::Unknown {
                reason_code: redact_reason(code),
            }
        } else {
            DispatchOutcome::KnownFailure {
                reason_code: redact_reason(code),
                retryable,
            }
        };
    }
    let digest = value
        .get("digest")
        .and_then(|value| value.as_str())
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .map(str::to_owned)
        .unwrap_or_else(|| {
            format!(
                "{:x}",
                Sha256::digest(format!(
                    "{}:{}:{}",
                    request.workflow_id, request.step_id, "governed-completion"
                ))
            )
        });
    match request.purpose {
        StepPurpose::Validation => DispatchOutcome::ValidationPassed {
            summary: "governed validation completed".into(),
            digest,
        },
        _ => DispatchOutcome::Succeeded {
            summary: "governed completion".into(),
            digest,
        },
    }
}

fn looks_unknown(code: &str) -> bool {
    code.contains("unknown") || code.contains("unproven") || code == "adapter_outcome_unknown"
}

fn redact_reason(code: &str) -> String {
    code.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_') {
                ch
            } else {
                '_'
            }
        })
        .take(64)
        .collect()
}
