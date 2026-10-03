//! The authorized-project command family.
//!
//! Seven routes, one registry: register one explicitly declared authorized
//! project, read one registered project, list the registered projects, declare
//! one artifact input a work item takes, and the three queries the declared
//! dependency model exists for — the declared inputs, the ones whose result is
//! not materialized, and the consumers a blocked producer actually blocks. Each
//! route decodes its own arguments into the shared
//! [`licoup_application::ProjectCommand`] and runs it through the single
//! application facade, so the CLI and any other interface reach one
//! implementation with one refusal vocabulary.
//!
//! The registration payload is the declared identity set: project, workspace,
//! plan, authorized root, and the authority reference the caller registers
//! under. Nothing here resolves an identity from a directory.
//!
//! No route composes the store's location: the port resolves the durable store
//! through the layout owner that already names the client-state root, so this
//! surface never joins a directory name of its own. The client bridge family for
//! these commands is not owned here either — `PROJECT-COMMAND-COMPOSITION` owns
//! the generated bridge sides (`schemas/client_bridge/project.json`).

use super::{AdmittedCommand, CliExecution, handler_error};
use crate::domain::application_port;
use anyhow::Result;
use licoup_application::{
    ApplicationCommand, ApplicationFailure, CommandResolution, DependencyDeclarationRequest,
    ProjectCommand, ProjectRegistrationRequest,
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

/// Declare one artifact input: the consumer work item and the result it takes.
///
/// The declaration names the producer inside the artifact, so a payload cannot
/// name one producer and take the result of another.
pub(super) fn handle_project_dependency_declare(command: AdmittedCommand) -> Result<CliExecution> {
    let payload = command
        .option_json("stdin-json")
        .cloned()
        .ok_or_else(|| handler_error("cli_json_invalid", "provide_valid_json"))?;
    let request: DependencyDeclarationRequest = serde_json::from_value(payload)
        .map_err(|_| handler_error("cli_json_invalid", "provide_valid_json"))?;
    Ok(project_surface(ProjectCommand::DeclareDependency(request)))
}

/// Every dependency one project declares, each with its explicit artifact state.
pub(super) fn handle_project_dependency_list(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(project_surface(ProjectCommand::Dependencies {
        project_id: command.required_text("project-id").to_owned(),
    }))
}

/// Every declared reference of one project whose result is not materialized.
pub(super) fn handle_project_dependency_unresolved(
    command: AdmittedCommand,
) -> Result<CliExecution> {
    Ok(project_surface(ProjectCommand::UnresolvedArtifacts {
        project_id: command.required_text("project-id").to_owned(),
    }))
}

/// The consumers one blocked producer blocks, transitively, across projects.
pub(super) fn handle_project_dependency_blocked(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(project_surface(ProjectCommand::BlockedConsumers {
        project_id: command.required_text("project-id").to_owned(),
        work_item_id: command.required_text("work-item-id").to_owned(),
    }))
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
///
/// The one extra field is the public presentation arguments a refusal carries —
/// the work-item path of a refused dependency cycle — and only when the owner
/// published one. A failure with nothing public to say stays exactly as it was.
fn failure_wire(failure: &ApplicationFailure) -> Value {
    let mut body = json!({
        "code": failure.code,
        "stage": failure.stage,
        "retryable": failure.retryable,
        "recovery": failure.recovery.mcp_wire(),
    });
    if !failure.presentation_args.is_empty() {
        body["presentationArgs"] =
            serde_json::to_value(&failure.presentation_args).unwrap_or(Value::Null);
    }
    body
}
