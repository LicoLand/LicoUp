use super::{endpoint_trust::*, relay_operations::*, support::*};

pub fn pairing_create(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    effective_gateway_url(&config)?;
    config["relayEnabled"] = json!(true);
    let (registration, _secure_mesh) =
        register_local_relay_endpoint(params, &mut config, "desktop_sidecar")?;
    let pairing_id = format!("pair_{}", Uuid::new_v4());
    let pairing_code = random_base64url(12);
    config["pairingId"] = json!(pairing_id);
    config["lastPairingCode"] = json!(pairing_code);
    let response = json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "transportProtocol": SECURE_MESH_PROTOCOL_VERSION,
        "pairingId": pairing_id,
        "pairingCode": pairing_code,
        "endpointRegistration": registration,
        "serverVisiblePairingState": false
    });
    let invite = one_time_pairing_invite(&config, &response);
    clear_pairing_presentation(&mut config);
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    let mut output = with_config(response, &config);
    if let (Some(object), Some(invite)) = (output.as_object_mut(), invite) {
        object.insert("mobileRelayPairingInvite".to_string(), invite);
    }
    Ok(output)
}

pub fn pairing_claim(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    effective_gateway_url(&config)?;
    config["relayEnabled"] = json!(true);
    apply_pairing_invite_params_with_context(&mut config, params, Some(&mut secret_context))?;
    let pairing_id = text_param(params, &["pairingId", "pairing_id"])
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            config
                .get("pairingId")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .ok_or_else(|| anyhow!("mobile relay pairing claim requires --pairing-id"))?;
    let code = text_param(params, &["pairingCode", "code"])
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            config
                .get("lastPairingCode")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay pairing claim requires --pairing-code"))?;
    let pc_secure_mesh = pairing_claim_secure_mesh_descriptor_from_params(params)?
        .or_else(|| peer_secure_mesh_descriptor(&config))
        .ok_or_else(|| anyhow!("mobile relay pairing claim requires PC secure mesh invite"))?;
    apply_peer_secure_mesh_descriptor_with_context(
        &mut config,
        &pc_secure_mesh,
        true,
        Some(&mut secret_context),
    )?;
    let expected_code = config
        .get("lastPairingCode")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty());
    if let Some(expected_code) = expected_code {
        ensure!(
            expected_code == code,
            "mobile relay pairing code does not match the local one-time invite"
        );
    }
    let (registration, mobile_secure_mesh) =
        register_local_relay_endpoint(params, &mut config, "mobile")?;
    let claim_proof = mobile_relay_claim_proof(&config, &pairing_id, &mobile_secure_mesh)?;
    config["paired"] = json!(true);
    let response = json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "transportProtocol": SECURE_MESH_PROTOCOL_VERSION,
        "pairingId": pairing_id,
        "endpointRegistration": registration,
        "outOfBandPairingResponse": {
            "mobileSecureMesh": mobile_secure_mesh,
            "secureMeshClaimProof": claim_proof
        },
        "serverVisiblePairingState": false
    });
    clear_pairing_presentation(&mut config);
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(with_config(response, &config))
}

pub fn pairing_status(params: &Value) -> Result<Value> {
    if let Some(response) = params
        .get("outOfBandPairingResponse")
        .filter(|value| value.is_object())
    {
        let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
        apply_out_of_band_pairing_response_with_context(
            &mut config,
            response,
            Some(&mut secret_context),
        )?;
        save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
        return Ok(pairing_status_response(&config));
    }
    let (config, _) = load_config_with_runtime_secret_overrides(params)?;
    Ok(pairing_status_response(&config))
}

pub(super) fn pairing_status_response(config: &Value) -> Value {
    with_config(
        json!({
            "ok": true,
            "schemaVersion": CONFIG_SCHEMA_VERSION,
            "transportProtocol": SECURE_MESH_PROTOCOL_VERSION,
            "registered": config
                .get("relayRegisteredEndpointId")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty()),
            "paired": config.get("paired").and_then(Value::as_bool).unwrap_or(false),
            "serverVisiblePairingState": false
        }),
        config,
    )
}

pub(super) fn refresh_pairing_status_with_context(
    params: &Value,
    config: &mut Value,
    secret_context: &mut RuntimeSecretContext,
) -> Result<Value> {
    let _ = secret_context;
    let response = json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "registered": config
            .get("relayRegisteredEndpointId")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty()),
        "paired": config.get("paired").and_then(Value::as_bool).unwrap_or(false),
        "serverVisiblePairingState": false
    });
    let _ = params;
    Ok(response)
}

pub(super) fn refresh_pairwise_acceptance_if_pending(
    params: &Value,
    config: &mut Value,
    secret_context: &mut RuntimeSecretContext,
) -> Result<()> {
    let Some(state) = config.get("mobileRelayE2ee") else {
        return Ok(());
    };
    let endpoint_kind = state
        .get("endpointKind")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let paired = config
        .get("paired")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let pending_intro = state.get("pendingPairwiseIntro").is_some();
    if endpoint_kind != "mobile" || !paired || !pending_intro {
        return Ok(());
    }
    let _ = refresh_pairing_status_with_context(params, config, secret_context)?;
    Ok(())
}

pub fn pairing_revoke(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar")?;
    let current_epoch = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("mailboxRotationEpoch"))
        .and_then(Value::as_u64)
        .unwrap_or(current_mailbox_rotation_epoch()?);
    let next_epoch = current_epoch
        .checked_add(1)
        .ok_or_else(|| anyhow!("secure client relay mailbox rotation epoch overflow"))?;
    config["mobileRelayE2ee"]["mailboxRotationEpoch"] = json!(next_epoch);
    let (registration, _) = register_local_relay_endpoint(params, &mut config, "desktop_sidecar")?;
    clear_mobile_relay_pairing_state(&mut config)?;
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(with_config(
        json!({
            "ok": true,
            "schemaVersion": CONFIG_SCHEMA_VERSION,
            "mailboxRotated": true,
            "endpointRegistration": registration,
            "serverVisiblePairingState": false
        }),
        &config,
    ))
}

#[cfg(test)]
mod tests {
    use super::super::config::default_config;
    use super::*;

    #[test]
    fn pairing_module_projects_local_pairing_status() {
        let mut config = default_config();
        config["relayRegisteredEndpointId"] = json!("endpoint-test");
        config["paired"] = json!(true);

        let status = pairing_status_response(&config);

        assert_eq!(status["registered"], true);
        assert_eq!(status["paired"], true);
        assert_eq!(status["serverVisiblePairingState"], false);
    }
}
