use super::context::{canonical_relay_context, remember_relay_scope};
use super::mailbox::canonical_mailbox_token;
use crate::domain::mobile_relay::endpoint_trust::{
    ensure_mobile_relay_endpoint_descriptor, local_endpoint_state,
};
use crate::platform::secure_client_relay::{
    SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST, SecureClientRelayEndpointRegistration,
    SecureClientRelayPublicJwk,
};
use anyhow::{Result, anyhow, ensure};
use base64::{Engine, engine::general_purpose};
use ed25519_dalek::Signer;
use serde_json::{Value, json};

pub(in crate::domain::mobile_relay) fn register_local_relay_endpoint(
    params: &Value,
    config: &mut Value,
    endpoint_kind: &str,
) -> Result<(Value, Value)> {
    let descriptor = ensure_mobile_relay_endpoint_descriptor(config, endpoint_kind)?;
    let endpoint = local_endpoint_state(config)?;
    let relay = canonical_relay_context(params, config)?;
    let signing_public_key =
        SecureClientRelayPublicJwk::ed25519(endpoint.signing_public_key.clone())?;
    let challenge = relay.transport.endpoint_challenge(
        &relay.scope,
        &endpoint.endpoint_id,
        &signing_public_key,
    )?;
    ensure!(
        challenge.get("challengeEncoding").and_then(Value::as_str) == Some("utf-8")
            && challenge.get("signatureAlgorithm").and_then(Value::as_str) == Some("Ed25519"),
        "secure client relay endpoint challenge profile is invalid"
    );
    let challenge_id = challenge
        .get("challengeId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("secure client relay challenge id is missing"))?;
    let challenge_text = challenge
        .get("challenge")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("secure client relay challenge is missing"))?;
    let signature = endpoint.signing_key()?.sign(challenge_text.as_bytes());
    let mailbox_token = canonical_mailbox_token(
        config,
        &endpoint.endpoint_id,
        &endpoint.endpoint_kind,
        endpoint.mailbox_rotation_epoch,
    )?;
    let registration = SecureClientRelayEndpointRegistration {
        endpoint_id: endpoint.endpoint_id.clone(),
        endpoint_kind: endpoint.endpoint_kind.clone(),
        identity_public_key: SecureClientRelayPublicJwk::x25519(endpoint.public_key.clone())?,
        signing_public_key,
        mailbox_token: mailbox_token.clone(),
        rotation_epoch: Some(endpoint.mailbox_rotation_epoch),
        challenge_id: challenge_id.to_string(),
        challenge_signature: general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    };
    let response = relay
        .transport
        .endpoint_register(&relay.scope, &registration)?;
    remember_relay_scope(config, &relay.scope);
    config["relayMailboxToken"] = json!(mailbox_token);
    config["relayRegisteredEndpointId"] = json!(endpoint.endpoint_id);
    config["relayCoreContractDigest"] = json!(SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST);
    Ok((response, descriptor))
}
