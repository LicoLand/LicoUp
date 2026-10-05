//! The OpenClaw session continuity binding, owned by the adapter package.
//!
//! How one ACP protocol session is tied to the resumable Gateway conversation
//! key, and how a mismatch is refused rather than resumed into the wrong
//! conversation, are OpenClaw's facts. Re-exported here at its former path for
//! the tests that drive the binding through this driver's own entry points.

#[allow(unused_imports)]
pub(in crate::platform) use licoup_agent_openclaw::gateway_acp::continuity::{
    SessionBinding, session_method, session_request,
};
