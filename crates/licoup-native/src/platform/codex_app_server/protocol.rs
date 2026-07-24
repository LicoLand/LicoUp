mod control;
mod events;
mod helpers;
mod session;

use self::helpers::request_id_matches;
use super::config::ProtocolConfig;
use super::limits::{INITIALIZE_REQUEST_ID, THREAD_REQUEST_ID, TURN_REQUEST_ID};
use super::model::{EffectiveSettings, ProtocolEffect, ProtocolFailure, ProtocolPhase};
use serde_json::{Value, json};

#[derive(Debug)]
pub(super) struct CodexProtocol {
    config: ProtocolConfig,
    phase: ProtocolPhase,
    session_id: Option<String>,
    thread_id: Option<String>,
    turn_id: Option<String>,
    effective: EffectiveSettings,
    completed_items: Vec<Value>,
}

impl CodexProtocol {
    pub(super) fn new(config: ProtocolConfig) -> Self {
        Self {
            config,
            phase: ProtocolPhase::AwaitInitialize,
            session_id: None,
            thread_id: None,
            turn_id: None,
            effective: EffectiveSettings::default(),
            completed_items: Vec::new(),
        }
    }

    pub(super) fn initial_request(&self) -> Value {
        json!({
            "id": INITIALIZE_REQUEST_ID,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "lico-up",
                    "title": "LicoUp",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": self.config.session_path.is_some()
                }
            }
        })
    }

    pub(super) fn handle_message(&mut self, message: Value) -> Vec<ProtocolEffect> {
        if let Some(effects) = self.reject_server_request(&message) {
            self.phase = ProtocolPhase::Finished;
            return effects;
        }
        if message.get("method").is_some() {
            return self.handle_notification(&message);
        }

        match self.phase {
            ProtocolPhase::AwaitInitialize
                if request_id_matches(&message, INITIALIZE_REQUEST_ID) =>
            {
                self.handle_initialize_response(&message)
            }
            ProtocolPhase::AwaitThread if request_id_matches(&message, THREAD_REQUEST_ID) => {
                self.handle_thread_response(&message)
            }
            ProtocolPhase::AwaitTurnStart if request_id_matches(&message, TURN_REQUEST_ID) => {
                self.handle_turn_start_response(&message)
            }
            _ => Vec::new(),
        }
    }

    pub(super) fn contextualize(&self, mut failure: ProtocolFailure) -> ProtocolFailure {
        if failure.session_id.is_none() {
            failure.session_id = self.session_id.clone();
        }
        if failure.thread_id.is_none() {
            failure.thread_id = self.thread_id.clone();
        }
        if failure.turn_id.is_none() {
            failure.turn_id = self.turn_id.clone();
        }
        failure
    }

    pub(super) fn active_turn_binding(&self) -> Option<(&str, &str)> {
        (self.phase == ProtocolPhase::AwaitTurnCompleted)
            .then_some((self.thread_id.as_deref()?, self.turn_id.as_deref()?))
    }
}
