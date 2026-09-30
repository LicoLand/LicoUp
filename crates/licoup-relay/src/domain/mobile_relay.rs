//! The relay family root. It declares every tree of the relay family: the
//! durable endpoint storage and the inbound peer-unit mapping, the trust and
//! transport base, endpoint trust with its local material and directory
//! transparency, secret custody, pairwise sessions, relay operations, pairing,
//! configuration, the shared prelude, key transparency and command sync, plus
//! the family tests that exercise all of them.
//!
//! `licoup-native` re-exports the family at its former path for the FFI layer
//! and the client-state migration, which are the callers that still live there.

pub mod command_sync;
pub mod config;
pub mod endpoint_storage;
pub mod endpoint_transport;
pub mod endpoint_trust;
pub mod key_transparency;
pub mod pairing;
pub mod pairwise_session;
pub mod relay_operations;
pub mod secret_custody;
pub mod support;

// The names the trees below reach at the family root rather than through a
// submodule, mirroring the re-exports the former root carried. The two config
// functions are `pub` because the client-state migration and the mobile FFI
// compose them from outside this crate.
pub use config::{migrate_config_document, validate_current_config_document};
// The KeyPackage publication refresh is a test-topology fixture, and the
// relay drives it from its own dispatch path: a consumer's test build enables
// this crate's `test-support` feature, so both sides of that call carry the
// same gate. `cfg(test)` alone would compile the caller out for the consumer
// while the fixture stayed reachable, which is a silent behaviour loss.
#[cfg(any(test, feature = "test-support"))]
pub(crate) use endpoint_trust::refresh_secure_mesh_mls_test_directory_authority;
#[cfg(test)]
pub(crate) use secret_custody::test_runtime_secret_material;

#[cfg(test)]
mod tests;
