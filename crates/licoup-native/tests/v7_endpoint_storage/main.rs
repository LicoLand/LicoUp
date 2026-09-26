//! V7-P1 endpoint storage — acceptance A28 at `component-integration`.
//!
//! The module under test is the production module
//! (`licoup_native::domain::mobile_relay::endpoint_v7_storage`), now declared
//! by the parent module.
//!
//! What is real here: the actual storage/custody sources, the pinned LicoArc
//! Candidate SDK at its frozen revision, real SQLite files in temporary roots,
//! real advisory file locks, real process death (SIGKILL), the SDK's own
//! handshake/ratchet/record/delete entries, and real file permissions.
//!
//! What is synthetic and stated plainly: the platform secret store is a
//! file-backed fixture (`fixture-file-vault`) that implements the same caller
//! custody port; it does not claim hardware custody. Test keys, identities,
//! conversations, and payloads are synthetic.

mod support;

mod a28_contracts;
mod a28_real_sdk;
