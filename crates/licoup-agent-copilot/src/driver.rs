//! Copilot's immutable ACP launch declaration.
//!
//! The shared ACP engine owns how a driver is started, bounded, supervised and
//! reconciled; what Copilot *is* to that engine — its runtime protocol
//! identity, the driver identity the transport pools and cancels sessions by,
//! the arguments its ACP entry point takes, and the error prefix its failures
//! are worded with — is Copilot's own fact and lives here.
//!
//! The declaration is metadata only. The frame dialect the transport reads is
//! resolved from [`crate::dialect`] by [`DRIVER_ID`], so this module cannot
//! name a frame rule and a dialect change is never a change to the spec.

use licoup_agent_drivers::acp_driver_runtime::AcpDriverSpec;

/// The runtime protocol identity Copilot's frames are recorded and reported
/// under.
pub const RUNTIME_PROTOCOL: &str = "copilot-acp-v1-stdio-ndjson";

/// The inbound format this package's declared native converter reads, named by
/// the crate rather than retyped in the release document.
pub const PROTOCOL_FORMAT: &str = "copilot.acp.v1";

/// The driver identity the shared ACP transport pools and cancels Copilot
/// sessions by. It is also the identity [`crate::dialect`] registers under.
pub const DRIVER_ID: &str = "copilot-acp";

/// The error prefix Copilot's protocol failures are worded with.
pub const ERROR_PREFIX: &str = "copilot_acp";

/// Copilot's ACP entry point: the one canonical invocation this Agent is
/// reached through.
pub const LAUNCH_ARGS: &[&str] = &["--acp", "--stdio", "--no-auto-update"];

/// Copilot's immutable launch declaration, as the shared engine reads it.
pub const DRIVER: AcpDriverSpec = AcpDriverSpec::new(RUNTIME_PROTOCOL, LAUNCH_ARGS)
    .with_identity(DRIVER_ID, ERROR_PREFIX);
