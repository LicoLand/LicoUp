//! Bounded process-local Level-2 conversation bridge.
//!
//! The bridge is deliberately not another daemon. It lives inside the durable
//! orchestrator owner process and adds only the ephemeral state needed for
//! wakeable progress, in-flight message admission, and exact-session follow-up.
//! Prompt and output bytes never enter this state machine.

use crate::domain::agent_orchestration::ArtifactRef;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    sync::{Condvar, Mutex},
    time::{Duration, Instant},
};

pub const MAX_BRIDGE_EVENTS: usize = 128;
pub const MAX_PENDING_MESSAGES: usize = 16;
pub const MAX_WAIT_MS: u64 = 30_000;
const PROGRESS_EMIT_BYTES: u64 = 4 * 1024;
const MAX_RESERVATION_WAIT: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NativeTurnBinding {
    pub agent_id: String,
    pub session_id: String,
    pub turn_id: String,
}

#[derive(Clone, Debug)]
pub struct PendingMessage {
    pub artifact: ArtifactRef,
    pub message_id: String,
    pub delivery_mode: &'static str,
    pub resume_session_id: Option<String>,
}

#[derive(Clone, Debug)]
struct ReservedMessage {
    artifact: ArtifactRef,
    resume_session_id: Option<String>,
}

#[derive(Clone, Debug)]
pub enum MessageReservation {
    Native {
        message_id: String,
        binding: NativeTurnBinding,
    },
    Interrupt {
        message_id: String,
        binding: NativeTurnBinding,
    },
    Queued {
        message_id: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MessageAdmission {
    pub message_id: String,
    pub delivery_mode: &'static str,
    pub state: &'static str,
}

#[derive(Clone, Debug)]
struct LiveEvent {
    cursor: u64,
    kind: &'static str,
    state: &'static str,
    step_id: Option<String>,
    agent_id: Option<String>,
    delivery_mode: Option<&'static str>,
    output_bytes: Option<u64>,
}

impl LiveEvent {
    fn project(&self) -> Value {
        let mut value = json!({
            "cursor": self.cursor,
            "type": self.kind,
            "state": self.state,
        });
        if let Some(step_id) = self.step_id.as_deref() {
            value["stepId"] = json!(step_id);
        }
        if let Some(agent_id) = self.agent_id.as_deref() {
            value["agentId"] = json!(agent_id);
        }
        if let Some(mode) = self.delivery_mode {
            value["deliveryMode"] = json!(mode);
        }
        if let Some(bytes) = self.output_bytes {
            value["outputBytes"] = json!(bytes);
        }
        value
    }
}

#[derive(Default)]
struct WorkflowLiveState {
    next_cursor: u64,
    events: VecDeque<LiveEvent>,
    active: bool,
    terminal: bool,
    step_id: Option<String>,
    agent_id: Option<String>,
    session_id: Option<String>,
    turn_id: Option<String>,
    pending: VecDeque<PendingMessage>,
    reservations: HashMap<String, ReservedMessage>,
    output_bytes: u64,
    last_progress_bytes: u64,
}

#[derive(Default)]
struct BridgeState {
    workflows: HashMap<String, WorkflowLiveState>,
}

#[derive(Default)]
pub struct LocalBridge {
    state: Mutex<BridgeState>,
    changed: Condvar,
}

impl LocalBridge {
    pub fn active_agent(&self, workflow_id: &str) -> Option<String> {
        let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state
            .workflows
            .get(workflow_id)
            .filter(|live| live.active && !live.terminal)
            .and_then(|live| live.agent_id.clone())
    }

    pub fn register_workflow(&self, workflow_id: &str) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state.workflows.entry(workflow_id.to_owned()).or_default();
        self.changed.notify_all();
    }

    pub fn begin_dispatch(&self, workflow_id: &str, step_id: &str, agent_id: &str) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let live = state.workflows.entry(workflow_id.to_owned()).or_default();
        live.active = true;
        live.terminal = false;
        live.step_id = Some(step_id.to_owned());
        live.agent_id = Some(agent_id.to_owned());
        live.session_id = None;
        live.turn_id = None;
        live.output_bytes = 0;
        live.last_progress_bytes = 0;
        push_event(live, "child.dispatch.started", "running", None, None);
        self.changed.notify_all();
    }

    /// Observe a driver event while retaining only bounded metadata. In
    /// particular, `payload.text`, tool arguments, paths, and model reasoning
    /// are never copied into bridge state.
    pub fn observe_driver_event(&self, workflow_id: &str, event: &Value) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let Some(live) = state.workflows.get_mut(workflow_id) else {
            return;
        };
        if let Some(session_id) = bounded_opaque(event.get("sessionId")) {
            live.session_id = Some(session_id);
        }
        if let Some(turn_id) = bounded_opaque(event.get("turnId")) {
            live.turn_id = Some(turn_id);
        }
        let kind = event
            .get("event")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match kind {
            "agent.message.chunk" => {
                let bytes = event
                    .pointer("/payload/text")
                    .and_then(Value::as_str)
                    .map_or(0, |text| text.len() as u64);
                live.output_bytes = live.output_bytes.saturating_add(bytes);
                if live.last_progress_bytes == 0
                    || live.output_bytes.saturating_sub(live.last_progress_bytes)
                        >= PROGRESS_EMIT_BYTES
                {
                    live.last_progress_bytes = live.output_bytes;
                    push_event(
                        live,
                        "child.output.progress",
                        "running",
                        None,
                        Some(live.output_bytes),
                    );
                }
            }
            "agent.message.completed" => {
                if let Some(text) = event.pointer("/payload/text").and_then(Value::as_str) {
                    live.output_bytes = live.output_bytes.max(text.len() as u64);
                }
                push_event(
                    live,
                    "child.output.completed",
                    "running",
                    None,
                    Some(live.output_bytes),
                );
            }
            _ => {
                // The binding itself is useful for native steer, but arbitrary
                // driver payloads are intentionally not projected.
            }
        }
        self.changed.notify_all();
    }

    pub fn observe_turn_result(&self, workflow_id: &str, result: &Value) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let Some(live) = state.workflows.get_mut(workflow_id) else {
            return;
        };
        if let Some(session_id) = bounded_opaque(
            result
                .get("nativeSessionId")
                .or_else(|| result.get("sessionId")),
        ) {
            live.session_id = Some(session_id);
        }
        if let Some(turn_id) = bounded_opaque(result.get("turnId")) {
            live.turn_id = Some(turn_id);
        }
        let state_name = if result.get("ok").and_then(Value::as_bool) == Some(true) {
            "running"
        } else {
            "failed"
        };
        push_event(live, "child.turn.completed", state_name, None, None);
        self.changed.notify_all();
    }

    pub fn reserve_message(
        &self,
        workflow_id: &str,
        artifact: ArtifactRef,
        message_id: &str,
        native_supported: bool,
        interrupt_supported: bool,
    ) -> Result<MessageReservation, &'static str> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let live = state
            .workflows
            .get_mut(workflow_id)
            .ok_or("workflow_unavailable")?;
        if !live.active || live.terminal {
            return Err("workflow_not_active");
        }
        if live.pending.len() + live.reservations.len() >= MAX_PENDING_MESSAGES {
            return Err("bridge_queue_full");
        }
        let native_binding = if native_supported {
            match (
                live.agent_id.clone(),
                live.session_id.clone(),
                live.turn_id.clone(),
            ) {
                (Some(agent_id), Some(session_id), Some(turn_id)) => Some(NativeTurnBinding {
                    agent_id,
                    session_id,
                    turn_id,
                }),
                _ => None,
            }
        } else {
            None
        };
        if let Some(binding) = native_binding {
            live.reservations.insert(
                message_id.to_owned(),
                ReservedMessage {
                    artifact,
                    resume_session_id: Some(binding.session_id.clone()),
                },
            );
            return Ok(MessageReservation::Native {
                message_id: message_id.to_owned(),
                binding,
            });
        }
        let interrupt_binding = if interrupt_supported {
            match (live.agent_id.clone(), live.session_id.clone()) {
                (Some(agent_id), Some(session_id)) => Some(NativeTurnBinding {
                    agent_id,
                    session_id,
                    turn_id: live.turn_id.clone().unwrap_or_default(),
                }),
                _ => None,
            }
        } else {
            None
        };
        if let Some(binding) = interrupt_binding {
            live.reservations.insert(
                message_id.to_owned(),
                ReservedMessage {
                    artifact,
                    resume_session_id: Some(binding.session_id.clone()),
                },
            );
            return Ok(MessageReservation::Interrupt {
                message_id: message_id.to_owned(),
                binding,
            });
        }
        live.pending.push_back(PendingMessage {
            artifact,
            message_id: message_id.to_owned(),
            delivery_mode: "bridge_follow_up",
            resume_session_id: None,
        });
        push_event(
            live,
            "child.message.queued",
            "running",
            Some("bridge_follow_up"),
            None,
        );
        self.changed.notify_all();
        Ok(MessageReservation::Queued {
            message_id: message_id.to_owned(),
        })
    }

    pub fn resolve_interrupt(
        &self,
        workflow_id: &str,
        message_id: &str,
        accepted: bool,
    ) -> Result<MessageAdmission, &'static str> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let live = state
            .workflows
            .get_mut(workflow_id)
            .ok_or("workflow_unavailable")?;
        let reserved = live
            .reservations
            .remove(message_id)
            .ok_or("message_reservation_unavailable")?;
        if !live.active || live.terminal {
            self.changed.notify_all();
            return Err("workflow_not_active");
        }
        let delivery_mode = if accepted {
            "bridge_interrupt_resume"
        } else {
            "bridge_follow_up"
        };
        live.pending.push_back(PendingMessage {
            artifact: reserved.artifact,
            message_id: message_id.to_owned(),
            delivery_mode,
            resume_session_id: reserved.resume_session_id,
        });
        push_event(
            live,
            if accepted {
                "child.turn.interrupt.requested"
            } else {
                "child.message.queued"
            },
            "running",
            Some(delivery_mode),
            None,
        );
        self.changed.notify_all();
        Ok(MessageAdmission {
            message_id: message_id.to_owned(),
            delivery_mode,
            state: if accepted { "interrupting" } else { "queued" },
        })
    }

    pub fn resolve_native(
        &self,
        workflow_id: &str,
        message_id: &str,
        accepted: bool,
    ) -> Result<MessageAdmission, &'static str> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let live = state
            .workflows
            .get_mut(workflow_id)
            .ok_or("workflow_unavailable")?;
        let reserved = live
            .reservations
            .remove(message_id)
            .ok_or("message_reservation_unavailable")?;
        let admission = if accepted {
            push_event(
                live,
                "child.message.delivered",
                "running",
                Some("native_steer"),
                None,
            );
            MessageAdmission {
                message_id: message_id.to_owned(),
                delivery_mode: "native_steer",
                state: "delivered",
            }
        } else if live.active && !live.terminal && live.pending.len() < MAX_PENDING_MESSAGES {
            live.pending.push_back(PendingMessage {
                artifact: reserved.artifact,
                message_id: message_id.to_owned(),
                delivery_mode: "bridge_follow_up",
                resume_session_id: reserved.resume_session_id,
            });
            push_event(
                live,
                "child.message.queued",
                "running",
                Some("bridge_follow_up"),
                None,
            );
            MessageAdmission {
                message_id: message_id.to_owned(),
                delivery_mode: "bridge_follow_up",
                state: "queued",
            }
        } else {
            self.changed.notify_all();
            return Err("workflow_not_active");
        };
        self.changed.notify_all();
        Ok(admission)
    }

    pub fn queued_admission(message_id: String) -> MessageAdmission {
        MessageAdmission {
            message_id,
            delivery_mode: "bridge_follow_up",
            state: "queued",
        }
    }

    pub fn observe_follow_up_delivered(
        &self,
        workflow_id: &str,
        message_id: &str,
        delivery_mode: &'static str,
    ) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let Some(live) = state.workflows.get_mut(workflow_id) else {
            return;
        };
        if message_id.is_empty() {
            return;
        }
        push_event(
            live,
            "child.message.delivered",
            "running",
            Some(delivery_mode),
            None,
        );
        self.changed.notify_all();
    }

    /// Atomically take the next follow-up or close the dispatch admission
    /// window. A concurrent message is therefore either accepted into the
    /// queue or rejected after closure; it can never disappear between them.
    pub fn next_follow_up_or_close(
        &self,
        workflow_id: &str,
        prior_turn_succeeded: bool,
    ) -> Option<PendingMessage> {
        let deadline = Instant::now() + MAX_RESERVATION_WAIT;
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        loop {
            let live = state.workflows.get_mut(workflow_id)?;
            let interrupt_resume_pending = live
                .pending
                .iter()
                .any(|message| message.delivery_mode == "bridge_interrupt_resume");
            if !live.pending.is_empty() && (prior_turn_succeeded || interrupt_resume_pending) {
                let message = live.pending.pop_front().expect("front checked above");
                push_event(
                    live,
                    "child.message.delivering",
                    "running",
                    Some(message.delivery_mode),
                    None,
                );
                self.changed.notify_all();
                return Some(message);
            }
            if !prior_turn_succeeded && !live.pending.is_empty() {
                live.active = false;
                live.pending.clear();
                live.reservations.clear();
                push_event(live, "child.dispatch.completed", "failed", None, None);
                self.changed.notify_all();
                return None;
            }
            if live.reservations.is_empty() {
                live.active = false;
                push_event(live, "child.dispatch.completed", "idle", None, None);
                self.changed.notify_all();
                return None;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                // A native transport call failed to resolve in its bounded
                // window. Preserve safety: close only after moving reservations
                // to the normal bridge queue.
                let reservations = std::mem::take(&mut live.reservations);
                for (message_id, reserved) in reservations {
                    live.pending.push_back(PendingMessage {
                        artifact: reserved.artifact,
                        message_id,
                        delivery_mode: "bridge_follow_up",
                        resume_session_id: reserved.resume_session_id,
                    });
                }
                continue;
            }
            let waited = self
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(|error| error.into_inner());
            state = waited.0;
        }
    }

    pub fn mark_workflow_state(&self, workflow_id: &str, state_name: &'static str, terminal: bool) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let live = state.workflows.entry(workflow_id.to_owned()).or_default();
        live.terminal = terminal;
        if terminal {
            live.active = false;
            live.pending.clear();
            live.reservations.clear();
        }
        push_event(live, "workflow.state.changed", state_name, None, None);
        self.changed.notify_all();
    }

    pub fn close_dispatch(&self, workflow_id: &str, state_name: &'static str) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let Some(live) = state.workflows.get_mut(workflow_id) else {
            return;
        };
        live.active = false;
        live.pending.clear();
        live.reservations.clear();
        push_event(live, "child.dispatch.completed", state_name, None, None);
        self.changed.notify_all();
    }

    pub fn wait(
        &self,
        workflow_id: &str,
        after_cursor: u64,
        limit: usize,
        timeout: Duration,
    ) -> Result<Value, &'static str> {
        let timeout = timeout.min(Duration::from_millis(MAX_WAIT_MS));
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if !state.workflows.contains_key(workflow_id) {
            return Err("workflow_unavailable");
        }
        let timed_out = loop {
            let live = state.workflows.get(workflow_id).expect("checked above");
            if live.events.iter().any(|event| event.cursor > after_cursor) || live.terminal {
                break false;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break true;
            }
            let waited = self
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(|error| error.into_inner());
            state = waited.0;
            if waited.1.timed_out() {
                break true;
            }
        };
        let live = state.workflows.get(workflow_id).expect("checked above");
        let oldest_cursor = live
            .events
            .front()
            .map_or(after_cursor, |event| event.cursor);
        let cursor_expired = after_cursor.saturating_add(1) < oldest_cursor;
        let events = live
            .events
            .iter()
            .filter(|event| event.cursor > after_cursor)
            .take(limit)
            .map(LiveEvent::project)
            .collect::<Vec<_>>();
        let next_cursor = events
            .last()
            .and_then(|event| event.get("cursor"))
            .and_then(Value::as_u64)
            .unwrap_or(after_cursor);
        let has_more = live.events.iter().any(|event| event.cursor > next_cursor);
        Ok(json!({
            "workflowId": workflow_id,
            "events": events,
            "nextCursor": next_cursor,
            "hasMore": has_more,
            "cursorExpired": cursor_expired,
            "timedOut": timed_out,
            "active": live.active,
            "terminal": live.terminal,
        }))
    }
}

fn bounded_opaque(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= 256)
        .map(str::to_owned)
}

fn push_event(
    live: &mut WorkflowLiveState,
    kind: &'static str,
    state: &'static str,
    delivery_mode: Option<&'static str>,
    output_bytes: Option<u64>,
) {
    live.next_cursor = live.next_cursor.saturating_add(1);
    live.events.push_back(LiveEvent {
        cursor: live.next_cursor,
        kind,
        state,
        step_id: live.step_id.clone(),
        agent_id: live.agent_id.clone(),
        delivery_mode,
        output_bytes,
    });
    while live.events.len() > MAX_BRIDGE_EVENTS {
        live.events.pop_front();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn artifact(id: &str) -> ArtifactRef {
        ArtifactRef {
            opaque_handle: id.to_owned(),
            digest: "a".repeat(64),
        }
    }

    #[test]
    fn wait_wakes_on_progress_without_projecting_output_text() {
        let bridge = Arc::new(LocalBridge::default());
        bridge.register_workflow("workflow-1");
        bridge.begin_dispatch("workflow-1", "step-1", "codex");
        let cursor = bridge.wait("workflow-1", 0, 8, Duration::ZERO).unwrap()["nextCursor"]
            .as_u64()
            .unwrap();
        let waiter = Arc::clone(&bridge);
        let thread = std::thread::spawn(move || {
            waiter
                .wait("workflow-1", cursor, 8, Duration::from_secs(1))
                .unwrap()
        });
        std::thread::sleep(Duration::from_millis(10));
        bridge.observe_driver_event(
            "workflow-1",
            &json!({
                "event": "agent.message.chunk",
                "sessionId": "private-session",
                "turnId": "private-turn",
                "payload": {"text": "secret child output"}
            }),
        );
        let page = thread.join().unwrap();
        assert_eq!(page["workflowId"], "workflow-1");
        assert_eq!(page["timedOut"], false);
        assert_eq!(page["events"][0]["type"], "child.output.progress");
        let encoded = page.to_string();
        assert!(!encoded.contains("secret child output"));
        assert!(!encoded.contains("private-session"));
        assert!(!encoded.contains("private-turn"));
    }

    #[test]
    fn fallback_message_is_taken_from_the_same_active_dispatch() {
        let bridge = LocalBridge::default();
        bridge.register_workflow("workflow-1");
        bridge.begin_dispatch("workflow-1", "step-1", "cursor");
        let reservation = bridge
            .reserve_message(
                "workflow-1",
                artifact("message-1"),
                "message-1",
                false,
                false,
            )
            .unwrap();
        assert!(matches!(reservation, MessageReservation::Queued { .. }));
        let next = bridge.next_follow_up_or_close("workflow-1", true).unwrap();
        assert_eq!(next.message_id, "message-1");
        assert!(bridge.next_follow_up_or_close("workflow-1", true).is_none());
        assert_eq!(
            bridge
                .reserve_message(
                    "workflow-1",
                    artifact("message-2"),
                    "message-2",
                    false,
                    false,
                )
                .unwrap_err(),
            "workflow_not_active"
        );
    }

    #[test]
    fn failed_native_reservation_falls_back_exactly_once() {
        let bridge = LocalBridge::default();
        bridge.register_workflow("workflow-1");
        bridge.begin_dispatch("workflow-1", "step-1", "codex");
        bridge.observe_driver_event(
            "workflow-1",
            &json!({"event": "turn.bound", "sessionId": "thread-1", "turnId": "turn-1"}),
        );
        let reservation = bridge
            .reserve_message("workflow-1", artifact("message-1"), "message-1", true, true)
            .unwrap();
        assert!(matches!(reservation, MessageReservation::Native { .. }));
        let admission = bridge
            .resolve_native("workflow-1", "message-1", false)
            .unwrap();
        assert_eq!(admission.delivery_mode, "bridge_follow_up");
        assert_eq!(
            bridge
                .next_follow_up_or_close("workflow-1", true)
                .unwrap()
                .message_id,
            "message-1"
        );
        assert!(bridge.next_follow_up_or_close("workflow-1", true).is_none());
    }

    #[test]
    fn accepted_interrupt_can_resume_after_the_prior_turn_stops() {
        let bridge = LocalBridge::default();
        bridge.register_workflow("workflow-1");
        bridge.begin_dispatch("workflow-1", "step-1", "cursor");
        bridge.observe_driver_event(
            "workflow-1",
            &json!({
                "event": "dispatch.turn.bound",
                "sessionId": "chat-1",
                "turnId": "turn-1"
            }),
        );
        let reservation = bridge
            .reserve_message(
                "workflow-1",
                artifact("message-1"),
                "message-1",
                false,
                true,
            )
            .unwrap();
        assert!(matches!(reservation, MessageReservation::Interrupt { .. }));
        let admission = bridge
            .resolve_interrupt("workflow-1", "message-1", true)
            .unwrap();
        assert_eq!(admission.delivery_mode, "bridge_interrupt_resume");
        assert_eq!(admission.state, "interrupting");
        let next = bridge.next_follow_up_or_close("workflow-1", false).unwrap();
        assert_eq!(next.resume_session_id.as_deref(), Some("chat-1"));
        assert_eq!(next.delivery_mode, "bridge_interrupt_resume");
    }

    #[test]
    fn accepted_interrupt_preserves_messages_queued_before_the_binding() {
        let bridge = LocalBridge::default();
        bridge.register_workflow("workflow-1");
        bridge.begin_dispatch("workflow-1", "step-1", "cursor");
        bridge
            .reserve_message(
                "workflow-1",
                artifact("message-before-binding"),
                "message-before-binding",
                false,
                true,
            )
            .unwrap();
        bridge.observe_driver_event(
            "workflow-1",
            &json!({
                "event": "dispatch.turn.bound",
                "sessionId": "chat-1",
                "turnId": "turn-1"
            }),
        );
        bridge
            .reserve_message(
                "workflow-1",
                artifact("message-that-interrupts"),
                "message-that-interrupts",
                false,
                true,
            )
            .unwrap();
        bridge
            .resolve_interrupt("workflow-1", "message-that-interrupts", true)
            .unwrap();

        let first = bridge.next_follow_up_or_close("workflow-1", false).unwrap();
        assert_eq!(first.message_id, "message-before-binding");
        assert_eq!(first.delivery_mode, "bridge_follow_up");
        let second = bridge.next_follow_up_or_close("workflow-1", true).unwrap();
        assert_eq!(second.message_id, "message-that-interrupts");
        assert_eq!(second.delivery_mode, "bridge_interrupt_resume");
    }

    #[test]
    fn queue_is_strictly_bounded() {
        let bridge = LocalBridge::default();
        bridge.register_workflow("workflow-1");
        bridge.begin_dispatch("workflow-1", "step-1", "hermes");
        for index in 0..MAX_PENDING_MESSAGES {
            bridge
                .reserve_message(
                    "workflow-1",
                    artifact(&format!("message-{index}")),
                    &format!("message-{index}"),
                    false,
                    false,
                )
                .unwrap();
        }
        assert_eq!(
            bridge
                .reserve_message("workflow-1", artifact("overflow"), "overflow", false, false,)
                .unwrap_err(),
            "bridge_queue_full"
        );
    }
}
