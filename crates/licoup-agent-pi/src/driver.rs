//! The Pi driver vocabulary this package owns.
//!
//! A Pi RPC turn is described by this Agent's own facts: the failure shape its
//! protocol reports, the effective settings a session negotiated, the launch
//! configuration one request becomes, and the session records a native resume
//! resolves against. All four are Pi's, so they live beside the parser that
//! reads Pi's frames rather than in the client that starts the process.
//!
//! What is *not* here is the process half — spawning `pi --mode rpc`, reading
//! its pipes, supervising the turn and answering control requests. That half
//! stays in the client until the agent-execution port this package declares
//! carries it, and the client reads the vocabulary below from here.

pub mod errors;
pub mod model;
pub mod params;
pub mod sessions;
