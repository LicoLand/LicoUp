use anyhow::Result;
use serde_json::Value;

use super::contract::{
    SecureClientRelayAuth, SecureClientRelayEndpointRegistration, SecureClientRelayPublicJwk,
    SecureClientRelayScope,
};
use super::http_io::SecureClientRelayHttpClient;
use super::request;
use super::response_binding::{
    validate_ack_response_binding, validate_challenge_response_binding,
    validate_registration_response_binding, validate_send_response_binding,
    validate_sync_response_binding,
};
use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;

pub struct SecureClientRelayTransport {
    http: SecureClientRelayHttpClient,
}

impl SecureClientRelayTransport {
    pub fn new(base_url: impl Into<String>, auth: SecureClientRelayAuth) -> Result<Self> {
        Ok(Self {
            http: SecureClientRelayHttpClient::new(base_url, auth)?,
        })
    }

    pub fn endpoint_challenge(
        &self,
        scope: &SecureClientRelayScope,
        endpoint_id: &str,
        signing_public_key: &SecureClientRelayPublicJwk,
    ) -> Result<Value> {
        let response = self.http.post(request::endpoint_challenge(
            scope,
            endpoint_id,
            signing_public_key,
        )?)?;
        validate_challenge_response_binding(&response, scope, endpoint_id)?;
        Ok(response)
    }

    pub fn endpoint_register(
        &self,
        scope: &SecureClientRelayScope,
        registration: &SecureClientRelayEndpointRegistration,
    ) -> Result<Value> {
        let response = self
            .http
            .post(request::endpoint_register(scope, registration)?)?;
        validate_registration_response_binding(&response, scope, registration)?;
        Ok(response)
    }

    pub fn envelope_send(
        &self,
        scope: &SecureClientRelayScope,
        envelope: &SecureMeshRelayEnvelope,
        transport: Option<&str>,
        opaque_sequence_label: Option<&str>,
    ) -> Result<Value> {
        let response = self.http.post(request::envelope_send(
            scope,
            envelope,
            transport,
            opaque_sequence_label,
        )?)?;
        validate_send_response_binding(
            &response,
            scope,
            envelope,
            transport,
            opaque_sequence_label,
        )?;
        Ok(response)
    }

    pub fn envelope_sync(
        &self,
        scope: &SecureClientRelayScope,
        mailbox_token: &str,
        after_delivery_sequence: Option<u64>,
        limit: Option<u64>,
        lease_ms: Option<u64>,
    ) -> Result<Value> {
        let response = self.http.post(request::envelope_sync(
            scope,
            mailbox_token,
            after_delivery_sequence,
            limit,
            lease_ms,
        )?)?;
        validate_sync_response_binding(&response, scope, mailbox_token, after_delivery_sequence)?;
        Ok(response)
    }

    pub fn envelope_ack(
        &self,
        scope: &SecureClientRelayScope,
        mailbox_token: &str,
        delivery_id: &str,
        lease_id: &str,
        lease_generation: u64,
    ) -> Result<Value> {
        let response = self.http.post(request::envelope_ack(
            scope,
            mailbox_token,
            delivery_id,
            lease_id,
            lease_generation,
        )?)?;
        validate_ack_response_binding(&response, scope, mailbox_token, delivery_id)?;
        Ok(response)
    }
}
