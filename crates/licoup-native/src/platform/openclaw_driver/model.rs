//! The OpenClaw run vocabulary, owned by the adapter package.
//!
//! The runtime-protocol identity, the effective settings a completed turn
//! reported, the bounded capability probe and the run result itself are this
//! Agent's own facts, so they live with the protocol. Re-exported here at its
//! former path for the driver leaves, the host's normalization and the tests.

#[allow(unused_imports)]
pub(in crate::platform) use licoup_agent_openclaw::gateway_acp::model::{
    CapabilityProbe, EffectiveSettings, PROCESS_POLL_INTERVAL, RUNTIME_PROTOCOL, RunResult,
};
