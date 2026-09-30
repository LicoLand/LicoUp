// The Key Transparency reset guard is secure-mesh state, not relay policy: the
// marker it reads blocks every protected secure-mesh operation, in both crates.
// It lives in `licoup-secure-mesh` with the Key Transparency surface it
// protects, and this module keeps the former paths reachable for the relay's
// own reset flow.
pub(in crate::domain::mobile_relay) use licoup_secure_mesh::core::secure_mesh_transparency::{
    begin_kt_authority_reset, complete_kt_authority_reset,
    ensure_no_kt_authority_reset_in_progress, ensure_secure_mesh_protected_operation_allowed,
    kt_authority_reset_failpoint, kt_authority_reset_in_progress,
};
// The reset failpoint the family tests drive. The guard type is not re-exported:
// nothing in this crate names it, and `set_kt_authority_reset_failpoint` returns
// it to a caller that only has to drop it.
#[cfg(test)]
pub(in crate::domain::mobile_relay) use licoup_secure_mesh::core::secure_mesh_transparency::set_kt_authority_reset_failpoint;

use super::*;

pub(in crate::domain::mobile_relay) fn config_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("config.json"))
}

pub(in crate::domain::mobile_relay) fn config_lock_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("config.writer.lock"))
}
