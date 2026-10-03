//! Authorized project and plan identity.
//!
//! This crate owns one thing: the explicit record that says a project exists,
//! who authorized it, where its authorized root is, and which workspace and plan
//! identity it carries. A project is *registered*, never discovered — there is
//! no directory walk anywhere below this paragraph, and
//! [`ProjectIdentitySource::Discovered`] exists only so that a request asking
//! the owner to name a project by reading its root is refused with a code
//! instead of being answered with a guess.
//!
//! Three rules make the record trustworthy rather than descriptive:
//!
//! - **Identity is declared.** A [`ProjectId`], [`WorkspaceId`] and [`PlanId`]
//!   are caller-supplied bounded identifiers, not derived from a path or a
//!   directory listing. [`AuthorizedRoot`] is a declared absolute location the
//!   owner stores but never opens.
//! - **Authority is a reference.** A registration names an
//!   [`AuthorityReference`] into the authority owner that already exists
//!   ([`ProjectAuthorityDirectory`]); no credential, token or secret is copied
//!   into the record, and the persisted table has no column that could hold one.
//! - **Refusal is typed.** A duplicate identity, a duplicate plan identity, an
//!   absent or unauthorized reference, and an identity that would need a
//!   directory scan all return a [`ProjectFailure`] code, so both interfaces
//!   report the same reason for the same request.
//!
//! Durability reuses the existing state root: the store writes one SQLite
//! database inside the client-state root, by the same location rule the
//! workflow store follows, with the same private-directory, schema-version and
//! connection rules.

mod authority;
mod failure;
mod identity;
mod store;

pub use authority::{NoAuthorityDirectory, ProjectAuthorityDirectory};
pub use failure::{IDENTITY_STAGE, ProjectFailure, REGISTRATION_STAGE, STORE_STAGE};
pub use identity::{
    AuthorityKind, AuthorityReference, AuthorizedRoot, MAX_AUTHORITY_REFERENCE_BYTES,
    MAX_AUTHORIZED_ROOT_BYTES, MAX_DISPLAY_NAME_BYTES, MAX_PLAN_ID_BYTES, MAX_PROJECT_ID_BYTES,
    MAX_WORKSPACE_ID_BYTES, PlanId, ProjectId, ProjectIdentitySource, ProjectRegistration,
    RegisteredProject, WorkspaceId,
};
pub use store::{PROJECT_IDENTITY_COLUMNS, PROJECT_IDENTITY_SCHEMA_VERSION, ProjectIdentityStore};

#[cfg(test)]
mod tests;
