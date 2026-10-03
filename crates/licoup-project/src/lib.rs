//! Authorized project and plan identity, and the dependency inputs a project
//! declares.
//!
//! This crate owns one thing: the explicit record that says a project exists,
//! who authorized it, where its authorized root is, which workspace and plan
//! identity it carries, and which declared results its work items take from
//! other work items. A project is *registered*, never discovered — there is no
//! directory walk anywhere below this paragraph, and
//! [`ProjectIdentitySource::Discovered`] exists only so that a request asking
//! the owner to name a project by reading its root is refused with a code
//! instead of being answered with a guess.
//!
//! Four rules make the record trustworthy rather than descriptive:
//!
//! - **Identity is declared.** A [`ProjectId`], [`WorkspaceId`], [`PlanId`] and
//!   [`WorkItemId`] are caller-supplied bounded identifiers, not derived from a
//!   path or a directory listing. [`AuthorizedRoot`] is a declared absolute
//!   location the owner stores but never opens to name a project.
//! - **Authority is a reference.** A registration names an
//!   [`AuthorityReference`] into the authority owner that already exists
//!   ([`ProjectAuthorityDirectory`]); no credential, token or secret is copied
//!   into the record, and the persisted table has no column that could hold one.
//! - **Dependencies are declared inputs.** A [`WorkDependency`] names the
//!   consumer work item and the result it takes, either as an
//!   [`ArtifactReference::Local`] location inside the declaring project's
//!   authorized root or as an [`ArtifactReference::CrossProject`] reference to a
//!   work item of another registered project. A shared result is referenced, not
//!   produced twice.
//! - **Refusal is typed, and so is absence.** A duplicate identity, a duplicate
//!   plan identity, an absent or unauthorized reference, an identity that would
//!   need a directory scan, a dependency cycle, an unauthorized cross-project
//!   reference and a location that escapes its authorized root all return a
//!   [`ProjectFailure`] code, so both interfaces report the same reason for the
//!   same request. An artifact that is not there is not an error and not an
//!   empty result: it is reported as [`ArtifactState::Missing`] or
//!   [`ArtifactState::Unavailable`], explicitly, and never resolved by walking
//!   outside the declared roots.
//!
//! Durability reuses the existing state root: the store writes one SQLite
//! database inside the client-state root, by the same location rule the
//! workflow store follows, with the same private-directory, schema-version and
//! connection rules. Identities and dependency inputs share that one database.

mod authority;
mod dependency;
mod failure;
mod identity;
mod store;

pub use authority::{NoAuthorityDirectory, ProjectAuthorityDirectory};
pub use dependency::{
    ArtifactReference, ArtifactState, DeclaredDependency, MAX_ARTIFACT_PATH_BYTES, WorkDependency,
    WorkRef, read_local_artifact, render_dependency_path, stays_inside_authorized_root,
};
pub use failure::{
    DEPENDENCY_STAGE, IDENTITY_STAGE, ProjectFailure, REGISTRATION_STAGE, STORE_STAGE,
};
pub use identity::{
    AuthorityKind, AuthorityReference, AuthorizedRoot, MAX_AUTHORITY_REFERENCE_BYTES,
    MAX_AUTHORIZED_ROOT_BYTES, MAX_DISPLAY_NAME_BYTES, MAX_PLAN_ID_BYTES, MAX_PROJECT_ID_BYTES,
    MAX_WORK_ITEM_ID_BYTES, MAX_WORKSPACE_ID_BYTES, PlanId, ProjectId, ProjectIdentitySource,
    ProjectRegistration, RegisteredProject, WorkItemId, WorkspaceId,
};
pub use store::{
    PROJECT_DEPENDENCY_COLUMNS, PROJECT_IDENTITY_COLUMNS, PROJECT_STORE_SCHEMA_VERSION,
    ProjectIdentityStore,
};

#[cfg(test)]
mod tests;
