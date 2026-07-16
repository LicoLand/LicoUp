use super::super::test_support::*;
#[test]
fn mobile_relay_encrypted_local_effect_command_requires_local_confirmation() {
    let dir = temp_dir("mobile-relay-local-effect-confirmation");
    let previous = set_portable_data_dir_override(Some(dir));
    let mut pc_config = default_config();
    let mut mobile_config = default_config();
    pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
    let mobile_endpoint = local_endpoint_state(&mobile_config).unwrap();
    let pc_endpoint = local_endpoint_state(&pc_config).unwrap();
    save_config(&mut pc_config).unwrap();

    let command_payload = json!({
        "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
        "commandId": "cmd_mobile_relay_local_effect",
        "commandKind": "secure_mesh.device.verify",
        "senderIdentity": {
            "endpointId": mobile_endpoint.endpoint_id,
            "identityFingerprint": mobile_endpoint.fingerprint,
            "trustState": "verified",
            "endpointKind": mobile_endpoint.endpoint_kind
        },
        "targetBinding": {
            "targetEndpointId": pc_endpoint.endpoint_id,
            "targetAgentId": null,
            "workspaceId": "default"
        },
        "riskClass": "local_effect",
        "requiresUserConfirmation": false,
        "idempotencyKey": "idem_mobile_relay_local_effect",
        "createdAt": now_iso(),
        "expiresAt": timestamp_after_seconds(MOBILE_RELAY_COMMAND_TTL_SECONDS).unwrap(),
        "body": {
            "privateCanary": "local-effect-body-canary"
        }
    });
    let envelope = seal_mobile_relay_payload(
        &mobile_config,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        &command_payload,
    )
    .unwrap();

    let result_envelope = execute_secure_envelope_command(
        &json!({
            "type": SECURE_MESH_ENVELOPE_COMMAND,
            "envelope": envelope
        }),
        &json!({}),
    )
    .unwrap();
    let result = opened_result_payload(&mobile_config, &result_envelope);
    assert_eq!(result["evaluation"]["accepted"], true);
    assert_eq!(result["evaluation"]["shouldExecute"], false);
    assert_eq!(result["evaluation"]["code"], "user_confirmation_required");
    assert_eq!(result["execution"]["outcome"], "error");
    assert_eq!(result["bodyRedacted"], true);
    let serialized = serde_json::to_string(&result).unwrap();
    assert!(!serialized.contains("local-effect-body-canary"));

    set_portable_data_dir_override(previous);
}

#[test]
fn command_result_secure_consumes_canonical_sync_and_acks_after_open() {
    let dir = temp_dir("mobile-relay-secure-result-canonical-sync");
    let previous = set_portable_data_dir_override(Some(dir));
    let (pc_config, mut mobile_config, _envelope) = paired_command_envelope_fixture();
    let result_envelope = seal_mobile_relay_payload(
        &pc_config,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        &json!({
            "ok": true,
            "result": "encrypted-result-canary",
            "bodyRedacted": true
        }),
    )
    .unwrap();
    let expected_delivery_id = result_envelope["deliveryId"].clone();
    let gateway = CanonicalRelayGateway::start(2, vec![result_envelope]);
    mobile_config["pairingId"] = json!("pair_canonical_result_sync");
    mobile_config["mobileToken"] = json!("mobile-token-canonical-result-sync");
    mobile_config["relayEnabled"] = json!(true);
    mobile_config["useCustomGateway"] = json!(true);
    mobile_config["customGatewayUrl"] = json!(gateway.url());
    save_config(&mut mobile_config).unwrap();

    let output = command_result_secure(&with_canonical_relay_params(json!({}))).unwrap();

    assert_eq!(output["ok"], true);
    assert_eq!(output["bodyRedacted"], true);
    assert_eq!(output["response"]["bodyRedacted"], true);
    assert_eq!(output["response"]["command"]["resultEnvelopePresent"], true);
    assert!(
        output["response"]["command"]
            .get("resultEnvelope")
            .is_none()
    );
    assert_eq!(output["openedResult"]["result"], "encrypted-result-canary");
    let serialized = serde_json::to_string(&output).unwrap();
    assert!(!serialized.contains("mobile-token-canonical-result-sync"));
    assert_eq!(
        serde_json::from_str::<Value>(&gateway.request_body(1)).unwrap()["deliveryId"],
        expected_delivery_id
    );
    gateway.assert_operations(&[
        SecureClientRelayOperation::EnvelopeSync,
        SecureClientRelayOperation::EnvelopeAck,
    ]);

    gateway.join();
    set_portable_data_dir_override(previous);
}

#[test]
fn command_result_secure_reuses_single_operation_auth_batch_for_fetch_and_result_open() {
    let dir = temp_dir("mobile-relay-secure-result-single-operation-auth-batch");
    let previous = set_portable_data_dir_override(Some(dir));
    let secret_store = Arc::new(EphemeralSecretStore::new());
    let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
    let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

    with_mobile_relay_secret_store_override(mobile_store_override, || {
        with_pairwise_secret_store_override(pairwise_store_override, || {
            let (pc_config, mut mobile_config, _envelope) = paired_command_envelope_fixture();
            let result_envelope = seal_mobile_relay_payload(
                &pc_config,
                crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
                &json!({
                    "ok": true,
                    "result": "single-auth-result-canary",
                    "bodyRedacted": true
                }),
            )?;
            let gateway = CanonicalRelayGateway::start(2, vec![result_envelope]);
            mobile_config["pairingId"] = json!("pair_secure_result_single_auth_batch");
            mobile_config["mobileToken"] = json!("mobile-token-secure-result-single-auth");
            mobile_config["relayEnabled"] = json!(true);
            mobile_config["useCustomGateway"] = json!(true);
            mobile_config["customGatewayUrl"] = json!(gateway.url());
            persist_config_secret_material_to_secret_store(
                &mut mobile_config,
                secret_store.as_ref(),
                MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
            )?;
            save_config(&mut mobile_config)?;
            let baseline_session_count = secret_store.authorization_session_count();

            let output = command_result_secure(&with_canonical_relay_params(json!({})))?;

            assert_eq!(output["ok"], true);
            assert_eq!(
                output["openedResult"]["result"],
                "single-auth-result-canary"
            );
            assert_eq!(
                secret_store.authorization_session_count(),
                baseline_session_count + 1
            );
            assert_eq!(
                secret_store.authorization_session_reasons()[baseline_session_count],
                "Mobile Relay secure result operation authorization batch"
            );
            gateway.assert_operations(&[
                SecureClientRelayOperation::EnvelopeSync,
                SecureClientRelayOperation::EnvelopeAck,
            ]);
            gateway.join();
            Ok(())
        })
    })
    .unwrap();

    set_portable_data_dir_override(previous);
}

#[test]
fn command_create_secure_reuses_single_operation_auth_batch_for_hydrate_and_seal() {
    let gateway = CanonicalRelayGateway::start(1, Vec::new());
    let dir = temp_dir("mobile-relay-secure-command-create-single-auth-batch");
    let previous = set_portable_data_dir_override(Some(dir));
    let secret_store = Arc::new(EphemeralSecretStore::new());
    let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
    let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

    with_mobile_relay_secret_store_override(mobile_store_override, || {
        with_pairwise_secret_store_override(pairwise_store_override, || {
            let mut pc_config = default_config();
            let mut mobile_config = default_config();
            pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
            mobile_config["pairingId"] = json!("pair_secure_command_create_single_auth_batch");
            mobile_config["mobileToken"] = json!("mobile-token-single-auth-create");
            mobile_config["relayEnabled"] = json!(true);
            mobile_config["useCustomGateway"] = json!(true);
            mobile_config["customGatewayUrl"] = json!(gateway.url());
            persist_config_secret_material_to_secret_store(
                &mut mobile_config,
                secret_store.as_ref(),
                MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
            )?;
            save_config(&mut mobile_config)?;
            let baseline_session_count = secret_store.authorization_session_count();

            let output = command_create_secure(&with_canonical_relay_params(json!({
                "commandKind": "agent.message.send",
                "targetAgentId": "codex",
                "workspaceId": "default",
                "body": {
                    "agentId": "codex",
                    "text": "single-auth-create-canary"
                },
                "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
                "secretOverrides": {
                    "mobileRelayE2eeSecretStore": {
                        "contract": "rust_secure_mesh_secret_store_handle_v1",
                        "namespace": MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                        "rawJsonSecretOverridesUsed": false
                    }
                }
            })))?;

            assert_eq!(output["ok"], true);
            assert_eq!(
                output["secureCommandBinding"]["commandKind"],
                "agent.message.send"
            );
            assert!(
                output["secureCommandBinding"]["payloadCommandId"]
                    .as_str()
                    .is_some_and(|value| !value.is_empty())
            );
            assert!(
                output["secureCommandBinding"]["idempotencyKey"]
                    .as_str()
                    .is_some_and(|value| !value.is_empty())
            );
            assert_eq!(
                secret_store.authorization_session_count(),
                baseline_session_count + 1
            );
            assert_eq!(
                secret_store.authorization_session_reasons()[baseline_session_count],
                "Mobile Relay secure command create authorization batch"
            );
            assert_eq!(
                secret_store.authorization_session_operation_counts()[baseline_session_count],
                mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
                    .saturating_add(3)
            );
            let request = gateway.request_body(0);
            let request_body = serde_json::from_str::<Value>(&request).unwrap();
            assert!(request_body["envelope"].is_object());
            assert!(!request.contains(SECURE_MESH_ENVELOPE_COMMAND));
            assert!(!request.contains("single-auth-create-canary"));
            assert!(!request.contains("mobile-token-single-auth-create"));
            assert!(!request.contains("commandId"));
            gateway.assert_operations(&[SecureClientRelayOperation::EnvelopeSend]);
            gateway.join();
            Ok(())
        })
    })
    .unwrap();

    set_portable_data_dir_override(previous);
}

#[test]
fn command_result_replay_proof_reuses_single_operation_auth_batch_for_fetch_and_replay_check() {
    let dir = temp_dir("mobile-relay-result-replay-proof-single-operation-auth-batch");
    let previous = set_portable_data_dir_override(Some(dir));
    let secret_store = Arc::new(EphemeralSecretStore::new());
    let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
    let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

    with_mobile_relay_secret_store_override(mobile_store_override, || {
        with_pairwise_secret_store_override(pairwise_store_override, || {
            let (pc_config, mut mobile_config, _envelope) = paired_command_envelope_fixture();
            let result_envelope = seal_mobile_relay_payload(
                &pc_config,
                crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
                &json!({
                    "ok": true,
                    "evaluation": {
                        "code": "execute"
                    },
                    "execution": {
                        "outcome": "result"
                    },
                    "bodyRedacted": true
                }),
            )?;
            let gateway = CanonicalRelayGateway::start(1, vec![result_envelope]);
            mobile_config["pairingId"] = json!("pair_result_replay_single_auth_batch");
            mobile_config["mobileToken"] = json!("mobile-token-result-replay-single-auth");
            mobile_config["relayEnabled"] = json!(true);
            mobile_config["useCustomGateway"] = json!(true);
            mobile_config["customGatewayUrl"] = json!(gateway.url());
            persist_config_secret_material_to_secret_store(
                &mut mobile_config,
                secret_store.as_ref(),
                MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
            )?;
            save_config(&mut mobile_config)?;
            let baseline_session_count = secret_store.authorization_session_count();

            let proof = command_result_replay_proof(&with_canonical_relay_params(json!({})))?;

            assert_eq!(proof["ok"], true);
            assert_eq!(proof["replayRejected"], true);
            assert_eq!(
                secret_store.authorization_session_count(),
                baseline_session_count + 1
            );
            assert_eq!(
                secret_store.authorization_session_reasons()[baseline_session_count],
                "Mobile Relay secure result replay proof authorization batch"
            );
            gateway.assert_operations(&[SecureClientRelayOperation::EnvelopeSync]);
            gateway.join();
            Ok(())
        })
    })
    .unwrap();

    set_portable_data_dir_override(previous);
}

#[test]
fn mobile_relay_commands_sync_reuses_single_operation_auth_batch_for_secure_commands() {
    let dir = temp_dir("mobile-relay-commands-sync-single-operation-auth-batch");
    let previous = set_portable_data_dir_override(Some(dir));
    let secret_store = Arc::new(EphemeralSecretStore::new());
    let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
    let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

    with_mobile_relay_secret_store_override(mobile_store_override, || {
        with_pairwise_secret_store_override(pairwise_store_override, || {
            let mut pc_config = default_config();
            let mut mobile_config = default_config();
            pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
            let mut envelopes = Vec::new();
            for index in 0..2 {
                let payload = secure_command_payload(
                    &mobile_config,
                    "agent.sessions.list",
                    None,
                    "default",
                    json!({
                        "agent": "codex",
                        "limit": index + 1
                    }),
                )?;
                envelopes.push(seal_mobile_relay_payload(
                    &mobile_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
                    &payload,
                )?);
            }
            let gateway = CanonicalRelayGateway::start(7, envelopes);
            pc_config["pairingId"] = json!("pair_commands_sync_single_auth_batch");
            pc_config["pcToken"] = json!("pc-token-commands-sync-single-auth");
            pc_config["relayEnabled"] = json!(true);
            pc_config["useCustomGateway"] = json!(true);
            pc_config["customGatewayUrl"] = json!(gateway.url());
            persist_config_secret_material_to_secret_store(
                &mut pc_config,
                secret_store.as_ref(),
                MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
            )?;
            save_config(&mut pc_config)?;
            let baseline_session_count = secret_store.authorization_session_count();

            let output = commands_sync(&with_canonical_relay_params(json!({
                "targets": [],
                "limit": 2,
                "allowInteraction": false
            })))?;

            assert_eq!(output["ok"], true);
            let completed = output["completed"].as_array().unwrap();
            assert_eq!(completed.len(), 2);
            assert!(completed.iter().all(|command| command["ok"] == true));
            assert_eq!(
                secret_store.authorization_session_count(),
                baseline_session_count + 1
            );
            assert_eq!(
                secret_store.authorization_session_reasons()[baseline_session_count],
                "Mobile Relay commands sync operation authorization batch"
            );
            assert!(
                !secret_store.authorization_session_allow_interactions()[baseline_session_count]
            );
            gateway.assert_operations(&[
                SecureClientRelayOperation::EndpointChallenge,
                SecureClientRelayOperation::EndpointRegister,
                SecureClientRelayOperation::EnvelopeSync,
                SecureClientRelayOperation::EnvelopeSend,
                SecureClientRelayOperation::EnvelopeAck,
                SecureClientRelayOperation::EnvelopeSend,
                SecureClientRelayOperation::EnvelopeAck,
            ]);
            gateway.join();
            Ok(())
        })
    })
    .unwrap();

    set_portable_data_dir_override(previous);
}

#[test]
fn mobile_relay_secure_command_execute_reuses_single_operation_auth_batch_for_open_and_result_seal()
{
    let dir = temp_dir("mobile-relay-secure-command-single-operation-auth-batch");
    let previous = set_portable_data_dir_override(Some(dir));
    let secret_store = Arc::new(EphemeralSecretStore::new());
    let store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

    with_pairwise_secret_store_override(store_override, || {
        let (mut pc_config, mobile_config, envelope) = paired_command_envelope_fixture();
        save_config(&mut pc_config).unwrap();
        let baseline_session_count = secret_store.authorization_session_count();

        let result_envelope = execute_secure_envelope_command(
            &json!({
                "type": SECURE_MESH_ENVELOPE_COMMAND,
                "envelope": envelope
            }),
            &json!({}),
        )?;

        assert_eq!(
            secret_store.authorization_session_count(),
            baseline_session_count + 1
        );
        assert_eq!(
            secret_store.authorization_session_reasons()[baseline_session_count],
            "Mobile Relay secure command operation authorization batch"
        );
        assert_eq!(
            secret_store.authorization_session_operation_counts()[baseline_session_count],
            5
        );
        let result = opened_result_payload(&mobile_config, &result_envelope);
        assert_eq!(result["evaluation"]["code"], "user_confirmation_required");
        assert_eq!(result["execution"]["outcome"], "error");
        Ok(())
    })
    .unwrap();

    set_portable_data_dir_override(previous);
}
