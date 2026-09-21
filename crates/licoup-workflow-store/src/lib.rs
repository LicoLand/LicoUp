//! Durable workflow storage.
//!
//! This crate is the SQLite implementation of `licoup-workflow-runtime`'s
//! ports:
//!
//! ```text
//!   licoup-workflow-store ──► licoup-workflow-runtime ──► licoup-workflow
//!      (implements)                  (declares)              (pure machine)
//! ```
//!
//! The store depends on the ports; the ports never depend on the store. That is
//! why a store can be replaced, or omitted entirely in a deployment that does
//! not install the optional workflow package, without the ports changing.
//!
//! ## Where it runs
//!
//! [`transactions`] holds the storage side of [`StatePort`] and of the notice
//! outbox, over [`schema`]'s view of the database. It runs on the database the
//! production store already wrote — same file, same format, same rows — which
//! is what lets the implementation move across this seam without a data
//! migration in the middle of it.
//!
//! ```text
//!   read + compile + reduce   │   one short write transaction
//!   (no lock)                 │   (CAS + event + checkpoint + commands + intents)
//! ```
//!
//! ## What is not here yet
//!
//! The production store — `licoup_native::domain::workflow_store::StrategyStore`
//! — still serves the running host. This crate now implements the transaction
//! and state-port layers over the same database; moving the host's callers onto
//! it, and retiring the old path, is the wiring step that follows, because that
//! move must not change effect semantics and is worth its own evidence.
//!
//! [`StatePort`]: licoup_workflow_runtime::ports::StatePort

pub mod deliveries;
pub mod recovery;
pub mod schema;
pub mod transactions;

/// The dependency direction this crate exists to hold.
///
/// Returns the crate names in the order the compile-time edges must point, so a
/// test can compare it against the real graph read from Cargo rather than from
/// this string.
pub const DEPENDENCY_DIRECTION: [&str; 3] = [
    "licoup-workflow-store",
    "licoup-workflow-runtime",
    "licoup-workflow",
];
