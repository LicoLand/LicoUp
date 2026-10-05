//! The port this package asks its host to answer.
//!
//! A package is a program: it carries one Agent's vendor protocol and it owns
//! nothing the client owns. Everything it needs from its host arrives here as a
//! value composition installs once per process, and the port is fail-closed
//! before it is installed — an uninstalled port answers nothing rather than
//! guessing, so a package started without its host cannot invent an effect.
//!
//! One seam is declared, and it is the reason this module exists at all:
//! [`execution`] carries the host's own admission decision. The `serve` engine
//! that starts the endpoint, the HTTP and SSE readers and the active-turn
//! registry are the client's shared local-service machinery and stay the
//! client's, so a package-side `turn_event` or `serve` seam would describe a
//! route this package does not have. Admission is different: it is the one fact
//! a turn may not derive for itself, and a package that could skip it would be
//! able to start work while the client is replacing installed state.

pub mod execution;
