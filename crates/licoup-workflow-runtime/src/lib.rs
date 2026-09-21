//! Consumer-owned workflow execution ports.
//!
//! This crate declares what a drive needs from storage, authority, and
//! notification, and depends only on the pure machine crate. Storage implements
//! these ports; it does not get to define them. The direction is therefore
//!
//! ```text
//!   licoup-workflow-store ──► licoup-workflow-runtime ──► licoup-workflow
//! ```
//!
//! which is a dependency inversion, not a cycle: a store is called *by* the
//! runtime through these traits, while the compile-time edge points at the
//! traits.
//!
//! The crate holds no I/O, no database handle, and no process management. It is
//! the boundary the rest of the extraction is written against, so keeping it
//! free of substrate is the point; `tests/ui/` proves the illegal directions
//! stay build errors.

pub mod admission;
pub mod driver;
pub mod node;
pub mod plan_cache;
pub mod ports;
pub mod routing;
