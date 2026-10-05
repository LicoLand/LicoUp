//! The Kilo Code `serve` driver, composed from the Kilo Code adapter package.
//!
//! The Agent's own half of a turn — the launch configuration, the request shape,
//! the session-open protocol, the stream classification, the result projection,
//! the capability probe and the endpoint policy — belongs to Kilo Code and lives
//! in `licoup-agent-kilo` now. What is left here is the composition: the client's
//! serve engine answered through the package's ports
//! ([`super::kilo_code_host`]), the shared ACP result vocabulary the driver table
//! reads, and the force-stop lane.
//!
//! The protocol reader is re-exported at its former path so the leaves below keep
//! reading it, and so the client carries one copy of the vocabulary rather than
//! two. It is the same parser the package's own replay arm drives, which is what
//! makes a recorded transcript a statement about the production ingress.

pub(crate) mod execution;
pub(crate) mod probe;

use super::acp_driver_runtime::AcpDriverSpec;
use licoup_agent_kilo::driver::{DRIVER_ID, ERROR_PREFIX};

/// This Agent's adapter parser, read from the package that owns it.
///
/// `health_ready`, `session_collection`, `session_id`, `message` and
/// `ServeEventParser` are the same functions the package's driver and its replay
/// arm call, so a divergence between the two cannot be expressed.
pub(in crate::platform) use licoup_agent_kilo::parser as parser;

pub(super) const KILO_CODE_DRIVER: AcpDriverSpec = AcpDriverSpec::new(
    licoup_agent_kilo::driver::RUNTIME_PROTOCOL,
    &["serve"],
)
.with_identity(DRIVER_ID, ERROR_PREFIX);

/// The runtime protocol stamp this Agent's results carry.
pub(super) const RUNTIME_PROTOCOL: &str = licoup_agent_kilo::driver::RUNTIME_PROTOCOL;

/// The durable serve owner descriptor force stop reads.
pub(crate) const CONTROL_SPEC: super::local_service::ServeSpec =
    super::kilo_code_host::CONTROL_SPEC;

/// The two engine entries the driver table reads.
///
/// The re-export is at the width of its readers — the driver table and force
/// stop, both inside this layer — and no wider, so the visibility it carries is
/// the visibility the definitions carry.
pub(in crate::platform) use execution::execute;
pub(in crate::platform) use probe::capability_probe;

/// Reach the endpoint's active turn for force stop.
///
/// The active-turn registry belongs to the serve engine, not to the package: it
/// is the same registry every serve-family Agent's stop uses.
pub(crate) fn cancel(
    session_id: &str,
) -> super::local_service::turn_control::ControlDisposition {
    super::local_service::turn_control::cancel(KILO_CODE_DRIVER.agent_id, session_id)
}

#[cfg(test)]
mod tests;
