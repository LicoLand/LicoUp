mod inventory;
mod key_package;
mod pairwise;
mod validation;

pub use inventory::{
    SECURE_MESH_PREKEY_STATUS, SecureMeshInventoryStatus, evaluate_prekey_inventory,
};
pub use key_package::{
    SECURE_MESH_KEYPACKAGE_PROTOCOL_VERSION, SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE,
    SecureMeshKeyPackageRecord, sign_key_package_record, verify_key_package_record,
};
pub use pairwise::{
    SECURE_MESH_PREKEY_PROTOCOL_VERSION, SecureMeshPairwisePreKeyBundle,
    SecureMeshPreKeyBundleValidation, SecureMeshPreKeyKind, SecureMeshPreKeyRecord,
    SecureMeshPreKeyValidationPolicy, one_time_prekey_batch_digest,
    prekey_public_key_from_base64url, sign_prekey_record, signed_prekey_bundle_digest,
    validate_pairwise_prekey_bundle, verify_prekey_record,
};

// The synthetic directory authority is read by callers outside this crate — the
// group (MLS) and ACP trees still above it — so it is carried as the acceptor
// mock feature rather than as `cfg(test)`, which is false for a dependency. In
// that build the module's `#[test]` cases are not compiled, so the imports and
// helpers only they use are expected to be unused.
#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
#[cfg_attr(not(test), allow(unused_imports, dead_code))]
mod tests;
#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
pub(crate) use tests::support::authorize_test_pairwise_prekey_bundle;
