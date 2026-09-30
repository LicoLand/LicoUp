//! The real `domain::mobile_relay` mount for this suite.
//!
//! `endpoint_transport` moved to `licoup-relay`, which is the single authority
//! for the relay's trust and transport base; this suite compiles the exact
//! source files from their new path.

#[path = "../../../../../licoup-relay/src/domain/mobile_relay/endpoint_transport/mod.rs"]
pub mod endpoint_transport;
