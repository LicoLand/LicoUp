//! The authorized-project command family.
//!
//! Three routes, one registry: register one explicitly declared authorized
//! project, read one registered project, list the registered projects. Each
//! route decodes its own arguments into the shared
//! [`licoup_application::ProjectCommand`] and runs it through the single
//! application facade, so the CLI and any other interface reach one
//! implementation with one refusal vocabulary.
//!
//! The registration payload is the declared identity set: project, workspace,
//! plan, authorized root, and the authority reference the caller registers
//! under. Nothing here resolves an identity from a directory.

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
