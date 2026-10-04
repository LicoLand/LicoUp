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

/// The model catalogue composition: this host's answers for the port
/// `licoup-model-catalog` declares.
///
/// It lives at the crate root for the same reason the inventory's does: the
/// catalogue owns the selection facts, this host owns the probe, the
/// declarations and the data roots, and neither layer has to know the other.
pub(crate) mod model_catalog_port;
/// The driver core's lane composition: this host's own conversation, generic
/// CLI, caller-manager and collaboration lanes, in the shape
/// `licoup-agent-drivers` reads them through its port.
///
/// It lives at the crate root for the same reason [`target_port`] does: two of
/// its answers read domain facts, and the platform layer may not reach the
/// domain layer. The layer that owns each fact stays where it is; this module
/// joins them once, above both.
pub(crate) mod host_lane;

/// The process composition entry: installs this host's answers for the ports
/// its layers ask.
///
/// It lives at the crate root, above both layers, so neither layer has to know
/// the other: a layer declares the port it needs, the other owns the fact, and
/// this function joins them once per process. That covers the environment
/// ports the domain asks, the gateway runtime's ports, the stop control's
/// Subagent-claim dispatcher, which the domain answers, and the ports the two
/// Agent adapter packages ask for — the progressive turn-event sink Codex emits
/// through and the execution admission Kimi Code asks for. A process that never
/// calls it keeps every port fail-closed.
pub fn install_environment_ports() -> Result<(), &'static str> {
    domain::conversation::history::install_open_codex_rollouts(
        licoup_agent_codex::observation::open_rollout_paths,
    )?;
    platform::gateway_composition::install_readiness()?;
    platform::stop_control::install_subagent_claim_stop(stop_subagent_claim)?;
    licoup_model_catalog::install_model_catalog_port(model_catalog_port::model_catalog_port())?;
    platform::extension_packages::install_maintenance_admission(std::sync::Arc::new(
        PackageGenerationAdmission,
    ))?;
    // The cross-device entry is this host's own inbound door for verified peer
    // units. It is installed here so the native route and the device layer reach
    // one owner; a process that never installs it refuses every admission
    // instead of inventing an entry with no bindings.
    domain::cross_device_entry::install()?;
    // An adapter package owns what one of its turns emits; this host owns where
    // it goes, because the host owns the consumer. Each package is linked here
    // for its registration while its binary route is completed by the
    // agent-execution port, and a host that never installs these ports leaves the
    // packages' emitters silent rather than inventing a consumer.
    licoup_agent_codex::port::turn_event::install(platform::codex_turn_event_port())?;
    licoup_agent_antigravity::port::turn_event::install(
        platform::antigravity_turn_event_port(),
    )?;
    // The Antigravity package asks this host two execution questions. The caller
    // context belongs to the Subagent mesh's own binding, and the admission
    // answer is the host's close-admission barrier, which a launching turn may
    // not bypass.
    licoup_agent_antigravity::port::execution::install(
        licoup_agent_antigravity::port::execution::ExecutionPort {
            subagent_caller_context: subagent_caller_context,
            admits_execution: admits_agent_execution,
        },
    )?;
    // The Kimi Code adapter package owns what one Kimi execution is; the one fact
    // it cannot derive is whether this host currently admits new work, because the
    // idle-admission decision is the host's. Installing the answer is what lets a
    // Kimi turn run at all, and a host that never installs it refuses rather than
    // running.
    licoup_agent_kimi::port::execution::install(licoup_agent_kimi::port::execution::ExecutionPort {
        admits_execution: admits_agent_execution,
    })?;
    // The Kilo Code adapter package owns what one Kilo turn is — the request
    // shape, the session protocol, the stream classification and the projection —
    // and this host owns the serve engine it runs on and the consumer its events
    // reach. Both ports are installed together because a package with an engine
    // and no consumer, or a consumer and no engine, is half-wired. The package's
    // binary route is completed by the agent-execution port; until then the client
    // still performs the turn, and removing that is the named remainder on
    // VENDOR-CODE-REMOVAL.
    licoup_agent_kilo::host::install(platform::kilo_code_host::host_ports())
}

/// The composition's answer for the Antigravity adapter package's caller-context
/// query: the exported Subagent caller context this host's own drivers bind.
///
/// It is the same environment contract the launcher applies, read through the
/// port so the package asks the host rather than reading a second copy of the
/// variable names.
fn subagent_caller_context() -> Option<String> {
    let provider = std::env::var("LICOUP_MCP_CALLER_PROVIDER").ok()?;
    if provider.trim().is_empty() {
        return None;
    }
    Some(provider)
}

/// Whether this host admits a new Agent execution right now: admission is open
/// unless a maintenance switch holds the close-admission barrier.
///
/// The barrier is the same record package activation and data conversion hold,
/// and it is read when the question is asked rather than cached, so a turn
/// cannot start from a decision the host has since closed. A data root whose
/// barrier cannot be read admits nothing: an unreadable record is not evidence
/// that admission is open.
fn admits_agent_execution() -> bool {
    let Ok(data_root) = licoup_foundation::platform::paths::portable_data_dir() else {
        return false;
    };
    domain::work_admission::WorkAdmission::open(data_root)
        .barrier()
        .is_ok_and(|barrier| barrier.is_none())
}

/// The composition's answer for the package-generation admission port: the
/// host-wide idle decision and its barrier, which live in the domain layer.
struct PackageGenerationAdmission;

impl platform::extension_packages::MaintenanceAdmission for PackageGenerationAdmission {
    fn hold(&self, data_root: &std::path::Path) -> Result<(), &'static str> {
        domain::work_admission::hold_package_activation_admission(data_root)
    }

    fn release(&self, data_root: &std::path::Path) -> Result<(), &'static str> {
        domain::work_admission::release_maintenance_admission(data_root)
    }
}

/// The composition's answer for the stop control's Subagent-claim port: the
/// claim owner's own dispatcher, which lives in the domain layer.
fn stop_subagent_claim(
    conversation_id: &str,
    caller_membership_id: &str,
    target_membership_id: &str,
) -> Result<serde_json::Value, &'static str> {
    domain::subagents::stop_active_claim(
        conversation_id,
        caller_membership_id,
        target_membership_id,
    )
    .map_err(|error| error.code)
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
