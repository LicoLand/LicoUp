use crate::domain::mobile_relay::endpoint_trust::{
    hex_encode_bytes, set_kt_freshness_now_override,
};
use crate::domain::mobile_relay::key_transparency::authority::parse_kt_authority_proposal;
use crate::domain::mobile_relay::key_transparency::authority::{
    KT_AUTHORITY_CHALLENGE_LEGACY_SCHEMA_VERSION, KT_AUTHORITY_CHALLENGE_PHASE_FIELD,
    KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION, KT_AUTHORITY_CHALLENGE_TTL_SECONDS, KtAuthorityProposal,
    complete_kt_authority_challenge, marker_phase, read_kt_authority_challenge,
    stage_kt_authority_challenge,
};
use crate::domain::mobile_relay::key_transparency::persistence::{
    create_authority_challenge_marker, read_authority_challenge_marker,
};
use crate::platform::paths::set_portable_data_dir_override;
use crate::state_machines::security_kt_authority_challenge_marker::State as ChallengeMarkerState;
use ed25519_dalek::SigningKey;
use rand_core::OsRng;
use serde_json::{Value, json};
use std::path::PathBuf;
use uuid::Uuid;

struct StateRoot {
    path: PathBuf,
    previous: Option<PathBuf>,
}

impl StateRoot {
    fn create() -> Self {
        let path = std::env::temp_dir().join(format!(
            "licoup-kt-authority-challenge-phase-{}",
            Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).unwrap();
        let previous = set_portable_data_dir_override(Some(path.clone()));
        Self { path, previous }
    }
}

impl Drop for StateRoot {
    fn drop(&mut self) {
        set_portable_data_dir_override(self.previous.take());
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn synthetic_proposal() -> KtAuthorityProposal {
    let signing_key = SigningKey::generate(&mut OsRng);
    parse_kt_authority_proposal(&json!({
        "directoryScopeCommitment": hex_encode_bytes(&[7_u8; 32]),
        "pin": {
            "logId": "synthetic-log",
            "keyId": "synthetic-key",
            "publicKeyHex": hex_encode_bytes(signing_key.verifying_key().as_bytes()),
            "provenance": "user-configured-external"
        },
        "maxSthAgeSeconds": 3600,
        "maxFutureSkewSeconds": 300
    }))
    .unwrap()
}

fn persisted_phase() -> ChallengeMarkerState {
    let raw = read_authority_challenge_marker().unwrap().unwrap();
    let marker: Value = serde_json::from_slice(&raw).unwrap();
    marker_phase(&marker).unwrap()
}

#[test]
fn persisted_phase_recovers_expiry_replacement_and_completion() {
    let _root = StateRoot::create();
    let proposal = synthetic_proposal();
    let config = json!({});

    let first_id = {
        let _clock = set_kt_freshness_now_override(10);
        let response = stage_kt_authority_challenge(&config, &proposal).unwrap();
        assert!(response.get(KT_AUTHORITY_CHALLENGE_PHASE_FIELD).is_none());
        response["authorityChallengeId"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    assert_eq!(persisted_phase(), ChallengeMarkerState::Pending);

    {
        let _clock = set_kt_freshness_now_override(10 + KT_AUTHORITY_CHALLENGE_TTL_SECONDS + 1);
        let reopened = read_kt_authority_challenge().unwrap().unwrap();
        assert_eq!(
            marker_phase(&reopened).unwrap(),
            ChallengeMarkerState::Expired
        );
        assert_eq!(persisted_phase(), ChallengeMarkerState::Expired);

        let replacement = stage_kt_authority_challenge(&config, &proposal).unwrap();
        assert_ne!(
            replacement["authorityChallengeId"].as_str().unwrap(),
            first_id
        );
        assert!(
            replacement
                .get(KT_AUTHORITY_CHALLENGE_PHASE_FIELD)
                .is_none()
        );
    }
    assert_eq!(persisted_phase(), ChallengeMarkerState::Pending);

    complete_kt_authority_challenge().unwrap();
    assert!(read_authority_challenge_marker().unwrap().is_none());
}

#[test]
fn legacy_marker_migrates_once_from_persisted_deadline() {
    let _root = StateRoot::create();
    let legacy = json!({
        "schemaVersion": KT_AUTHORITY_CHALLENGE_LEGACY_SCHEMA_VERSION,
        "challengeId": "synthetic-legacy-challenge",
        "proposalDigest": "7".repeat(64),
        "configGeneration": 3,
        "authorityGeneration": 2,
        "expiresAtEpochSeconds": 100,
        "requiresSecurityReset": false
    });
    create_authority_challenge_marker(&serde_json::to_vec(&legacy).unwrap()).unwrap();

    let migrated = {
        let _clock = set_kt_freshness_now_override(101);
        read_kt_authority_challenge().unwrap().unwrap()
    };
    assert_eq!(
        migrated["schemaVersion"],
        json!(KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION)
    );
    assert_eq!(
        marker_phase(&migrated).unwrap(),
        ChallengeMarkerState::Expired
    );

    let reopened: Value =
        serde_json::from_slice(&read_authority_challenge_marker().unwrap().unwrap()).unwrap();
    assert_eq!(
        reopened["schemaVersion"],
        json!(KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION)
    );
    assert_eq!(
        marker_phase(&reopened).unwrap(),
        ChallengeMarkerState::Expired
    );

    complete_kt_authority_challenge().unwrap();
    assert!(read_authority_challenge_marker().unwrap().is_none());
}

#[test]
fn current_marker_without_generated_phase_is_rejected_without_rewrite() {
    let _root = StateRoot::create();
    let invalid = json!({
        "schemaVersion": KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION,
        "challengeId": "synthetic-invalid-challenge",
        "proposalDigest": "8".repeat(64),
        "configGeneration": 1,
        "authorityGeneration": 1,
        "expiresAtEpochSeconds": u64::MAX,
        "requiresSecurityReset": false
    });
    let encoded = serde_json::to_vec(&invalid).unwrap();
    create_authority_challenge_marker(&encoded).unwrap();

    let error = read_kt_authority_challenge().unwrap_err().to_string();
    assert!(error.contains("marker phase is invalid"));
    assert_eq!(read_authority_challenge_marker().unwrap().unwrap(), encoded);
}
