//! The OpenClaw Gateway ACP state machine, owned by the adapter package.
//!
//! This is the sole raw-frame ingress for this Agent: the package's
//! `parser::protocol` classifies one line once, below the adapter port, and the
//! kernel re-exports it here at its former path so the driver leaves that drive
//! it keep one name.

#[allow(unused_imports)]
pub(in crate::platform) use licoup_agent_openclaw::parser::protocol::{
    OpenClawProtocol, ProtocolEffect, ProtocolOutcome, ProtocolPhase,
};
