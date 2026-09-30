//! The single authority for LicoUp's endpoint relay: endpoint trust and local
//! endpoint material, secret custody, pairing, pairwise sessions, relay
//! operations, key transparency, command sync, the durable endpoint storage the
//! pinned LicoArc Candidate contract leaves caller-owned, the inbound mapping for
//! one verified peer unit, and the HTTP adapter for an untrusted BadTower
//! transport station.
//!
//! `domain` holds `mobile_relay`, the relay family root, and it declares the
//! whole family: `endpoint_storage`, which owns one pinned-SDK endpoint's
//! durable snapshot, its bounded pending set, the coupled handle lifecycle, the
//! exclusive writer lock and the restart/rollback classification;
//! `endpoint_transport`, which maps one verified peer unit into a value whose
//! provenance keeps the verified author, the verified device and the carriage
//! forwarder apart; `endpoint_trust`, which owns the local endpoint material,
//! the device-trust records and the directory-transparency authorization;
//! `secret_custody`, which owns the runtime secret context and the bounded
//! secret-store authorization batch; `pairwise_session`, which owns the pairwise
//! transaction, its crypto operations and its durable store; `relay_operations`,
//! which owns the command, mailbox, envelope, station, delivery and allow-list
//! surfaces; `pairing`, which owns the pairing claim, creation, status and
//! revocation commands; `config`, with the relay configuration document;
//! `support`, the shared prelude; `key_transparency`, which owns the transparency
//! authority, gossip, publication, provisioning and revocation workflows; and
//! `command_sync`, which synchronizes relay deliveries through one bounded
//! secret-store authorization context. The family tests that exercise all of
//! them live in this crate too, under `domain::mobile_relay::tests`.
//!
//! `platform` holds one: `badtower_station`, the transport adapter that speaks
//! the closed BadTower station contract over loopback or HTTPS. It is carriage
//! only: a station's own report is a read-only hint and never delivery,
//! admission, read or acceptance evidence.
//!
//! Two seams of the family are explicit rather than implicit. The fixtures an
//! out-of-crate test build reads travel behind the `test-support` feature,
//! because `cfg(test)` is false for a dependency. The secure-command path takes
//! four capabilities from its caller — the packaged agent ids, the local target
//! scan, the replay-ledger path and the local executor — because they are
//! composition owned above this crate.
//!
//! `licoup-native` keeps a re-export facade at the former path of every tree
//! that moved here, for the relay, FFI and client-state-migration callers that
//! later Nodes extract.
//!
//! Nothing here reaches upward. The LicoUp crates below are
//! `licoup-protocol-bindings`, which owns the pinned Candidate contract and the
//! shared protocol formats, `licoup-foundation`, which owns the process and IO
//! boundary primitives, `licoup-client-state`, which owns the portable
//! client-state store the relay's configuration and caches are written through,
//! and `licoup-secure-mesh`, which owns the platform secret store the durable
//! snapshot is bound to.
//!
//! The two agent-inventory facts `relay_operations::allow_list` reads — the
//! packaged adapter ids and the local target scan — are owned above this crate
//! and arrive as arguments from the caller that composes them, so no name here
//! refers to the agent inventory. The same is true of the replay-ledger path
//! and the local executor `command_sync` takes, and of the local agent history
//! the executor reads on the caller's side.

pub mod domain;
pub mod platform;

pub(crate) mod state_machines {
    include!(concat!(env!("OUT_DIR"), "/state_machines.rs"));
}
