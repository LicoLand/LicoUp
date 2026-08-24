use crate::platform::codex_app_server::config::ProtocolConfig;
use crate::platform::codex_app_server::limits::{
    INITIALIZE_REQUEST_ID, THREAD_REQUEST_ID, TURN_REQUEST_ID,
};
use crate::platform::codex_app_server::model::{ProtocolEffect, ProtocolFailure, ProtocolOutcome};
use crate::platform::native_agent_parser::adapters::codex::CodexParser;
use serde_json::{Value, json};
use std::path::Path;

pub(super) fn config(params: Value, prompt: &str, session_id: &str) -> ProtocolConfig {
    ProtocolConfig::from_params(
        &params,
        prompt,
        session_id,
        Some(Path::new("/workspace/project")),
    )
    .unwrap()
}

pub(super) fn initialize(protocol: &mut CodexParser) -> Vec<ProtocolEffect> {
    protocol.handle_message(json!({
        "id": INITIALIZE_REQUEST_ID,
        "result": {
            "userAgent": "codex-test",
            "platformFamily": "test",
            "platformOs": "test",
            "codexHome": "/redacted"
        }
    }))
}

pub(super) fn open_thread(protocol: &mut CodexParser) -> Vec<ProtocolEffect> {
    protocol.handle_message(json!({
        "id": THREAD_REQUEST_ID,
        "result": {
            "thread": {
                "id": "thread-1",
                "sessionId": "non-authoritative-session",
                "cwd": "/workspace/project"
            },
            "cwd": "/workspace/project",
            "model": "non-authoritative-default-model",
            "reasoningEffort": "non-authoritative-medium",
            "sandbox": {"type": "workspaceWrite", "writableRoots": []},
            "approvalPolicy": "on-request"
        }
    }))
}

pub(super) fn start_turn(protocol: &mut CodexParser) {
    let effects = protocol.handle_message(json!({
        "id": TURN_REQUEST_ID,
        "result": {
            "turn": {"id": "turn-1", "status": "inProgress", "items": []}
        }
    }));
    assert!(effects.is_empty());
}

pub(super) fn sent_messages(effects: Vec<ProtocolEffect>) -> Vec<Value> {
    effects
        .into_iter()
        .filter_map(|effect| match effect {
            ProtocolEffect::Send(message) => Some(message),
            ProtocolEffect::Complete(_) | ProtocolEffect::Fail(_) => None,
        })
        .collect()
}

pub(super) fn completed_outcome(effects: Vec<ProtocolEffect>) -> ProtocolOutcome {
    effects
        .into_iter()
        .find_map(|effect| match effect {
            ProtocolEffect::Complete(outcome) => Some(*outcome),
            ProtocolEffect::Send(_) | ProtocolEffect::Fail(_) => None,
        })
        .expect("matching completion should finish the protocol")
}

pub(super) fn failed_effect(effects: Vec<ProtocolEffect>) -> ProtocolFailure {
    effects
        .into_iter()
        .find_map(|effect| match effect {
            ProtocolEffect::Fail(failure) => Some(failure),
            ProtocolEffect::Send(_) | ProtocolEffect::Complete(_) => None,
        })
        .expect("matching failure should finish the protocol")
}
