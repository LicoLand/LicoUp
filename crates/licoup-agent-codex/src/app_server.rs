//! The Codex app-server protocol vocabulary this package owns.
//!
//! It is the *wire* half of one Codex turn: the request identifiers, the phases
//! the handshake advances through, the effects a parsed frame produces, the
//! failure shape the parser reports, the effective settings a thread response
//! establishes, the launch configuration, and the reserve-model projection.
//!
//! It is here rather than in the client because it is Codex's protocol, and
//! ADR-0008 keeps vendor protocol below the adapter port: a raw app-server line
//! is parsed once, here, and nothing above the port re-parses it. A client that
//! carries no Codex package therefore carries no app-server field name at all.
//!
//! `driver` — the process that speaks this protocol to a real app-server — moves
//! here too; while it is still composed by the client, the client reads these
//! modules through this package rather than keeping a second copy.

pub mod config;
pub mod contract;
pub mod failure;
pub mod limits;
pub mod model;
pub mod reserve;
