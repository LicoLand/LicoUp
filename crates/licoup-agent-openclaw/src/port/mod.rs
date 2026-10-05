//! The ports this package asks the host to answer.
//!
//! A package is a program: it carries one Agent's vendor protocol and it owns
//! nothing the client owns. Everything it needs from its host arrives here as a
//! value composition installs once per process, and every port is fail-closed
//! before it is installed — an uninstalled port answers nothing rather than
//! guessing, so a package started without its host cannot invent an effect.
//!
//! Two seams are declared, and they are deliberately different shapes:
//!
//! - [`turn_event`] is the host's progressive turn-event emission. The client
//!   owns the sink (a CLI `--stream-events` consumer, a Flutter NDJSON reader)
//!   and this package owns the events one OpenClaw turn produces, so the package
//!   calls the host rather than reimplementing the sink. It is a process-wide
//!   port because the package's state machine emits from deep inside frame
//!   classification, where there is no caller to hand an answer to.
//! - [`execution`] is the agent-execution port. The client owns dispatch,
//!   cancellation and admission; this package owns what one OpenClaw execution
//!   is. The package publishes the vendor side of that contract, and the host
//!   supplies the other side through the extension host that starts this
//!   package's binary.
//!
//! One host fact deliberately has no port: *which* MCP servers a turn registers
//! is the client's own answer, and
//! [`crate::gateway_acp::params::ProtocolConfig::from_params`] takes it as an
//! explicit lazy supplier because that call is the one place the answer is
//! needed. A port would move that fact behind a second global for no gain, and
//! would lose the ordering the kernel has always used — the supplier runs only
//! after the request itself has been accepted.
//!
//! Neither port names a vendor fact about the client: a host that composes no
//! OpenClaw package installs nothing and links nothing of this crate.

pub mod execution;
pub mod turn_event;
