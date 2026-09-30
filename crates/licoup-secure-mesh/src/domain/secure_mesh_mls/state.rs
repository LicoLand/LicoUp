//! This endpoint's durable MLS state and the public directory context the
//! status projection reads.
//!
//! Both are secure-mesh state reached through the endpoint configuration the
//! composition above this crate owns. The directory context takes that
//! configuration document as an argument rather than loading it, so nothing
//! here reads the relay's configuration store.

use std::path::PathBuf;

use anyhow::Result;
use serde_json::Value;

use crate::core::secure_mesh_trust::DeviceTrustPublicIdentity;

/// The directory every durable MLS store of this endpoint lives in.
///
/// The store sits beside the relay configuration that names it, under the
/// private client-state root, and it keeps that layout: the path is
/// private-state format, not an implementation detail of either crate.
pub fn state_dir() -> Result<PathBuf> {
    let directory = licoup_client_state::ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("secure-mesh-mls");
    std::fs::create_dir_all(&directory)?;
    Ok(directory)
}

/// The local endpoint identity published into this endpoint's directory.
///
/// The caller supplies the persisted endpoint configuration it already holds;
/// this crate loads no configuration of its own.
pub fn public_directory_context(config: &Value) -> Result<DeviceTrustPublicIdentity> {
    crate::core::secure_mesh_transparency::ensure_secure_mesh_protected_operation_allowed()?;
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow::anyhow!("secure mesh MLS local endpoint state is unavailable"))?;
    let identity_public_key = super::input_codec::decode_base64url(
        &descriptor_text(state, "publicKeyBase64url")?,
        "MLS local identity public key",
        32,
    )?;
    let signing_public_key = super::input_codec::decode_base64url(
        &descriptor_text(state, "signingPublicKeyBase64url")?,
        "MLS local signing public key",
        32,
    )?;
    DeviceTrustPublicIdentity::new(
        descriptor_text(state, "endpointId")?,
        identity_public_key
            .try_into()
            .map_err(|_| anyhow::anyhow!("secure mesh MLS local identity public key length is invalid"))?,
        signing_public_key
            .try_into()
            .map_err(|_| anyhow::anyhow!("secure mesh MLS local signing public key length is invalid"))?,
        state
            .get("rotationEpoch")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow::anyhow!("secure mesh MLS local rotation epoch is unavailable"))?,
    )
}

fn descriptor_text(value: &Value, key: &str) -> Result<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("secure mesh MLS descriptor missing {key}"))
}
