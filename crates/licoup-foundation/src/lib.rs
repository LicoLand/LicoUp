//! The single authority for LicoUp's process, IO, path, record and archive primitives.
//!
//! Every crate above this one reaches down for bounded process execution,
//! process supervision, private-file access, path resolution, archive safety,
//! user-presence authorization, the generic user-present versioned record,
//! full data-root capture and restore, turn-event emission and interaction
//! routing instead of reimplementing them. Nothing here reaches upward: a name
//! that belongs to a domain stays in that domain, so this crate depends on no
//! LicoUp crate.
//!
//! `platform` holds the process, IO, path, network-boundary and user-presence
//! primitives and the platform adapter that stores a record; `core` holds the
//! record authority, the event queue, the archive container formats and the
//! Agent Client Protocol wire primitives.

pub mod core;
pub mod platform;

pub(crate) mod state_machines {
    include!(concat!(env!("OUT_DIR"), "/state_machines.rs"));
}
