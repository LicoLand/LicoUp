//! Model, credential and control-plane contracts of the Gateway Runtime.
//!
//! The runtime process and the client that manages it share exactly this
//! surface: the compiled model router, the in-memory credential lease, the
//! private control channels and the communication-channel state. Conversation
//! access, credential custody and verified readiness belong to the composing
//! host and reach the runtime only through the ports in [`ports`].

pub mod channels;
pub mod control;
pub mod credentials;
pub mod model;
pub mod ports;
pub mod usage;
