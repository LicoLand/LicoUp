//! V7-X1 acceptance at `component-integration` level: the runtime capability
//! catalog, on-demand activation, generation hot-swap and fault domains.
//!
//! This harness composes the production [`licoup_native::platform::extension_host`]
//! slice — the real catalog snapshots, the contract crate's profile decision,
//! the M13 admission rules and the real instance/in-flight machine — and drives
//! it through controlled in-process carriers that implement the production
//! `ExtensionCarrier` port. Versions, revocation and repeated concurrency are
//! exercised against that port rather than against canned JSON.
//!
//! What this harness does not prove, stated plainly: there is no subprocess and
//! no OS confinement here, so nothing below is process-isolation evidence. The
//! real untrusted-process fixture and the resource-quota enforcement belong to
//! X2, and the production wiring of the module into the CLI/MCP/desktop entry
//! points is the native integration owner's step, not this component's.
//!
//! Scenarios: A18 (catalog discovery and error chain), A19 (replaceable carrier
//! and fault domains), A30 (hot reload and in-flight binding), A38 (fault
//! injection around the activation lifecycle).

mod a18_catalog;
mod a19_isolation;
mod a30_generation;
mod a38_lifecycle;
mod cross_host_identity;
mod persistence_and_owner;
mod runtime_catalog_journal;
mod support;
