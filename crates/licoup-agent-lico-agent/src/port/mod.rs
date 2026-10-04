//! The port this package asks its host to answer.
//!
//! A package is a program: it carries one Agent's protocol and it owns nothing
//! the client owns. Everything it needs from its host arrives here as a value
//! composition installs once per process, and the port is fail-closed before it
//! is installed — an uninstalled port answers nothing rather than guessing, so a
//! package started without its host cannot invent an effect.
//!
//! One seam is declared. The client owns dispatch and admission: whether this
//! host currently admits new work is a decision the client makes and a package
//! may not bypass, so the package names the seam and the host answers it.
//!
//! The Subagent MCP caller context is deliberately *not* a member here: the
//! mesh dispatches `codex`, `cursor`, `antigravity` and `claude-code`, and never
//! Lico Agent, so there is no delegation fact for this Agent to ask about. A
//! package that declared a seam it never reads would be describing a
//! conversation it does not have.

pub mod execution;
