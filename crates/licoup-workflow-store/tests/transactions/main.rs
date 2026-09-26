//! Integration tests for the transaction adapter.
//!
//! They live under one target rather than as separate files so they can share
//! the fixtures in [`support`] — and because what they test is one thing: a
//! short write transaction over the database the production store already
//! writes.

mod support;

mod atomic_intent;
mod fairness;
mod history;
mod old_database;
mod outbox;
mod reopen;
