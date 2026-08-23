//! Service-neutral ACP process runtime.
//!
//! Vendor adapters contribute only immutable launch metadata. Protocol
//! framing, capability negotiation, session lifecycle, bounded process I/O,
//! failure projection, and result types are owned here so no adapter depends
//! on another vendor implementation.

mod control;
mod errors;
#[path = "native_agent_parser/adapters/copilot/framing.rs"]
mod events;
mod io;
mod model;
mod params;
mod probe;
#[path = "native_agent_parser/adapters/copilot/protocol.rs"]
mod protocol;
mod session_plan;
mod settings;
mod stdio_transport;
mod supervision;

pub(in crate::platform) use control::{ActiveAcpControl, ControlDisposition, cancel_active_turn};
pub(in crate::platform) use errors::ProtocolFailure;
pub(in crate::platform) use model::{
    AcpDriverSpec, AcpParserKind, CapabilityProbe, EffectiveSettings, RunResult,
};
pub(in crate::platform) use params::{ProtocolConfig, timestamp};
pub(in crate::platform) use probe::probe_acp;
pub(in crate::platform) use stdio_transport::execute_acp;

#[cfg(test)]
mod tests;
