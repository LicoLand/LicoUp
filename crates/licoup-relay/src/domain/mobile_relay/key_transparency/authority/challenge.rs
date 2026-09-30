use super::proposal::{
    KtAuthorityProposal, authority_change_requires_reset, authority_configuration_matches,
};
use crate::domain::mobile_relay::endpoint_trust::{
    current_secure_mesh_kt_gate_epoch_seconds, random_base64url,
};
use crate::domain::mobile_relay::key_transparency::config::{
    AUTHORITY_GENERATION_FIELD, CONFIG_GENERATION_FIELD, CONFIG_SCHEMA_VERSION, config_generation,
    kt_authority_reset_in_progress,
};
use crate::domain::mobile_relay::key_transparency::persistence::{
    create_authority_challenge_marker, read_authority_challenge_marker,
    remove_authority_challenge_marker, replace_authority_challenge_marker,
};
use crate::domain::mobile_relay::key_transparency::projection::authority_challenge_response;
use crate::state_machines::security_kt_authority_challenge_marker::{
    self, Event as ChallengeMarkerEvent, State as ChallengeMarkerState,
};
use anyhow::{Result, anyhow, ensure};
use serde_json::{Value, json};

pub(in crate::domain::mobile_relay) const KT_AUTHORITY_CHALLENGE_LEGACY_SCHEMA_VERSION: u64 = 1;
pub(in crate::domain::mobile_relay) const KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION: u64 = 2;
pub(in crate::domain::mobile_relay) const KT_AUTHORITY_CHALLENGE_TTL_SECONDS: u64 = 5 * 60;
pub(in crate::domain::mobile_relay) const KT_AUTHORITY_CHALLENGE_PHASE_FIELD: &str = "markerPhase";

pub(in crate::domain::mobile_relay) fn marker_phase(
    challenge: &Value,
) -> Result<ChallengeMarkerState> {
    challenge
        .get(KT_AUTHORITY_CHALLENGE_PHASE_FIELD)
        .and_then(Value::as_str)
        .and_then(ChallengeMarkerState::from_name)
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge marker phase is invalid"))
}

fn transition_marker(
    challenge: &mut Value,
    event: ChallengeMarkerEvent,
) -> Result<ChallengeMarkerState> {
    let from = marker_phase(challenge)?;
    let target =
        security_kt_authority_challenge_marker::transition(from, event).ok_or_else(|| {
            anyhow!("secure mesh KT authority challenge marker transition is invalid")
        })?;
    challenge[KT_AUTHORITY_CHALLENGE_PHASE_FIELD] = json!(target.as_str());
    Ok(target)
}

fn persist_marker(challenge: &Value) -> Result<()> {
    replace_authority_challenge_marker(&serde_json::to_vec(challenge)?)
}

pub(super) enum KtAuthorityChallengeState {
    Pending { requires_security_reset: bool },
    AlreadyCommitted { required_security_reset: bool },
}

pub(in crate::domain::mobile_relay) fn read_kt_authority_challenge() -> Result<Option<Value>> {
    let Some(raw) = read_authority_challenge_marker()? else {
        return Ok(None);
    };
    let mut challenge: Value = serde_json::from_slice(&raw)
        .map_err(|_| anyhow!("secure mesh KT authority challenge is invalid"))?;
    let schema_version = challenge.get("schemaVersion").and_then(Value::as_u64);
    ensure!(
        matches!(
            schema_version,
            Some(KT_AUTHORITY_CHALLENGE_LEGACY_SCHEMA_VERSION)
                | Some(KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION)
        ) && challenge
            .get("challengeId")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
            && challenge
                .get("proposalDigest")
                .and_then(Value::as_str)
                .is_some_and(|value| value.len() == 64)
            && challenge
                .get("configGeneration")
                .and_then(Value::as_u64)
                .is_some()
            && challenge
                .get("authorityGeneration")
                .and_then(Value::as_u64)
                .is_some()
            && challenge
                .get("expiresAtEpochSeconds")
                .and_then(Value::as_u64)
                .is_some()
            && challenge
                .get("requiresSecurityReset")
                .and_then(Value::as_bool)
                .is_some(),
        "secure mesh KT authority challenge is invalid"
    );
    let now = current_secure_mesh_kt_gate_epoch_seconds()?;
    if schema_version == Some(KT_AUTHORITY_CHALLENGE_LEGACY_SCHEMA_VERSION) {
        migrate_legacy_marker(&mut challenge, now)?;
        persist_marker(&challenge)?;
    } else {
        marker_phase(&challenge)?;
    }
    if marker_phase(&challenge)? == ChallengeMarkerState::Pending
        && now > challenge["expiresAtEpochSeconds"].as_u64().unwrap_or(0)
    {
        transition_marker(&mut challenge, ChallengeMarkerEvent::Expire)?;
        persist_marker(&challenge)?;
    }
    Ok(Some(challenge))
}

fn migrate_legacy_marker(challenge: &mut Value, now: u64) -> Result<()> {
    let staged = security_kt_authority_challenge_marker::transition(
        security_kt_authority_challenge_marker::INITIAL,
        ChallengeMarkerEvent::Stage,
    )
    .ok_or_else(|| anyhow!("secure mesh KT authority challenge stage transition is invalid"))?;
    challenge[KT_AUTHORITY_CHALLENGE_PHASE_FIELD] = json!(staged.as_str());
    if now > challenge["expiresAtEpochSeconds"].as_u64().unwrap_or(0) {
        transition_marker(challenge, ChallengeMarkerEvent::Expire)?;
    }
    challenge["schemaVersion"] = json!(KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION);
    Ok(())
}

pub(in crate::domain::mobile_relay) fn stage_kt_authority_challenge(
    config: &Value,
    proposal: &KtAuthorityProposal,
) -> Result<Value> {
    let now = current_secure_mesh_kt_gate_epoch_seconds()?;
    let mesh_config_generation = config_generation(config, CONFIG_GENERATION_FIELD)?;
    let authority_generation = config_generation(config, AUTHORITY_GENERATION_FIELD)?;
    if let Some(mut existing) = read_kt_authority_challenge()? {
        let phase = marker_phase(&existing)?;
        let same_proposal = existing["proposalDigest"].as_str() == Some(proposal.digest.as_str())
            && existing["configGeneration"].as_u64() == Some(mesh_config_generation)
            && existing["authorityGeneration"].as_u64() == Some(authority_generation);
        if phase == ChallengeMarkerState::Pending && same_proposal {
            return Ok(authority_challenge_response(
                &existing,
                CONFIG_SCHEMA_VERSION,
            ));
        }
        if phase == ChallengeMarkerState::Pending {
            return Err(anyhow!(
                "a different secure mesh KT authority challenge is already pending"
            ));
        }
        let target = transition_marker(&mut existing, ChallengeMarkerEvent::Replace)?;
        let replacement = new_challenge(
            config,
            proposal,
            mesh_config_generation,
            authority_generation,
            now,
            target,
        )?;
        persist_marker(&replacement)?;
        return Ok(authority_challenge_response(
            &replacement,
            CONFIG_SCHEMA_VERSION,
        ));
    }
    let target = security_kt_authority_challenge_marker::transition(
        security_kt_authority_challenge_marker::INITIAL,
        ChallengeMarkerEvent::Stage,
    )
    .ok_or_else(|| anyhow!("secure mesh KT authority challenge stage transition is invalid"))?;
    let challenge = new_challenge(
        config,
        proposal,
        mesh_config_generation,
        authority_generation,
        now,
        target,
    )?;
    create_authority_challenge_marker(&serde_json::to_vec(&challenge)?)?;
    Ok(authority_challenge_response(
        &challenge,
        CONFIG_SCHEMA_VERSION,
    ))
}

fn new_challenge(
    config: &Value,
    proposal: &KtAuthorityProposal,
    mesh_config_generation: u64,
    authority_generation: u64,
    now: u64,
    phase: ChallengeMarkerState,
) -> Result<Value> {
    Ok(json!({
        "schemaVersion": KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION,
        (KT_AUTHORITY_CHALLENGE_PHASE_FIELD): phase.as_str(),
        "challengeId": random_base64url(24),
        "proposalDigest": proposal.digest,
        "configGeneration": mesh_config_generation,
        "authorityGeneration": authority_generation,
        "expiresAtEpochSeconds": now.saturating_add(KT_AUTHORITY_CHALLENGE_TTL_SECONDS),
        "requiresSecurityReset": authority_change_requires_reset(config, proposal)
            || kt_authority_reset_in_progress()?,
    }))
}

pub(super) fn verify_kt_authority_challenge(
    config: &Value,
    proposal: &KtAuthorityProposal,
    challenge_id: &str,
) -> Result<KtAuthorityChallengeState> {
    let challenge = read_kt_authority_challenge()?
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is missing"))?;
    ensure!(
        challenge["challengeId"].as_str() == Some(challenge_id),
        "secure mesh KT authority challenge id mismatch"
    );
    ensure!(
        challenge["proposalDigest"].as_str() == Some(proposal.digest.as_str()),
        "secure mesh KT authority challenge proposal mismatch"
    );
    let prepared_config_generation = challenge["configGeneration"]
        .as_u64()
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is invalid"))?;
    let prepared_authority_generation = challenge["authorityGeneration"]
        .as_u64()
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is invalid"))?;
    let requires_security_reset = challenge["requiresSecurityReset"]
        .as_bool()
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is invalid"))?;
    let current_config_generation = config_generation(config, CONFIG_GENERATION_FIELD)?;
    let current_authority_generation = config_generation(config, AUTHORITY_GENERATION_FIELD)?;
    let committed_authority_generation =
        prepared_authority_generation.saturating_add(u64::from(requires_security_reset));
    if current_config_generation > prepared_config_generation
        && current_authority_generation == committed_authority_generation
        && authority_configuration_matches(config, proposal)
    {
        return Ok(KtAuthorityChallengeState::AlreadyCommitted {
            required_security_reset: requires_security_reset,
        });
    }
    ensure!(
        current_config_generation == prepared_config_generation
            && current_authority_generation == prepared_authority_generation,
        "secure mesh KT authority challenge generation is stale"
    );
    if marker_phase(&challenge)? == ChallengeMarkerState::Expired {
        return Err(anyhow!("secure mesh KT authority challenge has expired"));
    }
    ensure!(
        marker_phase(&challenge)? == ChallengeMarkerState::Pending,
        "secure mesh KT authority challenge marker is not pending"
    );
    Ok(KtAuthorityChallengeState::Pending {
        requires_security_reset,
    })
}

pub(in crate::domain::mobile_relay) fn complete_kt_authority_challenge() -> Result<()> {
    let mut challenge = read_kt_authority_challenge()?
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is missing"))?;
    let target = transition_marker(&mut challenge, ChallengeMarkerEvent::Complete)?;
    if target == ChallengeMarkerState::Absent {
        ensure!(
            remove_authority_challenge_marker()?,
            "secure mesh KT authority challenge is missing"
        );
    } else {
        persist_marker(&challenge)?;
    }
    Ok(())
}
