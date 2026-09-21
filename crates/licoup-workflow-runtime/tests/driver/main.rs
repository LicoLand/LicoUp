//! Driver tests over the contract fixture.
//!
//! These tests drive `Driver` against an in-process implementation of the two
//! ports (`fixture.rs`) and assert what the plan makes load-bearing: one owner
//! per run, successors advancing on each completion rather than per batch, the
//! possible-effect marker being durable before the invocation, an admission
//! bound, adapters that cannot re-enter the drive loop, and control that is not
//! starved by results.
//!
//! They are contract tests. They prove the driver's own behaviour against the
//! ports; they do not prove that a production store or adapter implements those
//! ports correctly, which is what V7-S1, V7-R4 and V7-I1 carry.

mod advance;
mod capacity;
mod control;
mod fence;
mod fixture;
mod lease;
mod non_reentrancy;
mod workset;
