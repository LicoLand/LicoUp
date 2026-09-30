// The relay family moved to `licoup-relay`, which is the single authority for
// endpoint trust, secret custody, pairwise sessions, relay operations, pairing,
// key transparency and command sync. Every former path stays reachable through
// these re-exports for the FFI layer and the client-state migration, which are
// the consumers that still live in `licoup-native`; the family root and the
// family tests now live in `licoup-relay`.
pub use licoup_relay::domain::mobile_relay::{
    command_sync, config, endpoint_storage, endpoint_transport, endpoint_trust, key_transparency,
    pairing, pairwise_session, relay_operations, secret_custody, support,
};

pub use licoup_relay::domain::mobile_relay::command_sync::commands_sync;
pub use licoup_relay::domain::mobile_relay::config::{config_get, config_set};
pub use licoup_relay::domain::mobile_relay::config::{
    migrate_config_document, validate_current_config_document,
};
pub use licoup_relay::domain::mobile_relay::key_transparency::{
    SECURE_MESH_KT_NATIVE_ACTIONS, dispatch_key_transparency_action,
};
pub use licoup_relay::domain::mobile_relay::pairing::{
    pairing_claim, pairing_create, pairing_revoke, pairing_status,
};
pub use licoup_relay::domain::mobile_relay::relay_operations::{
    command_create, command_create_secure, command_result, command_result_replay_proof,
    command_result_secure, commands_poll, e2ee_status, pc_check_in,
};
pub use licoup_relay::domain::mobile_relay::secret_custody::{
    dispatch_secure_mesh_mls_action, e2ee_secret_store_cleanup, e2ee_secret_store_self_test,
    selected_mobile_relay_capability_evaluation, with_mobile_relay_secret_store_override,
    with_pairwise_secret_store_override,
};

// The fixtures the native test surface drives. They are `cfg(test)` in the relay
// crate, which is never configured for test as a dependency, so they arrive
// through that crate's explicit `test-support` feature. Only the three the FFI
// tests read are re-exported; the family tests that read the rest moved to
// `licoup-relay` with them.
#[cfg(test)]
pub(crate) use licoup_relay::domain::mobile_relay::endpoint_trust::{
    initialize_secure_mesh_mls_test_endpoint, initialize_secure_mesh_mls_test_peer,
    secure_mesh_mls_test_directory_response,
};

// The protected-operation gate and the Key Transparency reset guard it reads
// moved to `licoup-secure-mesh` with the state they belong to; the former path
// stays reachable for the relay's reset flow and its callers.
pub(crate) use licoup_secure_mesh::core::secure_mesh_transparency::ensure_secure_mesh_protected_operation_allowed;
