use anyhow::Result;
use serde_json::Value;

use super::evaluate_service_action_json;
use super::projection::{decode_protected_projection, protected_plaintext};
use crate::core::secure_mesh_crypto::{OpenedSecureMeshPayload, SecureMeshContentContext};
use crate::core::secure_mesh_pairwise::SecureMeshPairwiseSession;
use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;

/// Seal a lifecycle service action inside a pairwise envelope. Plaintext service-action
/// transport outside pairwise/MLS envelopes is not a production path.
pub fn seal_lifecycle_service_action_pairwise(
    session: &mut SecureMeshPairwiseSession,
    context: &SecureMeshContentContext,
    params: &Value,
) -> Result<SecureMeshRelayEnvelope> {
    let projected = evaluate_service_action_json(params)?;
    session.seal_payload_envelope(context, &protected_plaintext(&projected)?)
}

pub fn open_lifecycle_service_action_pairwise(
    session: &mut SecureMeshPairwiseSession,
    _context: &SecureMeshContentContext,
    envelope: &SecureMeshRelayEnvelope,
) -> Result<(OpenedSecureMeshPayload, Value)> {
    let opened = session.open_payload_envelope(
        envelope,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
    )?;
    let value = decode_protected_projection(&opened, "pairwise")?;
    Ok((opened, value))
}
