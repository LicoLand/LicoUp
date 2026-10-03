//! The one seam every mutating maintenance operation passes through.
//!
//! Replacing an installed version, or activating one, changes state that running
//! work is reading. The decision that no such work is in flight belongs to one
//! owner: `UPDATE-IDLE-ADMISSION` composes the native idle guard from the
//! canonical execution and process owners and publishes the real verdict.
//!
//! This module is the seam and nothing more. It deliberately does **not** guess,
//! approximate or stub an idle check:
//!
//! - There is exactly one way to obtain a [`MaintenancePermit`]: ask
//!   [`MaintenanceAdmission::admit`]. Its field is private, so no caller can
//!   construct one, and no route can hand itself permission.
//! - While no guard is composed, `admit` refuses **every** mutating request with
//!   one stable code and a reason that says the guard is absent and who owns it.
//!   A refusal is the honest answer; a fabricated "idle" would be a lie that a
//!   later writer cannot detect.
//! - Read-only work never comes here at all. Checking for an update and reading
//!   the catalogue are not mutations and are not gated.
//!
//! When `UPDATE-IDLE-ADMISSION` lands it replaces [`idle_verdict`] with the real
//! decision and this seam starts admitting; every existing caller already routes
//! through it, so there is no second path to close.

use licoup_application::{ApplicationFailure, RecoveryAction};

/// The component a maintenance refusal names.
pub(crate) const COMPONENT: &str = "extension_packages_maintenance";

/// The refusal code: the seam is composed, the guard behind it is not.
pub const ADMISSION_UNAVAILABLE: &str = "package_maintenance_admission_unavailable";

/// The refusal code a composed guard reports for unfinished local work.
pub const ADMISSION_WORK_IN_FLIGHT: &str = "package_maintenance_work_in_flight";

/// The stage every refusal from this seam reports.
pub const STAGE: &str = "extension/package-maintenance";

/// The owner of the real idle guard, named in the refusal so a caller is not
/// left guessing what is missing.
pub const GUARD_OWNER: &str = "UPDATE-IDLE-ADMISSION";

/// A mutating maintenance operation that needs the idle guard.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MaintenanceOperation {
    /// Replace the installed bytes of a package version with another.
    UpdateApply,
    /// Start a generation of an installed package version.
    Activation,
}

impl MaintenanceOperation {
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::UpdateApply => "update-apply",
            Self::Activation => "activation",
        }
    }
}

impl std::fmt::Display for MaintenanceOperation {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.wire_name())
    }
}

/// One request for maintenance admission.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MaintenanceRequest {
    pub operation: MaintenanceOperation,
    pub package_id: String,
    pub version: String,
}

impl MaintenanceRequest {
    pub fn new(
        operation: MaintenanceOperation,
        package_id: impl Into<String>,
        version: impl Into<String>,
    ) -> Self {
        Self {
            operation,
            package_id: package_id.into(),
            version: version.into(),
        }
    }
}

/// The idle verdict the native guard owns.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IdleVerdict {
    /// No locally owned work is in flight and maintenance may proceed.
    Idle,
    /// Work is still unfinished; maintenance is refused and the reason travels.
    Busy,
}

/// The native maintenance-admission seam.
///
/// A zero-sized value: admission is a decision about shared process state, not
/// per-caller state, so there is nothing for a caller to hold. Holding one grants
/// nothing.
#[derive(Clone, Copy, Debug, Default)]
pub struct MaintenanceAdmission;

/// Permission to perform one mutating maintenance operation.
///
/// Not constructible outside this module. Possessing one means the seam admitted
/// the request; while no guard is composed, no value of this type exists.
#[derive(Debug)]
pub struct MaintenancePermit {
    operation: MaintenanceOperation,
}

impl MaintenancePermit {
    pub fn operation(&self) -> MaintenanceOperation {
        self.operation
    }
}

impl MaintenanceAdmission {
    pub const fn new() -> Self {
        Self
    }

    /// Decide one mutating maintenance operation.
    ///
    /// Read-only callers never reach this: a preview, a catalogue read or an
    /// update check is not maintenance and is not gated.
    pub fn admit(
        &self,
        request: &MaintenanceRequest,
    ) -> Result<MaintenancePermit, ApplicationFailure> {
        let refusal_code = match idle_verdict() {
            Some(IdleVerdict::Idle) => {
                return Ok(MaintenancePermit {
                    operation: request.operation,
                });
            }
            Some(IdleVerdict::Busy) => ADMISSION_WORK_IN_FLIGHT,
            // Not "idle" and not "busy": the decision does not exist here yet,
            // and that is the one value that cannot be mistaken for a check.
            None => ADMISSION_UNAVAILABLE,
        };
        // Retryable and with a real next step: the guard is what is missing, and
        // it is expected to arrive. `NotAttempted` is exact here — nothing on the
        // mutation path ran.
        Err(ApplicationFailure::retryable(refusal_code, STAGE)
            .with_recovery(RecoveryAction::RetryAfterRecovery)
            .with_component(COMPONENT)
            .with_field("maintenance")
            .with_presentation_arg("operation", request.operation.wire_name())
            .with_presentation_arg("package", request.package_id.as_str())
            .with_presentation_arg("guardOwner", GUARD_OWNER))
    }

    /// Whether a real idle guard is composed into this process.
    pub fn guard_present(&self) -> bool {
        idle_verdict().is_some()
    }
}

/// The idle decision, or `None` while no guard is composed.
///
/// `UPDATE-IDLE-ADMISSION` owns this function. Until it composes the real guard,
/// the answer is `None`: not "idle", not "busy", but "the decision does not exist
/// here yet". That is the only value that cannot be mistaken for an idle check.
fn idle_verdict() -> Option<IdleVerdict> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// No caller can hand itself permission: the only producer refuses today.
    #[test]
    fn every_mutating_request_is_refused_while_no_guard_is_composed() {
        let admission = MaintenanceAdmission::new();
        assert!(!admission.guard_present());
        for operation in [
            MaintenanceOperation::UpdateApply,
            MaintenanceOperation::Activation,
        ] {
            let request =
                MaintenanceRequest::new(operation, "example.specialist.echo", "2.0.0");
            let failure = admission
                .admit(&request)
                .expect_err("the seam refuses while the guard is absent");
            assert_eq!(failure.code, ADMISSION_UNAVAILABLE);
            assert_eq!(failure.stage, STAGE);
            assert_eq!(failure.component.as_ref(), COMPONENT);
            assert_eq!(failure.field.as_deref(), Some("maintenance"));
            assert!(
                failure.retryable,
                "the guard may arrive; a retry is meaningful"
            );
            assert_eq!(
                operation.wire_name(),
                match operation {
                    MaintenanceOperation::UpdateApply => "update-apply",
                    MaintenanceOperation::Activation => "activation",
                }
            );
        }
    }

    /// The refusal names what is missing and who owns it, so it is a report and
    /// not an opaque failure.
    #[test]
    fn the_refusal_names_the_absent_guard_and_its_owner() {
        assert_eq!(GUARD_OWNER, "UPDATE-IDLE-ADMISSION");
        assert_eq!(idle_verdict(), None);
        let admission = MaintenanceAdmission;
        let failure = admission
            .admit(&MaintenanceRequest::new(
                MaintenanceOperation::UpdateApply,
                "example.specialist.echo",
                "2.0.0",
            ))
            .expect_err("refused");
        let args = failure
            .presentation_args
            .iter()
            .map(|arg| (arg.key.as_str(), arg.value.as_str()))
            .collect::<Vec<_>>();
        assert!(args.contains(&("operation", "update-apply")));
        assert!(args.contains(&("package", "example.specialist.echo")));
        assert!(args.contains(&("guardOwner", "UPDATE-IDLE-ADMISSION")));
    }
}
