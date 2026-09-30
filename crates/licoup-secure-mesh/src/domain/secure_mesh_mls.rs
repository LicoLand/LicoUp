//! The product-facing Secure Mesh group (MLS) surface.
//!
//! The stable native action registry, the group operations behind it, their
//! durable group state and security ledger, and the selected-custody context
//! each participant action runs under. The composition above this crate opens
//! that custody and supplies the endpoint configuration; nothing here loads a
//! configuration store or selects a custody backend of its own.

mod actions;
mod commit_process;
mod directory_authorization;
mod group_create;
mod group_join;
mod group_state;
mod input_codec;
mod journal_recovery;
mod member_mutation;
mod participant_key_package;
mod participant_runtime;
mod payload;
mod state;

pub use actions::{
    SECURE_MESH_MLS_NATIVE_ACTIONS, SecureMeshMlsActionContext, SecureMeshMlsStatusContext,
    dispatch, runtime_binding_wired, status,
};
pub use participant_runtime::{
    SECURE_MESH_MLS_PARTICIPANT_SECRET_STORE_OPERATIONS, SecureMeshMlsCustody,
    reset_durable_state_for_kt_authority_change, reset_selected_custody_for_kt_authority_change,
};
pub use state::{public_directory_context, state_dir};

#[cfg(test)]
mod tests;
