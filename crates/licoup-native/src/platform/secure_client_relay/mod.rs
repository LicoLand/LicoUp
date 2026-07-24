//! Closed-schema HTTP adapter for the five Secure Client Relay operations.
//!
//! The module keeps relay contracts, request construction, bounded network I/O, response
//! validation, and caller binding in separate leaves. Only `http_io` may access the network.

mod contract;
mod http_io;
mod redaction;
mod request;
mod response_binding;
mod response_codec;
mod response_schema;
mod status_projection;
mod transport;

pub use contract::{
    SECURE_CLIENT_RELAY_CORE_CONFORMANCE, SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST,
    SECURE_CLIENT_RELAY_CORE_CONTRACT, SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST,
    SECURE_CLIENT_RELAY_PROTOCOL_VERSION, SecureClientRelayAuth,
    SecureClientRelayEndpointRegistration, SecureClientRelayHttpError, SecureClientRelayOperation,
    SecureClientRelayPublicJwk, SecureClientRelayScope,
};
pub use transport::SecureClientRelayTransport;

#[cfg(test)]
mod tests;
