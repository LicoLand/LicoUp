#[cfg(all(feature = "secure-mesh-acceptance-mock-kt", not(debug_assertions)))]
compile_error!(
    "secure-mesh-acceptance-mock-kt is acceptance-only and cannot be compiled in a release profile"
);

pub mod contracts;
pub mod core;
pub mod domain;
pub mod ffi;
pub mod platform;

/// Every declarative state machine this host compiles from
/// `resources/state-machines`. The JSON configuration is the transition
/// authority; an owner that reads a machine names it through this module.
pub(crate) mod state_machines {
    include!(concat!(env!("OUT_DIR"), "/state_machines.rs"));
}

/// The Agent inventory composition: this host's answers for the port
/// `licoup-agent-targets` declares.
///
/// Like the environment-port and product-version bindings below, it lives at
/// the crate root, above both layers: each fact is answered by the module that
/// owns it, and neither layer has to know the other. The public
/// [`agent_target_port`] accessor is the one path to it.
pub(crate) mod target_port;

/// The process composition entry: installs this host's answers for the
/// environment ports the domain asks.
///
/// It lives at the crate root, above both layers, so neither layer has to know
/// the other: the domain declares the port it needs, the platform owns how the
/// fact is observed, and this function joins them once per process. A process
/// that never calls it keeps every port fail-closed.
pub fn install_environment_ports() -> Result<(), &'static str> {
    domain::conversation::history::install_open_codex_rollouts(
        platform::codex_runtime_observation::open_rollout_paths,
    )?;
    platform::gateway_composition::install_readiness()
}

/// The product version this binary was built with.
///
/// The build script injects `LICO_CLIENT_PRODUCT_VERSION` from
/// `tools/client-version.json`; a build with no injected version is a
/// development build and reports the documented fallback. The composition owns
/// this process fact, so the platform layer answers a package's compatibility
/// admission through it instead of reaching into the domain layer.
pub fn running_product_version() -> anyhow::Result<&'static str> {
    domain::client_state_migration::running_product_version()
}

/// The Agent inventory port this host composes, for the `lico-agent` binary.
///
/// The composition itself is the crate-root [`target_port`] module; this is the
/// one public path to it, so the domain layer no longer hosts a composition
/// that reaches into the platform layer.
pub fn agent_target_port() -> licoup_agent_targets::port::AgentTargetPort {
    target_port::agent_target_port()
}

// The Agent inventory port: the facts `licoup-agent-targets` reads from the
// layers above it. It is declared by the inventory crate and composed by
// `target_port`; this alias keeps the two naming one path without widening the
// host's public surface.
pub(crate) use licoup_agent_targets::port;

