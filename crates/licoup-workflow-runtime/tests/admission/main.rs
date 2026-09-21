//! Admission tests over the contract fixture.
//!
//! These tests hold the four things V7-R2 delivers, each against an in-process
//! owner rather than a database:
//!
//! * an authority a caller cannot mint (`authority.rs`),
//! * resource receipts that report what was true (`resources.rs`),
//! * a pause/stop fence that stops a new visit from starting (`barrier.rs`),
//! * C01's linearization rule for a revocation (`ordering.rs`).
//!
//! They are contract tests: they prove the boundary's own behaviour against the
//! ports it consumes. They do not prove that a production store implements
//! `AuthorityPort`, `ResourcePort` or `ScopeBarrierPort` correctly — the native
//! adaptation of the existing authorization owner is
//! `licoup-native/src/domain/workflow_runtime/authority_adapter.rs`, whose own
//! unit tests cover the store wiring, and the durable reservation ledger belongs
//! to V7-EC1.

mod authority;
mod barrier;
mod fixture;
mod ordering;
mod resources;
