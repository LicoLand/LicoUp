//! The endpoint collaboration authority check every outbound send passes.
//!
//! The composition above resolves what the host knows about the optional
//! endpoint collaboration package, and this port is the one place the sending
//! half of [`crate::domain::mobile_relay`] asks it. Nothing here opens a store,
//! performs a cryptographic operation or classifies a transport outcome: it
//! answers whether this client may emit outbound endpoint traffic at all, and
//! refuses with the owner's own stable reason when it may not.
//!
//! The check is deliberately at the send entries rather than in the user
//! interface: a disabled or uninstalled package must cut the capability, and a
//! hidden control is not a cut.
//!
//! The port is a value of one `fn` pointer, so the sending half keeps no state
//! the composition did not hand it. A process that composed no answer reads
//! [`pre_package_path_permits`]: the kernel's own pre-package path is what is
//! actually running then, exactly as the host's own gate answers before the
//! package lifecycle installs anything.

use anyhow::{Result, anyhow};
use std::sync::OnceLock;

/// Answers whether this process may emit outbound endpoint traffic, or the
/// owner's own stable reason it may not.
pub type EndpointOutboundAuthorityAnswer = fn() -> Result<(), &'static str>;

/// The answer a process that composed no package authority gives.
///
/// The build carries the kernel's own pre-package path, and that path is what is
/// running, so it permits the send. It is a statement about which implementation
/// runs, not a grant: an installed package that was switched off, removed or
/// left unreadable installs its own refusal into this port and cuts the
/// capability.
pub fn pre_package_path_permits() -> Result<(), &'static str> {
    Ok(())
}

/// One process's installed answer.
///
/// The production program has exactly one; tests build their own, so the
/// uncomposed answer and an installed one are both observable without depending
/// on test order.
pub struct EndpointOutboundAuthorityPort {
    answer: OnceLock<EndpointOutboundAuthorityAnswer>,
}

impl EndpointOutboundAuthorityPort {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            answer: OnceLock::new(),
        }
    }

    /// Install the composition's answer. One answer per port: a second
    /// installation is refused rather than silently replacing the first.
    pub fn install(&self, answer: EndpointOutboundAuthorityAnswer) -> Result<(), &'static str> {
        self.answer
            .set(answer)
            .map_err(|_| "the endpoint outbound authority is already installed")
    }

    /// The installed answer, or the pre-package one.
    ///
    /// An installed refusal is authoritative and refuses. With nothing installed
    /// the client runs its own pre-package path, and that path is named as such
    /// rather than reported as a granted package authority.
    pub fn authority(&self) -> Result<(), &'static str> {
        self.answer
            .get()
            .copied()
            .unwrap_or(pre_package_path_permits)()
    }

    /// Refuse an outbound send this answer does not permit, in the owner's own
    /// words.
    pub(in crate::domain::mobile_relay) fn ensure_permitted(&self) -> Result<()> {
        match self.authority() {
            Ok(()) => Ok(()),
            Err(reason) => Err(anyhow!("{reason}")),
        }
    }
}

impl Default for EndpointOutboundAuthorityPort {
    fn default() -> Self {
        Self::new()
    }
}

static PORT: EndpointOutboundAuthorityPort = EndpointOutboundAuthorityPort::new();

/// Install the composition's answer for this process.
///
/// Called once by `install_environment_ports`. A process that never calls it
/// keeps the kernel's own pre-package path, which is what the host's gate
/// answers with before the package lifecycle installs anything.
pub(crate) fn install_endpoint_outbound_authority(
    answer: EndpointOutboundAuthorityAnswer,
) -> Result<(), &'static str> {
    PORT.install(answer)
}

/// Refuse an outbound send the installed package authority does not permit.
pub(in crate::domain::mobile_relay) fn ensure_outbound_permitted() -> Result<()> {
    PORT.ensure_permitted()
}

#[cfg(test)]
mod tests {
    use super::{
        EndpointOutboundAuthorityPort, ensure_outbound_permitted, pre_package_path_permits,
    };

    /// The answer an installed package the user switched off gives.
    fn package_switched_off() -> Result<(), &'static str> {
        Err("endpoint_collaboration_package_disabled")
    }

    /// The answer an installed package that owns the outbound path gives.
    fn package_owns_the_path() -> Result<(), &'static str> {
        Ok(())
    }

    #[test]
    fn an_uncomposed_port_runs_the_kernel_own_pre_package_path() {
        let port = EndpointOutboundAuthorityPort::new();

        assert_eq!(port.authority(), pre_package_path_permits());
        assert!(port.ensure_permitted().is_ok());
    }

    #[test]
    fn an_installed_authority_permits_the_send() {
        let port = EndpointOutboundAuthorityPort::new();
        port.install(package_owns_the_path).unwrap();

        assert!(port.ensure_permitted().is_ok());
    }

    #[test]
    fn an_installed_refusal_reaches_the_send_as_the_owners_own_reason() {
        let port = EndpointOutboundAuthorityPort::new();
        port.install(package_switched_off).unwrap();

        assert_eq!(
            port.ensure_permitted().unwrap_err().to_string(),
            "endpoint_collaboration_package_disabled"
        );
    }

    #[test]
    fn one_answer_per_port_and_the_first_one_wins() {
        let port = EndpointOutboundAuthorityPort::new();
        port.install(package_switched_off).unwrap();

        assert!(port.install(pre_package_path_permits).is_err());
        assert_eq!(
            port.authority(),
            Err("endpoint_collaboration_package_disabled")
        );
    }

    #[test]
    fn the_process_wide_port_permits_until_the_composition_installs_an_answer() {
        // Nothing but `install_environment_ports` installs into the
        // process-wide port, so an uncomposed lib test reads the kernel's own
        // pre-package path here, which is the production default too.
        assert!(ensure_outbound_permitted().is_ok());
    }
}
