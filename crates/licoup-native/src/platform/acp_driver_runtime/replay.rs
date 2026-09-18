//! Replay arms for the ACP adapters that share this protocol state machine.
//!
//! The state machine is module-private here, so the arm lives with it rather
//! than in the parser tree. Both copilot and kimi-code replay the same real
//! `AcpProtocol`; only the parser kind and the resulting message unit differ.

use crate::platform::native_agent_parser::Transition;
use crate::platform::native_agent_parser::replay::{FrameReplay, RecordedFrame};
use serde_json::{Value, json};

use super::model::AcpParserKind;
use super::params::{ProtocolConfig, RequestedSettings};
use super::protocol::{AcpProtocol, ProtocolEffect};
use super::{CapabilityProbe, EffectiveSettings, ProtocolFailure};

/// `AcpProtocol` fixes its configuration for the whole transcript, and the
/// recorded transcripts open the conversation the client already knew, so the
/// arm replays the driver's exact-resume configuration. That is the identity
/// the `native-resume` transcript binds: `session/load` carrying
/// `REQUESTED_SESSION_ID`.
const REQUESTED_SESSION_ID: &str = "native-session";
const PROMPT: &str = "<REDACTED_CONTENT>";
const CWD: &str = "/workspace/synthetic-project";

pub(in crate::platform) struct Replay {
    protocol: AcpProtocol,
}

impl Replay {
    pub(in crate::platform) fn new(adapter_id: &str) -> Result<Self, String> {
        let parser = match adapter_id {
            "copilot" => AcpParserKind::Copilot,
            "kimi-code" => AcpParserKind::KimiCode,
            other => {
                return Err(format!(
                    "no ACP protocol parser is registered for adapter {other}"
                ));
            }
        };
        Ok(Self {
            protocol: AcpProtocol::new(
                ProtocolConfig {
                    prompt: PROMPT.to_owned(),
                    requested_session_id: REQUESTED_SESSION_ID.to_owned(),
                    cwd: CWD.to_owned(),
                    settings: RequestedSettings {
                        model: None,
                        reasoning_effort: None,
                        mode: None,
                        runtime_agent: None,
                        allow_all: None,
                    },
                    allow_all_authorized: false,
                    mcp_servers: Vec::new(),
                },
                parser,
            ),
        })
    }
}

impl FrameReplay for Replay {
    fn feed(&mut self, frame: &RecordedFrame) -> Result<Vec<Value>, String> {
        // The ACP state machine consumes every recorded frame: a frame it
        // rejects is reported as a `fail` effect, never as a boundary error.
        Ok(self
            .protocol
            .handle_frame(frame.payload.as_bytes())
            .effects
            .into_iter()
            .map(effect_projection)
            .collect())
    }
}

/// Project one real `ProtocolEffect`.
///
/// `AcpProtocol::new` generates the turn id with `Uuid::new_v4()`, so every
/// field carrying it is omitted: a recorded projection may only hold
/// deterministic parser output.
fn effect_projection(effect: ProtocolEffect) -> Value {
    match effect {
        ProtocolEffect::Send(message) => json!({"effect": "send", "message": message}),
        ProtocolEffect::Complete(outcome) => {
            let outcome = *outcome;
            json!({
                "effect": "complete",
                "output": outcome.output,
                "sessionId": outcome.session_id,
                "threadId": outcome.thread_id,
                "turnStatus": outcome.turn_status,
                "effective": effective_projection(&outcome.effective),
                "capabilities": capabilities_projection(&outcome.capabilities),
                "transitions": outcome
                    .transitions
                    .iter()
                    .map(Transition::to_json)
                    .collect::<Vec<Value>>(),
            })
        }
        ProtocolEffect::Fail(failure) => failure_projection(&failure),
    }
}

fn failure_projection(failure: &ProtocolFailure) -> Value {
    let mut entry = json!({
        "error": failure.code.as_str(),
        "message": failure.message,
        "stage": failure.stage,
        "userInteractionRequired": failure.user_interaction_required,
    });
    let fields = entry.as_object_mut().expect("projection object");
    if let Some(session_id) = failure.session_id.as_deref() {
        fields.insert("sessionId".into(), json!(session_id));
    }
    if let Some(thread_id) = failure.thread_id.as_deref() {
        fields.insert("threadId".into(), json!(thread_id));
    }
    if let Some(method) = failure.request_method.as_deref() {
        fields.insert("requestMethod".into(), json!(method));
    }
    if let Some(status) = failure.turn_status.as_deref() {
        fields.insert("turnStatus".into(), json!(status));
    }
    entry
}

fn effective_projection(effective: &EffectiveSettings) -> Value {
    json!({
        "cwd": effective.cwd,
        "model": effective.model,
        "reasoningEffort": effective.reasoning_effort,
        "mode": effective.mode,
        "runtimeAgent": effective.runtime_agent,
        "allowAll": effective.allow_all,
        "sandbox": effective.sandbox,
        "approvalPolicy": effective.approval_policy,
    })
}

fn capabilities_projection(capabilities: &CapabilityProbe) -> Value {
    json!({
        "protocolVersion": capabilities.protocol_version,
        "loadSession": capabilities.load_session,
        "resumeSession": capabilities.resume_session,
        "closeSession": capabilities.close_session,
        "listSessions": capabilities.list_sessions,
        "deleteSession": capabilities.delete_session,
        "additionalDirectories": capabilities.additional_directories,
        "imagePrompts": capabilities.image_prompts,
        "audioPrompts": capabilities.audio_prompts,
        "embeddedContext": capabilities.embedded_context,
    })
}
