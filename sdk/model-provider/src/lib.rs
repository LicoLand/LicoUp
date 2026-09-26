//! C10 host-side model provider runtime: configuration generations, catalogs,
//! credentials and streams.
//!
//! This package is the host half of the model-provider contract
//! ([`licoup_extension_contracts::provider`]). The contract owns the shapes — a
//! provider configuration, a catalog key, an alias, a credential scope, a
//! dialect; this runtime owns what happens over time: which generation a request
//! binds to, which catalog a reader sees, which credential a stream carries and
//! how a stream ends.
//!
//! Three properties are enforced here rather than documented:
//!
//! - **Updates are atomic and old generations stay addressable.**
//!   [`ProviderRuntime::install_user`] assigns a new generation and publishes
//!   a fresh snapshot in one step. A reader never sees half an update, and a
//!   stream that was bound to an earlier generation keeps its configuration and
//!   its credential scope until it reaches a terminal state. Removing a provider
//!   neither rewrites another provider nor restores a default it shadowed.
//! - **Unknown stays unknown.** Usage facts are [`Option`]s end to end, so a
//!   provider that reports no token counts produces `None`, never zero. A model
//!   whose context limit or price is unpublished keeps `None` through the
//!   catalog.
//! - **A custom API supplies its own adapter.** A compatible dialect is served
//!   by a transport registered for that dialect; anything else is served only by
//!   a stream adapter registered under the `streamAdapter` id the configuration
//!   named, and the absence of one is an actionable refusal, never a silent
//!   imitation of a compatible API.
//!
//! The runtime never holds key material: a configuration carries a
//! `credential:` handle and [`CredentialVault`] resolves it per provider *and*
//! endpoint origin, so pointing a provider at a new origin does not inherit the
//! old endpoint's secret.

pub mod auth;
pub mod catalog;
pub mod credentials;
pub mod instance;
pub mod plugin;
pub mod registry;
pub mod runtime;
pub mod stream;

#[allow(dead_code, clippy::collapsible_if, clippy::enum_variant_names)]
pub(crate) mod state_machine {
    include!(concat!(env!("OUT_DIR"), "/state_machines.rs"));
}

pub use auth::{AuthChallenge, AuthDriver, AuthFlow, AuthInput, AuthStage, SecretInputHandle};
pub use catalog::{CatalogEntry, ModelCatalog, Selection};
pub use credentials::{CredentialHandle, CredentialResolution, CredentialVault};
pub use instance::ProviderInstance;
pub use plugin::{AdapterFactory, AdapterRegistry, ProviderPlugin, ProviderPluginAdapter};
pub use registry::{
    InstallReceipt, ProviderOrigin, ProviderRegistry, RegisteredProvider, RegistrySnapshot,
    RemoveReceipt,
};
pub use runtime::ProviderRuntime;
pub use stream::{
    CancelOutcome, CancelReport, CancelSupport, StartAck, StreamAdapter, StreamBinding,
    StreamEvent, StreamRequest, StreamSession, StreamTerminal, StreamUsage, TerminalState,
};

pub use licoup_extension_contracts::provider::{
    AliasTable, CatalogSource, Dialect, ModelCatalogKey, ProviderConfig, ProviderModel,
    credential_ref_is_handle, endpoint_origin,
};

/// The failure vocabulary this runtime raises, built once so every module names
/// the same component and none invents a second error account.
pub(crate) mod refusal {
    use licoup_application::{ApplicationFailure, RecoveryAction};

    /// The component every failure from this runtime names.
    pub(crate) const COMPONENT: &str = "model_provider";

    /// A refusal that is a fact about the configuration or the stream, not about
    /// the shape of a request.
    pub(crate) fn new(code: &str, stage: &str) -> ApplicationFailure {
        ApplicationFailure::permanent(code, stage).with_component(COMPONENT)
    }

    /// A refusal whose next step is a real one for the user: configure, install
    /// or select something that exists.
    pub(crate) fn actionable(
        code: &str,
        stage: &str,
        field: &str,
        recovery: RecoveryAction,
    ) -> ApplicationFailure {
        new(code, stage).with_field(field).with_recovery(recovery)
    }
}
