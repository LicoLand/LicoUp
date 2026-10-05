//! The OpenClaw protocol failure vocabulary, owned by the adapter package.
//!
//! The code, the stage, whether explicit user interaction is required and the
//! identifiers a caller may project are OpenClaw's own facts, so the typed
//! failure lives with the protocol that produces it. Re-exported here at its
//! former path for the driver leaves and the host's failure projection, which
//! reads the payload through `into_payload` rather than by naming its type.

pub(in crate::platform) use licoup_agent_openclaw::gateway_acp::errors::ProtocolFailure;
