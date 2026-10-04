//! The authorized-project command family.
//!
//! Five routes, one registry: register one explicitly declared authorized
//! project, read one registered project, list the registered projects, and
//! preview or apply one canonical plan document. Each route decodes its own
//! arguments into the shared [`licoup_application::ProjectCommand`] and runs it
//! through the single application facade, so the CLI, an authorized Agent
//! caller and any other interface reach one implementation with one refusal
//! vocabulary.
//!
//! The registration payload is the declared identity set: project, workspace,
//! plan, authorized root, and the authority reference the caller registers
//! under. Nothing here resolves an identity from a directory.
//!
//! # Converting a source into a plan document
//!
//! `project import-preview` and `project import-apply` take the canonical plan
//! document on `--stdin-json`; an apply also takes the `--expected-revision` it
//! previewed. The caller — a person, a script or an authorized Agent — reads the
//! source under its own authorization and converts it deliberately. This owner
//! never opens, scans or parses a source document, and there is no model call
//! anywhere on this path.
//!
//! The document declares `schema` (`licoup.project-plan/v1`), `projectId`,
//! `planId`, the `source` it was read from and one or more `workItems`. Each work
//! item declares its `workItemId`, `outcome`, `acceptance` criteria, `inputs`,
//! `roles` and the `sourceAnchor` it was read from. Two properties are not
//! negotiable, and both are refusals rather than repairs:
//!
//! - **Progress is not admitted.** A `status`, `progress`, `completedAt`,
//!   `accepted` or similar field is refused by code
//!   (`project_plan_progress_not_admitted`) and by path. A run, a completion and
//!   an acceptance are established by the work owner that observed them; an
//!   import can never mark work executed or accepted.
//! - **An omission is not a deletion.** A work item the document leaves out is
//!   retained and reported as `retained`, never deleted or cancelled.
//!
//! A preview changes nothing and returns the revision an apply must expect. An
//! apply whose `--expected-revision` is not current is refused
//! (`project_plan_import_stale_apply`); re-submitting the document already
//! stored is one effect, not two. An import never starts execution and never
//! widens a directory, cost, disclosure or task grant.

use super::{AdmittedCommand, CliExecution, handler_error};
use crate::domain::application_port;
use anyhow::Result;
use licoup_application::{
    ApplicationCommand, ApplicationFailure, CommandResolution, ProjectCommand,
    ProjectRegistrationRequest,
};
use serde_json::{Value, json};

/// Stable identifier of the envelope this surface publishes.
const PROJECT_ENVELOPE_SCHEMA: &str = "licoup.project-identity/v1";

pub(super) fn handle_project_register(command: AdmittedCommand) -> Result<CliExecution> {
    let payload = command
        .option_json("stdin-json")
        .cloned()
        .ok_or_else(|| handler_error("cli_json_invalid", "provide_valid_json"))?;
    let request: ProjectRegistrationRequest = serde_json::from_value(payload)
        .map_err(|_| handler_error("cli_json_invalid", "provide_valid_json"))?;
    Ok(project_surface(ProjectCommand::Register(request)))
}

pub(super) fn handle_project_read(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(project_surface(ProjectCommand::Read {
        project_id: command.required_text("project-id").to_owned(),
    }))
}

pub(super) fn handle_project_list(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(project_surface(ProjectCommand::List))
}

pub(super) fn handle_project_import_preview(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(project_surface(ProjectCommand::ImportPreview {
        document: import_document(&command)?,
    }))
}

pub(super) fn handle_project_import_apply(command: AdmittedCommand) -> Result<CliExecution> {
    let expected_revision = command
        .option_text("expected-revision")
        .ok_or_else(|| handler_error("cli_argument_invalid", "provide_expected_revision"))?
        .parse::<u64>()
        .map_err(|_| handler_error("cli_argument_invalid", "provide_expected_revision"))?;
    Ok(project_surface(ProjectCommand::ImportApply {
        document: import_document(&command)?,
        expected_revision,
    }))
}

/// The one canonical plan document an import command carries.
///
/// The document arrives as JSON because it is the caller's deliberate
/// conversion of a source this owner never reads; whether it is canonical is the
/// project owner's answer, reported with its own codes and paths.
fn import_document(command: &AdmittedCommand) -> Result<Value> {
    command
        .option_json("stdin-json")
        .cloned()
        .ok_or_else(|| handler_error("cli_json_invalid", "provide_valid_json"))
}

/// Run one project command through the shared facade and frame its resolution.
fn project_surface(command: ProjectCommand) -> CliExecution {
    let mut envelope = json!({
        "schema": PROJECT_ENVELOPE_SCHEMA,
        "family": "project",
        "operation": command.operation().as_str(),
    });
    match application_port::execute(&ApplicationCommand::Project(command)) {
        CommandResolution::Resolved(outcome) => {
            envelope["status"] = Value::String("ok".to_owned());
            envelope["outcome"] = serde_json::to_value(outcome).unwrap_or(Value::Null);
        }
        CommandResolution::Failed(failure) => {
            envelope["status"] = Value::String("failed".to_owned());
            envelope["failure"] = failure_wire(&failure);
        }
    }
    CliExecution::Json(envelope)
}

/// The failure body: the neutral fields, with the caller's own code and stage.
fn failure_wire(failure: &ApplicationFailure) -> Value {
    json!({
        "code": failure.code,
        "stage": failure.stage,
        "retryable": failure.retryable,
        "recovery": failure.recovery.mcp_wire(),
    })
}
