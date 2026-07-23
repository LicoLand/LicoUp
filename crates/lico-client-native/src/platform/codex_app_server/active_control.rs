//! Process-local control registry for the official Codex App Server turn API.

use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock, mpsc},
    time::Duration,
};

const MAX_ACTIVE_TURNS: usize = 32;
const CONTROL_ACK_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Debug)]
pub(super) struct SteerRequest {
    pub(super) text: String,
    acknowledged: mpsc::SyncSender<bool>,
}

#[derive(Clone)]
struct ActiveTurn {
    turn_id: String,
    token: String,
    sender: mpsc::SyncSender<SteerRequest>,
}

static ACTIVE: OnceLock<Mutex<HashMap<String, ActiveTurn>>> = OnceLock::new();

fn active() -> &'static Mutex<HashMap<String, ActiveTurn>> {
    ACTIVE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(super) struct ActiveTurnGuard {
    thread_id: String,
    token: String,
}

impl Drop for ActiveTurnGuard {
    fn drop(&mut self) {
        if let Ok(mut registry) = active().lock()
            && registry
                .get(&self.thread_id)
                .is_some_and(|turn| turn.token == self.token)
        {
            registry.remove(&self.thread_id);
        }
    }
}

pub(super) fn bind(
    thread_id: &str,
    turn_id: &str,
    sender: mpsc::SyncSender<SteerRequest>,
) -> Option<ActiveTurnGuard> {
    if !valid_id(thread_id) || !valid_id(turn_id) {
        return None;
    }
    let mut registry = active().lock().ok()?;
    if registry.len() >= MAX_ACTIVE_TURNS && !registry.contains_key(thread_id) {
        return None;
    }
    let token = uuid::Uuid::new_v4().simple().to_string();
    registry.insert(
        thread_id.to_owned(),
        ActiveTurn {
            turn_id: turn_id.to_owned(),
            token: token.clone(),
            sender,
        },
    );
    Some(ActiveTurnGuard {
        thread_id: thread_id.to_owned(),
        token,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ControlDisposition {
    Accepted,
    NoActiveTurn,
    SessionUnavailable,
    TransportUnavailable,
}

pub(in crate::platform) fn steer(
    thread_id: &str,
    expected_turn_id: &str,
    text: &str,
) -> ControlDisposition {
    if text.trim().is_empty() || text.len() > 1024 * 1024 {
        return ControlDisposition::TransportUnavailable;
    }
    let Some(turn) = active()
        .lock()
        .ok()
        .and_then(|registry| registry.get(thread_id).cloned())
    else {
        return ControlDisposition::SessionUnavailable;
    };
    if turn.turn_id != expected_turn_id {
        return ControlDisposition::NoActiveTurn;
    }
    let (acknowledged, receiver) = mpsc::sync_channel(1);
    if turn
        .sender
        .try_send(SteerRequest {
            text: text.to_owned(),
            acknowledged,
        })
        .is_err()
    {
        return ControlDisposition::TransportUnavailable;
    }
    match receiver.recv_timeout(CONTROL_ACK_TIMEOUT) {
        Ok(true) => ControlDisposition::Accepted,
        Ok(false) => ControlDisposition::NoActiveTurn,
        Err(_) => ControlDisposition::TransportUnavailable,
    }
}

impl SteerRequest {
    pub(super) fn into_protocol(
        self,
        thread_id: &str,
        turn_id: &str,
    ) -> (String, Value, mpsc::SyncSender<bool>) {
        let request_id = format!("lico-steer-{}", uuid::Uuid::new_v4().simple());
        let message = json!({
            "id": request_id,
            "method": "turn/steer",
            "params": {
                "threadId": thread_id,
                "expectedTurnId": turn_id,
                "input": [{"type": "text", "text": self.text}]
            }
        });
        (request_id, message, self.acknowledged)
    }
}

fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 512 && !value.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_turn_binding_accepts_and_mismatch_rejects() {
        let (sender, receiver) = mpsc::sync_channel(2);
        let _guard = bind("thread-1", "turn-1", sender).unwrap();
        assert_eq!(
            steer("thread-1", "turn-other", "guidance"),
            ControlDisposition::NoActiveTurn
        );
        let worker = std::thread::spawn(move || {
            let request = receiver.recv().unwrap();
            let (request_id, message, acknowledged) = request.into_protocol("thread-1", "turn-1");
            assert_eq!(message["id"], request_id);
            assert_eq!(message["method"], "turn/steer");
            acknowledged.send(true).unwrap();
        });
        assert_eq!(
            steer("thread-1", "turn-1", "guidance"),
            ControlDisposition::Accepted
        );
        worker.join().unwrap();
    }
}
