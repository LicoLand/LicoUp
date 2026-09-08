//! Codex/Pi work-context bind seam. Hermetic constructors are test-support only.

use licoup_agent_runtime::work_context::{
    HermeticProtocol, NativeWorkContextPort, UnavailableNativeWorkContext, WorkContextConfig,
    WorkContextRuntime, unavailable_work_context_port, work_context_runtime,
};

mod adapter;
#[cfg(any(test, feature = "test-support"))]
mod codex;
mod host_driver;
#[cfg(any(test, feature = "test-support"))]
mod pi;
mod transport;

pub use adapter::{
    CodexAdapterProtocol, PiAdapterProtocol, bind_adapter_work_context,
    bind_persisted_work_context, pi_session_id_missing, unverified_snapshot,
};
pub use host_driver::HostDriverTransport;
pub use transport::{
    AdapterCall, AdapterResponse, AdapterTransport, CountingTransport, UnavailableAdapterTransport,
};

#[cfg(any(test, feature = "test-support"))]
pub use licoup_agent_runtime::work_context::{CapabilityProfile, ChildBinding, SessionPresence};

#[cfg(any(test, feature = "test-support"))]
pub use codex::{hermetic_codex, hermetic_codex_high, hermetic_codex_lost, hermetic_codex_low};
#[cfg(any(test, feature = "test-support"))]
pub use pi::{hermetic_pi, hermetic_pi_high, hermetic_pi_lost, hermetic_pi_low};

pub fn preregistered_work_context_port() -> UnavailableNativeWorkContext {
    unavailable_work_context_port()
}

pub fn boxed_work_context_port() -> Box<dyn NativeWorkContextPort> {
    Box::new(preregistered_work_context_port())
}

/// Test-only hermetic bind. Production attach does not call this.
pub fn bind_host_work_context(
    protocol: HermeticProtocol,
    config: WorkContextConfig,
) -> WorkContextRuntime {
    work_context_runtime(protocol, config)
}

#[cfg(any(test, feature = "test-support"))]
pub fn fixture_child_binding() -> ChildBinding {
    ChildBinding {
        child_conversation_id: "conversation:child".into(),
        membership_id: "membership:child-assistant".into(),
        source_task_id: "goal:source-task".into(),
        parent_conversation_id: "conversation:parent".into(),
    }
}

#[cfg(any(test, feature = "test-support"))]
pub fn fixture_config(knowledge_injected: bool) -> WorkContextConfig {
    WorkContextConfig::child(fixture_child_binding()).with_knowledge_injected(knowledge_injected)
}

#[cfg(any(test, feature = "test-support"))]
pub fn lost_session_protocol(family_codex: bool) -> HermeticProtocol {
    let protocol = if family_codex {
        HermeticProtocol::codex(CapabilityProfile::High)
    } else {
        HermeticProtocol::pi(CapabilityProfile::High)
    };
    protocol.with_presence(SessionPresence::Lost)
}
