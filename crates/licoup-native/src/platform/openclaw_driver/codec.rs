//! The OpenClaw Gateway ACP byte-line codec, owned by the adapter package.
//!
//! One Gateway line becomes one decoded `Value` there and is never decoded
//! again above this path, per ADR-0008. The module is kept at its former path so
//! the driver leaves that read it, and the tests that check it, name one place.

#[allow(unused_imports)]
pub(in crate::platform) use licoup_agent_openclaw::parser::codec::{
    INITIALIZE_REQUEST_ID, MODE_REQUEST_ID, PROMPT_REQUEST_ID, SESSION_REQUEST_ID, decode_message,
    encode_message, request_id_matches,
};
