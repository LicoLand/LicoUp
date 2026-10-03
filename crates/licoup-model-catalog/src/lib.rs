//! The model selection catalogue: what a model identity is, what this host has
//! actually observed, and what it costs — kept apart and never guessed.
//!
//! Three kinds of fact live here, and the crate exists so that they stay
//! distinguishable:
//!
//! - **declared identity** ([`identity`]): the canonical model a selector
//!   names, its lab, its family and the provider aliases that reach it,
//!   including the historical aliases recorded usage is projected through.
//!   Identity is a declaration about names, not a claim that this host can run
//!   the model.
//! - **observed availability** ([`availability`]): which models a live source
//!   on this machine reported, with the time it reported them. An observation
//!   is evidence with a timestamp; its absence is `Unknown`, and nothing is
//!   ever synthesized as available from a name, a price row or an intelligence
//!   score.
//! - **recorded price facts** ([`pricing`]) and the [`planning`] inputs built
//!   on them. A missing route has no price; it is never priced at zero.
//!
//! [`selection`] is the one query that joins them, and it reports the two
//! dimensions separately: a declared model this host never observed is not
//! available, and an observed model with no declared identity is still
//! observed.
//!
//! The crate reads nothing owned above it directly. Probes, credential states
//! and source generations arrive through [`port::ModelCatalogPort`], which this
//! crate declares and the `licoup-native` crate root composes; the crate's own
//! fail-closed answer is [`port::ModelCatalogPort::unavailable`], and a process
//! that composes nothing keeps it.
//!
//! Nothing here reaches upward: the only LicoUp dependency is
//! `licoup-foundation`, which owns the path, atomic-write and display-name
//! primitives every consumer of these facts already stands on.

pub mod availability;
pub mod identity;
pub mod planning;
pub mod port;
pub mod pricing;
pub mod selection;

pub use availability::{
    ObservedAvailability, ObservedCatalog, ObservedCatalogCache, ObservedModel, now_unix_ms,
};
pub use identity::{
    CanonicalModel, RegistrySnapshot, SnapshotProvenance, model_display_name, snapshot_report,
};
pub use planning::{PlanningModelPrice, planning_agent_model_price, planning_model_price};
pub use port::{
    CatalogSourceGeneration, CredentialState, ModelCatalogPort, install_model_catalog_port,
    model_catalog_port,
};
pub use pricing::{ModelTokenPrice, agent_model_price, model_price};
pub use selection::{
    SelectionEvidence, SelectionFacts, SelectionReport, declared_facts, selection_facts,
    selection_report, unknown_facts,
};
