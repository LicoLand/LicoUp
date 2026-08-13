use super::errors::ProtocolFailure;
use serde_json::Value;
use serde_json::json;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU8, Ordering};
#[cfg(test)]
use std::sync::{Condvar, Mutex};
use std::time::Duration;

/// Official Claude Code streaming-input lane. Prompt and process-local
/// conversation identity never use the command line.
pub(in crate::platform) const RUNTIME_PROTOCOL: &str = "claude-code-cli-stream-json";
pub(super) const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
pub(super) const MAX_TRANSCRIPT_TURNS: usize = 64;
pub(super) const MAX_TRANSCRIPT_BYTES: usize = 1024 * 1024;

#[repr(u8)]
enum TransportState {
    Live = 0,
    Closing = 1,
    Closed = 2,
}

#[derive(Debug)]
pub(in crate::platform) struct TransportLifecycle {
    state: AtomicU8,
    #[cfg(test)]
    changed: Mutex<()>,
    #[cfg(test)]
    notification: Condvar,
}

impl Default for TransportLifecycle {
    fn default() -> Self {
        Self {
            state: AtomicU8::new(TransportState::Live as u8),
            #[cfg(test)]
            changed: Mutex::new(()),
            #[cfg(test)]
            notification: Condvar::new(),
        }
    }
}

impl TransportLifecycle {
    pub(in crate::platform) fn is_live(&self) -> bool {
        self.state.load(Ordering::Acquire) == TransportState::Live as u8
    }

    #[cfg(test)]
    pub(in crate::platform) fn is_closing(&self) -> bool {
        self.state.load(Ordering::Acquire) == TransportState::Closing as u8
    }

    pub(in crate::platform) fn is_closed(&self) -> bool {
        self.state.load(Ordering::Acquire) == TransportState::Closed as u8
    }

    pub(in crate::platform) fn begin_closing(&self) -> bool {
        let claimed = self
            .state
            .compare_exchange(
                TransportState::Live as u8,
                TransportState::Closing as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok();
        if claimed {
            #[cfg(test)]
            self.notification.notify_all();
        }
        claimed
    }

    pub(in crate::platform) fn mark_closed(&self) -> bool {
        let closed = self
            .state
            .compare_exchange(
                TransportState::Closing as u8,
                TransportState::Closed as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok();
        if closed {
            #[cfg(test)]
            self.notification.notify_all();
        }
        closed
    }

    #[cfg(test)]
    pub(in crate::platform) fn wait_until_closing(&self, timeout: Duration) -> bool {
        if !self.is_live() {
            return true;
        }
        let Ok(guard) = self.changed.lock() else {
            return false;
        };
        let _ = self
            .notification
            .wait_timeout_while(guard, timeout, |_| self.is_live());
        !self.is_live()
    }

    #[cfg(test)]
    pub(in crate::platform) fn wait_until_closed(&self, timeout: Duration) -> bool {
        if self.is_closed() {
            return true;
        }
        let Ok(guard) = self.changed.lock() else {
            return false;
        };
        let _ = self
            .notification
            .wait_timeout_while(guard, timeout, |_| !self.is_closed());
        self.is_closed()
    }
}

#[derive(Clone, Debug)]
struct TranscriptTurn {
    turn_id: String,
    output: String,
    output_bytes: usize,
}

#[derive(Debug)]
pub(in crate::platform) struct BoundedTranscript {
    turns: VecDeque<TranscriptTurn>,
    max_turns: usize,
    max_bytes: usize,
    byte_count: usize,
}

impl BoundedTranscript {
    pub(in crate::platform) fn new(max_turns: usize, max_bytes: usize) -> Self {
        Self {
            turns: VecDeque::new(),
            max_turns,
            max_bytes,
            byte_count: 0,
        }
    }

    pub(in crate::platform) fn record_success(&mut self, turn_id: &str, output: &str) {
        let output_bytes = output.len();
        if turn_id.trim().is_empty()
            || output.is_empty()
            || self.max_turns == 0
            || output_bytes > self.max_bytes
        {
            if output_bytes > self.max_bytes {
                self.clear();
            }
            return;
        }
        self.turns.push_back(TranscriptTurn {
            turn_id: turn_id.to_string(),
            output: output.to_string(),
            output_bytes,
        });
        self.byte_count = self.byte_count.saturating_add(output_bytes);
        while self.turns.len() > self.max_turns || self.byte_count > self.max_bytes {
            if let Some(evicted) = self.turns.pop_front() {
                self.byte_count = self.byte_count.saturating_sub(evicted.output_bytes);
            }
        }
    }

    pub(in crate::platform) fn project(&self) -> Vec<Value> {
        self.turns
            .iter()
            .map(|turn| json!({"turnId": turn.turn_id, "output": turn.output}))
            .collect()
    }

    pub(in crate::platform) fn byte_count(&self) -> usize {
        self.byte_count
    }

    pub(in crate::platform) fn clear(&mut self) {
        self.turns.clear();
        self.byte_count = 0;
    }
}

#[derive(Clone, Debug, Default)]
pub(in crate::platform) struct EffectiveSettings {
    pub(in crate::platform) cwd: Option<String>,
    pub(in crate::platform) model: Option<String>,
    pub(in crate::platform) reasoning_effort: Option<String>,
    pub(in crate::platform) permission_mode: Option<String>,
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
        stdout_truncated: bool,
        stderr_truncated: bool,
    ) -> Self {
        let session_id = failure.session_id.clone().unwrap_or_default();
        Self {
            ok: false,
            output: String::new(),
            events: Vec::new(),
            thread_id: failure
                .thread_id
                .clone()
                .unwrap_or_else(|| session_id.clone()),
            session_id,
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            error: Some(failure),
            status_code: None,
            stdout_truncated,
            stderr_truncated,
            started_at,
        }
    }
}

/// Continuation is available only while the exact supervised streaming-input
/// process remains live. Persisted CLI resume is intentionally not used because
/// the vendor contract puts the native session identifier on argv.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(in crate::platform) struct CapabilityProbe {
    pub(in crate::platform) available: bool,
    pub(in crate::platform) version_command_ok: bool,
    pub(in crate::platform) help_command_ok: bool,
    pub(in crate::platform) stdin_prompt: bool,
    pub(in crate::platform) structured_stream: bool,
    pub(in crate::platform) new_session: bool,
    pub(in crate::platform) resume_session: bool,
    pub(in crate::platform) model: bool,
    pub(in crate::platform) reasoning_effort: bool,
    pub(in crate::platform) permission_mode: bool,
    pub(in crate::platform) interactive_approval_events: bool,
}

impl CapabilityProbe {
    pub(super) fn official(version_command_ok: bool, help_command_ok: bool) -> Self {
        Self {
            available: version_command_ok || help_command_ok,
            version_command_ok,
            help_command_ok,
            stdin_prompt: true,
            structured_stream: true,
            new_session: true,
            resume_session: true,
            model: true,
            reasoning_effort: true,
            permission_mode: true,
            interactive_approval_events: false,
        }
    }
}
