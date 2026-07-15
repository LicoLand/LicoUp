use anyhow::{Result, anyhow, ensure};
#[cfg(test)]
use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

use crate::core::secure_mesh_crypto::{
    OpenedSecureMeshPayload, SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
};
use crate::core::secure_mesh_mls::SecureMeshMlsGroup;
use crate::core::secure_mesh_mls::SecureMeshMlsParticipant;
use crate::core::secure_mesh_mls_product::{
    open_product_payload_message, seal_product_payload_message,
};
use crate::core::secure_mesh_pairwise::SecureMeshPairwiseSession;
use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;
use crate::core::secure_mesh_trust::{DeviceTrustPublicIdentity, DeviceTrustState};

pub const SECURE_MESH_LIFECYCLE_STATUS: &str = "ttl_delete_screenshot_resend_ack_purge_typing_read_receipt_service_actions_redacted_policy_available_pairwise_mls_envelope_required";
pub const SECURE_MESH_LIFECYCLE_CONTENT_TYPE: &str =
    "application/vnd.licolite.secure-mesh.lifecycle-service-action+json";

const MAX_TTL_SECONDS: u64 = 31 * 24 * 60 * 60;
const MAX_MISSING_MESSAGE_IDS: usize = 64;
const MAX_TEXT_BYTES: usize = 255;

pub fn evaluate_service_action_json(params: &Value) -> Result<Value> {
    let action_kind = read_required_text(
        params,
        &["actionKind", "kind", "serviceAction", "service_action"],
    )?;
    let scope = service_action_scope(params)?;
    let response = match action_kind.as_str() {
        "message_ttl_set" => {
            let ttl_seconds = read_u64(params, &["ttlSeconds", "ttl_seconds"])?;
            ensure!(
                (1..=MAX_TTL_SECONDS).contains(&ttl_seconds),
                "secure mesh message TTL is outside the supported range"
            );
            json!({
                "ttlSeconds": ttl_seconds,
                "expiresExistingMessages": read_bool(params, "expiresExistingMessages", false),
                "localTimerRequired": true,
                "remoteServiceNoticeRequired": true
            })
        }
        "message_delete" => {
            ensure!(
                read_bool(params, "userConfirmed", false),
                "secure mesh delete service action requires local user confirmation"
            );
            json!({
                "localDeleteRequired": true,
                "remoteDeleteNoticeRequired": true,
                "purgeLocalPlaintext": true,
                "purgeLocalCiphertextAfterAck": true
            })
        }
        "screenshot_detected" => json!({
            "userVisibleWarningRequired": true,
            "remoteServiceNoticeRequired": true,
            "screenshotContentIncluded": false
        }),
        "resend_request" => {
            let missing = missing_message_digests(params)?;
            ensure!(
                !missing.is_empty(),
                "secure mesh resend service action requires missing message ids"
            );
            json!({
                "resendRequestRequired": true,
                "missingMessageCount": missing.len(),
                "missingMessageDigests": missing,
                "missingMessageIdsRedacted": true
            })
        }
        "typing_state" => {
            let typing_state = read_required_text(params, &["typingState", "typing_state"])?;
            ensure!(
                matches!(typing_state.as_str(), "started" | "stopped"),
                "secure mesh typing service action state is unsupported"
            );
            json!({
                "typingState": typing_state,
                "typingNoticeRequired": true,
                "typingStateEncrypted": true,
                "typingContentIncluded": false,
                "remoteServiceNoticeRequired": true
            })
        }
        "read_receipt" => {
            let read_up_to = required_digest(
                params,
                &[
                    "readUpToMessageId",
                    "read_up_to_message_id",
                    "messageId",
                    "message_id",
                ],
                "read receipt message id",
            )?;
            json!({
                "readReceiptRequired": true,
                "readUpToMessageDigest": read_up_to,
                "readMessageIdsRedacted": true,
                "remoteServiceNoticeRequired": true,
                "localUnreadStateUpdateRequired": true
            })
        }
        "ack_purge" => {
            let acknowledged = read_bool(params, "acknowledged", false);
            let transfer_complete = read_bool(params, "transferComplete", false);
            json!({
                "ackRequired": !acknowledged,
                "purgeLocalCiphertext": acknowledged && transfer_complete,
                "purgeLocalPlaintext": true,
                "transferComplete": transfer_complete
            })
        }
        _ => {
            return Err(anyhow!(
                "secure mesh lifecycle service action is unsupported"
            ));
        }
    };
    Ok(json!({
        "ok": true,
        "protocolVersion": crate::core::secure_mesh::SECURE_MESH_PROTOCOL_VERSION,
        "lifecycleStatus": SECURE_MESH_LIFECYCLE_STATUS,
        "actionKind": action_kind,
        "scope": scope,
        "servicePolicy": response,
        "requiresPairwiseOrMlsEnvelope": true,
        "serverVisiblePlaintextAllowed": false,
        "metadataRedacted": true,
        "bodyRedacted": true,
        "keyMaterial": "redacted"
    }))
}

/// Seal a lifecycle service action inside a pairwise envelope. Plaintext service-action
/// transport outside pairwise/MLS envelopes is not a production path.
pub fn seal_lifecycle_service_action_pairwise(
    session: &mut SecureMeshPairwiseSession,
    context: &SecureMeshContentContext,
    params: &Value,
) -> Result<SecureMeshRelayEnvelope> {
    let evaluated = evaluate_service_action_json(params)?;
    ensure!(
        evaluated
            .get("requiresPairwiseOrMlsEnvelope")
            .and_then(Value::as_bool)
            == Some(true),
        "secure mesh lifecycle service action must require a protected envelope"
    );
    let body = serde_json::to_vec(&evaluated)?;
    let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::ServiceAction, body)
        .with_content_type(SECURE_MESH_LIFECYCLE_CONTENT_TYPE);
    session.seal_payload_envelope(context, &plaintext)
}

pub fn open_lifecycle_service_action_pairwise(
    session: &mut SecureMeshPairwiseSession,
    _context: &SecureMeshContentContext,
    envelope: &SecureMeshRelayEnvelope,
) -> Result<(OpenedSecureMeshPayload, Value)> {
    let opened = session.open_payload_envelope(envelope, SecureMeshPayloadKind::ServiceAction)?;
    ensure!(
        opened.content_type.as_deref() == Some(SECURE_MESH_LIFECYCLE_CONTENT_TYPE),
        "secure mesh lifecycle content type mismatch"
    );
    let value: Value = serde_json::from_slice(&opened.body)?;
    ensure!(
        value
            .get("requiresPairwiseOrMlsEnvelope")
            .and_then(Value::as_bool)
            == Some(true),
        "secure mesh lifecycle opened action missing envelope requirement"
    );
    Ok((opened, value))
}

pub fn seal_lifecycle_service_action_mls(
    group: &mut SecureMeshMlsGroup,
    sender: &SecureMeshMlsParticipant,
    sender_identity: &DeviceTrustPublicIdentity,
    sender_trust_state: &DeviceTrustState,
    trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
    context: &SecureMeshContentContext,
    params: &Value,
) -> Result<Vec<u8>> {
    let evaluated = evaluate_service_action_json(params)?;
    let body = serde_json::to_vec(&evaluated)?;
    let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::ServiceAction, body)
        .with_content_type(SECURE_MESH_LIFECYCLE_CONTENT_TYPE);
    seal_product_payload_message(
        group,
        sender,
        sender_identity,
        sender_trust_state,
        trusted_roster,
        context,
        &plaintext,
    )
}

pub fn open_lifecycle_service_action_mls(
    group: &mut SecureMeshMlsGroup,
    receiver: &SecureMeshMlsParticipant,
    receiver_identity: &DeviceTrustPublicIdentity,
    trusted_sender_identity: &DeviceTrustPublicIdentity,
    trusted_sender_state: &DeviceTrustState,
    trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
    context: &SecureMeshContentContext,
    message: &[u8],
) -> Result<(OpenedSecureMeshPayload, Value)> {
    let opened = open_product_payload_message(
        group,
        receiver,
        receiver_identity,
        trusted_sender_identity,
        trusted_sender_state,
        trusted_roster,
        context,
        message,
        SecureMeshPayloadKind::ServiceAction,
    )?;
    ensure!(
        opened.content_type.as_deref() == Some(SECURE_MESH_LIFECYCLE_CONTENT_TYPE),
        "secure mesh lifecycle MLS content type mismatch"
    );
    let value: Value = serde_json::from_slice(&opened.body)?;
    Ok((opened, value))
}

pub fn reject_plaintext_lifecycle_service_action_transport(params: &Value) -> Result<()> {
    let _ = evaluate_service_action_json(params)?;
    Err(anyhow!(
        "secure mesh lifecycle service action plaintext transport is forbidden; pairwise or MLS envelope required"
    ))
}

fn service_action_scope(params: &Value) -> Result<Value> {
    Ok(json!({
        "endpointHash": optional_digest(params, &["endpointId", "endpoint_id", "deviceId", "device_id"])?,
        "conversationHash": optional_digest(params, &["conversationId", "conversation_id", "chatId", "chat_id"])?,
        "messageHash": optional_digest(params, &["messageId", "message_id"])?,
        "fileTransferHash": optional_digest(params, &["fileTransferId", "file_transfer_id", "fileId", "file_id"])?,
        "scopeIdsRedacted": true
    }))
}

fn missing_message_digests(params: &Value) -> Result<Vec<String>> {
    let Some(values) = params
        .get("missingMessageIds")
        .or_else(|| params.get("missing_message_ids"))
        .and_then(Value::as_array)
    else {
        return Ok(Vec::new());
    };
    ensure!(
        values.len() <= MAX_MISSING_MESSAGE_IDS,
        "secure mesh resend service action has too many missing message ids"
    );
    values
        .iter()
        .map(|value| {
            let text = value.as_str().unwrap_or_default().trim().to_string();
            validate_text(&text, "missing message id")?;
            Ok(hash_text(&text))
        })
        .collect()
}

fn optional_digest(params: &Value, keys: &[&str]) -> Result<Option<String>> {
    keys.iter()
        .find_map(|key| params.get(*key))
        .and_then(Value::as_str)
        .map(|value| {
            let text = value.trim().to_string();
            validate_text(&text, "scope id")?;
            Ok(hash_text(&text))
        })
        .transpose()
}

fn required_digest(params: &Value, keys: &[&str], label: &str) -> Result<String> {
    let value = keys
        .iter()
        .find_map(|key| params.get(*key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    validate_text(&value, label)?;
    Ok(hash_text(&value))
}

fn read_required_text(params: &Value, keys: &[&str]) -> Result<String> {
    let value = keys
        .iter()
        .find_map(|key| params.get(*key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    validate_text(&value, "service action text field")?;
    Ok(value)
}

fn read_u64(params: &Value, keys: &[&str]) -> Result<u64> {
    let value = keys
        .iter()
        .find_map(|key| params.get(*key))
        .ok_or_else(|| anyhow!("secure mesh lifecycle integer field is required"))?;
    if let Some(number) = value.as_u64() {
        return Ok(number);
    }
    value
        .as_str()
        .unwrap_or_default()
        .trim()
        .parse::<u64>()
        .map_err(|_| anyhow!("secure mesh lifecycle integer field is invalid"))
}

fn read_bool(params: &Value, key: &str, default_value: bool) -> bool {
    match params.get(key) {
        Some(Value::Bool(value)) => *value,
        Some(Value::String(value)) => match value.trim() {
            "true" | "1" | "yes" => true,
            "false" | "0" | "no" => false,
            _ => default_value,
        },
        _ => default_value,
    }
}

fn validate_text(value: &str, label: &str) -> Result<()> {
    ensure!(!value.is_empty(), "secure mesh {label} is required");
    ensure!(
        value.len() <= MAX_TEXT_BYTES,
        "secure mesh {label} is too large"
    );
    Ok(())
}

fn hash_text(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    format!(
        "sha256:{}",
        digest
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn secure_mesh_lifecycle_service_actions_redact_private_ids_and_plaintext() {
        let fixtures = [
            json!({
                "actionKind": "message_ttl_set",
                "endpointId": "private-endpoint-canary",
                "conversationId": "private-conversation-canary",
                "messageId": "private-message-canary",
                "ttlSeconds": 60,
                "body": "plaintext-body-canary"
            }),
            json!({
                "actionKind": "message_delete",
                "endpointId": "private-endpoint-canary",
                "conversationId": "private-conversation-canary",
                "messageId": "private-message-canary",
                "userConfirmed": true,
                "body": "plaintext-body-canary"
            }),
            json!({
                "actionKind": "screenshot_detected",
                "endpointId": "private-endpoint-canary",
                "conversationId": "private-conversation-canary",
                "messageId": "private-message-canary",
                "body": "plaintext-body-canary"
            }),
            json!({
                "actionKind": "resend_request",
                "endpointId": "private-endpoint-canary",
                "conversationId": "private-conversation-canary",
                "missingMessageIds": ["private-missing-message-a", "private-missing-message-b"],
                "body": "plaintext-body-canary"
            }),
            json!({
                "actionKind": "typing_state",
                "endpointId": "private-endpoint-canary",
                "conversationId": "private-conversation-canary",
                "typingState": "started",
                "body": "plaintext-body-canary"
            }),
            json!({
                "actionKind": "read_receipt",
                "endpointId": "private-endpoint-canary",
                "conversationId": "private-conversation-canary",
                "readUpToMessageId": "private-read-message-canary",
                "body": "plaintext-body-canary"
            }),
            json!({
                "actionKind": "ack_purge",
                "endpointId": "private-endpoint-canary",
                "fileTransferId": "private-file-transfer-canary",
                "acknowledged": true,
                "transferComplete": true,
                "body": "plaintext-body-canary"
            }),
        ];

        for fixture in fixtures {
            let output = evaluate_service_action_json(&fixture).unwrap();
            assert_eq!(output["ok"], true);
            assert_eq!(output["requiresPairwiseOrMlsEnvelope"], true);
            assert_eq!(output["serverVisiblePlaintextAllowed"], false);
            assert_eq!(output["metadataRedacted"], true);
            assert_eq!(output["bodyRedacted"], true);
            let serialized = output.to_string();
            for forbidden in [
                "private-endpoint-canary",
                "private-conversation-canary",
                "private-message-canary",
                "private-missing-message-a",
                "private-missing-message-b",
                "private-read-message-canary",
                "private-file-transfer-canary",
                "plaintext-body-canary",
            ] {
                assert!(
                    !serialized.contains(forbidden),
                    "service action leaked {forbidden}"
                );
            }
        }
    }

    #[test]
    fn secure_mesh_lifecycle_delete_requires_confirmation_and_ttl_bounds() {
        let delete = evaluate_service_action_json(&json!({
            "actionKind": "message_delete",
            "messageId": "msg-delete"
        }))
        .unwrap_err();
        assert!(
            delete
                .to_string()
                .contains("requires local user confirmation")
        );

        let ttl = evaluate_service_action_json(&json!({
            "actionKind": "message_ttl_set",
            "messageId": "msg-ttl",
            "ttlSeconds": MAX_TTL_SECONDS + 1
        }))
        .unwrap_err();
        assert!(ttl.to_string().contains("outside the supported range"));
    }

    #[test]
    fn secure_mesh_lifecycle_typing_and_read_receipts_are_encrypted_service_actions() {
        let typing = evaluate_service_action_json(&json!({
            "actionKind": "typing_state",
            "endpointId": "typing-private-endpoint",
            "conversationId": "typing-private-conversation",
            "typingState": "started"
        }))
        .unwrap();
        assert_eq!(typing["requiresPairwiseOrMlsEnvelope"], true);
        assert_eq!(typing["serverVisiblePlaintextAllowed"], false);
        assert_eq!(typing["servicePolicy"]["typingNoticeRequired"], true);
        assert_eq!(typing["servicePolicy"]["typingStateEncrypted"], true);
        assert_eq!(typing["servicePolicy"]["typingContentIncluded"], false);

        let read_receipt = evaluate_service_action_json(&json!({
            "actionKind": "read_receipt",
            "endpointId": "receipt-private-endpoint",
            "conversationId": "receipt-private-conversation",
            "readUpToMessageId": "receipt-private-message"
        }))
        .unwrap();
        assert_eq!(read_receipt["requiresPairwiseOrMlsEnvelope"], true);
        assert_eq!(read_receipt["serverVisiblePlaintextAllowed"], false);
        assert_eq!(read_receipt["servicePolicy"]["readReceiptRequired"], true);
        assert_eq!(
            read_receipt["servicePolicy"]["readMessageIdsRedacted"],
            true
        );
        assert!(
            read_receipt["servicePolicy"]["readUpToMessageDigest"]
                .as_str()
                .unwrap_or_default()
                .starts_with("sha256:")
        );

        let serialized = json!([typing, read_receipt]).to_string();
        for forbidden in [
            "typing-private-endpoint",
            "typing-private-conversation",
            "receipt-private-endpoint",
            "receipt-private-conversation",
            "receipt-private-message",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "typing/read receipt service action leaked {forbidden}"
            );
        }
    }

    #[test]
    fn secure_mesh_lifecycle_service_actions_seal_only_inside_pairwise_envelopes() {
        use crate::core::secure_mesh_crypto::SecureMeshContentContext;
        use crate::core::secure_mesh_pairwise::{
            SecureMeshPairwisePrivateKey, SecureMeshPairwiseSession,
        };
        use crate::core::secure_mesh_pqxdh::SecureMeshMlKem1024PreKeySeed;
        use crate::core::secure_mesh_prekey::{
            SecureMeshPairwisePreKeyBundle, SecureMeshPreKeyKind, SecureMeshPreKeyValidationPolicy,
            authorize_test_pairwise_prekey_bundle, sign_prekey_record,
        };
        use crate::core::secure_mesh_trust::{DeviceTrustPublicIdentity, DeviceTrustState};
        use ed25519_dalek::SigningKey;
        use rand::rngs::OsRng;
        use time::OffsetDateTime;

        let alice_identity_secret = SecureMeshPairwisePrivateKey::generate();
        let alice_signing = SigningKey::generate(&mut OsRng);
        let alice_identity = DeviceTrustPublicIdentity::new(
            "desktop_gui:alice",
            alice_identity_secret.public_key(),
            alice_signing.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        let bob_identity_secret = SecureMeshPairwisePrivateKey::generate();
        let bob_signing = SigningKey::generate(&mut OsRng);
        let bob_identity = DeviceTrustPublicIdentity::new(
            "mobile:bob",
            bob_identity_secret.public_key(),
            bob_signing.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        let signed_secret = SecureMeshPairwisePrivateKey::generate();
        let one_time_secret = SecureMeshPairwisePrivateKey::generate();
        let one_time_mlkem1024_prekey_seed = SecureMeshMlKem1024PreKeySeed::generate();
        let bundle = SecureMeshPairwisePreKeyBundle {
            endpoint_identity: bob_identity.clone(),
            trust_state: DeviceTrustState::Verified,
            signed_prekey: sign_prekey_record(
                &bob_signing,
                &bob_identity,
                SecureMeshPreKeyKind::SignedPreKey,
                "spk-life-1",
                signed_secret.public_key(),
                "2026-07-11T00:00:00Z",
                "2026-08-11T00:00:00Z",
            )
            .unwrap(),
            one_time_prekey: Some(
                sign_prekey_record(
                    &bob_signing,
                    &bob_identity,
                    SecureMeshPreKeyKind::OneTimePreKey,
                    "otpk-life-1",
                    one_time_secret.public_key(),
                    "2026-07-11T00:00:00Z",
                    "2026-08-11T00:00:00Z",
                )
                .unwrap(),
            ),
            one_time_mlkem1024_prekey: sign_prekey_record(
                &bob_signing,
                &bob_identity,
                SecureMeshPreKeyKind::OneTimeMlKem1024PreKey,
                "pqotpk-life-1",
                one_time_mlkem1024_prekey_seed.public_key(),
                "2026-07-11T00:00:00Z",
                "2026-08-11T00:00:00Z",
            )
            .unwrap(),
            prekey_publication_version: 1,
        };
        let directory_authorization = authorize_test_pairwise_prekey_bundle(&bundle);
        let now = OffsetDateTime::parse(
            "2026-07-11T00:00:01Z",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap();
        let (mut alice_session, intro) = SecureMeshPairwiseSession::initiate(
            &alice_identity,
            &alice_identity_secret,
            &alice_signing,
            &bundle,
            &directory_authorization,
            &SecureMeshPreKeyValidationPolicy::default(),
            &crate::core::secure_mesh_pairwise::secure_mesh_pairwise_test_capability_evaluation()
                .unwrap(),
            now,
        )
        .unwrap();
        let (mut bob_session, accepted) = SecureMeshPairwiseSession::accept(
            &bob_identity,
            &bob_identity_secret,
            &bob_signing,
            &alice_identity,
            &signed_secret,
            Some(&one_time_secret),
            &one_time_mlkem1024_prekey_seed,
            &intro,
            &crate::core::secure_mesh_pairwise::secure_mesh_pairwise_test_capability_evaluation()
                .unwrap(),
            now,
            &mut crate::core::secure_mesh_session_negotiation::CapabilityProofReplayGuard::default(
            ),
        )
        .unwrap();
        let finished = alice_session
            .complete_initiator_handshake(
                &alice_identity,
                &bob_identity,
                &accepted,
                now,
                &mut crate::core::secure_mesh_session_negotiation::CapabilityProofReplayGuard::default(),
            )
            .unwrap();
        bob_session.complete_responder_handshake(&finished).unwrap();

        let params = json!({
            "actionKind": "ack_purge",
            "endpointId": "lifecycle-private-endpoint",
            "fileTransferId": "lifecycle-private-file",
            "acknowledged": true,
            "transferComplete": true,
            "body": "lifecycle-plaintext-canary"
        });
        let plaintext_forbidden =
            reject_plaintext_lifecycle_service_action_transport(&params).unwrap_err();
        assert!(
            plaintext_forbidden
                .to_string()
                .contains("plaintext transport is forbidden")
        );

        let context = SecureMeshContentContext::new(
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(&Sha256::digest(b"env-life-1")[..24]),
            "msg-life-1",
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(Sha256::digest(b"mailbox-life-1")),
            "desktop_gui:alice",
            "mobile:bob",
            alice_session.session_id.clone(),
            "2026-07-11T00:00:00Z",
            "2026-07-11T00:10:00Z",
        );
        let envelope =
            seal_lifecycle_service_action_pairwise(&mut alice_session, &context, &params).unwrap();
        for forbidden in [
            "lifecycle-private-endpoint",
            "lifecycle-private-file",
            "lifecycle-plaintext-canary",
        ] {
            assert!(
                !envelope.encrypted_header().contains(forbidden),
                "lifecycle envelope header leaked {forbidden}"
            );
            assert!(
                !envelope.ciphertext().contains(forbidden),
                "lifecycle envelope ciphertext leaked {forbidden}"
            );
        }
        let (_opened, value) =
            open_lifecycle_service_action_pairwise(&mut bob_session, &context, &envelope).unwrap();
        assert_eq!(value["actionKind"], "ack_purge");
        assert_eq!(value["requiresPairwiseOrMlsEnvelope"], true);
    }
}
