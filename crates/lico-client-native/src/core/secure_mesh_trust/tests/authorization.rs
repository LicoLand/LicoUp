use super::super::{
    DeviceTrustState, ProtectedSendPayloadKind, authorize_protected_send,
    authorize_protected_send_from_trust_record, evaluate_device_trust_verification_json,
    qr_verification_payload, sign_device_trust_record,
};
use super::support::{identity_fixture, identity_json};
use serde_json::json;

#[test]
fn secure_mesh_authorize_protected_send_blocks_unverified_key_changed_and_revoked_for_all_kinds() {
    for kind in ProtectedSendPayloadKind::all() {
        let authorized =
            authorize_protected_send("mobile:bob", &DeviceTrustState::Verified, kind).unwrap();
        assert_eq!(authorized.payload_kind(), kind);
        assert_eq!(authorized.peer_endpoint_id(), "mobile:bob");

        for (state, code) in [
            (DeviceTrustState::Unverified, "verification_required"),
            (DeviceTrustState::KeyChanged, "identity_key_changed"),
            (DeviceTrustState::Revoked, "device_revoked"),
            (
                DeviceTrustState::CrossSigned,
                "cross_signature_requires_durable_epoch_validation",
            ),
        ] {
            let error = authorize_protected_send("mobile:bob", &state, kind).unwrap_err();
            let message = error.to_string();
            assert!(
                message.contains(code),
                "kind {} state {:?} missing code {code}: {message}",
                kind.as_str(),
                state
            );
            assert!(
                message.contains(kind.as_str()),
                "kind {} missing from blocked send error: {message}",
                kind.as_str()
            );
        }
    }
}

#[test]
fn secure_mesh_authorize_protected_send_from_trust_record_and_rejects_observation_alone() {
    let (alice_key, alice) = identity_fixture("desktop_gui:alice");
    let (_bob_key, bob) = identity_fixture("mobile:bob");
    let record = sign_device_trust_record(
        &alice_key,
        &alice,
        &bob,
        DeviceTrustState::Verified,
        1,
        "qr",
        100,
        200,
    )
    .unwrap();
    let authorized = authorize_protected_send_from_trust_record(
        &alice,
        &bob,
        &record,
        150,
        ProtectedSendPayloadKind::Command,
    )
    .unwrap();
    assert_eq!(authorized.payload_kind(), ProtectedSendPayloadKind::Command);

    let observation = evaluate_device_trust_verification_json(
        &json!({
            "localIdentity": identity_json(&alice),
            "peerIdentity": identity_json(&bob),
            "qrPayload": qr_verification_payload(&alice, &bob, 1).unwrap(),
            "rosterEpoch": 1
        }),
        "qr",
    )
    .unwrap();
    assert_eq!(observation["observationMatched"], true);
    assert_eq!(observation["decision"]["allowedForHighRiskCommand"], false);
    assert_eq!(
        observation["decision"]["code"],
        "verification_observation_requires_persisted_trust_record"
    );
}
