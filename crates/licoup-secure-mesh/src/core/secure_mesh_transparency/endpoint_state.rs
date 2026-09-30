//! This endpoint's durable Key Transparency state.
//!
//! The authority store and the reset guard are secure-mesh state that lives
//! under the endpoint's private client-state root. The guard marker is written
//! before a Key Transparency authority reset begins and removed when it
//! completes; while it exists every protected secure-mesh operation fails
//! closed, so a process that starts in the middle of an interrupted reset
//! cannot hydrate key material or open group state before the reset finishes.
//!
//! The module is the single reader of that marker, in both crates: the relay
//! that runs the reset calls the same guard the MLS and directory surfaces are
//! gated on, rather than keeping a second copy of the rule.

#[cfg(any(test, feature = "test-support"))]
use std::cell::RefCell;
use std::path::PathBuf;

use anyhow::{Result, anyhow, ensure};
use licoup_client_state::ClientStateStore;
use licoup_foundation::platform::file_security::{
    create_private_state_marker, private_state_marker_exists, read_private_state_marker,
    remove_private_state_marker,
};
use serde_json::Value;
use sha2::{Digest, Sha256};

/// Schema of the reset guard marker. The marker's own shape is part of the
/// private-state format, so a marker written by another schema is rejected
/// rather than interpreted.
const KT_AUTHORITY_RESET_GUARD_SCHEMA_VERSION: u64 = 1;
const KT_AUTHORITY_RESET_GUARD_STATE: &str = "security-blocked-reset-in-progress";

#[cfg(any(test, feature = "test-support"))]
thread_local! {
    static KT_AUTHORITY_RESET_FAILPOINT: RefCell<Option<&'static str>> =
        const { RefCell::new(None) };
}

/// The Key Transparency authority database this endpoint publishes and verifies
/// through, one store per local endpoint identity.
pub fn kt_authority_path(local_endpoint_id: &str) -> Result<PathBuf> {
    ensure!(
        !local_endpoint_id.trim().is_empty(),
        "secure mesh KT local endpoint id is required"
    );
    let directory = secure_mesh_endpoint_state_dir("secure-mesh-kt")?;
    let path = directory.join(format!(
        "{}.sqlite3",
        sha256_hex(local_endpoint_id.as_bytes())
    ));
    Ok(path)
}

/// True while a Key Transparency authority reset is incomplete.
pub fn kt_authority_reset_in_progress() -> Result<bool> {
    let path = kt_authority_reset_guard_path()?;
    if !private_state_marker_exists(&path)? {
        return Ok(false);
    }
    let raw = read_private_state_marker(&path)?
        .ok_or_else(|| anyhow!("secure mesh KT authority reset guard disappeared"))?;
    let guard: Value = serde_json::from_slice(&raw)
        .map_err(|_| anyhow!("secure mesh KT authority reset guard is invalid"))?;
    ensure!(
        guard.get("schemaVersion").and_then(Value::as_u64)
            == Some(KT_AUTHORITY_RESET_GUARD_SCHEMA_VERSION)
            && guard.get("state").and_then(Value::as_str) == Some(KT_AUTHORITY_RESET_GUARD_STATE),
        "secure mesh KT authority reset guard is invalid"
    );
    Ok(true)
}

/// Fails closed for every protected secure-mesh operation.
pub fn ensure_no_kt_authority_reset_in_progress() -> Result<()> {
    ensure!(
        !kt_authority_reset_in_progress()?,
        "secure mesh KT authority reset is incomplete; security operations remain blocked"
    );
    Ok(())
}

/// The gate every protected secure-mesh operation passes before it touches key
/// material or durable group state.
pub fn ensure_secure_mesh_protected_operation_allowed() -> Result<()> {
    ensure_no_kt_authority_reset_in_progress()
}

/// Blocks protected operations for the duration of an authority reset.
pub fn begin_kt_authority_reset() -> Result<()> {
    let path = kt_authority_reset_guard_path()?;
    let content = serde_json::to_vec(&serde_json::json!({
        "schemaVersion": KT_AUTHORITY_RESET_GUARD_SCHEMA_VERSION,
        "state": KT_AUTHORITY_RESET_GUARD_STATE
    }))?;
    create_private_state_marker(&path, &content)
        .map_err(|_| anyhow!("secure mesh KT authority reset guard could not be created"))
}

/// Releases protected operations once an authority reset has completed.
pub fn complete_kt_authority_reset() -> Result<()> {
    let path = kt_authority_reset_guard_path()?;
    ensure!(
        kt_authority_reset_in_progress()?,
        "secure mesh KT authority reset guard is missing"
    );
    ensure!(
        remove_private_state_marker(&path)?,
        "secure mesh KT authority reset guard is missing"
    );
    Ok(())
}

/// A named interruption point inside an authority reset.
///
/// The seam is a feature rather than `cfg(test)` because `cfg(test)` is false
/// for a dependency: the relay that drives the reset is a different crate, and
/// its tests must be able to interrupt the reset at the same points this
/// crate's own tests do. Without `test-support` the call is a no-op, which is
/// what a production build compiles.
#[cfg(not(any(test, feature = "test-support")))]
pub fn kt_authority_reset_failpoint(_name: &str) -> Result<()> {
    Ok(())
}

#[cfg(any(test, feature = "test-support"))]
pub fn kt_authority_reset_failpoint(name: &str) -> Result<()> {
    KT_AUTHORITY_RESET_FAILPOINT.with(|slot| {
        ensure!(
            slot.borrow().as_ref().copied() != Some(name),
            "secure mesh KT authority reset failpoint"
        );
        Ok(())
    })
}

#[cfg(any(test, feature = "test-support"))]
pub struct KtAuthorityResetFailpointGuard {
    previous: Option<&'static str>,
}

#[cfg(any(test, feature = "test-support"))]
impl Drop for KtAuthorityResetFailpointGuard {
    fn drop(&mut self) {
        KT_AUTHORITY_RESET_FAILPOINT.with(|slot| {
            slot.replace(self.previous.take());
        });
    }
}

#[cfg(any(test, feature = "test-support"))]
pub fn set_kt_authority_reset_failpoint(name: &'static str) -> KtAuthorityResetFailpointGuard {
    let previous = KT_AUTHORITY_RESET_FAILPOINT.with(|slot| slot.replace(Some(name)));
    KtAuthorityResetFailpointGuard { previous }
}

fn kt_authority_reset_guard_path() -> Result<PathBuf> {
    Ok(secure_mesh_endpoint_state_dir("")?.join("secure-mesh-kt-authority-reset.guard"))
}

/// The endpoint's private secure-mesh state directory, shared with the relay's
/// on-disk layout: every secure-mesh store this endpoint keeps sits beside the
/// relay configuration that names it.
pub(crate) fn secure_mesh_endpoint_state_dir(name: &str) -> Result<PathBuf> {
    let directory = ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join(name);
    std::fs::create_dir_all(&directory)?;
    Ok(directory)
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
