//! The project family behind the shared `licoup_application` facade.
//!
//! One translation each way: the typed command becomes the crate owner's own
//! registration or query, and the owner's answer becomes the neutral
//! [`CommandOutcome`] both interfaces already publish. The port decides nothing
//! about identity, authority or durability — it supplies the authority answer
//! and the store, and refuses a registration the caller's own claim cannot
//! authorize before the store is reached.
//!
//! The store is opened per call, exactly as the workflow store opens its own
//! connection: a one-shot CLI process and the durable desktop host then read the
//! same rows, and a data root that is unavailable becomes a typed retryable
//! failure instead of a facade that cannot be composed.

use super::authority::VerifiedClaimAuthority;
use crate::domain::project::{portable_store, store_at};
use licoup_application::{
    ActorClaim, ApplicationFailure, CommandOutcome, FailureNormalization, Operation,
    OperationReference, OperationState, ProjectCommand, ProjectPort, ProjectRegistrationRequest,
};
use licoup_project::{
    AuthorityKind, AuthorityReference, ImportDiagnostic, PLAN_IMPORT_STAGE, PlanAdmission,
    PlanDocument, ProjectFailure, ProjectId, ProjectIdentitySource, ProjectIdentityStore,
    ProjectRegistration, RegisteredProject,
};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// Which portable data root this family composes over.
#[derive(Clone, Debug)]
enum ProjectStoreRoot {
    /// The data root this process selected.
    Portable,
    /// An explicit root, used by tests and by an embedding host.
    At(PathBuf),
}

/// The project identity family, composed over one durable store root.
pub struct NativeProjectApplication {
    root: ProjectStoreRoot,
}

impl NativeProjectApplication {
    /// Compose the family over a store rooted at one portable data root.
    pub fn at(portable_root: &Path) -> Self {
        Self {
            root: ProjectStoreRoot::At(portable_root.to_path_buf()),
        }
    }

    /// Compose the family over this process's portable data root.
    pub fn portable() -> Self {
        Self {
            root: ProjectStoreRoot::Portable,
        }
    }

    /// Open the durable store this family reads and writes.
    pub fn store(&self) -> Result<ProjectIdentityStore, ProjectFailure> {
        match &self.root {
            ProjectStoreRoot::Portable => portable_store(),
            ProjectStoreRoot::At(root) => store_at(root),
        }
    }
}

impl ProjectPort for NativeProjectApplication {
    fn execute(
        &self,
        claim: &ActorClaim,
        command: &ProjectCommand,
    ) -> Result<CommandOutcome, ApplicationFailure> {
        match command {
            ProjectCommand::Register(request) => self.register(claim, request),
            ProjectCommand::Read { project_id } => {
                let project_id = ProjectId::declare(project_id.clone()).map_err(failure)?;
                let project = self
                    .store()
                    .map_err(failure)?
                    .read(&project_id)
                    .map_err(failure)?;
                Ok(read_outcome(
                    Operation::ProjectRead,
                    json!({"project": project.as_ref().map(project_wire)}),
                ))
            }
            ProjectCommand::List => {
                let projects = self
                    .store()
                    .map_err(failure)?
                    .list()
                    .map_err(failure)?
                    .iter()
                    .map(project_wire)
                    .collect::<Vec<_>>();
                Ok(read_outcome(
                    Operation::ProjectList,
                    json!({"projects": projects}),
                ))
            }
            ProjectCommand::ImportPreview { document } => {
                let admission = admit_document(document.clone())?;
                let change = self
                    .store()
                    .map_err(failure)?
                    .preview_import(&admission)
                    .map_err(failure)?;
                Ok(read_outcome(
                    Operation::ProjectImportPreview,
                    serde_json::to_value(change).unwrap_or(Value::Null),
                ))
            }
            ProjectCommand::ImportApply {
                document,
                expected_revision,
            } => {
                let admission = admit_document(document.clone())?;
                let outcome = self
                    .store()
                    .map_err(failure)?
                    .apply_import(&admission, *expected_revision)
                    .map_err(failure)?;
                Ok(CommandOutcome::new(OperationReference::new(
                    Operation::ProjectImportApply,
                    admission.document.plan_id.as_str(),
                    OperationState::Completed,
                ))
                .with_payload(serde_json::to_value(outcome).unwrap_or(Value::Null)))
            }
        }
    }
}

/// Parse and resolve one carried document, or refuse with its own diagnostics.
///
/// The document crosses the facade as an opaque value because this facade is
/// protocol-neutral; it becomes the owner's typed declaration here, once, and
/// every refusal it produces is reported before the store is reached. The
/// published code is the first diagnostic's — a caller branches on one stable
/// code — and its document path travels as the offending field, so an ambiguous
/// conversion is corrected at the exact place the owner named.
fn admit_document(document: Value) -> Result<PlanAdmission, ApplicationFailure> {
    let document = PlanDocument::from_value(document).map_err(import_diagnostics)?;
    document.admit().map_err(import_diagnostics)
}

/// One refusal for a document the owner would not admit.
fn import_diagnostics(diagnostics: Vec<ImportDiagnostic>) -> ApplicationFailure {
    let first = diagnostics.first();
    let failure = ApplicationFailure::permanent(
        first.map_or("project_plan_document_invalid", |first| first.code),
        PLAN_IMPORT_STAGE,
    );
    match first.map(|first| first.path.as_str()) {
        Some(path) if !path.is_empty() => failure.with_field(path),
        _ => failure,
    }
}

impl NativeProjectApplication {
    fn register(
        &self,
        claim: &ActorClaim,
        request: &ProjectRegistrationRequest,
    ) -> Result<CommandOutcome, ApplicationFailure> {
        let authority = VerifiedClaimAuthority::of(claim).map_err(failure)?;
        let kind = AuthorityKind::parse(&request.authority_kind).ok_or_else(|| {
            failure(ProjectFailure::registration(
                "project_authority_reference_required",
            ))
        })?;
        let declared = AuthorityReference::declare(kind, request.authority_reference.clone())
            .map_err(failure)?;
        if &declared != authority.reference() {
            // The caller asked to register under an authority it does not hold.
            // Refusing here keeps the store's own admission one testable rule.
            return Err(failure(ProjectFailure::registration(
                "project_authority_unauthorized",
            )));
        }
        let registration = ProjectRegistration {
            identity: ProjectIdentitySource::Declared {
                project_id: request.project_id.clone(),
            },
            display_name: request.display_name.clone(),
            authorized_root: request.authorized_root.clone(),
            authority: Some(declared),
            workspace_id: request.workspace_id.clone(),
            plan_id: request.plan_id.clone(),
        };
        let registered = self
            .store()
            .map_err(failure)?
            .register(&authority, &registration)
            .map_err(failure)?;
        Ok(CommandOutcome::new(OperationReference::new(
            Operation::ProjectRegister,
            registered.project_id.as_str(),
            OperationState::Completed,
        ))
        .with_payload(project_wire(&registered)))
    }
}

/// One registered project as both interfaces publish it.
///
/// The authority travels as the reference the owner admitted, in its two parts;
/// there is no field for a credential, because the record has none.
fn project_wire(project: &RegisteredProject) -> Value {
    json!({
        "projectId": project.project_id.as_str(),
        "displayName": project.display_name,
        "authorizedRoot": project.authorized_root.as_str(),
        "authorityKind": project.authority.kind().as_str(),
        "authorityReference": project.authority.reference(),
        "workspaceId": project.workspace_id.as_str(),
        "planId": project.plan_id.as_str(),
        "registrationSequence": project.registration_sequence,
    })
}

/// A read outcome: no live identity, the operation's own body.
fn read_outcome(operation: Operation, payload: Value) -> CommandOutcome {
    CommandOutcome::new(OperationReference::new(
        operation,
        "",
        OperationState::Completed,
    ))
    .with_payload(payload)
}

/// A project refusal in the neutral failure model.
///
/// An unavailable store is the one failure a caller may retry unchanged; every
/// other refusal names a request the caller has to correct, so it is permanent
/// rather than a blind retry.
fn failure(error: ProjectFailure) -> ApplicationFailure {
    let normalization = if error.code() == "project_identity_store_unavailable" {
        FailureNormalization::RETRYABLE
    } else {
        FailureNormalization::PERMANENT
    };
    normalization.into_failure(error.code(), error.stage())
}
