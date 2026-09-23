//! Integration tests for effect recovery and successor handoff.
//!
//! They live under one target rather than as separate files so they share the
//! fixtures in [`support`] — and because what they test is one thing: what a
//! second host may conclude from the facts a first host left behind, over the
//! same database the production store writes.

mod support;

mod checkpoint_admission;
mod effect_recovery;
mod successor_handoff;
