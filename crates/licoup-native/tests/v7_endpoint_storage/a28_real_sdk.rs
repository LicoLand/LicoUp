//! A28 real-SDK cases for endpoint storage and custody.
//!
//! These cases drive the pinned LicoArc Candidate SDK's own handshake, ratchet,
//! record, and delete entries on top of the durable store and custody adapter,
//! and one of them kills a real host process to prove the durable record is
//! old-or-new without a graceful close.
//!
//! They need the explicit read-only authority artifact through
//! `LICOARC_AUTHORITY_BUNDLE` and are `#[ignore]`d so an absent artifact is
//! reported as not run instead of passing silently. No network, no keychain,
//! no real user data: keys and payloads are synthetic and the platform custody
//! is the announced file-backed fixture.

use std::io::Write;
use std::sync::Arc;

use licoup_native::core::secure_mesh_secret_store::SecureMeshSecretStore;
use licoup_protocol_bindings::endpoint::{Endpoint, EndpointState, Initiator, Responder};
use licoup_protocol_bindings::provider::RustCryptoProvider;
use licoup_protocol_bindings::state::{AtomicState, CustodyRef, KeyCustody};
use licoup_protocol_bindings::{EndpointConsumer, ErrorCode};

use licoup_native::domain::mobile_relay::endpoint_v7_storage::{
    EndpointV7Continuity, EndpointV7Custody, EndpointV7StateStore, EndpointV7Storage,
    EndpointV7StorageError,
};

use crate::support::{
    CHILD_ROLE_ENV, CaptureCarrier, CaptureReceiver, ChildSpec, FIXTURE_NAMESPACE, FixedClock,
    FixtureVault, NoEffects, RecordedIdentity, TempDir, admitted_line, child_path, child_value,
    hex, parse_marker, synthetic_identity,
};

type ResponderEndpoint =
    Endpoint<Responder, RustCryptoProvider, EndpointV7Custody, EndpointV7StateStore>;
type InitiatorEndpoint =
    Endpoint<Initiator, RustCryptoProvider, EndpointV7Custody, EndpointV7StateStore>;

fn open(
    root: &std::path::Path,
    vault: &Arc<FixtureVault>,
    initial_state: EndpointState,
) -> Result<EndpointV7Storage, EndpointV7StorageError> {
    EndpointV7Storage::open(
        root,
        initial_state,
        Arc::clone(vault) as Arc<dyn SecureMeshSecretStore>,
        FIXTURE_NAMESPACE,
    )
}

#[test]
#[ignore = "requires LICOARC_AUTHORITY_BUNDLE (explicit read-only Candidate artifact)"]
fn a_real_two_role_session_commits_state_custody_and_revocation() {
    let line = admitted_line().expect("the explicit authority artifact admits the fixed line");
    let temp = TempDir::new("real-session");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let responder_root = temp.path().join("responder");
    let initiator_root = temp.path().join("initiator");
    let clock = FixedClock(50);
    let provider = RustCryptoProvider;

    // Responder side: identity, a one-time prekey pair, and the first durable
    // commit (adopt the staged prekey pair).
    let responder_storage =
        open(&responder_root, &vault, EndpointState::responder()).expect("responder root");
    let responder_signing = responder_storage
        .custody()
        .install_device_identity([0x51; 32], [0x52; 32])
        .expect("responder identity installs");
    let (ed_public, ml_dsa_public) = responder_storage
        .custody()
        .device_identity_public_keys()
        .expect("identity public keys")
        .expect("identity is installed");
    let responder_identity = synthetic_identity(0x53, ed_public, ml_dsa_public);
    let consumer = EndpointConsumer::new();
    let trusted_responder = consumer
        .trust_peer(
            &line,
            &RecordedIdentity {
                identity: responder_identity.clone(),
                profile: *line.protection_profile_id(),
            },
            &responder_identity,
        )
        .expect("the caller-recorded responder identity is trusted");

    let prekey_x25519 = responder_storage
        .custody()
        .stage_x25519([0x31; 32])
        .expect("staged prekey X25519");
    let adopted_prekey_x25519 = prekey_x25519.adopted_handle();
    let prekey_ml_kem = responder_storage
        .custody()
        .stage_ml_kem_768([0x32; 64])
        .expect("staged prekey ML-KEM");
    let mut responder: ResponderEndpoint = Endpoint::responder(
        line.clone(),
        provider,
        responder_storage.custody(),
        responder_storage.state_store(),
    )
    .expect("responder endpoint");
    let bundle = responder
        .admit_prekey(
            &responder_identity,
            &responder_signing,
            1,
            prekey_x25519,
            prekey_ml_kem,
            10,
            100,
        )
        .expect("prekey admission commits");
    assert_eq!(
        responder_storage.status().expect("status").generation,
        1,
        "the prekey admission is one durable generation"
    );
    let identity_handles = responder_storage
        .custody()
        .device_identity_handles()
        .expect("identity handles")
        .expect("identity is installed");

    // Initiator side: identity, the first packet commit, then the responder's
    // accept commit and the initiator's verification.
    let initiator_storage =
        open(&initiator_root, &vault, EndpointState::initiator()).expect("initiator root");
    let initiator_signing = initiator_storage
        .custody()
        .install_device_identity([0x41; 32], [0x42; 32])
        .expect("initiator identity installs");
    let (ed_public, ml_dsa_public) = initiator_storage
        .custody()
        .device_identity_public_keys()
        .expect("identity public keys")
        .expect("identity is installed");
    let initiator_identity = synthetic_identity(0x43, ed_public, ml_dsa_public);
    let trusted_initiator = consumer
        .trust_peer(
            &line,
            &RecordedIdentity {
                identity: initiator_identity.clone(),
                profile: *line.protection_profile_id(),
            },
            &initiator_identity,
        )
        .expect("the caller-recorded initiator identity is trusted");

    let initiator_ratchet_x25519 = initiator_storage
        .custody()
        .stage_x25519([0x71; 32])
        .expect("staged initiator ratchet key");
    let adopted_ratchet_x25519 = initiator_ratchet_x25519.adopted_handle();
    let initiator_entropy = initiator_storage
        .custody()
        .adopted_encapsulation_entropy([0x72; 32])
        .expect("adopted encapsulation entropy");
    let mut initiator: InitiatorEndpoint = Endpoint::initiator(
        line.clone(),
        provider,
        initiator_storage.custody(),
        initiator_storage.state_store(),
    )
    .expect("initiator endpoint");
    let first_packet = initiator
        .create_first_packet(
            &initiator_identity,
            &trusted_responder,
            [0x81; 32],
            [0x82; 32],
            &initiator_signing,
            bundle,
            &clock,
            initiator_ratchet_x25519,
            initiator_entropy,
        )
        .expect("the first packet commits");
    let accept = responder
        .accept_first_packet(
            &trusted_initiator,
            &responder_identity,
            [0x82; 32],
            &first_packet,
            &clock,
        )
        .expect("the responder accepts and commits");
    initiator
        .verify_session_accept(&accept)
        .expect("the initiator verifies the accept");
    assert_eq!(responder_storage.status().expect("status").generation, 2);
    assert_eq!(initiator_storage.status().expect("status").generation, 2);

    // The SDK restart contract over the durable generation: the exact
    // committed generation is accepted, an older one is a rollback, and a
    // newer one is not a transition this store ever produced.
    let committed_generation = initiator_storage.status().expect("status").generation;
    initiator
        .restart(committed_generation)
        .expect("the exact committed generation is restorable");
    assert_eq!(
        initiator
            .restart(committed_generation - 1)
            .expect_err("an older generation is a rollback")
            .code,
        ErrorCode::StateRollback
    );
    assert_eq!(
        initiator
            .restart(committed_generation + 1)
            .expect_err("a newer generation was never committed here")
            .code,
        ErrorCode::InvalidTransition
    );

    // One real record round trip: the initiator commits the protected packet,
    // dispatches it, the responder verifies and durably commits it, and the
    // plaintext is released through the caller boundary.
    let pending = initiator
        .send_record(b"opaque-i2r", None)
        .expect("the record commits");
    assert_eq!(
        initiator_storage.status().expect("status").pending_count,
        1,
        "the committed packet is durable before any delivery"
    );
    let mut carrier = CaptureCarrier::default();
    initiator
        .dispatch_pending(pending, &mut carrier, &mut NoEffects)
        .expect("the committed packet is dispatched and settled");
    assert_eq!(initiator_storage.status().expect("status").pending_count, 0);
    let received = responder
        .receive_record(&carrier.packet, None)
        .expect("the responder verifies and commits the record");
    let mut receiver = CaptureReceiver::default();
    responder
        .release_pending_plaintext(received, &mut receiver)
        .expect("the plaintext is released");
    assert_eq!(receiver.plaintext, b"opaque-i2r");

    // Revocation: the SDK's own delete_session emits the bounded handle
    // deletions; the committed ratchet token is tombstoned and its material
    // removed, while the device identity survives.
    initiator
        .delete_session()
        .expect("the session deletion commits");
    assert!(
        initiator_storage
            .custody()
            .x25519_public(CustodyRef::Adopted(&adopted_ratchet_x25519))
            .is_err(),
        "the deleted ratchet token is unreachable after revocation"
    );
    assert!(
        initiator_storage
            .custody()
            .ed25519_public(&initiator_signing.ed25519)
            .is_ok(),
        "revocation of a session never removes the device identity"
    );
    assert!(responder.delete_session().is_ok());
    assert!(
        responder_storage
            .custody()
            .x25519_public(CustodyRef::Adopted(&adopted_prekey_x25519))
            .is_err(),
        "the deleted prekey token is unreachable after revocation"
    );
    assert!(
        responder_storage
            .custody()
            .ed25519_public(&identity_handles.ed25519)
            .is_ok(),
        "the identity remains usable after the session is gone"
    );
    drop((initiator, responder, responder_storage, initiator_storage));

    // Reopen after the committed sessions: the snapshots did not survive, so
    // the store refuses to continue them and only an explicit new epoch moves.
    let storage =
        open(&responder_root, &vault, EndpointState::responder()).expect("reopen responder");
    assert_eq!(
        storage.status().expect("status").continuity,
        EndpointV7Continuity::ContinuityLost
    );
    assert_eq!(
        storage
            .state_store()
            .load()
            .expect_err("a lost session never loads")
            .code,
        ErrorCode::StateRollback
    );
    storage
        .begin_new_session()
        .expect("an explicit new session is the way forward");
    assert!(storage.state_store().load().is_ok());
}

#[test]
#[ignore = "requires LICOARC_AUTHORITY_BUNDLE and re-executes this test binary"]
fn killed_host_leaves_old_or_new_and_no_reusable_ratchet() {
    let line = admitted_line().expect("the explicit authority artifact admits the fixed line");
    let temp = TempDir::new("killed-host");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    let marker = temp.path().join("child-marker.txt");

    let child = crate::support::spawn_and_kill_child(
        &ChildSpec {
            role: "killed-host",
            root: root.clone(),
            vault: temp.path().join("vault"),
            marker: marker.clone(),
        },
        "a28_real_sdk::killed_host_process",
    );
    assert!(child.killed, "the host process was killed by SIGKILL");
    assert!(
        child.observed.iter().any(|line| line == "ready"),
        "the child announced its committed state before dying: {:?}",
        child.observed
    );
    let marker_fields = parse_marker(&child.marker);
    let old_generation = marker_fields
        .iter()
        .find(|(key, _)| key == "generation")
        .map(|(_, value)| value.clone())
        .expect("the child wrote its committed generation");
    assert_eq!(old_generation, "1");
    let old_public = marker_fields
        .iter()
        .find(|(key, _)| key == "x25519_public")
        .map(|(_, value)| value.clone())
        .expect("the child wrote its committed prekey public");

    // The root lock is released by the kernel, the committed generation is
    // intact, and the session snapshot is gone: no silent continuation.
    let storage =
        open(&root, &vault, EndpointState::responder()).expect("reopen after a killed host");
    let status = storage.status().expect("status");
    assert_eq!(status.continuity, EndpointV7Continuity::ContinuityLost);
    assert_eq!(status.generation, 1);
    assert!(
        status.session_keys_fenced >= 2,
        "the adopted prekey pair is fenced"
    );
    let refused = Endpoint::<Responder, _, _, _>::responder(
        line.clone(),
        RustCryptoProvider,
        storage.custody(),
        storage.state_store(),
    )
    .expect_err("a killed session is never resumed");
    assert_eq!(refused.code, ErrorCode::StateRollback);
    let facts = storage.begin_new_session().expect("explicit new session");
    assert_eq!(facts.generation, 1);

    // A new session works, and it uses newly issued keys: the committed public
    // key of the dead session is never offered again.
    let signing = storage
        .custody()
        .device_identity_handles()
        .expect("identity handles")
        .expect("the identity survived the kill");
    let (ed_public, ml_dsa_public) = storage
        .custody()
        .device_identity_public_keys()
        .expect("identity public keys")
        .expect("the identity survived the kill");
    let identity = synthetic_identity(0x93, ed_public, ml_dsa_public);
    let mut responder: ResponderEndpoint = Endpoint::responder(
        line,
        RustCryptoProvider,
        storage.custody(),
        storage.state_store(),
    )
    .expect("a fresh session after the explicit new epoch");
    let fresh_x25519 = storage
        .custody()
        .stage_x25519([0xb1; 32])
        .expect("fresh staged key");
    let fresh_ml_kem = storage
        .custody()
        .stage_ml_kem_768([0xb2; 64])
        .expect("fresh staged key");
    let fresh_bundle = responder
        .admit_prekey(&identity, &signing, 1, fresh_x25519, fresh_ml_kem, 10, 100)
        .expect("the new session commits its own prekey");
    assert_ne!(
        hex(&fresh_bundle.x25519_public),
        old_public,
        "the new session never reuses the dead session's ratchet key"
    );
}

#[test]
#[ignore = "spawned as a killed child by the recovery case"]
fn killed_host_process() {
    if child_value(CHILD_ROLE_ENV).as_deref() != Some("killed-host") {
        return;
    }
    let root = child_path("V7_ENDPOINT_STORAGE_CHILD_ROOT").expect("child root");
    let vault_path = child_path("V7_ENDPOINT_STORAGE_CHILD_VAULT").expect("child vault");
    let marker = child_path("V7_ENDPOINT_STORAGE_CHILD_MARKER").expect("child marker");
    let line = admitted_line().expect("the child admits the fixed line");
    let vault = Arc::new(FixtureVault::new(vault_path));
    let storage =
        open(&root, &vault, EndpointState::responder()).expect("the child opens the root");
    let signing = storage
        .custody()
        .install_device_identity([0x91; 32], [0x92; 32])
        .expect("the child installs an identity");
    let (ed_public, ml_dsa_public) = storage
        .custody()
        .device_identity_public_keys()
        .expect("identity public keys")
        .expect("identity is installed");
    let identity = synthetic_identity(0x93, ed_public, ml_dsa_public);
    let x25519 = storage
        .custody()
        .stage_x25519([0xa1; 32])
        .expect("the child stages a prekey");
    let ml_kem = storage
        .custody()
        .stage_ml_kem_768([0xa2; 64])
        .expect("the child stages a prekey");
    let mut responder: ResponderEndpoint = Endpoint::responder(
        line,
        RustCryptoProvider,
        storage.custody(),
        storage.state_store(),
    )
    .expect("the child builds a responder endpoint");
    let bundle = responder
        .admit_prekey(&identity, &signing, 1, x25519, ml_kem, 10, 100)
        .expect("the child commits its prekey");
    std::fs::write(
        &marker,
        format!(
            "generation={}\nx25519_public={}\n",
            storage.status().expect("status").generation,
            hex(&bundle.x25519_public)
        ),
    )
    .expect("the child writes its marker");
    println!("ready");
    let _ = std::io::stdout().flush();
    loop {
        std::thread::sleep(std::time::Duration::from_secs(60));
    }
}
