// The peer trust authority this file establishes is read where it is owned:
// `licoup-secure-mesh` holds the reader, the durable MLS state paths and the Key
// Transparency authority path, because they are secure-mesh state rather than
// relay state. What remains here maintains the authority for this endpoint's
// own pairing flow, and every remaining item is a test fixture, so the glob is
// compiled only where the fixtures are.
#[cfg(any(test, feature = "test-support"))]
use super::*;

#[cfg(any(test, feature = "test-support"))]
pub(super) fn persist_peer_trust_authority_entry(
    config: &mut Value,
    local_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
    trust_record: &Value,
) -> Result<()> {
    ensure!(
        verify_device_trust_record_json(
            local_identity,
            peer_identity,
            trust_record,
            mobile_relay_trust_record_now_epoch()?,
        )? == DeviceTrustState::Verified,
        "secure mesh peer trust authority only accepts verified records"
    );
    let stable_label = stable_directory_label(
        configured_directory_scope_commitment(config)?,
        &peer_identity.endpoint_id,
    );
    if config["mobileRelayE2ee"]
        .get("peerTrustAuthority")
        .is_none()
    {
        config["mobileRelayE2ee"]["peerTrustAuthority"] = json!({
            "schemaVersion": SECURE_MESH_PEER_TRUST_AUTHORITY_SCHEMA,
            "entries": {}
        });
    }
    let authority = config["mobileRelayE2ee"]
        .get_mut("peerTrustAuthority")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("secure mesh peer trust authority is invalid"))?;
    ensure!(
        authority.get("schemaVersion").and_then(Value::as_str)
            == Some(SECURE_MESH_PEER_TRUST_AUTHORITY_SCHEMA),
        "secure mesh peer trust authority schema is invalid"
    );
    let entries = authority
        .get_mut("entries")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("secure mesh peer trust authority entries are invalid"))?;
    ensure!(
        entries.contains_key(&stable_label) || entries.len() < MAX_SECURE_MESH_PEER_TRUST_ENTRIES,
        "secure mesh peer trust authority is at capacity"
    );
    entries.insert(
        stable_label.clone(),
        json!({
            "stableLabel": stable_label,
            "identity": {
                "endpointId": peer_identity.endpoint_id,
                "identityPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(peer_identity.identity_public_key),
                "signingPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(peer_identity.signing_public_key),
                "rotationEpoch": peer_identity.rotation_epoch,
            },
            "trustRecord": trust_record,
        }),
    );
    Ok(())
}

#[cfg(test)]
pub(super) fn remove_peer_trust_authority_entry(
    config: &mut Value,
    peer_endpoint_id: &str,
) -> Result<()> {
    let scope = configured_directory_scope_commitment(config)?.to_string();
    let stable_label = stable_directory_label(&scope, peer_endpoint_id);
    if let Some(entries) = config
        .get_mut("mobileRelayE2ee")
        .and_then(|state| state.get_mut("peerTrustAuthority"))
        .and_then(|authority| authority.get_mut("entries"))
        .and_then(Value::as_object_mut)
    {
        entries.remove(&stable_label);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peer_trust_removal_is_scoped_to_the_stable_directory_label() {
        let scope = "a".repeat(64);
        let peer_endpoint_id = "device-a";
        let stable_label = stable_directory_label(&scope, peer_endpoint_id);
        let mut entries = serde_json::Map::new();
        entries.insert(stable_label.clone(), json!({"fixture": true}));
        entries.insert("unrelated".to_string(), json!({"fixture": true}));
        let mut config = json!({
            "secureMeshDirectoryScopeCommitment": scope,
            "mobileRelayE2ee": {
                "peerTrustAuthority": {"entries": Value::Object(entries)}
            }
        });

        remove_peer_trust_authority_entry(&mut config, peer_endpoint_id).unwrap();

        let entries = config["mobileRelayE2ee"]["peerTrustAuthority"]["entries"]
            .as_object()
            .unwrap();
        assert!(!entries.contains_key(&stable_label));
        assert!(entries.contains_key("unrelated"));
    }
}
