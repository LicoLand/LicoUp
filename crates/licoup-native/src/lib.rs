#[cfg(all(feature = "secure-mesh-acceptance-mock-kt", not(debug_assertions)))]
compile_error!(
    "secure-mesh-acceptance-mock-kt is acceptance-only and cannot be compiled in a release profile"
);

pub mod contracts;
pub mod core;
pub mod domain;
pub mod ffi;
pub mod platform;

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
