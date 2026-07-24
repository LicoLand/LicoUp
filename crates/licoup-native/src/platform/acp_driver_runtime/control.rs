//! Bounded in-flight ACP cancellation registry for per-turn stdio transports.

use super::super::process_supervisor::BoundedStdinWriter;
use super::io::write_message;
use crate::core::acp;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

const MAX_ACTIVE_TURNS: usize = 128;
const CONTROL_QUEUE_CAPACITY: usize = 8;
const CONTROL_ACK_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ControlDisposition {
    Accepted,
    NoActiveTurn,
    SessionUnavailable,
    TransportUnavailable,
}

#[derive(Debug)]
enum ControlRequest {
    Cancel {
        external_session_id: String,
        acknowledged: SyncSender<bool>,
    },
}

#[derive(Clone)]
struct RegistryEntry {
    sender: SyncSender<ControlRequest>,
    generation: u64,
}

#[derive(Clone, Debug)]
struct Binding {
    external_session_id: String,
    protocol_session_id: String,
    generation: u64,
}

pub(in crate::platform) struct ActiveAcpControl {
    driver_id: &'static str,
    sender: SyncSender<ControlRequest>,
    receiver: Receiver<ControlRequest>,
    binding: Option<Binding>,
}

static ACTIVE_TURNS: OnceLock<Mutex<HashMap<(&'static str, String), RegistryEntry>>> =
    OnceLock::new();
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

fn active_turns() -> &'static Mutex<HashMap<(&'static str, String), RegistryEntry>> {
    ACTIVE_TURNS.get_or_init(|| Mutex::new(HashMap::new()))
}

impl ActiveAcpControl {
    pub(in crate::platform) fn new(driver_id: &'static str) -> Self {
        let (sender, receiver) = mpsc::sync_channel(CONTROL_QUEUE_CAPACITY);
        Self {
            driver_id,
            sender,
            receiver,
            binding: None,
        }
    }

    pub(in crate::platform) fn sync_binding(
        &mut self,
        external_session_id: Option<&str>,
        protocol_session_id: Option<&str>,
    ) -> Result<(), ()> {
        let next = external_session_id
            .zip(protocol_session_id)
            .filter(|(external, protocol)| {
                !external.is_empty()
                    && external.len() <= 256
                    && !protocol.is_empty()
                    && protocol.len() <= 256
            });
        if self.binding.as_ref().is_some_and(|binding| {
            next == Some((
                binding.external_session_id.as_str(),
                binding.protocol_session_id.as_str(),
            ))
        }) {
            return Ok(());
        }
        self.unregister();
        let Some((external_session_id, protocol_session_id)) = next else {
            return Ok(());
        };
        let generation = NEXT_GENERATION.fetch_add(1, Ordering::Relaxed);
        let key = (self.driver_id, external_session_id.to_owned());
        let mut registry = active_turns().lock().map_err(|_| ())?;
        if registry.len() >= MAX_ACTIVE_TURNS && !registry.contains_key(&key) {
            return Err(());
        }
        registry.insert(
            key,
            RegistryEntry {
                sender: self.sender.clone(),
                generation,
            },
        );
        self.binding = Some(Binding {
            external_session_id: external_session_id.to_owned(),
            protocol_session_id: protocol_session_id.to_owned(),
            generation,
        });
        Ok(())
    }

    pub(in crate::platform) fn poll(
        &mut self,
        stdin: &mut BoundedStdinWriter,
    ) -> std::io::Result<()> {
        loop {
            match self.receiver.try_recv() {
                Ok(ControlRequest::Cancel {
                    external_session_id,
                    acknowledged,
                }) => {
                    let protocol_session_id = self.binding.as_ref().and_then(|binding| {
                        (binding.external_session_id == external_session_id)
                            .then_some(binding.protocol_session_id.as_str())
                    });
                    let written = protocol_session_id
                        .and_then(|session_id| acp::cancel_notification(session_id).ok())
                        .is_some_and(|notification| write_message(stdin, &notification).is_ok());
                    let _ = acknowledged.send(written);
                    if !written && protocol_session_id.is_some() {
                        return Err(std::io::Error::other(
                            "ACP active-turn control write failed",
                        ));
                    }
                }
                Err(TryRecvError::Empty) => return Ok(()),
                Err(TryRecvError::Disconnected) => {
                    return Err(std::io::Error::other(
                        "ACP active-turn control channel closed",
                    ));
                }
            }
        }
    }

    fn unregister(&mut self) {
        let Some(binding) = self.binding.take() else {
            return;
        };
        if let Ok(mut registry) = active_turns().lock() {
            let key = (self.driver_id, binding.external_session_id);
            if registry
                .get(&key)
                .is_some_and(|entry| entry.generation == binding.generation)
            {
                registry.remove(&key);
            }
        }
    }
}

impl Drop for ActiveAcpControl {
    fn drop(&mut self) {
        self.unregister();
    }
}

pub(in crate::platform) fn cancel_active_turn(
    driver_id: &'static str,
    session_id: &str,
) -> ControlDisposition {
    if session_id.is_empty() || session_id.len() > 256 {
        return ControlDisposition::SessionUnavailable;
    }
    let sender = active_turns()
        .lock()
        .ok()
        .and_then(|registry| registry.get(&(driver_id, session_id.to_owned())).cloned())
        .map(|entry| entry.sender);
    let Some(sender) = sender else {
        return ControlDisposition::NoActiveTurn;
    };
    let (acknowledged, receiver) = mpsc::sync_channel(1);
    if sender
        .try_send(ControlRequest::Cancel {
            external_session_id: session_id.to_owned(),
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
