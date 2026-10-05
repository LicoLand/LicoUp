//! The allowlisted OpenClaw update projection, owned by the adapter package.
//!
//! What one ACP session update may project is this Agent's privacy decision, so
//! it lives with the protocol that reads the update. Re-exported here at its
//! former path for the tests that state that decision.

#[allow(unused_imports)]
pub(in crate::platform) use licoup_agent_openclaw::parser::events::projected_event;
