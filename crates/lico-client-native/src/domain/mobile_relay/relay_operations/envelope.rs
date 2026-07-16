use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;
use crate::domain::mobile_relay::support::{
    MOBILE_RELAY_COMMAND_TTL_SECONDS, MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS, json_param,
};
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};

pub(in crate::domain::mobile_relay) fn secure_envelope_param(params: &Value) -> Option<Value> {
    let envelope = json_param(params, "envelope")?;
    if validate_secure_envelope(&envelope).is_ok() {
        Some(envelope)
    } else {
        None
    }
}

pub(in crate::domain::mobile_relay) fn validate_secure_envelope(envelope: &Value) -> Result<()> {
    let wire = serde_json::to_string(envelope)
        .context("secure mesh relay envelope serialization failed")?;
    SecureMeshRelayEnvelope::from_json(&wire)?;
    Ok(())
}

#[allow(dead_code)]
pub(in crate::domain::mobile_relay) fn validate_envelope_text_field(
    label: &str,
    value: &str,
    max_bytes: usize,
) -> Result<()> {
    if value.trim().is_empty() {
        return Err(anyhow!("secure envelope missing {label}"));
    }
    if value.len() > max_bytes {
        return Err(anyhow!("secure envelope {label} is too large"));
    }
    Ok(())
}

#[allow(dead_code)]
pub(in crate::domain::mobile_relay) fn validate_envelope_time_window(
    created_at: &str,
    expires_at: &str,
) -> Result<()> {
    let created = OffsetDateTime::parse(created_at, &Rfc3339)
        .map_err(|error| anyhow!("secure envelope createdAt is not RFC3339: {error}"))?;
    let expires = OffsetDateTime::parse(expires_at, &Rfc3339)
        .map_err(|error| anyhow!("secure envelope expiresAt is not RFC3339: {error}"))?;
    if expires <= created {
        return Err(anyhow!("secure envelope expiresAt must be after createdAt"));
    }
    let now = OffsetDateTime::now_utc();
    if created > now + Duration::seconds(MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS) {
        return Err(anyhow!("secure envelope createdAt is in the future"));
    }
    if expires <= now - Duration::seconds(MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS) {
        return Err(anyhow!("secure envelope has expired"));
    }
    if expires
        > now
            + Duration::seconds(
                MOBILE_RELAY_COMMAND_TTL_SECONDS + MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS,
            )
    {
        return Err(anyhow!(
            "secure envelope expiresAt exceeds mobile relay TTL"
        ));
    }
    Ok(())
}

#[allow(dead_code)]
pub(in crate::domain::mobile_relay) fn encoded_len_limit(decoded_bytes: usize) -> usize {
    decoded_bytes.div_ceil(3) * 4
}

pub(in crate::domain::mobile_relay) fn relay_envelope_from_value(
    value: &Value,
) -> Result<SecureMeshRelayEnvelope> {
    let wire = serde_json::to_string(value)
        .context("secure client relay envelope serialization failed")?;
    SecureMeshRelayEnvelope::from_json(&wire)
}
