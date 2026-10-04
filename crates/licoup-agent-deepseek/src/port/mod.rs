//! The ports this package asks the host to answer.
//!
//! A package is a program: it carries one Agent's vendor protocol and it owns
//! nothing the client owns. Everything it needs from its host arrives here as a
//! value composition installs once per process, and every port is fail-closed
//! before it is installed — an uninstalled port answers nothing rather than
//! guessing, so a package started without its host cannot invent an effect.
//!
//! One seam is declared here:
//!
//! - [`usage`] is where one folded session artifact goes. The client owns the
//!   caller — the usage pipeline that decides which artifacts are in scope, how
//!   a sample becomes a request record and which calendar day it lands on — and
//!   this package owns the fold that reads the vendor's own row format, so the
//!   package hands the samples over rather than reimplementing the accounting.
//!
//! The agent-execution port is deliberately *not* declared yet. The client still
//! composes the process half of this Agent — spawning the Harness, supervising
//! the transport and settling the turn — exactly as it does for the Codex
//! package, so a seam nothing answers would describe a route that does not
//! exist. Declaring it is the first step of the client-execution removal this
//! package names as its remainder, not a claim about today.

pub mod usage;
