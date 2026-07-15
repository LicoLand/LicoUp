use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit, Payload as AeadPayload},
};
use ed25519_dalek::{Signature, Signer, SigningKey};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::{RngCore, rngs::OsRng};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::sync::{Arc, OnceLock};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, Zeroizing};

use crate::core::secure_mesh::{SECURE_MESH_PROTOCOL_BUILD_REVISION, SECURE_MESH_PROTOCOL_VERSION};
use crate::core::secure_mesh_capability::{CapabilityEvaluation, capability_catalog};
use crate::core::secure_mesh_capability_proof::{
    CAPABILITY_PROOF_MAX_LIFETIME_SECONDS, CapabilityProofRequest,
    CapabilityProofVerificationContext, ClientCapabilityProjection, SignedCapabilityProof,
    encode_signed_capability_proof_json, sign_capability_proof, signed_capability_proof_challenge,
    signed_capability_proof_digest,
};
use crate::core::secure_mesh_crypto::{
    ContentKey, OpenedSecureMeshPayload, SECURE_MESH_CONTENT_CIPHER_SUITE, SealedSecureMeshPayload,
    SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
};
use crate::core::secure_mesh_directory::AuthorizedDirectoryLeaf;
#[cfg(test)]
use crate::core::secure_mesh_pqxdh::ML_KEM_1024_KEY_GENERATION_SEED_BYTES;
use crate::core::secure_mesh_pqxdh::{
    ML_KEM_1024_CIPHERTEXT_BYTES, SecureMeshMlKem1024PreKeySeed, decapsulate_ml_kem_1024,
    derive_triple_ratchet_initial_secrets, encapsulate_ml_kem_1024,
};
use crate::core::secure_mesh_prekey::{
    SecureMeshPairwisePreKeyBundle, SecureMeshPreKeyValidationPolicy,
    validate_pairwise_prekey_bundle,
};
use crate::core::secure_mesh_relay_envelope::{
    SecureMeshRelayEnvelope, SecureMeshRelayEnvelopeDraft, open_private_relay_header,
    seal_private_relay_header,
};
use crate::core::secure_mesh_session_negotiation::{
    CapabilityProofPeer, CapabilityProofReplayGuard, NegotiatedCapabilityBinding,
    VerifiedSessionNegotiation, accept_pairwise_capability_binding,
    create_pairwise_capability_binding, restore_verified_pairwise_session_negotiation,
};
use crate::core::secure_mesh_sparse_pq_ratchet::{
    SecureMeshSparsePqHeader, SecureMeshSparsePqRatchet, derive_hybrid_message_key,
};
use crate::core::secure_mesh_trust::DeviceTrustPublicIdentity;
use crate::platform::secure_mesh_secret_store::{
    PlatformSecretStore, SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession,
    SecretStoreHandle, SecureMeshSecretStore,
};
use time::OffsetDateTime;
use uuid::Uuid;

pub const SECURE_MESH_PAIRWISE_CIPHER_SUITE: &str =
    "licolite.pqxdh-triple-ratchet.v1.x25519-ed25519-mlkem1024-hkdfsha256-chacha20poly1305";
pub const SECURE_MESH_PAIRWISE_STATUS: &str = "authenticated_transcript_pqxdh_mlkem1024_triple_ratchet_encrypted_headers_bounded_skipped_header_keys_capability_bound_explicit_finished_bilateral_key_confirmation_unique_bound_snapshots_sesame_session_manager_multi_device_fanout_payload_codec_cross_endpoint_command_result_relay_available_independent_review_pending";

static PAIRWISE_RUNTIME_CRYPTO_SELF_TEST: OnceLock<bool> = OnceLock::new();

/// Exercises the in-memory PQXDH and Triple Ratchet primitives used by the
/// mobile runtime without touching persisted client state.
pub fn runtime_crypto_self_test() -> bool {
    *PAIRWISE_RUNTIME_CRYPTO_SELF_TEST.get_or_init(|| {
        (|| -> Result<()> {
            let alice_identity = SecureMeshPairwisePrivateKey::generate();
            let alice_ephemeral = SecureMeshPairwisePrivateKey::generate();
            let bob_identity = SecureMeshPairwisePrivateKey::generate();
            let bob_signed_prekey = SecureMeshPairwisePrivateKey::generate();
            let bob_one_time_prekey = SecureMeshPairwisePrivateKey::generate();

            let initiator_dh1 = alice_identity.diffie_hellman(&bob_signed_prekey.public_key())?;
            let initiator_dh2 = alice_ephemeral.diffie_hellman(&bob_identity.public_key())?;
            let initiator_dh3 = alice_ephemeral.diffie_hellman(&bob_signed_prekey.public_key())?;
            let initiator_dh4 =
                alice_ephemeral.diffie_hellman(&bob_one_time_prekey.public_key())?;

            let initiator_classical_secret = collect_pqxdh_classical_secret(
                "runtime-self-test:initiator",
                "runtime-self-test:responder",
                &initiator_dh1,
                &initiator_dh2,
                &initiator_dh3,
                Some(&initiator_dh4),
            )?;

            let responder_dh1 = bob_signed_prekey.diffie_hellman(&alice_identity.public_key())?;
            let responder_dh2 = bob_identity.diffie_hellman(&alice_ephemeral.public_key())?;
            let responder_dh3 = bob_signed_prekey.diffie_hellman(&alice_ephemeral.public_key())?;
            let responder_dh4 =
                bob_one_time_prekey.diffie_hellman(&alice_ephemeral.public_key())?;
            let responder_classical_secret = collect_pqxdh_classical_secret(
                "runtime-self-test:initiator",
                "runtime-self-test:responder",
                &responder_dh1,
                &responder_dh2,
                &responder_dh3,
                Some(&responder_dh4),
            )?;
            ensure!(
                initiator_classical_secret.as_slice() == responder_classical_secret.as_slice(),
                "pairwise runtime PQXDH classical agreement failed"
            );

            let bob_mlkem1024_seed = SecureMeshMlKem1024PreKeySeed::generate();
            let bob_mlkem1024_public_key = bob_mlkem1024_seed.public_key();
            let initiator_mlkem1024 = encapsulate_ml_kem_1024(&bob_mlkem1024_public_key)?;
            let responder_mlkem1024 = decapsulate_ml_kem_1024(
                &bob_mlkem1024_seed,
                &bob_mlkem1024_public_key,
                &initiator_mlkem1024.ciphertext,
            )?;
            let session_binding = b"runtime-self-test:session";
            let initiator_triple_secrets = derive_triple_ratchet_initial_secrets(
                initiator_classical_secret.as_slice(),
                initiator_mlkem1024.shared_secret(),
                &alice_identity.public_key(),
                &bob_identity.public_key(),
                session_binding,
            )?;
            let responder_triple_secrets = derive_triple_ratchet_initial_secrets(
                responder_classical_secret.as_slice(),
                &responder_mlkem1024,
                &alice_identity.public_key(),
                &bob_identity.public_key(),
                session_binding,
            )?;
            ensure!(
                initiator_triple_secrets.ec_secret() == responder_triple_secrets.ec_secret()
                    && initiator_triple_secrets.scka_secret()
                        == responder_triple_secrets.scka_secret()
                    && initiator_triple_secrets.ec_secret()
                        != initiator_triple_secrets.scka_secret(),
                "pairwise runtime PQXDH key schedule failed"
            );

            let initiator_keys = derive_initial_keys(
                initiator_triple_secrets.ec_secret(),
                "runtime-self-test:session",
                "runtime-self-test:initiator",
                "runtime-self-test:responder",
            )?;
            let responder_keys = derive_initial_keys(
                responder_triple_secrets.ec_secret(),
                "runtime-self-test:session",
                "runtime-self-test:initiator",
                "runtime-self-test:responder",
            )?;
            ensure!(
                initiator_keys.root_key == responder_keys.root_key
                    && initiator_keys.initiator_chain_key == responder_keys.initiator_chain_key
                    && initiator_keys.responder_chain_key == responder_keys.responder_chain_key
                    && initiator_keys.initiator_chain_key != initiator_keys.responder_chain_key,
                "pairwise runtime key schedule failed"
            );

            let (_, initiator_classical_message_key) =
                advance_chain(&initiator_keys.initiator_chain_key, 1, 0, "message")?;
            let (_, responder_classical_message_key) =
                advance_chain(&responder_keys.initiator_chain_key, 1, 0, "message")?;
            ensure!(
                initiator_classical_message_key.as_ref()
                    == responder_classical_message_key.as_ref(),
                "pairwise runtime classical ratchet key mismatch"
            );
            let mut initiator_sparse_pq =
                SecureMeshSparsePqRatchet::new_initiator(initiator_triple_secrets.scka_secret())?;
            let mut responder_sparse_pq =
                SecureMeshSparsePqRatchet::new_responder(responder_triple_secrets.scka_secret())?;
            let initiator_post_quantum = initiator_sparse_pq.send_key()?;
            let responder_post_quantum =
                responder_sparse_pq.receive_key(&initiator_post_quantum.header)?;
            let initiator_message_key = derive_hybrid_message_key(
                &initiator_classical_message_key,
                &initiator_post_quantum.message_key,
                session_binding,
            )?;
            let responder_message_key = derive_hybrid_message_key(
                &responder_classical_message_key,
                &responder_post_quantum,
                session_binding,
            )?;
            ensure!(
                initiator_message_key.as_ref() == responder_message_key.as_ref(),
                "pairwise runtime Triple Ratchet key mismatch"
            );
            let nonce = [0x5au8; NONCE_LEN];
            let aad = b"licolite-pairwise-runtime-self-test-aad";
            let plaintext = b"licolite-pairwise-runtime-self-test-body";
            let cipher = ChaCha20Poly1305::new(Key::from_slice(initiator_message_key.as_ref()));
            let ciphertext = cipher
                .encrypt(
                    Nonce::from_slice(&nonce),
                    AeadPayload {
                        msg: plaintext,
                        aad,
                    },
                )
                .map_err(|_| anyhow!("pairwise runtime encryption failed"))?;
            ensure!(
                !ciphertext
                    .windows(plaintext.len())
                    .any(|window| window == plaintext),
                "pairwise runtime ciphertext exposed plaintext"
            );
            let opener = ChaCha20Poly1305::new(Key::from_slice(responder_message_key.as_ref()));
            let opened = opener
                .decrypt(
                    Nonce::from_slice(&nonce),
                    AeadPayload {
                        msg: &ciphertext,
                        aad,
                    },
                )
                .map_err(|_| anyhow!("pairwise runtime decryption failed"))?;
            ensure!(opened == plaintext, "pairwise runtime plaintext mismatch");
            let mut tampered = ciphertext;
            tampered[0] ^= 1;
            ensure!(
                opener
                    .decrypt(
                        Nonce::from_slice(&nonce),
                        AeadPayload {
                            msg: &tampered,
                            aad,
                        },
                    )
                    .is_err(),
                "pairwise runtime tamper was accepted"
            );
            Ok(())
        })()
        .is_ok()
    })
}

const ROOT_KEY_LEN: usize = 32;
const CHAIN_KEY_LEN: usize = 32;
const MESSAGE_KEY_LEN: usize = 32;
const HEADER_KEY_LEN: usize = 32;
const NONCE_LEN: usize = 12;
const PUBLIC_KEY_LEN: usize = 32;
const MAX_SKIPPED_KEYS: usize = 32;
const MAX_REPLAY_IDS: usize = 256;
const MAX_CIPHERTEXT_BYTES: usize = 16 * 1024 * 1024;
const MAX_CONTENT_ENCRYPTED_HEADER_BYTES: usize = 1024;
const MAX_SPARSE_PQ_HEADER_BYTES: usize = 512;
const MAX_PERSISTED_SECRET_SNAPSHOT_BYTES: usize = 2 * 1024 * 1024;
const MAX_ENCODED_SPARSE_PQ_RATCHET_BYTES: usize = (1024 * 1024 * 8 + 5) / 6;
const MAX_ENDPOINT_ID_LEN: usize = 255;
const MAX_MESSAGE_ID_LEN: usize = 255;
const MAX_PERSISTED_CAPABILITY_PROOF_USES: usize = 4096;

const PQXDH_CLASSICAL_SALT_DOMAIN: &[u8] = b"licolite.secure-mesh.pqxdh-classical.salt.v1";
const PQXDH_CLASSICAL_INFO_DOMAIN: &[u8] = b"licolite.secure-mesh.pqxdh-classical.info.v1";
const CHAIN_INFO_DOMAIN: &[u8] = b"licolite.secure-mesh.double-ratchet.chain.v1";
const ROOT_INFO_DOMAIN: &[u8] = b"licolite.secure-mesh.double-ratchet.root.v1";
const MESSAGE_AAD_MAGIC: &[u8] = b"LCOSM-PAIRWISE-AAD-v1";
const PAYLOAD_AAD_BINDING_MAGIC: &[u8] = b"LCOSM-PAIRWISE-PAYLOAD-AAD-v1";
const SECRET_DOMAIN: &[u8] = b"LCOSM-PAIRWISE-SECRET-v1";
const INTRO_SIGNATURE_MAGIC: &[u8] = b"LCOSM-PAIRWISE-INTRO-SIGNATURE-v1";
const ACCEPT_SIGNATURE_MAGIC: &[u8] = b"LCOSM-PAIRWISE-ACCEPT-SIGNATURE-v1";
const HANDSHAKE_TRANSCRIPT_MAGIC: &[u8] = b"LCOSM-PAIRWISE-HANDSHAKE-v1";
const KEY_CONFIRMATION_MAGIC: &[u8] = b"LCOSM-PAIRWISE-KEY-CONFIRMATION-v1";
const CAPABILITY_BOUND_KEY_SCHEDULE_MAGIC: &[u8] =
    b"LCOSM-PAIRWISE-CAPABILITY-BOUND-KEY-SCHEDULE-v1";
const INITIATOR_FINISHED_MAGIC: &[u8] = b"LCOSM-PAIRWISE-INITIATOR-FINISHED-v1";
const HANDSHAKE_HASH_LEN: usize = 32;
const SIGNATURE_LEN: usize = 64;
const KEY_CONFIRMATION_LEN: usize = 32;
const PAIRWISE_SNAPSHOT_SCHEMA_VERSION: u32 = 10;
const PAIRWISE_SECRET_STORE_CLASS: &str = "pairwiseSessionSnapshot";
const PAIRWISE_SECRET_STORE_SERVICE: &str = "app.licolite.licoarc.mobile-relay.pqxdh-mlkem1024.v1";
const PAIRWISE_SECRET_STORE_ACCOUNT_PREFIX: &str = "mobileRelayE2ee";

type HmacSha256 = Hmac<Sha256>;

pub const SECURE_MESH_PAIRWISE_CAPABILITY_POLICY_REVISION: u64 = 1;

#[derive(Clone)]
pub struct SecureMeshPairwisePrivateKey(StaticSecret);

impl SecureMeshPairwisePrivateKey {
    pub fn generate() -> Self {
        Self(StaticSecret::random_from_rng(OsRng))
    }

    pub fn from_bytes(bytes: [u8; PUBLIC_KEY_LEN]) -> Self {
        Self(StaticSecret::from(bytes))
    }

    pub fn public_key(&self) -> [u8; PUBLIC_KEY_LEN] {
        PublicKey::from(&self.0).to_bytes()
    }

    fn diffie_hellman(&self, remote_public_key: &[u8]) -> Result<Zeroizing<[u8; PUBLIC_KEY_LEN]>> {
        let remote = PublicKey::from(parse_key_bytes(remote_public_key, "remote public key")?);
        let shared_secret = self.0.diffie_hellman(&remote).to_bytes();
        ensure!(
            shared_secret != [0u8; PUBLIC_KEY_LEN],
            "secure mesh pairwise X25519 input is non-contributory"
        );
        Ok(Zeroizing::new(shared_secret))
    }

    fn to_bytes(&self) -> [u8; PUBLIC_KEY_LEN] {
        self.0.to_bytes()
    }

    fn destroy(&mut self) {
        self.0.zeroize();
    }
}

pub fn secure_mesh_pairwise_build_protocol_digest() -> Result<String> {
    secure_mesh_pairwise_build_protocol_digest_for_revision(SECURE_MESH_PROTOCOL_BUILD_REVISION)
}

fn secure_mesh_pairwise_build_protocol_digest_for_revision(
    profile_revision: u64,
) -> Result<String> {
    let mut transcript = Vec::new();
    transcript.extend_from_slice(b"LICO-SM-PAIRWISE-BUILD-PROTOCOL-v1");
    append_len_prefixed_bytes(&mut transcript, SECURE_MESH_PROTOCOL_VERSION.as_bytes())?;
    append_len_prefixed_bytes(
        &mut transcript,
        SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes(),
    )?;
    transcript.extend_from_slice(&profile_revision.to_be_bytes());
    transcript.extend_from_slice(&SECURE_MESH_PAIRWISE_CAPABILITY_POLICY_REVISION.to_be_bytes());
    append_len_prefixed_bytes(&mut transcript, capability_catalog()?.digest().as_bytes())?;
    let digest: [u8; 32] = Sha256::digest(transcript).into();
    Ok(crate::core::secure_mesh_capability_proof::encode_sha256_digest(&digest))
}

#[cfg(test)]
pub(crate) fn secure_mesh_pairwise_test_capability_evaluation() -> Result<CapabilityEvaluation> {
    let facts = crate::core::secure_mesh_capability::mandatory_protocol_facts(
        crate::core::secure_mesh_capability::CapabilityEvidenceKind::TestFixture,
    )?;
    capability_catalog()?.evaluate(&facts)
}

fn capability_proof_request(
    challenge: [u8; 32],
    now: OffsetDateTime,
) -> Result<CapabilityProofRequest> {
    let issued_at_unix_seconds = now.unix_timestamp();
    let expires_at_unix_seconds = issued_at_unix_seconds
        .checked_add(CAPABILITY_PROOF_MAX_LIFETIME_SECONDS)
        .ok_or_else(|| anyhow!("secure mesh pairwise capability proof time is invalid"))?;
    Ok(CapabilityProofRequest {
        build_protocol_digest: secure_mesh_pairwise_build_protocol_digest()?,
        policy_revision: SECURE_MESH_PAIRWISE_CAPABILITY_POLICY_REVISION,
        challenge,
        issued_at_unix_seconds,
        expires_at_unix_seconds,
    })
}

fn capability_verification_context(
    challenge: [u8; 32],
    now: OffsetDateTime,
) -> Result<CapabilityProofVerificationContext> {
    Ok(CapabilityProofVerificationContext {
        expected_build_protocol_digest: secure_mesh_pairwise_build_protocol_digest()?,
        expected_policy_revision: SECURE_MESH_PAIRWISE_CAPABILITY_POLICY_REVISION,
        expected_challenge: challenge,
        now_unix_seconds: now.unix_timestamp(),
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPairwiseSessionIntro {
    pub protocol_version: String,
    pub cipher_suite: String,
    pub session_id: String,
    pub initiator_endpoint_id: String,
    pub responder_endpoint_id: String,
    pub initiator_identity_public_key: Vec<u8>,
    pub initiator_ephemeral_public_key: Vec<u8>,
    pub initiator_initial_ratchet_public_key: Vec<u8>,
    pub responder_signed_prekey_id: String,
    pub responder_one_time_prekey_id: Option<String>,
    pub responder_one_time_mlkem1024_prekey_id: String,
    pub mlkem1024_ciphertext: Vec<u8>,
    pub directory_authorization_digest: String,
    pub initiator_capability_proof: SignedCapabilityProof,
    pub initiator_signature: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPairwiseSessionAccepted {
    pub protocol_version: String,
    pub cipher_suite: String,
    pub session_id: String,
    pub responder_endpoint_id: String,
    pub responder_initial_ratchet_public_key: Vec<u8>,
    pub handshake_transcript_hash: String,
    pub responder_capability_proof: SignedCapabilityProof,
    pub capability_binding: NegotiatedCapabilityBinding,
    pub responder_signature: String,
    pub key_confirmation: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPairwiseSessionFinished {
    pub protocol_version: String,
    pub cipher_suite: String,
    pub session_id: String,
    pub initiator_endpoint_id: String,
    pub responder_endpoint_id: String,
    pub handshake_transcript_hash: String,
    pub capability_transcript_digest: String,
    pub key_confirmation: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPairwiseMessage {
    pub protocol_version: String,
    pub cipher_suite: String,
    pub session_id: String,
    pub message_id: String,
    pub sender_endpoint_id: String,
    pub recipient_endpoint_id: String,
    pub dh_epoch: u64,
    pub chain_index: u64,
    pub previous_chain_length: u64,
    pub sender_ratchet_public_key: Vec<u8>,
    pub sparse_pq_header: SecureMeshSparsePqHeader,
    pub encrypted_header: String,
    pub ciphertext: String,
    pub ciphertext_size: usize,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct SecureMeshPairwisePrivateRelayHeader {
    protocol_version: String,
    cipher_suite: String,
    delivery_id: String,
    mailbox_token: String,
    message_id: String,
    session_id: String,
    sender_endpoint_id: String,
    recipient_endpoint_id: String,
    created_at: String,
    expires_at: String,
    dh_epoch: u64,
    chain_index: u64,
    previous_chain_length: u64,
    sender_ratchet_public_key: String,
    sparse_pq_header: SecureMeshSparsePqHeader,
    content_encrypted_header: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpenedPairwiseMessage {
    pub message_id: String,
    pub sender_endpoint_id: String,
    pub body: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecureMeshPairwiseRole {
    Initiator,
    Responder,
}

impl SecureMeshPairwiseRole {
    fn as_str(self) -> &'static str {
        match self {
            Self::Initiator => "initiator",
            Self::Responder => "responder",
        }
    }

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "initiator" => Ok(Self::Initiator),
            "responder" => Ok(Self::Responder),
            _ => Err(anyhow!("secure mesh pairwise role is unsupported")),
        }
    }
}

#[derive(Clone)]
struct SkippedMessageKey {
    message_id: String,
    dh_epoch: u64,
    chain_index: u64,
    sender_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    message_key: Zeroizing<[u8; MESSAGE_KEY_LEN]>,
}

pub struct SecureMeshPairwiseSession {
    pub session_id: String,
    pub local_endpoint_id: String,
    pub remote_endpoint_id: String,
    role: SecureMeshPairwiseRole,
    root_key: Zeroizing<[u8; ROOT_KEY_LEN]>,
    sending_chain_key: Zeroizing<[u8; CHAIN_KEY_LEN]>,
    receiving_chain_key: Zeroizing<[u8; CHAIN_KEY_LEN]>,
    sending_header_key: Zeroizing<[u8; HEADER_KEY_LEN]>,
    receiving_header_key: Zeroizing<[u8; HEADER_KEY_LEN]>,
    next_sending_header_key: Zeroizing<[u8; HEADER_KEY_LEN]>,
    next_receiving_header_key: Zeroizing<[u8; HEADER_KEY_LEN]>,
    skipped_receiving_header_keys: Vec<Zeroizing<[u8; HEADER_KEY_LEN]>>,
    local_ratchet_secret: SecureMeshPairwisePrivateKey,
    local_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    remote_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    handshake_transcript_hash: [u8; HANDSHAKE_HASH_LEN],
    dh_epoch: u64,
    receiving_ratchet_epoch: u64,
    sending_chain_index: u64,
    receiving_chain_index: u64,
    previous_chain_length: u64,
    skipped_keys: Vec<SkippedMessageKey>,
    received_message_ids: Vec<String>,
    pending_sending_ratchet: bool,
    initiator_key_confirmed: bool,
    local_capability_proof: SignedCapabilityProof,
    capability_negotiation: Option<VerifiedSessionNegotiation>,
    sparse_pq_ratchet: SecureMeshSparsePqRatchet,
    revoked: bool,
}

impl SecureMeshPairwiseSession {
    fn try_clone(&self) -> Result<Self> {
        Ok(Self {
            session_id: self.session_id.clone(),
            local_endpoint_id: self.local_endpoint_id.clone(),
            remote_endpoint_id: self.remote_endpoint_id.clone(),
            role: self.role,
            root_key: self.root_key.clone(),
            sending_chain_key: self.sending_chain_key.clone(),
            receiving_chain_key: self.receiving_chain_key.clone(),
            sending_header_key: self.sending_header_key.clone(),
            receiving_header_key: self.receiving_header_key.clone(),
            next_sending_header_key: self.next_sending_header_key.clone(),
            next_receiving_header_key: self.next_receiving_header_key.clone(),
            skipped_receiving_header_keys: self.skipped_receiving_header_keys.clone(),
            local_ratchet_secret: self.local_ratchet_secret.clone(),
            local_ratchet_public_key: self.local_ratchet_public_key,
            remote_ratchet_public_key: self.remote_ratchet_public_key,
            handshake_transcript_hash: self.handshake_transcript_hash,
            dh_epoch: self.dh_epoch,
            receiving_ratchet_epoch: self.receiving_ratchet_epoch,
            sending_chain_index: self.sending_chain_index,
            receiving_chain_index: self.receiving_chain_index,
            previous_chain_length: self.previous_chain_length,
            skipped_keys: self.skipped_keys.clone(),
            received_message_ids: self.received_message_ids.clone(),
            pending_sending_ratchet: self.pending_sending_ratchet,
            initiator_key_confirmed: self.initiator_key_confirmed,
            local_capability_proof: self.local_capability_proof.clone(),
            capability_negotiation: self.capability_negotiation.clone(),
            sparse_pq_ratchet: self.sparse_pq_ratchet.try_clone()?,
            revoked: self.revoked,
        })
    }

    pub fn initiate(
        local_identity: &DeviceTrustPublicIdentity,
        local_identity_secret: &SecureMeshPairwisePrivateKey,
        local_signing_key: &SigningKey,
        remote_bundle: &SecureMeshPairwisePreKeyBundle,
        remote_directory_authorization: &AuthorizedDirectoryLeaf,
        policy: &SecureMeshPreKeyValidationPolicy,
        capability_evaluation: &CapabilityEvaluation,
        now: OffsetDateTime,
    ) -> Result<(Self, SecureMeshPairwiseSessionIntro)> {
        validate_endpoint_id(&local_identity.endpoint_id)?;
        ensure_local_identity_key_material(
            local_identity,
            local_identity_secret,
            local_signing_key,
        )?;
        let validation = validate_pairwise_prekey_bundle(
            remote_bundle,
            remote_directory_authorization,
            policy,
            now,
        )?;
        let local_ephemeral = SecureMeshPairwisePrivateKey::generate();
        let local_ratchet_secret = SecureMeshPairwisePrivateKey::generate();
        let classical_secret = derive_pqxdh_classical_initiator_secret(
            local_identity,
            local_identity_secret,
            &local_ephemeral,
            remote_bundle,
        )?;
        let mlkem1024 =
            encapsulate_ml_kem_1024(&remote_bundle.one_time_mlkem1024_prekey.public_key)?;
        let session_id = derive_session_id(
            local_identity,
            &remote_bundle.endpoint_identity,
            &local_ephemeral.public_key(),
            &validation.signed_prekey_id,
            &remote_bundle.signed_prekey.public_key,
            validation.one_time_prekey_id.as_deref(),
            remote_bundle
                .one_time_prekey
                .as_ref()
                .map(|record| record.public_key.as_slice()),
            &validation.one_time_mlkem1024_prekey_id,
            &remote_bundle.one_time_mlkem1024_prekey.public_key,
            &mlkem1024.ciphertext,
            &validation.directory_authorization_digest,
        )?;
        let triple_ratchet_secrets = derive_triple_ratchet_initial_secrets(
            classical_secret.as_slice(),
            mlkem1024.shared_secret(),
            &local_identity.identity_public_key,
            &remote_bundle.endpoint_identity.identity_public_key,
            session_id.as_bytes(),
        )?;
        let keys = derive_initial_keys(
            triple_ratchet_secrets.ec_secret(),
            &session_id,
            &local_identity.endpoint_id,
            &remote_bundle.endpoint_identity.endpoint_id,
        )?;
        let sparse_pq_ratchet =
            SecureMeshSparsePqRatchet::new_initiator(triple_ratchet_secrets.scka_secret())?;
        let local_ratchet_public_key = local_ratchet_secret.public_key();
        let mut capability_challenge = [0u8; 32];
        OsRng.fill_bytes(&mut capability_challenge);
        let local_capability_proof = sign_capability_proof(
            local_identity,
            local_signing_key,
            capability_evaluation,
            &capability_proof_request(capability_challenge, now)?,
        )?;
        let mut intro = SecureMeshPairwiseSessionIntro {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: session_id.clone(),
            initiator_endpoint_id: local_identity.endpoint_id.clone(),
            responder_endpoint_id: remote_bundle.endpoint_identity.endpoint_id.clone(),
            initiator_identity_public_key: local_identity.identity_public_key.to_vec(),
            initiator_ephemeral_public_key: local_ephemeral.public_key().to_vec(),
            initiator_initial_ratchet_public_key: local_ratchet_public_key.to_vec(),
            responder_signed_prekey_id: validation.signed_prekey_id,
            responder_one_time_prekey_id: validation.one_time_prekey_id,
            responder_one_time_mlkem1024_prekey_id: validation.one_time_mlkem1024_prekey_id,
            mlkem1024_ciphertext: mlkem1024.ciphertext,
            directory_authorization_digest: validation.directory_authorization_digest,
            initiator_capability_proof: local_capability_proof.clone(),
            initiator_signature: String::new(),
        };
        intro.initiator_signature =
            sign_pairwise_transcript(local_signing_key, &intro_signature_payload(&intro)?);
        let handshake_transcript_hash = handshake_transcript_hash(&intro)?;
        let session = Self {
            session_id: session_id.clone(),
            local_endpoint_id: local_identity.endpoint_id.clone(),
            remote_endpoint_id: remote_bundle.endpoint_identity.endpoint_id.clone(),
            role: SecureMeshPairwiseRole::Initiator,
            root_key: Zeroizing::new(keys.root_key),
            sending_chain_key: Zeroizing::new(keys.initiator_chain_key),
            receiving_chain_key: Zeroizing::new(keys.responder_chain_key),
            sending_header_key: Zeroizing::new(keys.initiator_header_key),
            receiving_header_key: Zeroizing::new(keys.responder_header_key),
            next_sending_header_key: Zeroizing::new(keys.initiator_next_header_key),
            next_receiving_header_key: Zeroizing::new(keys.responder_next_header_key),
            skipped_receiving_header_keys: Vec::new(),
            local_ratchet_secret,
            local_ratchet_public_key,
            remote_ratchet_public_key: [0u8; PUBLIC_KEY_LEN],
            handshake_transcript_hash,
            dh_epoch: 0,
            receiving_ratchet_epoch: 0,
            sending_chain_index: 0,
            receiving_chain_index: 0,
            previous_chain_length: 0,
            skipped_keys: Vec::new(),
            received_message_ids: Vec::new(),
            pending_sending_ratchet: false,
            initiator_key_confirmed: false,
            local_capability_proof,
            capability_negotiation: None,
            sparse_pq_ratchet,
            revoked: false,
        };
        Ok((session, intro))
    }

    pub fn accept(
        local_identity: &DeviceTrustPublicIdentity,
        local_identity_secret: &SecureMeshPairwisePrivateKey,
        local_signing_key: &SigningKey,
        expected_initiator_identity: &DeviceTrustPublicIdentity,
        local_signed_prekey_secret: &SecureMeshPairwisePrivateKey,
        local_one_time_prekey_secret: Option<&SecureMeshPairwisePrivateKey>,
        local_one_time_mlkem1024_prekey_seed: &SecureMeshMlKem1024PreKeySeed,
        intro: &SecureMeshPairwiseSessionIntro,
        capability_evaluation: &CapabilityEvaluation,
        now: OffsetDateTime,
        capability_replay_guard: &mut CapabilityProofReplayGuard,
    ) -> Result<(Self, SecureMeshPairwiseSessionAccepted)> {
        ensure_intro(intro)?;
        ensure_local_identity_key_material(
            local_identity,
            local_identity_secret,
            local_signing_key,
        )?;
        ensure!(
            intro.responder_endpoint_id == local_identity.endpoint_id,
            "secure mesh pairwise intro responder mismatch"
        );
        ensure!(
            intro.initiator_endpoint_id == expected_initiator_identity.endpoint_id
                && intro.initiator_identity_public_key
                    == expected_initiator_identity.identity_public_key,
            "secure mesh pairwise intro initiator identity mismatch"
        );
        verify_pairwise_transcript_signature(
            expected_initiator_identity,
            &intro_signature_payload(intro)?,
            &intro.initiator_signature,
            "intro",
        )?;
        let local_one_time_prekey_public_key =
            local_one_time_prekey_secret.map(SecureMeshPairwisePrivateKey::public_key);
        let local_one_time_mlkem1024_prekey_public_key =
            local_one_time_mlkem1024_prekey_seed.public_key();
        let expected_session_id = derive_session_id(
            expected_initiator_identity,
            local_identity,
            &intro.initiator_ephemeral_public_key,
            &intro.responder_signed_prekey_id,
            &local_signed_prekey_secret.public_key(),
            intro.responder_one_time_prekey_id.as_deref(),
            local_one_time_prekey_public_key
                .as_ref()
                .map(|public_key| public_key.as_slice()),
            &intro.responder_one_time_mlkem1024_prekey_id,
            &local_one_time_mlkem1024_prekey_public_key,
            &intro.mlkem1024_ciphertext,
            &intro.directory_authorization_digest,
        )?;
        ensure!(
            intro.session_id == expected_session_id,
            "secure mesh pairwise intro session transcript mismatch"
        );
        let classical_secret = derive_pqxdh_classical_responder_secret(
            local_identity_secret,
            local_signed_prekey_secret,
            local_one_time_prekey_secret,
            intro,
        )?;
        let mlkem1024_shared_secret = decapsulate_ml_kem_1024(
            local_one_time_mlkem1024_prekey_seed,
            &local_one_time_mlkem1024_prekey_public_key,
            &intro.mlkem1024_ciphertext,
        )?;
        let triple_ratchet_secrets = derive_triple_ratchet_initial_secrets(
            classical_secret.as_slice(),
            &mlkem1024_shared_secret,
            &expected_initiator_identity.identity_public_key,
            &local_identity.identity_public_key,
            intro.session_id.as_bytes(),
        )?;
        let initial_keys = derive_initial_keys(
            triple_ratchet_secrets.ec_secret(),
            &intro.session_id,
            &intro.initiator_endpoint_id,
            &intro.responder_endpoint_id,
        )?;
        let sparse_pq_ratchet =
            SecureMeshSparsePqRatchet::new_responder(triple_ratchet_secrets.scka_secret())?;
        let local_ratchet_secret = SecureMeshPairwisePrivateKey::generate();
        let local_ratchet_public_key = local_ratchet_secret.public_key();
        let remote_ratchet_public_key = parse_key_bytes(
            &intro.initiator_initial_ratchet_public_key,
            "initiator ratchet public key",
        )?;
        let handshake_transcript_hash = handshake_transcript_hash(intro)?;
        let capability_challenge =
            signed_capability_proof_challenge(&intro.initiator_capability_proof)?;
        let local_capability_proof = sign_capability_proof(
            local_identity,
            local_signing_key,
            capability_evaluation,
            &capability_proof_request(capability_challenge, now)?,
        )?;
        let verification_context = capability_verification_context(capability_challenge, now)?;
        let initiator_verified =
            crate::core::secure_mesh_capability_proof::verify_capability_proof(
                expected_initiator_identity,
                &intro.initiator_capability_proof,
                &verification_context,
            )?;
        let responder_verified =
            crate::core::secure_mesh_capability_proof::verify_capability_proof(
                local_identity,
                &local_capability_proof,
                &verification_context,
            )?;
        let base_transcript_digest =
            crate::core::secure_mesh_capability_proof::encode_sha256_digest(
                &handshake_transcript_hash,
            );
        let capability_binding = create_pairwise_capability_binding(
            &initiator_verified,
            &responder_verified,
            &base_transcript_digest,
        )?;
        let capability_negotiation = accept_pairwise_capability_binding(
            CapabilityProofPeer {
                identity: local_identity,
                proof: &local_capability_proof,
                verification_context: &verification_context,
            },
            CapabilityProofPeer {
                identity: expected_initiator_identity,
                proof: &intro.initiator_capability_proof,
                verification_context: &verification_context,
            },
            &base_transcript_digest,
            &capability_binding,
            capability_replay_guard,
        )?;
        let keys = derive_capability_bound_initial_keys(
            &initial_keys.root_key,
            &capability_binding.transcript_digest,
            &intro.session_id,
            &intro.initiator_endpoint_id,
            &intro.responder_endpoint_id,
        )?;
        let mut accepted = SecureMeshPairwiseSessionAccepted {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: intro.session_id.clone(),
            responder_endpoint_id: local_identity.endpoint_id.clone(),
            responder_initial_ratchet_public_key: local_ratchet_public_key.to_vec(),
            handshake_transcript_hash: general_purpose::URL_SAFE_NO_PAD
                .encode(handshake_transcript_hash),
            responder_capability_proof: local_capability_proof.clone(),
            capability_binding,
            responder_signature: String::new(),
            key_confirmation: String::new(),
        };
        accepted.responder_signature =
            sign_pairwise_transcript(local_signing_key, &accept_signature_payload(&accepted)?);
        accepted.key_confirmation = pairwise_key_confirmation(&keys.root_key, &accepted)?;
        let session = Self {
            session_id: intro.session_id.clone(),
            local_endpoint_id: local_identity.endpoint_id.clone(),
            remote_endpoint_id: intro.initiator_endpoint_id.clone(),
            role: SecureMeshPairwiseRole::Responder,
            root_key: Zeroizing::new(keys.root_key),
            sending_chain_key: Zeroizing::new(keys.responder_chain_key),
            receiving_chain_key: Zeroizing::new(keys.initiator_chain_key),
            sending_header_key: Zeroizing::new(keys.responder_header_key),
            receiving_header_key: Zeroizing::new(keys.initiator_header_key),
            next_sending_header_key: Zeroizing::new(keys.responder_next_header_key),
            next_receiving_header_key: Zeroizing::new(keys.initiator_next_header_key),
            skipped_receiving_header_keys: Vec::new(),
            local_ratchet_secret,
            local_ratchet_public_key,
            remote_ratchet_public_key,
            handshake_transcript_hash,
            dh_epoch: 0,
            receiving_ratchet_epoch: 0,
            sending_chain_index: 0,
            receiving_chain_index: 0,
            previous_chain_length: 0,
            skipped_keys: Vec::new(),
            received_message_ids: Vec::new(),
            pending_sending_ratchet: false,
            initiator_key_confirmed: false,
            local_capability_proof,
            capability_negotiation: Some(capability_negotiation),
            sparse_pq_ratchet,
            revoked: false,
        };
        Ok((session, accepted))
    }

    pub fn complete_initiator_handshake(
        &mut self,
        local_identity: &DeviceTrustPublicIdentity,
        expected_responder_identity: &DeviceTrustPublicIdentity,
        accepted: &SecureMeshPairwiseSessionAccepted,
        now: OffsetDateTime,
        capability_replay_guard: &mut CapabilityProofReplayGuard,
    ) -> Result<SecureMeshPairwiseSessionFinished> {
        ensure!(
            self.role == SecureMeshPairwiseRole::Initiator,
            "secure mesh pairwise accept can only complete an initiator session"
        );
        ensure!(
            accepted.protocol_version == SECURE_MESH_PROTOCOL_VERSION
                && accepted.cipher_suite == SECURE_MESH_PAIRWISE_CIPHER_SUITE,
            "secure mesh pairwise accept protocol is unsupported"
        );
        ensure!(
            accepted.session_id == self.session_id
                && accepted.responder_endpoint_id == self.remote_endpoint_id
                && local_identity.endpoint_id == self.local_endpoint_id
                && expected_responder_identity.endpoint_id == self.remote_endpoint_id,
            "secure mesh pairwise accept subject mismatch"
        );
        ensure!(
            self.capability_negotiation.is_none(),
            "secure mesh pairwise capability negotiation is already complete"
        );
        let accepted_handshake_hash = decode_fixed_base64url::<HANDSHAKE_HASH_LEN>(
            &accepted.handshake_transcript_hash,
            "accept handshake transcript hash",
        )?;
        ensure!(
            accepted_handshake_hash == self.handshake_transcript_hash,
            "secure mesh pairwise accept handshake transcript mismatch"
        );
        verify_pairwise_transcript_signature(
            expected_responder_identity,
            &accept_signature_payload(accepted)?,
            &accepted.responder_signature,
            "accept",
        )?;
        let remote_ratchet_public_key = parse_key_bytes(
            &accepted.responder_initial_ratchet_public_key,
            "responder ratchet public key",
        )?;
        ensure!(
            remote_ratchet_public_key != [0u8; PUBLIC_KEY_LEN],
            "secure mesh pairwise responder ratchet public key is invalid"
        );
        let capability_challenge = signed_capability_proof_challenge(&self.local_capability_proof)?;
        let verification_context = capability_verification_context(capability_challenge, now)?;
        let base_transcript_digest =
            crate::core::secure_mesh_capability_proof::encode_sha256_digest(
                &self.handshake_transcript_hash,
            );
        let mut verification_guard = CapabilityProofReplayGuard::default();
        let verified_without_consumption = accept_pairwise_capability_binding(
            CapabilityProofPeer {
                identity: local_identity,
                proof: &self.local_capability_proof,
                verification_context: &verification_context,
            },
            CapabilityProofPeer {
                identity: expected_responder_identity,
                proof: &accepted.responder_capability_proof,
                verification_context: &verification_context,
            },
            &base_transcript_digest,
            &accepted.capability_binding,
            &mut verification_guard,
        )?;
        let bound_keys = derive_capability_bound_initial_keys(
            &self.root_key,
            &verified_without_consumption.binding().transcript_digest,
            &self.session_id,
            &self.local_endpoint_id,
            &self.remote_endpoint_id,
        )?;
        verify_pairwise_key_confirmation(&bound_keys.root_key, accepted)?;
        let capability_negotiation = accept_pairwise_capability_binding(
            CapabilityProofPeer {
                identity: local_identity,
                proof: &self.local_capability_proof,
                verification_context: &verification_context,
            },
            CapabilityProofPeer {
                identity: expected_responder_identity,
                proof: &accepted.responder_capability_proof,
                verification_context: &verification_context,
            },
            &base_transcript_digest,
            &accepted.capability_binding,
            capability_replay_guard,
        )?;
        *self.root_key = bound_keys.root_key;
        *self.sending_chain_key = bound_keys.initiator_chain_key;
        *self.receiving_chain_key = bound_keys.responder_chain_key;
        *self.sending_header_key = bound_keys.initiator_header_key;
        *self.receiving_header_key = bound_keys.responder_header_key;
        *self.next_sending_header_key = bound_keys.initiator_next_header_key;
        *self.next_receiving_header_key = bound_keys.responder_next_header_key;
        self.remote_ratchet_public_key = remote_ratchet_public_key;
        self.capability_negotiation = Some(capability_negotiation);
        self.initiator_key_confirmed = true;
        // The first protected message performs a fresh DH step for post-compromise recovery.
        // Initiator authentication itself is explicit and cannot be inferred from app data.
        self.pending_sending_ratchet = true;
        let mut finished = SecureMeshPairwiseSessionFinished {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: self.session_id.clone(),
            initiator_endpoint_id: self.local_endpoint_id.clone(),
            responder_endpoint_id: self.remote_endpoint_id.clone(),
            handshake_transcript_hash: accepted.handshake_transcript_hash.clone(),
            capability_transcript_digest: accepted.capability_binding.transcript_digest.clone(),
            key_confirmation: String::new(),
        };
        finished.key_confirmation = initiator_finished_key_confirmation(&self.root_key, &finished)?;
        Ok(finished)
    }

    pub fn complete_responder_handshake(
        &mut self,
        finished: &SecureMeshPairwiseSessionFinished,
    ) -> Result<()> {
        ensure!(
            self.role == SecureMeshPairwiseRole::Responder,
            "secure mesh pairwise finished can only complete a responder session"
        );
        ensure!(
            !self.initiator_key_confirmed,
            "secure mesh pairwise initiator finished is already complete"
        );
        ensure!(
            finished.protocol_version == SECURE_MESH_PROTOCOL_VERSION
                && finished.cipher_suite == SECURE_MESH_PAIRWISE_CIPHER_SUITE,
            "secure mesh pairwise finished protocol is unsupported"
        );
        ensure!(
            finished.session_id == self.session_id
                && finished.initiator_endpoint_id == self.remote_endpoint_id
                && finished.responder_endpoint_id == self.local_endpoint_id,
            "secure mesh pairwise finished subject mismatch"
        );
        ensure!(
            decode_fixed_base64url::<HANDSHAKE_HASH_LEN>(
                &finished.handshake_transcript_hash,
                "finished handshake transcript hash",
            )? == self.handshake_transcript_hash,
            "secure mesh pairwise finished handshake transcript mismatch"
        );
        let binding = self
            .capability_binding()
            .ok_or_else(|| anyhow!("secure mesh pairwise capability negotiation is incomplete"))?;
        ensure!(
            finished.capability_transcript_digest == binding.transcript_digest,
            "secure mesh pairwise finished capability transcript mismatch"
        );
        verify_initiator_finished_key_confirmation(&self.root_key, finished)?;
        self.initiator_key_confirmed = true;
        Ok(())
    }

    pub fn capability_projection(&self) -> Option<&ClientCapabilityProjection> {
        self.capability_negotiation
            .as_ref()
            .map(VerifiedSessionNegotiation::projection)
    }

    pub fn capability_binding(&self) -> Option<&NegotiatedCapabilityBinding> {
        self.capability_negotiation
            .as_ref()
            .map(VerifiedSessionNegotiation::binding)
    }

    pub(crate) fn local_capability_proof(&self) -> &SignedCapabilityProof {
        &self.local_capability_proof
    }

    pub fn handshake_confirmed(&self) -> bool {
        self.initiator_key_confirmed && self.capability_negotiation.is_some() && !self.revoked
    }

    fn require_capability_negotiation(&self) -> Result<()> {
        ensure!(
            self.capability_negotiation.is_some(),
            "secure mesh pairwise capability negotiation is incomplete"
        );
        Ok(())
    }

    pub fn seal_message(
        &mut self,
        message_id: impl Into<String>,
        body: impl AsRef<[u8]>,
    ) -> Result<SecureMeshPairwiseMessage> {
        let mut nonce = [0u8; NONCE_LEN];
        OsRng.fill_bytes(&mut nonce);
        self.seal_message_with_nonce(message_id, body, nonce)
    }

    fn seal_message_with_nonce(
        &mut self,
        message_id: impl Into<String>,
        body: impl AsRef<[u8]>,
        nonce: [u8; NONCE_LEN],
    ) -> Result<SecureMeshPairwiseMessage> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        self.require_capability_negotiation()?;
        ensure!(
            self.initiator_key_confirmed,
            "secure mesh pairwise handshake key confirmation is incomplete"
        );
        let message_id = require_text(message_id.into(), "message id")?;
        validate_message_id(&message_id)?;
        let body = body.as_ref();
        ensure!(
            body.len() <= MAX_CIPHERTEXT_BYTES,
            "secure mesh pairwise message body is too large"
        );
        let mut candidate = self.try_clone()?;
        candidate.prepare_sending_ratchet_for_send()?;
        let chain_index = candidate.sending_chain_index;
        let (next_chain_key, classical_message_key) = advance_chain(
            &candidate.sending_chain_key,
            candidate.dh_epoch,
            chain_index,
            "message",
        )?;
        let sparse_pq = candidate.sparse_pq_ratchet.send_key()?;
        let message_key = derive_hybrid_message_key(
            &classical_message_key,
            &sparse_pq.message_key,
            candidate.session_id.as_bytes(),
        )?;
        let mut message = SecureMeshPairwiseMessage {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: candidate.session_id.clone(),
            message_id,
            sender_endpoint_id: candidate.local_endpoint_id.clone(),
            recipient_endpoint_id: candidate.remote_endpoint_id.clone(),
            dh_epoch: candidate.dh_epoch,
            chain_index,
            previous_chain_length: candidate.previous_chain_length,
            sender_ratchet_public_key: candidate.local_ratchet_public_key.to_vec(),
            sparse_pq_header: sparse_pq.header,
            encrypted_header: general_purpose::URL_SAFE_NO_PAD.encode(nonce),
            ciphertext: String::new(),
            ciphertext_size: 0,
        };
        let aad = message_aad(&message)?;
        let cipher = ChaCha20Poly1305::new(Key::from_slice(message_key.as_ref()));
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                AeadPayload {
                    msg: body,
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow!("secure mesh pairwise message encryption failed"))?;
        message.ciphertext_size = ciphertext.len();
        message.ciphertext = general_purpose::URL_SAFE_NO_PAD.encode(ciphertext);
        *candidate.sending_chain_key = *next_chain_key;
        candidate.sending_chain_index += 1;
        *self = candidate;
        Ok(message)
    }

    pub fn open_message(
        &mut self,
        message: &SecureMeshPairwiseMessage,
    ) -> Result<OpenedPairwiseMessage> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        self.require_capability_negotiation()?;
        ensure!(
            self.initiator_key_confirmed,
            "secure mesh pairwise handshake key confirmation is incomplete"
        );
        ensure_message_for_session(self, message)?;
        let replay_fingerprint = message_replay_fingerprint(message)?;
        ensure!(
            !self
                .received_message_ids
                .iter()
                .any(|id| id == &replay_fingerprint),
            "secure mesh pairwise message replay detected"
        );
        let aad = message_aad(message)?;
        let ciphertext = general_purpose::URL_SAFE_NO_PAD
            .decode(&message.ciphertext)
            .context("secure mesh pairwise ciphertext is not base64url")?;
        ensure!(
            ciphertext.len() == message.ciphertext_size,
            "secure mesh pairwise ciphertext size mismatch"
        );
        let nonce_bytes = general_purpose::URL_SAFE_NO_PAD
            .decode(&message.encrypted_header)
            .context("secure mesh pairwise encrypted header is not base64url")?;
        ensure!(
            nonce_bytes.len() == NONCE_LEN,
            "secure mesh pairwise nonce length is invalid"
        );
        let mut nonce = [0u8; NONCE_LEN];
        nonce.copy_from_slice(&nonce_bytes);

        let mut candidate = self.try_clone()?;
        let classical_message_key = candidate.message_key_for_open(message)?;
        let post_quantum_message_key = candidate
            .sparse_pq_ratchet
            .receive_key(&message.sparse_pq_header)?;
        let message_key = derive_hybrid_message_key(
            &classical_message_key,
            &post_quantum_message_key,
            candidate.session_id.as_bytes(),
        )?;
        let cipher = ChaCha20Poly1305::new(Key::from_slice(message_key.as_ref()));
        let plaintext = cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                AeadPayload {
                    msg: &ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow!("secure mesh pairwise message authentication failed"))?;
        candidate.record_received_message_id(replay_fingerprint);
        *self = candidate;
        Ok(OpenedPairwiseMessage {
            message_id: message.message_id.clone(),
            sender_endpoint_id: message.sender_endpoint_id.clone(),
            body: plaintext,
        })
    }

    pub fn seal_payload(
        &mut self,
        context: &SecureMeshContentContext,
        plaintext: &SecureMeshPlaintext,
    ) -> Result<SecureMeshPairwiseMessage> {
        self.seal_payload_with_extra_aad(context, plaintext, &[])
    }

    pub fn seal_payload_with_extra_aad(
        &mut self,
        context: &SecureMeshContentContext,
        plaintext: &SecureMeshPlaintext,
        extra_aad: &[u8],
    ) -> Result<SecureMeshPairwiseMessage> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        self.require_capability_negotiation()?;
        ensure!(
            self.initiator_key_confirmed,
            "secure mesh pairwise handshake key confirmation is incomplete"
        );
        ensure_pairwise_context_for_send(self, context)?;
        let mut candidate = self.try_clone()?;
        candidate.prepare_sending_ratchet_for_send()?;
        let chain_index = candidate.sending_chain_index;
        let (next_chain_key, classical_message_key) = advance_chain(
            &candidate.sending_chain_key,
            candidate.dh_epoch,
            chain_index,
            "message",
        )?;
        let sparse_pq = candidate.sparse_pq_ratchet.send_key()?;
        let message_key = derive_hybrid_message_key(
            &classical_message_key,
            &sparse_pq.message_key,
            candidate.session_id.as_bytes(),
        )?;
        let content_key = ContentKey::from_bytes(*message_key);
        let mut message = SecureMeshPairwiseMessage {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: candidate.session_id.clone(),
            message_id: context.message_id.clone(),
            sender_endpoint_id: candidate.local_endpoint_id.clone(),
            recipient_endpoint_id: candidate.remote_endpoint_id.clone(),
            dh_epoch: candidate.dh_epoch,
            chain_index,
            previous_chain_length: candidate.previous_chain_length,
            sender_ratchet_public_key: candidate.local_ratchet_public_key.to_vec(),
            sparse_pq_header: sparse_pq.header,
            encrypted_header: String::new(),
            ciphertext: String::new(),
            ciphertext_size: 0,
        };
        let combined_aad = combine_pairwise_and_extra_aad(&message, extra_aad)?;
        let sealed = crate::core::secure_mesh_crypto::seal_payload_with_aad_binding(
            &content_key,
            context,
            plaintext,
            &combined_aad,
        )?;
        message.encrypted_header = sealed.encrypted_header;
        message.ciphertext = sealed.ciphertext;
        message.ciphertext_size = sealed.ciphertext_size;
        *candidate.sending_chain_key = *next_chain_key;
        candidate.sending_chain_index += 1;
        *self = candidate;
        Ok(message)
    }

    pub fn seal_payload_envelope(
        &mut self,
        context: &SecureMeshContentContext,
        plaintext: &SecureMeshPlaintext,
    ) -> Result<SecureMeshRelayEnvelope> {
        self.seal_payload_envelope_with_extra_aad(context, plaintext, &[])
    }

    pub fn seal_payload_envelope_with_extra_aad(
        &mut self,
        context: &SecureMeshContentContext,
        plaintext: &SecureMeshPlaintext,
        extra_aad: &[u8],
    ) -> Result<SecureMeshRelayEnvelope> {
        let rollback = self.try_clone()?;
        let result = (|| {
            let message = self.seal_payload_with_extra_aad(context, plaintext, extra_aad)?;
            relay_envelope_from_pairwise_message(self, context, &message)
        })();
        if result.is_err() {
            *self = rollback;
        }
        result
    }

    pub fn open_payload(
        &mut self,
        context: &SecureMeshContentContext,
        message: &SecureMeshPairwiseMessage,
        expected_kind: SecureMeshPayloadKind,
    ) -> Result<OpenedSecureMeshPayload> {
        self.open_payload_with_extra_aad(context, message, expected_kind, &[])
    }

    pub fn open_payload_with_extra_aad(
        &mut self,
        context: &SecureMeshContentContext,
        message: &SecureMeshPairwiseMessage,
        expected_kind: SecureMeshPayloadKind,
        extra_aad: &[u8],
    ) -> Result<OpenedSecureMeshPayload> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        self.require_capability_negotiation()?;
        ensure!(
            self.initiator_key_confirmed,
            "secure mesh pairwise handshake key confirmation is incomplete"
        );
        ensure_message_for_session(self, message)?;
        ensure_pairwise_context_for_open(self, context, message)?;
        let replay_fingerprint = message_replay_fingerprint(message)?;
        ensure!(
            !self
                .received_message_ids
                .iter()
                .any(|id| id == &replay_fingerprint),
            "secure mesh pairwise message replay detected"
        );
        let mut candidate = self.try_clone()?;
        let classical_message_key = candidate.message_key_for_open(message)?;
        let post_quantum_message_key = candidate
            .sparse_pq_ratchet
            .receive_key(&message.sparse_pq_header)?;
        let message_key = derive_hybrid_message_key(
            &classical_message_key,
            &post_quantum_message_key,
            candidate.session_id.as_bytes(),
        )?;
        let content_key = ContentKey::from_bytes(*message_key);
        let combined_aad = combine_pairwise_and_extra_aad(message, extra_aad)?;
        let sealed = SealedSecureMeshPayload {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_CONTENT_CIPHER_SUITE.to_string(),
            encrypted_header: message.encrypted_header.clone(),
            ciphertext: message.ciphertext.clone(),
            ciphertext_size: message.ciphertext_size,
        };
        let opened = crate::core::secure_mesh_crypto::open_payload_with_aad_binding(
            &content_key,
            context,
            &sealed,
            expected_kind,
            &combined_aad,
        )?;
        candidate.record_received_message_id(replay_fingerprint);
        *self = candidate;
        Ok(opened)
    }

    pub fn open_payload_envelope(
        &mut self,
        envelope: &SecureMeshRelayEnvelope,
        expected_kind: SecureMeshPayloadKind,
    ) -> Result<OpenedSecureMeshPayload> {
        self.open_payload_envelope_with_extra_aad(envelope, expected_kind, &[])
    }

    pub fn open_payload_envelope_with_extra_aad(
        &mut self,
        envelope: &SecureMeshRelayEnvelope,
        expected_kind: SecureMeshPayloadKind,
        extra_aad: &[u8],
    ) -> Result<OpenedSecureMeshPayload> {
        // Reject revoked sessions before attempting header-key selection. This
        // keeps the public failure semantic stable and avoids doing any
        // attacker-controlled envelope work after local revocation.
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        let (context, message) = pairwise_message_from_relay_envelope(self, envelope)?;
        self.open_payload_with_extra_aad(&context, &message, expected_kind, extra_aad)
    }

    pub fn pending_sending_ratchet(&self) -> bool {
        self.pending_sending_ratchet
    }

    pub fn rotate_sending_ratchet(&mut self) -> Result<()> {
        ensure!(
            self.pending_sending_ratchet,
            "secure mesh pairwise sending ratchet requires an authenticated remote ratchet"
        );
        self.rotate_sending_ratchet_with_secret(SecureMeshPairwisePrivateKey::generate())
    }

    fn prepare_sending_ratchet_for_send(&mut self) -> Result<()> {
        if self.pending_sending_ratchet {
            self.rotate_sending_ratchet()?;
        }
        Ok(())
    }

    fn rotate_sending_ratchet_with_secret(
        &mut self,
        next_ratchet_secret: SecureMeshPairwisePrivateKey,
    ) -> Result<()> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        self.require_capability_negotiation()?;
        ensure!(
            self.initiator_key_confirmed,
            "secure mesh pairwise handshake key confirmation is incomplete"
        );
        ensure!(
            self.remote_ratchet_public_key != [0u8; PUBLIC_KEY_LEN],
            "secure mesh pairwise remote ratchet public key is unavailable"
        );
        self.previous_chain_length = self.sending_chain_index;
        self.local_ratchet_secret = next_ratchet_secret;
        self.local_ratchet_public_key = self.local_ratchet_secret.public_key();
        let dh_secret = self
            .local_ratchet_secret
            .diffie_hellman(&self.remote_ratchet_public_key)?;
        let (root_key, chain_key, next_header_key) =
            derive_ratchet_root(&self.root_key, &dh_secret, self.dh_epoch + 1)?;
        *self.root_key = root_key;
        *self.sending_chain_key = chain_key;
        *self.sending_header_key = *self.next_sending_header_key;
        *self.next_sending_header_key = next_header_key;
        self.dh_epoch += 1;
        self.sending_chain_index = 0;
        self.pending_sending_ratchet = false;
        Ok(())
    }

    pub fn revoke(&mut self) {
        self.revoked = true;
        self.root_key.zeroize();
        self.sending_chain_key.zeroize();
        self.receiving_chain_key.zeroize();
        self.sending_header_key.zeroize();
        self.receiving_header_key.zeroize();
        self.next_sending_header_key.zeroize();
        self.next_receiving_header_key.zeroize();
        for header_key in &mut self.skipped_receiving_header_keys {
            header_key.zeroize();
        }
        self.skipped_receiving_header_keys.clear();
        for skipped in &mut self.skipped_keys {
            skipped.message_key.zeroize();
        }
        self.skipped_keys.clear();
        self.local_ratchet_secret.destroy();
        self.sparse_pq_ratchet.destroy();
        self.pending_sending_ratchet = false;
        self.initiator_key_confirmed = false;
        self.capability_negotiation = None;
    }

    pub fn sent_count(&self) -> u64 {
        self.sending_chain_index
    }

    pub fn received_count(&self) -> u64 {
        self.receiving_chain_index
    }

    pub fn skipped_key_count(&self) -> usize {
        self.skipped_keys.len()
    }

    pub fn dh_epoch(&self) -> u64 {
        self.dh_epoch
    }

    fn store_skipped_message_keys_until(
        &mut self,
        dh_epoch: u64,
        sender_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
        previous_chain_length: u64,
    ) -> Result<()> {
        ensure!(
            previous_chain_length >= self.receiving_chain_index,
            "secure mesh pairwise previous chain length regressed"
        );
        let missing = previous_chain_length - self.receiving_chain_index;
        ensure!(
            missing as usize <= MAX_SKIPPED_KEYS.saturating_sub(self.skipped_keys.len()),
            "secure mesh pairwise skipped-key limit exceeded before ratchet"
        );
        while self.receiving_chain_index < previous_chain_length {
            let skipped_index = self.receiving_chain_index;
            let skipped_id = format!("{}:{}:{}", self.session_id, dh_epoch, skipped_index);
            let (next_chain_key, message_key) = advance_chain(
                &self.receiving_chain_key,
                dh_epoch,
                skipped_index,
                "message",
            )?;
            *self.receiving_chain_key = *next_chain_key;
            self.receiving_chain_index += 1;
            self.push_skipped_message_key(SkippedMessageKey {
                message_id: skipped_id,
                dh_epoch,
                chain_index: skipped_index,
                sender_ratchet_public_key,
                message_key,
            });
        }
        Ok(())
    }

    fn advance_receiving_chain_to(
        &mut self,
        message: &SecureMeshPairwiseMessage,
        sender_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    ) -> Result<Zeroizing<[u8; MESSAGE_KEY_LEN]>> {
        if sender_ratchet_public_key != self.remote_ratchet_public_key {
            ensure!(
                self.dh_epoch.checked_add(1) == Some(message.dh_epoch),
                "secure mesh pairwise ratchet epoch must advance exactly once"
            );
            self.store_skipped_message_keys_until(
                self.receiving_ratchet_epoch,
                self.remote_ratchet_public_key,
                message.previous_chain_length,
            )?;
            let dh_secret = self
                .local_ratchet_secret
                .diffie_hellman(&sender_ratchet_public_key)?;
            let (root_key, chain_key, next_header_key) =
                derive_ratchet_root(&self.root_key, &dh_secret, message.dh_epoch)?;
            *self.root_key = root_key;
            *self.receiving_chain_key = chain_key;
            self.skipped_receiving_header_keys
                .push(self.receiving_header_key.clone());
            while self.skipped_receiving_header_keys.len() > MAX_SKIPPED_KEYS {
                let mut evicted = self.skipped_receiving_header_keys.remove(0);
                evicted.zeroize();
            }
            *self.receiving_header_key = *self.next_receiving_header_key;
            *self.next_receiving_header_key = next_header_key;
            self.remote_ratchet_public_key = sender_ratchet_public_key;
            self.dh_epoch = message.dh_epoch;
            self.receiving_ratchet_epoch = message.dh_epoch;
            self.receiving_chain_index = 0;
            self.pending_sending_ratchet = true;
        } else {
            ensure!(
                message.dh_epoch == self.receiving_ratchet_epoch,
                "secure mesh pairwise message epoch mismatch"
            );
        }
        ensure!(
            message.chain_index >= self.receiving_chain_index,
            "secure mesh pairwise stale chain index"
        );
        let missing = message.chain_index - self.receiving_chain_index;
        ensure!(
            usize::try_from(missing).is_ok_and(|missing| {
                missing <= MAX_SKIPPED_KEYS.saturating_sub(self.skipped_keys.len())
            }),
            "secure mesh pairwise skipped-key limit exceeded"
        );
        while self.receiving_chain_index < message.chain_index {
            let skipped_index = self.receiving_chain_index;
            let skipped_id = format!("{}:{}:{}", self.session_id, message.dh_epoch, skipped_index);
            let (next_chain_key, message_key) = advance_chain(
                &self.receiving_chain_key,
                message.dh_epoch,
                skipped_index,
                "message",
            )?;
            *self.receiving_chain_key = *next_chain_key;
            self.receiving_chain_index += 1;
            self.push_skipped_message_key(SkippedMessageKey {
                message_id: skipped_id,
                dh_epoch: message.dh_epoch,
                chain_index: skipped_index,
                sender_ratchet_public_key,
                message_key,
            });
        }
        let (next_chain_key, message_key) = advance_chain(
            &self.receiving_chain_key,
            message.dh_epoch,
            self.receiving_chain_index,
            "message",
        )?;
        *self.receiving_chain_key = *next_chain_key;
        self.receiving_chain_index += 1;
        Ok(message_key)
    }

    fn message_key_for_open(
        &mut self,
        message: &SecureMeshPairwiseMessage,
    ) -> Result<Zeroizing<[u8; MESSAGE_KEY_LEN]>> {
        let sender_ratchet_public_key = parse_key_bytes(
            &message.sender_ratchet_public_key,
            "sender ratchet public key",
        )?;
        if self
            .skipped_message_key_position(
                message.dh_epoch,
                message.chain_index,
                sender_ratchet_public_key,
            )
            .is_some()
        {
            self.take_skipped_message_key(
                &message.message_id,
                message.dh_epoch,
                message.chain_index,
                sender_ratchet_public_key,
            )
        } else if sender_ratchet_public_key != self.remote_ratchet_public_key {
            self.advance_receiving_chain_to(message, sender_ratchet_public_key)
        } else if message.chain_index < self.receiving_chain_index {
            Err(anyhow!(
                "secure mesh pairwise skipped message key is unavailable"
            ))
        } else {
            self.advance_receiving_chain_to(message, sender_ratchet_public_key)
        }
    }

    fn skipped_message_key_position(
        &self,
        dh_epoch: u64,
        chain_index: u64,
        sender_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    ) -> Option<usize> {
        self.skipped_keys.iter().position(|candidate| {
            candidate.dh_epoch == dh_epoch
                && candidate.chain_index == chain_index
                && candidate.sender_ratchet_public_key == sender_ratchet_public_key
        })
    }

    fn take_skipped_message_key(
        &mut self,
        message_id: &str,
        dh_epoch: u64,
        chain_index: u64,
        sender_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    ) -> Result<Zeroizing<[u8; MESSAGE_KEY_LEN]>> {
        match self.skipped_message_key_position(dh_epoch, chain_index, sender_ratchet_public_key) {
            Some(index) => {
                let skipped = self.skipped_keys.remove(index);
                if skipped.message_id != message_id {
                    // The placeholder id is deterministic for out-of-order gaps; the AEAD AAD
                    // still binds the real message id before any plaintext is returned.
                }
                Ok(skipped.message_key)
            }
            None => Err(anyhow!(
                "secure mesh pairwise skipped message key is unavailable"
            )),
        }
    }

    fn push_skipped_message_key(&mut self, skipped: SkippedMessageKey) {
        self.skipped_keys.push(skipped);
        while self.skipped_keys.len() > MAX_SKIPPED_KEYS {
            let mut removed = self.skipped_keys.remove(0);
            removed.message_key.zeroize();
        }
    }

    fn record_received_message_id(&mut self, message_id: String) {
        self.received_message_ids.push(message_id);
        while self.received_message_ids.len() > MAX_REPLAY_IDS {
            self.received_message_ids.remove(0);
        }
    }

    fn to_public_snapshot(
        &self,
        state_version: u64,
        secret_store_namespace: String,
        secret_store_key: String,
    ) -> PersistedPairwisePublicSession {
        PersistedPairwisePublicSession {
            schema_version: PAIRWISE_SNAPSHOT_SCHEMA_VERSION,
            state_version,
            secret_store_class: PAIRWISE_SECRET_STORE_CLASS.to_string(),
            secret_store_namespace,
            secret_store_key,
            session_id: self.session_id.clone(),
            local_endpoint_id: self.local_endpoint_id.clone(),
            remote_endpoint_id: self.remote_endpoint_id.clone(),
            role: self.role.as_str().to_string(),
            local_ratchet_public_key: encode_secret(&self.local_ratchet_public_key),
            remote_ratchet_public_key: encode_secret(&self.remote_ratchet_public_key),
            handshake_transcript_hash: general_purpose::URL_SAFE_NO_PAD
                .encode(self.handshake_transcript_hash),
            dh_epoch: self.dh_epoch,
            receiving_ratchet_epoch: self.receiving_ratchet_epoch,
            sending_chain_index: self.sending_chain_index,
            receiving_chain_index: self.receiving_chain_index,
            previous_chain_length: self.previous_chain_length,
            skipped_keys: self
                .skipped_keys
                .iter()
                .map(PersistedSkippedMessageKeyPublic::from)
                .collect(),
            received_message_ids: self.received_message_ids.clone(),
            pending_sending_ratchet: self.pending_sending_ratchet,
            initiator_key_confirmed: self.initiator_key_confirmed,
            local_capability_proof: self.local_capability_proof.clone(),
            capability_binding: self
                .capability_negotiation
                .as_ref()
                .map(|negotiation| negotiation.binding().clone()),
            capability_projection: self
                .capability_negotiation
                .as_ref()
                .map(|negotiation| negotiation.projection().clone()),
            revoked: self.revoked,
        }
    }

    fn to_secret_snapshot(
        &self,
        state_version: u64,
        public_snapshot_digest: String,
    ) -> Result<PersistedPairwiseSessionSecrets> {
        let sparse_pq_ratchet = self.sparse_pq_ratchet.persist()?;
        let local_ratchet_secret = Zeroizing::new(self.local_ratchet_secret.to_bytes());
        Ok(PersistedPairwiseSessionSecrets {
            schema_version: PAIRWISE_SNAPSHOT_SCHEMA_VERSION,
            state_version,
            session_id: self.session_id.clone(),
            local_endpoint_id: self.local_endpoint_id.clone(),
            remote_endpoint_id: self.remote_endpoint_id.clone(),
            public_snapshot_digest,
            root_key: PairwiseSecretString::new(encode_secret(&self.root_key)),
            sending_chain_key: PairwiseSecretString::new(encode_secret(&self.sending_chain_key)),
            receiving_chain_key: PairwiseSecretString::new(encode_secret(
                &self.receiving_chain_key,
            )),
            sending_header_key: PairwiseSecretString::new(encode_secret(&self.sending_header_key)),
            receiving_header_key: PairwiseSecretString::new(encode_secret(
                &self.receiving_header_key,
            )),
            next_sending_header_key: PairwiseSecretString::new(encode_secret(
                &self.next_sending_header_key,
            )),
            next_receiving_header_key: PairwiseSecretString::new(encode_secret(
                &self.next_receiving_header_key,
            )),
            skipped_receiving_header_keys: self
                .skipped_receiving_header_keys
                .iter()
                .map(|key| PairwiseSecretString::new(encode_secret(key)))
                .collect(),
            local_ratchet_secret: PairwiseSecretString::new(encode_secret(&local_ratchet_secret)),
            sparse_pq_ratchet: PairwiseSecretString::new(
                general_purpose::URL_SAFE_NO_PAD.encode(sparse_pq_ratchet.as_slice()),
            ),
            skipped_keys: self
                .skipped_keys
                .iter()
                .map(PersistedSkippedMessageKeySecret::from)
                .collect(),
        })
    }

    fn from_persisted_snapshots(
        public: PersistedPairwisePublicSession,
        secrets: PersistedPairwiseSessionSecrets,
    ) -> Result<Self> {
        ensure!(
            public.schema_version == PAIRWISE_SNAPSHOT_SCHEMA_VERSION
                && secrets.schema_version == PAIRWISE_SNAPSHOT_SCHEMA_VERSION,
            "secure mesh pairwise persisted snapshot schema is unsupported"
        );
        ensure!(
            public.secret_store_class == PAIRWISE_SECRET_STORE_CLASS,
            "secure mesh pairwise persisted snapshot secret class is unsupported"
        );
        ensure!(
            public.state_version == secrets.state_version
                && public.session_id == secrets.session_id
                && public.local_endpoint_id == secrets.local_endpoint_id
                && public.remote_endpoint_id == secrets.remote_endpoint_id,
            "secure mesh pairwise persisted public and secret snapshots are not bound"
        );
        ensure!(
            public.skipped_keys.len() == secrets.skipped_keys.len(),
            "secure mesh pairwise persisted skipped-key snapshot is inconsistent"
        );
        ensure!(
            secrets.skipped_receiving_header_keys.len() <= MAX_SKIPPED_KEYS,
            "secure mesh pairwise persisted skipped header-key limit exceeded"
        );
        validate_endpoint_id(&public.local_endpoint_id)?;
        validate_endpoint_id(&public.remote_endpoint_id)?;
        let _secret_store_key = require_text(public.secret_store_key, "secret store key")?;
        let _secret_store_namespace =
            require_text(public.secret_store_namespace, "secret store namespace")?;
        let local_ratchet_secret = SecureMeshPairwisePrivateKey::from_bytes(decode_secret_32(
            secrets.local_ratchet_secret.as_str(),
        )?);
        let role = SecureMeshPairwiseRole::from_str(&public.role)?;
        let handshake_transcript_hash = decode_fixed_base64url::<HANDSHAKE_HASH_LEN>(
            &public.handshake_transcript_hash,
            "persisted handshake transcript hash",
        )?;
        let capability_negotiation = match (public.capability_binding, public.capability_projection)
        {
            (Some(binding), Some(projection)) => {
                let base_transcript_digest =
                    crate::core::secure_mesh_capability_proof::encode_sha256_digest(
                        &handshake_transcript_hash,
                    );
                ensure!(
                    binding.base_transcript_digest == base_transcript_digest,
                    "secure mesh pairwise persisted capability transcript mismatch"
                );
                let local_proof_digest =
                    signed_capability_proof_digest(&public.local_capability_proof)?;
                ensure!(
                    binding
                        .capability_proof_digests
                        .contains(&local_proof_digest),
                    "secure mesh pairwise persisted local capability proof is unbound"
                );
                Some(restore_verified_pairwise_session_negotiation(
                    binding, projection,
                )?)
            }
            (None, None) => None,
            _ => {
                return Err(anyhow!(
                    "secure mesh pairwise persisted capability negotiation is incomplete"
                ));
            }
        };
        ensure!(
            public.revoked
                || ((role == SecureMeshPairwiseRole::Initiator
                    || capability_negotiation.is_some())
                    && (!public.initiator_key_confirmed || capability_negotiation.is_some())),
            "secure mesh pairwise persisted protected session lacks capability negotiation"
        );
        ensure!(
            public.receiving_ratchet_epoch <= public.dh_epoch
                && public.dh_epoch - public.receiving_ratchet_epoch <= 1,
            "secure mesh pairwise persisted ratchet epochs are inconsistent"
        );
        ensure!(
            secrets.sparse_pq_ratchet.as_str().len() <= MAX_ENCODED_SPARSE_PQ_RATCHET_BYTES,
            "secure mesh pairwise persisted sparse PQ ratchet exceeds the resource limit"
        );
        let sparse_pq_ratchet_bytes = Zeroizing::new(
            general_purpose::URL_SAFE_NO_PAD
                .decode(secrets.sparse_pq_ratchet.as_str())
                .context("secure mesh pairwise persisted sparse PQ ratchet is not base64url")?,
        );
        let canonical_sparse_pq_ratchet = Zeroizing::new(
            general_purpose::URL_SAFE_NO_PAD.encode(sparse_pq_ratchet_bytes.as_slice()),
        );
        ensure!(
            canonical_sparse_pq_ratchet.as_str() == secrets.sparse_pq_ratchet.as_str(),
            "secure mesh pairwise persisted sparse PQ ratchet encoding is non-canonical"
        );
        let sparse_pq_ratchet =
            SecureMeshSparsePqRatchet::restore(sparse_pq_ratchet_bytes.as_slice())?;
        Ok(Self {
            session_id: require_text(public.session_id, "session id")?,
            local_endpoint_id: public.local_endpoint_id,
            remote_endpoint_id: public.remote_endpoint_id,
            role,
            root_key: Zeroizing::new(decode_secret_32(secrets.root_key.as_str())?),
            sending_chain_key: Zeroizing::new(decode_secret_32(
                secrets.sending_chain_key.as_str(),
            )?),
            receiving_chain_key: Zeroizing::new(decode_secret_32(
                secrets.receiving_chain_key.as_str(),
            )?),
            sending_header_key: Zeroizing::new(decode_secret_32(
                secrets.sending_header_key.as_str(),
            )?),
            receiving_header_key: Zeroizing::new(decode_secret_32(
                secrets.receiving_header_key.as_str(),
            )?),
            next_sending_header_key: Zeroizing::new(decode_secret_32(
                secrets.next_sending_header_key.as_str(),
            )?),
            next_receiving_header_key: Zeroizing::new(decode_secret_32(
                secrets.next_receiving_header_key.as_str(),
            )?),
            skipped_receiving_header_keys: secrets
                .skipped_receiving_header_keys
                .iter()
                .map(|key| decode_secret_32(key.as_str()).map(Zeroizing::new))
                .collect::<Result<Vec<_>>>()?,
            local_ratchet_secret,
            local_ratchet_public_key: decode_secret_32(&public.local_ratchet_public_key)?,
            remote_ratchet_public_key: decode_secret_32(&public.remote_ratchet_public_key)?,
            handshake_transcript_hash,
            dh_epoch: public.dh_epoch,
            receiving_ratchet_epoch: public.receiving_ratchet_epoch,
            sending_chain_index: public.sending_chain_index,
            receiving_chain_index: public.receiving_chain_index,
            previous_chain_length: public.previous_chain_length,
            skipped_keys: public
                .skipped_keys
                .into_iter()
                .zip(secrets.skipped_keys.iter())
                .map(SkippedMessageKey::try_from)
                .collect::<Result<Vec<_>>>()?,
            received_message_ids: public.received_message_ids,
            pending_sending_ratchet: public.pending_sending_ratchet,
            initiator_key_confirmed: public.initiator_key_confirmed,
            local_capability_proof: public.local_capability_proof,
            capability_negotiation,
            sparse_pq_ratchet,
            revoked: public.revoked,
        })
    }
}

#[cfg(test)]
impl Clone for SecureMeshPairwiseSession {
    fn clone(&self) -> Self {
        self.try_clone()
            .expect("valid secure mesh pairwise test session must be cloneable")
    }
}

fn relay_envelope_from_pairwise_message(
    session: &SecureMeshPairwiseSession,
    context: &SecureMeshContentContext,
    message: &SecureMeshPairwiseMessage,
) -> Result<SecureMeshRelayEnvelope> {
    ensure!(
        context.message_id == message.message_id
            && context.session_id == message.session_id
            && context.sender_endpoint_id == message.sender_endpoint_id
            && context.recipient_endpoint_id == message.recipient_endpoint_id,
        "secure mesh pairwise relay context does not match message"
    );
    let draft = SecureMeshRelayEnvelopeDraft::from_canonical_ids(
        &context.opaque_mailbox_id,
        &context.envelope_id,
        message.ciphertext_size,
    )?;
    let private_header = SecureMeshPairwisePrivateRelayHeader {
        protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
        cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
        delivery_id: context.envelope_id.clone(),
        mailbox_token: context.opaque_mailbox_id.clone(),
        message_id: context.message_id.clone(),
        session_id: context.session_id.clone(),
        sender_endpoint_id: context.sender_endpoint_id.clone(),
        recipient_endpoint_id: context.recipient_endpoint_id.clone(),
        created_at: context.created_at.clone(),
        expires_at: context.expires_at.clone(),
        dh_epoch: message.dh_epoch,
        chain_index: message.chain_index,
        previous_chain_length: message.previous_chain_length,
        sender_ratchet_public_key: general_purpose::URL_SAFE_NO_PAD
            .encode(&message.sender_ratchet_public_key),
        sparse_pq_header: message.sparse_pq_header.clone(),
        content_encrypted_header: message.encrypted_header.clone(),
    };
    let private_header = serde_json::to_vec(&private_header)
        .context("secure mesh pairwise private relay header serialization failed")?;
    let encrypted_header =
        seal_private_relay_header(&draft, session.sending_header_key.as_ref(), &private_header)?;
    let ciphertext = general_purpose::URL_SAFE_NO_PAD
        .decode(&message.ciphertext)
        .context("secure mesh pairwise ciphertext is not base64url")?;
    ensure!(
        ciphertext.len() == message.ciphertext_size,
        "secure mesh pairwise ciphertext size mismatch"
    );
    draft.finish(&encrypted_header, &ciphertext)
}

fn pairwise_message_from_relay_envelope(
    session: &SecureMeshPairwiseSession,
    envelope: &SecureMeshRelayEnvelope,
) -> Result<(SecureMeshContentContext, SecureMeshPairwiseMessage)> {
    let private_header = open_private_relay_header(
        envelope,
        std::iter::once(session.receiving_header_key.as_ref())
            .chain(std::iter::once(session.next_receiving_header_key.as_ref()))
            .chain(
                session
                    .skipped_receiving_header_keys
                    .iter()
                    .rev()
                    .map(AsRef::as_ref),
            ),
    )?;
    let header: SecureMeshPairwisePrivateRelayHeader = serde_json::from_slice(&private_header)
        .context("secure mesh pairwise private relay header is invalid")?;
    ensure!(
        header.protocol_version == SECURE_MESH_PROTOCOL_VERSION
            && header.cipher_suite == SECURE_MESH_PAIRWISE_CIPHER_SUITE,
        "secure mesh pairwise private relay protocol is unsupported"
    );
    ensure!(
        header.delivery_id == envelope.delivery_id()
            && header.mailbox_token == envelope.mailbox_token(),
        "secure mesh pairwise private relay routing binding mismatch"
    );
    ensure!(
        header.session_id == session.session_id
            && header.sender_endpoint_id == session.remote_endpoint_id
            && header.recipient_endpoint_id == session.local_endpoint_id,
        "secure mesh pairwise private relay receiver binding mismatch"
    );
    let sender_ratchet_public_key = general_purpose::URL_SAFE_NO_PAD
        .decode(&header.sender_ratchet_public_key)
        .context("secure mesh pairwise ratchet public key is not base64url")?;
    parse_key_bytes(
        &sender_ratchet_public_key,
        "relay sender ratchet public key",
    )?;
    let context = SecureMeshContentContext::new(
        &header.delivery_id,
        &header.message_id,
        &header.mailbox_token,
        &header.sender_endpoint_id,
        &header.recipient_endpoint_id,
        &header.session_id,
        &header.created_at,
        &header.expires_at,
    );
    let message = SecureMeshPairwiseMessage {
        protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
        cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
        session_id: header.session_id,
        message_id: header.message_id,
        sender_endpoint_id: header.sender_endpoint_id,
        recipient_endpoint_id: header.recipient_endpoint_id,
        dh_epoch: header.dh_epoch,
        chain_index: header.chain_index,
        previous_chain_length: header.previous_chain_length,
        sender_ratchet_public_key,
        sparse_pq_header: header.sparse_pq_header,
        encrypted_header: header.content_encrypted_header,
        ciphertext: envelope.ciphertext().to_string(),
        ciphertext_size: envelope.ciphertext_bucket(),
    };
    Ok((context, message))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshSesameDeviceRecord {
    pub user_id: String,
    pub endpoint_id: String,
    pub active_session_id: Option<String>,
    pub inactive_session_ids: Vec<String>,
    pub revoked: bool,
    pub stale: bool,
}

#[derive(Clone, Debug)]
pub struct SecureMeshSesameSessionManager {
    inactive_session_limit: usize,
    devices: Vec<SecureMeshSesameDeviceRecord>,
}

impl SecureMeshSesameSessionManager {
    pub fn new(inactive_session_limit: usize) -> Self {
        Self {
            inactive_session_limit: inactive_session_limit.max(1),
            devices: Vec::new(),
        }
    }

    pub fn activate_session(
        &mut self,
        user_id: impl Into<String>,
        endpoint_id: impl Into<String>,
        session_id: impl Into<String>,
    ) -> Result<()> {
        let user_id = require_text(user_id.into(), "user id")?;
        let endpoint_id = require_text(endpoint_id.into(), "endpoint id")?;
        let session_id = require_text(session_id.into(), "session id")?;
        let limit = self.inactive_session_limit;
        let device = self.device_mut_or_insert(&user_id, &endpoint_id);
        if let Some(active_session_id) = &device.active_session_id {
            if active_session_id != &session_id {
                push_bounded_inactive(
                    &mut device.inactive_session_ids,
                    active_session_id.clone(),
                    limit,
                );
            }
        }
        device.active_session_id = Some(session_id);
        device.revoked = false;
        device.stale = false;
        Ok(())
    }

    pub fn mark_session_inactive(
        &mut self,
        user_id: &str,
        endpoint_id: &str,
        session_id: &str,
    ) -> Result<()> {
        let limit = self.inactive_session_limit;
        let device = self.device_mut(user_id, endpoint_id)?;
        if device.active_session_id.as_deref() == Some(session_id) {
            device.active_session_id = None;
        }
        push_bounded_inactive(
            &mut device.inactive_session_ids,
            session_id.to_string(),
            limit,
        );
        Ok(())
    }

    pub fn converge_session_collision(
        &mut self,
        user_id: &str,
        endpoint_id: &str,
        candidate_session_id: &str,
    ) -> Result<String> {
        let candidate_session_id = require_text(candidate_session_id.to_string(), "session id")?;
        let limit = self.inactive_session_limit;
        let device = self.device_mut(user_id, endpoint_id)?;
        let chosen = match &device.active_session_id {
            Some(active) if active <= &candidate_session_id => active.clone(),
            Some(active) => {
                push_bounded_inactive(&mut device.inactive_session_ids, active.clone(), limit);
                candidate_session_id.clone()
            }
            None => candidate_session_id.clone(),
        };
        if chosen != candidate_session_id {
            push_bounded_inactive(
                &mut device.inactive_session_ids,
                candidate_session_id,
                limit,
            );
        }
        device.active_session_id = Some(chosen.clone());
        Ok(chosen)
    }

    pub fn revoke_device(&mut self, user_id: &str, endpoint_id: &str) -> Result<()> {
        let device = self.device_mut(user_id, endpoint_id)?;
        device.active_session_id = None;
        device.inactive_session_ids.clear();
        device.revoked = true;
        device.stale = true;
        Ok(())
    }

    pub fn active_sessions_for_user(&self, user_id: &str) -> Vec<String> {
        self.devices
            .iter()
            .filter(|device| device.user_id == user_id && !device.revoked)
            .filter_map(|device| device.active_session_id.clone())
            .collect()
    }

    pub fn fanout_targets_for_user(&self, user_id: &str) -> Vec<(String, String)> {
        self.devices
            .iter()
            .filter(|device| device.user_id == user_id && !device.revoked)
            .filter_map(|device| {
                device
                    .active_session_id
                    .clone()
                    .map(|session_id| (device.endpoint_id.clone(), session_id))
            })
            .collect()
    }

    pub fn device_record(
        &self,
        user_id: &str,
        endpoint_id: &str,
    ) -> Option<&SecureMeshSesameDeviceRecord> {
        self.devices
            .iter()
            .find(|device| device.user_id == user_id && device.endpoint_id == endpoint_id)
    }

    fn device_mut(
        &mut self,
        user_id: &str,
        endpoint_id: &str,
    ) -> Result<&mut SecureMeshSesameDeviceRecord> {
        self.devices
            .iter_mut()
            .find(|device| device.user_id == user_id && device.endpoint_id == endpoint_id)
            .ok_or_else(|| anyhow!("secure mesh Sesame device session record is missing"))
    }

    fn device_mut_or_insert(
        &mut self,
        user_id: &str,
        endpoint_id: &str,
    ) -> &mut SecureMeshSesameDeviceRecord {
        if let Some(index) = self
            .devices
            .iter()
            .position(|device| device.user_id == user_id && device.endpoint_id == endpoint_id)
        {
            return &mut self.devices[index];
        }
        self.devices.push(SecureMeshSesameDeviceRecord {
            user_id: user_id.to_string(),
            endpoint_id: endpoint_id.to_string(),
            active_session_id: None,
            inactive_session_ids: Vec::new(),
            revoked: false,
            stale: false,
        });
        self.devices
            .last_mut()
            .expect("secure mesh Sesame device record was inserted")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPairwiseDurableRecord {
    pub session_id: String,
    pub local_endpoint_id: String,
    pub remote_endpoint_id: String,
    pub state_version: u64,
    pub dh_epoch: u64,
    pub sent_count: u64,
    pub received_count: u64,
    pub revoked_at: Option<String>,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshRemotePreKeyUse {
    pub session_id: String,
    pub local_endpoint_id: String,
    pub remote_endpoint_id: String,
    pub remote_identity_fingerprint: String,
    pub signed_prekey_id: String,
    pub one_time_prekey_id: String,
    pub one_time_prekey_public_key_hash: String,
    pub one_time_mlkem1024_prekey_id: String,
    pub one_time_mlkem1024_prekey_public_key_hash: String,
    pub directory_authorization_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshLocalPreKeyUse {
    pub local_endpoint_id: String,
    pub local_identity_fingerprint: String,
    pub one_time_prekey_id: String,
    pub one_time_prekey_public_key_hash: String,
    pub one_time_mlkem1024_prekey_id: String,
    pub one_time_mlkem1024_prekey_public_key_hash: String,
}

pub struct SecureMeshPairwiseDurableStore {
    connection: Connection,
    secret_store: Arc<dyn SecureMeshSecretStore>,
    secret_store_namespace: String,
}

struct PreparedCapabilityProofPair {
    local_scope_hash: String,
    first_digest: String,
    second_digest: String,
    first_expiry: i64,
    second_expiry: i64,
    now_unix_seconds: i64,
}

struct PreparedRemotePreKeyUse {
    session_id: String,
    local_endpoint_id: String,
    remote_endpoint_id: String,
    remote_identity_fingerprint: String,
    signed_prekey_id: String,
    one_time_prekey_id: String,
    one_time_prekey_public_key_hash: String,
    one_time_mlkem1024_prekey_id: String,
    one_time_mlkem1024_prekey_public_key_hash: String,
    directory_authorization_digest: String,
    used_at: String,
}

impl PreparedRemotePreKeyUse {
    fn new(prekey_use: &SecureMeshRemotePreKeyUse, used_at: String) -> Result<Self> {
        Ok(Self {
            session_id: require_text(prekey_use.session_id.clone(), "session_id")?,
            local_endpoint_id: require_text(
                prekey_use.local_endpoint_id.clone(),
                "local_endpoint_id",
            )?,
            remote_endpoint_id: require_text(
                prekey_use.remote_endpoint_id.clone(),
                "remote_endpoint_id",
            )?,
            remote_identity_fingerprint: require_text(
                prekey_use.remote_identity_fingerprint.clone(),
                "remote_identity_fingerprint",
            )?,
            signed_prekey_id: require_text(
                prekey_use.signed_prekey_id.clone(),
                "signed_prekey_id",
            )?,
            one_time_prekey_id: require_text(
                prekey_use.one_time_prekey_id.clone(),
                "one_time_prekey_id",
            )?,
            one_time_prekey_public_key_hash: require_text(
                prekey_use.one_time_prekey_public_key_hash.clone(),
                "one_time_prekey_public_key_hash",
            )?,
            one_time_mlkem1024_prekey_id: require_text(
                prekey_use.one_time_mlkem1024_prekey_id.clone(),
                "one_time_mlkem1024_prekey_id",
            )?,
            one_time_mlkem1024_prekey_public_key_hash: require_text(
                prekey_use.one_time_mlkem1024_prekey_public_key_hash.clone(),
                "one_time_mlkem1024_prekey_public_key_hash",
            )?,
            directory_authorization_digest: require_sha256_hex(
                prekey_use.directory_authorization_digest.clone(),
                "directory_authorization_digest",
            )?,
            used_at: require_text(used_at, "used_at")?,
        })
    }
}

fn consume_remote_prekey_use(
    tx: &Transaction<'_>,
    prekey_use: &PreparedRemotePreKeyUse,
) -> Result<()> {
    let changed = tx
        .execute(
            r#"
            INSERT OR IGNORE INTO secure_mesh_pairwise_remote_prekey_uses (
                remote_endpoint_id,
                remote_identity_fingerprint,
                signed_prekey_id,
                one_time_prekey_id,
                one_time_prekey_public_key_hash,
                one_time_mlkem1024_prekey_id,
                one_time_mlkem1024_prekey_public_key_hash,
                directory_authorization_digest,
                session_id,
                local_endpoint_id,
                used_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
            params![
                prekey_use.remote_endpoint_id,
                prekey_use.remote_identity_fingerprint,
                prekey_use.signed_prekey_id,
                prekey_use.one_time_prekey_id,
                prekey_use.one_time_prekey_public_key_hash,
                prekey_use.one_time_mlkem1024_prekey_id,
                prekey_use.one_time_mlkem1024_prekey_public_key_hash,
                prekey_use.directory_authorization_digest,
                prekey_use.session_id,
                prekey_use.local_endpoint_id,
                prekey_use.used_at
            ],
        )
        .context("secure mesh pairwise remote prekey-use insert failed")?;
    ensure!(
        changed == 1,
        "secure mesh pairwise remote one-time prekey was already used"
    );
    Ok(())
}

impl PreparedCapabilityProofPair {
    fn new(
        secret_store_namespace: &str,
        local_endpoint_id: &str,
        first: &SignedCapabilityProof,
        second: &SignedCapabilityProof,
        now_unix_seconds: i64,
    ) -> Result<Self> {
        validate_endpoint_id(local_endpoint_id)?;
        let first_digest = signed_capability_proof_digest(first)?;
        let second_digest = signed_capability_proof_digest(second)?;
        ensure!(
            first_digest != second_digest,
            "secure mesh durable capability replay ledger requires distinct proofs"
        );
        let first_expiry = first.claims.expires_at_unix_seconds;
        let second_expiry = second.claims.expires_at_unix_seconds;
        ensure!(
            first_expiry >= now_unix_seconds && second_expiry >= now_unix_seconds,
            "secure mesh durable capability replay ledger rejected expired proof"
        );
        Ok(Self {
            local_scope_hash: sha256_hex(
                format!("{secret_store_namespace}:{local_endpoint_id}").as_bytes(),
            ),
            first_digest,
            second_digest,
            first_expiry,
            second_expiry,
            now_unix_seconds,
        })
    }
}

fn consume_prepared_capability_proof_pair(
    tx: &Transaction<'_>,
    pair: &PreparedCapabilityProofPair,
) -> Result<()> {
    let effective_now_unix_seconds =
        advance_pairwise_replay_time_watermark(tx, pair.now_unix_seconds)?;
    ensure!(
        pair.first_expiry >= effective_now_unix_seconds
            && pair.second_expiry >= effective_now_unix_seconds,
        "secure mesh durable capability replay ledger rejected proof revived by clock rollback"
    );
    tx.execute(
        "DELETE FROM secure_mesh_pairwise_capability_proof_uses WHERE expires_at_unix_seconds < ?1",
        params![effective_now_unix_seconds],
    )
    .context("secure mesh durable capability replay expiry pruning failed")?;
    let existing_count: i64 = tx
        .query_row(
            r#"
            SELECT COUNT(*)
            FROM secure_mesh_pairwise_capability_proof_uses
            WHERE local_endpoint_scope_hash = ?1
              AND proof_digest IN (?2, ?3)
            "#,
            params![pair.local_scope_hash, pair.first_digest, pair.second_digest],
            |row| row.get(0),
        )
        .context("secure mesh durable capability replay lookup failed")?;
    ensure!(
        existing_count == 0,
        "secure mesh capability proof replay rejected"
    );
    let unexpired_count: i64 = tx
        .query_row(
            r#"
            SELECT COUNT(*)
            FROM secure_mesh_pairwise_capability_proof_uses
            WHERE local_endpoint_scope_hash = ?1
            "#,
            params![pair.local_scope_hash],
            |row| row.get(0),
        )
        .context("secure mesh durable capability replay capacity lookup failed")?;
    ensure!(
        usize::try_from(unexpired_count)
            .unwrap_or(usize::MAX)
            .saturating_add(2)
            <= MAX_PERSISTED_CAPABILITY_PROOF_USES,
        "secure mesh capability proof replay guard is at capacity"
    );
    for (digest, expiry) in [
        (pair.first_digest.as_str(), pair.first_expiry),
        (pair.second_digest.as_str(), pair.second_expiry),
    ] {
        tx.execute(
            r#"
            INSERT INTO secure_mesh_pairwise_capability_proof_uses (
                local_endpoint_scope_hash,
                proof_digest,
                expires_at_unix_seconds,
                consumed_at_unix_seconds
            ) VALUES (?1, ?2, ?3, ?4)
            "#,
            params![
                pair.local_scope_hash,
                digest,
                expiry,
                effective_now_unix_seconds
            ],
        )
        .context("secure mesh durable capability proof consumption failed")?;
    }
    Ok(())
}

fn advance_pairwise_replay_time_watermark(
    tx: &Transaction<'_>,
    now_unix_seconds: i64,
) -> Result<i64> {
    ensure!(
        now_unix_seconds >= 0,
        "secure mesh pairwise replay clock is before unix epoch"
    );
    let persisted: i64 = tx.query_row(
        "SELECT max_observed_unix_seconds FROM secure_mesh_pairwise_time_guard WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    let effective = persisted.max(now_unix_seconds);
    tx.execute(
        "UPDATE secure_mesh_pairwise_time_guard SET max_observed_unix_seconds = ?1 WHERE singleton = 1",
        params![effective],
    )?;
    Ok(effective)
}

impl SecureMeshPairwiseDurableStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let secret_store = Arc::new(PlatformSecretStore::new(
            PAIRWISE_SECRET_STORE_SERVICE,
            PAIRWISE_SECRET_STORE_ACCOUNT_PREFIX,
        ));
        Self::open_with_secret_store(path, secret_store, pairwise_secret_store_namespace(path))
    }

    pub fn open_with_secret_store(
        path: impl AsRef<Path>,
        secret_store: Arc<dyn SecureMeshSecretStore>,
        secret_store_namespace: impl Into<String>,
    ) -> Result<Self> {
        let connection = Connection::open(path.as_ref())
            .context("secure mesh pairwise durable store open failed")?;
        let store = Self {
            connection,
            secret_store,
            secret_store_namespace: require_text(
                secret_store_namespace.into(),
                "secret store namespace",
            )?,
        };
        store.initialize()?;
        Ok(store)
    }

    pub fn begin_authorized_session(
        &self,
        request: &SecretStoreAuthorizationRequest,
    ) -> Result<SecretStoreAuthorizationSession> {
        self.secret_store.begin_authorized_session(request)
    }

    pub fn secret_store_backend(&self) -> &'static str {
        self.secret_store.backend()
    }

    #[cfg(test)]
    pub fn consume_capability_proof_pair(
        &mut self,
        local_endpoint_id: &str,
        first: &SignedCapabilityProof,
        second: &SignedCapabilityProof,
        now_unix_seconds: i64,
    ) -> Result<()> {
        let prepared = PreparedCapabilityProofPair::new(
            &self.secret_store_namespace,
            local_endpoint_id,
            first,
            second,
            now_unix_seconds,
        )?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh durable capability replay transaction failed")?;
        consume_prepared_capability_proof_pair(&tx, &prepared)?;
        tx.commit()
            .context("secure mesh durable capability replay commit failed")?;
        Ok(())
    }

    pub fn purge_unrecoverable_memory_only_sessions(&mut self) -> Result<usize> {
        if self.secret_store.backend() != "memory-only-ephemeral" {
            return Ok(0);
        }
        let mut statement = self.connection.prepare(
            "SELECT snapshot_json FROM secure_mesh_pairwise_sessions ORDER BY session_id, local_endpoint_id",
        )?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut missing_secret = false;
        for row in rows {
            let public: PersistedPairwisePublicSession = serde_json::from_str(&row?)
                .context("secure mesh memory-only public snapshot is invalid")?;
            let handle = self
                .secret_snapshot_handle(&public.secret_store_namespace, &public.secret_store_key)?;
            if self.secret_store.get_secret(&handle)?.is_none() {
                missing_secret = true;
                break;
            }
        }
        drop(statement);
        if !missing_secret {
            return Ok(0);
        }
        self.connection
            .execute("DELETE FROM secure_mesh_pairwise_sessions", [])
            .context("secure mesh unrecoverable memory-only session purge failed")
    }

    pub fn upsert_initial(
        &mut self,
        session: &SecureMeshPairwiseSession,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        self.upsert_initial_with_security_claims(session, updated_at.into(), None, None, None)
    }

    pub fn upsert_initial_with_local_prekey_claim(
        &mut self,
        session: &SecureMeshPairwiseSession,
        local_prekey_use: &SecureMeshLocalPreKeyUse,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        self.upsert_initial_with_security_claims(
            session,
            updated_at.into(),
            Some(local_prekey_use),
            None,
            None,
        )
    }

    pub fn upsert_initial_with_local_prekey_claim_and_capability_proofs(
        &mut self,
        session: &SecureMeshPairwiseSession,
        local_prekey_use: &SecureMeshLocalPreKeyUse,
        first_proof: &SignedCapabilityProof,
        second_proof: &SignedCapabilityProof,
        now_unix_seconds: i64,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        self.upsert_initial_with_security_claims(
            session,
            updated_at.into(),
            Some(local_prekey_use),
            None,
            Some((first_proof, second_proof, now_unix_seconds)),
        )
    }

    pub fn upsert_initial_with_remote_prekey_claim(
        &mut self,
        session: &SecureMeshPairwiseSession,
        remote_prekey_use: &SecureMeshRemotePreKeyUse,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        self.upsert_initial_with_security_claims(
            session,
            updated_at.into(),
            None,
            Some(remote_prekey_use),
            None,
        )
    }

    fn upsert_initial_with_security_claims(
        &mut self,
        session: &SecureMeshPairwiseSession,
        updated_at: String,
        local_prekey_use: Option<&SecureMeshLocalPreKeyUse>,
        remote_prekey_use: Option<&SecureMeshRemotePreKeyUse>,
        capability_proofs: Option<(&SignedCapabilityProof, &SignedCapabilityProof, i64)>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        let updated_at = require_text(updated_at.into(), "updated_at")?;
        let local_prekey_claim = local_prekey_use
            .map(|prekey_use| {
                ensure!(
                    prekey_use.local_endpoint_id == session.local_endpoint_id,
                    "secure mesh pairwise local prekey claim endpoint mismatch"
                );
                Ok((
                    require_text(
                        prekey_use.local_endpoint_id.clone(),
                        "local prekey endpoint id",
                    )?,
                    require_text(
                        prekey_use.local_identity_fingerprint.clone(),
                        "local prekey identity fingerprint",
                    )?,
                    require_text(
                        prekey_use.one_time_prekey_id.clone(),
                        "local one-time prekey id",
                    )?,
                    require_text(
                        prekey_use.one_time_prekey_public_key_hash.clone(),
                        "local one-time prekey public key hash",
                    )?,
                    require_text(
                        prekey_use.one_time_mlkem1024_prekey_id.clone(),
                        "local one-time ML-KEM-1024 prekey id",
                    )?,
                    require_text(
                        prekey_use.one_time_mlkem1024_prekey_public_key_hash.clone(),
                        "local one-time ML-KEM-1024 prekey public key hash",
                    )?,
                ))
            })
            .transpose()?;
        let remote_prekey_claim = remote_prekey_use
            .map(|prekey_use| PreparedRemotePreKeyUse::new(prekey_use, updated_at.clone()))
            .transpose()?;
        if let Some(remote_prekey_claim) = &remote_prekey_claim {
            ensure!(
                remote_prekey_claim.session_id == session.session_id
                    && remote_prekey_claim.local_endpoint_id == session.local_endpoint_id
                    && remote_prekey_claim.remote_endpoint_id == session.remote_endpoint_id,
                "secure mesh pairwise remote prekey claim session binding mismatch"
            );
        }
        let capability_proofs = capability_proofs
            .map(|(first, second, now)| {
                PreparedCapabilityProofPair::new(
                    &self.secret_store_namespace,
                    &session.local_endpoint_id,
                    first,
                    second,
                    now,
                )
            })
            .transpose()?;
        let existing: Option<i64> = self
            .connection
            .query_row(
                "SELECT 1 FROM secure_mesh_pairwise_sessions WHERE session_id = ?1 AND local_endpoint_id = ?2",
                params![session.session_id, session.local_endpoint_id],
                |row| row.get(0),
            )
            .optional()
            .context("secure mesh pairwise initial durable existence check failed")?;
        ensure!(
            existing.is_none(),
            "secure mesh pairwise durable record already exists"
        );
        let pending = self.prepare_secret_bound_snapshot(session, 1)?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh pairwise initial durable transaction failed")?;
        if let Some((
            endpoint_id,
            identity_fingerprint,
            prekey_id,
            prekey_hash,
            mlkem1024_prekey_id,
            mlkem1024_prekey_hash,
        )) = local_prekey_claim
        {
            let changed = match tx.execute(
                r#"
                    INSERT OR IGNORE INTO secure_mesh_pairwise_local_prekey_uses (
                        local_endpoint_id,
                        local_identity_fingerprint,
                        one_time_prekey_id,
                        one_time_prekey_public_key_hash,
                        one_time_mlkem1024_prekey_id,
                        one_time_mlkem1024_prekey_public_key_hash,
                        session_id,
                        used_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    "#,
                params![
                    endpoint_id,
                    identity_fingerprint,
                    prekey_id,
                    prekey_hash,
                    mlkem1024_prekey_id,
                    mlkem1024_prekey_hash,
                    session.session_id,
                    updated_at,
                ],
            ) {
                Ok(changed) => changed,
                Err(error) => {
                    drop(tx);
                    self.cleanup_pending_snapshot(&pending).context(
                        "secure mesh pairwise failed initial snapshot cleanup is incomplete",
                    )?;
                    return Err(error)
                        .context("secure mesh pairwise local one-time prekey claim failed");
                }
            };
            if changed != 1 {
                drop(tx);
                self.cleanup_pending_snapshot(&pending).context(
                    "secure mesh pairwise rejected initial snapshot cleanup is incomplete",
                )?;
                return Err(anyhow!(
                    "secure mesh pairwise local one-time prekey was already consumed"
                ));
            }
        }
        if let Some(remote_prekey_claim) = &remote_prekey_claim {
            if let Err(error) = consume_remote_prekey_use(&tx, remote_prekey_claim) {
                drop(tx);
                self.cleanup_pending_snapshot(&pending).context(
                    "secure mesh pairwise failed remote prekey snapshot cleanup is incomplete",
                )?;
                return Err(error);
            }
        }
        if let Some(capability_proofs) = &capability_proofs {
            if let Err(error) = consume_prepared_capability_proof_pair(&tx, capability_proofs) {
                drop(tx);
                self.cleanup_pending_snapshot(&pending).context(
                    "secure mesh pairwise failed capability snapshot cleanup is incomplete",
                )?;
                return Err(error);
            }
        }
        let insert_result = tx.execute(
            r#"
            INSERT INTO secure_mesh_pairwise_sessions (
                session_id,
                local_endpoint_id,
                remote_endpoint_id,
                state_version,
                dh_epoch,
                sent_count,
                received_count,
                revoked_at,
                snapshot_json,
                updated_at
            ) VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, NULL, ?7, ?8)
            "#,
            params![
                session.session_id,
                session.local_endpoint_id,
                session.remote_endpoint_id,
                session.dh_epoch as i64,
                session.sending_chain_index as i64,
                session.receiving_chain_index as i64,
                pending.public_json,
                updated_at
            ],
        );
        if let Err(error) = insert_result {
            drop(tx);
            self.cleanup_pending_snapshot(&pending).context(
                "secure mesh pairwise failed initial insert snapshot cleanup is incomplete",
            )?;
            return Err(error).context("secure mesh pairwise initial durable insert failed");
        }
        if let Err(error) = tx.commit() {
            self.cleanup_pending_snapshot(&pending).context(
                "secure mesh pairwise failed initial commit snapshot cleanup is incomplete",
            )?;
            return Err(error).context("secure mesh pairwise initial durable commit failed");
        }
        self.read_record(&session.session_id, &session.local_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh pairwise durable record disappeared after insert"))
    }

    #[cfg(test)]
    pub fn record_remote_prekey_use(
        &mut self,
        prekey_use: &SecureMeshRemotePreKeyUse,
        used_at: impl Into<String>,
    ) -> Result<()> {
        let prepared = PreparedRemotePreKeyUse::new(prekey_use, used_at.into())?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh pairwise remote prekey-use transaction failed")?;
        consume_remote_prekey_use(&tx, &prepared)?;
        tx.commit()
            .context("secure mesh pairwise remote prekey-use commit failed")?;
        Ok(())
    }

    pub fn commit_session(
        &mut self,
        previous: &SecureMeshPairwiseDurableRecord,
        session: &SecureMeshPairwiseSession,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        self.commit_session_with_optional_authorization(
            previous,
            session,
            updated_at.into(),
            None,
            None,
        )
    }

    pub fn commit_session_with_authorized_session(
        &mut self,
        previous: &SecureMeshPairwiseDurableRecord,
        session: &SecureMeshPairwiseSession,
        updated_at: impl Into<String>,
        secret_store_session: &SecretStoreAuthorizationSession,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        self.commit_session_with_optional_authorization(
            previous,
            session,
            updated_at.into(),
            Some(secret_store_session),
            None,
        )
    }

    pub fn commit_session_with_authorized_session_and_capability_proofs(
        &mut self,
        previous: &SecureMeshPairwiseDurableRecord,
        session: &SecureMeshPairwiseSession,
        first_proof: &SignedCapabilityProof,
        second_proof: &SignedCapabilityProof,
        now_unix_seconds: i64,
        updated_at: impl Into<String>,
        secret_store_session: &SecretStoreAuthorizationSession,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        self.commit_session_with_optional_authorization(
            previous,
            session,
            updated_at.into(),
            Some(secret_store_session),
            Some((first_proof, second_proof, now_unix_seconds)),
        )
    }

    fn commit_session_with_optional_authorization(
        &mut self,
        previous: &SecureMeshPairwiseDurableRecord,
        session: &SecureMeshPairwiseSession,
        updated_at: String,
        secret_store_session: Option<&SecretStoreAuthorizationSession>,
        capability_proofs: Option<(&SignedCapabilityProof, &SignedCapabilityProof, i64)>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        ensure!(
            previous.session_id == session.session_id
                && previous.local_endpoint_id == session.local_endpoint_id,
            "secure mesh pairwise durable commit subject mismatch"
        );
        ensure!(
            previous.revoked_at.is_none(),
            "secure mesh pairwise durable session is revoked"
        );
        ensure!(
            session.dh_epoch >= previous.dh_epoch,
            "secure mesh pairwise durable rollback detected"
        );
        let previous_public = self
            .read_public_snapshot(&previous.session_id, &previous.local_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh pairwise durable previous snapshot is missing"))?;
        ensure!(
            session.dh_epoch > previous.dh_epoch
                || (session.sending_chain_index >= previous.sent_count
                    && session.receiving_chain_index >= previous.received_count),
            "secure mesh pairwise durable state regression detected"
        );
        let received_advance = session
            .receiving_chain_index
            .saturating_sub(previous.received_count);
        ensure!(
            replay_window_preserved(
                &previous_public.received_message_ids,
                &session.received_message_ids,
                received_advance,
            ),
            "secure mesh pairwise durable replay cache rollback detected"
        );
        ensure!(
            skipped_keys_not_reintroduced(&previous_public.skipped_keys, session, previous),
            "secure mesh pairwise durable skipped-key rollback detected"
        );
        ensure!(
            !previous_public.initiator_key_confirmed || session.initiator_key_confirmed,
            "secure mesh pairwise durable handshake confirmation rollback detected"
        );
        ensure!(
            previous_public.capability_binding.is_none()
                || session.capability_negotiation.is_some(),
            "secure mesh pairwise durable capability negotiation rollback detected"
        );
        let capability_proofs = capability_proofs
            .map(|(first, second, now)| {
                PreparedCapabilityProofPair::new(
                    &self.secret_store_namespace,
                    &session.local_endpoint_id,
                    first,
                    second,
                    now,
                )
            })
            .transpose()?;
        let updated_at = require_text(updated_at, "updated_at")?;
        let previous_secret_handle = self.secret_snapshot_handle(
            &previous_public.secret_store_namespace,
            &previous_public.secret_store_key,
        )?;
        let pending = self.prepare_secret_bound_snapshot_with_optional_authorization(
            session,
            previous.state_version + 1,
            secret_store_session,
        )?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh pairwise durable commit transaction failed")?;
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_pairwise_sessions
            SET remote_endpoint_id = ?1,
                state_version = state_version + 1,
                dh_epoch = ?2,
                sent_count = ?3,
                received_count = ?4,
                snapshot_json = ?5,
                updated_at = ?6
            WHERE session_id = ?7
              AND local_endpoint_id = ?8
              AND state_version = ?9
              AND revoked_at IS NULL
            "#,
            params![
                session.remote_endpoint_id,
                session.dh_epoch as i64,
                session.sending_chain_index as i64,
                session.receiving_chain_index as i64,
                pending.public_json,
                updated_at,
                previous.session_id,
                previous.local_endpoint_id,
                previous.state_version as i64
            ],
        );
        let changed = match changed {
            Ok(changed) => changed,
            Err(error) => {
                drop(tx);
                self.cleanup_pending_snapshot(&pending)
                    .context("secure mesh pairwise failed update snapshot cleanup is incomplete")?;
                return Err(error).context("secure mesh pairwise durable update failed");
            }
        };
        if changed != 1 {
            drop(tx);
            self.cleanup_pending_snapshot(&pending)
                .context("secure mesh pairwise rejected update snapshot cleanup is incomplete")?;
            return Err(anyhow!(
                "secure mesh pairwise durable compare-and-swap failed"
            ));
        }
        if let Some(capability_proofs) = &capability_proofs {
            if let Err(error) = consume_prepared_capability_proof_pair(&tx, capability_proofs) {
                drop(tx);
                self.cleanup_pending_snapshot(&pending).context(
                    "secure mesh pairwise failed proof update snapshot cleanup is incomplete",
                )?;
                return Err(error);
            }
        }
        if let Err(error) = tx.commit() {
            self.cleanup_pending_snapshot(&pending)
                .context("secure mesh pairwise failed commit snapshot cleanup is incomplete")?;
            return Err(error).context("secure mesh pairwise durable commit failed");
        }
        if previous_secret_handle != pending.secret_handle {
            self.delete_secret_or_enqueue_cleanup(
                &pending.secret_store_session,
                &previous_secret_handle,
            )
            .context("secure mesh pairwise superseded secret cleanup is incomplete")?;
        }
        self.read_record(&session.session_id, &session.local_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh pairwise durable record disappeared after commit"))
    }

    pub fn mark_revoked(
        &mut self,
        previous: &SecureMeshPairwiseDurableRecord,
        revoked_at: impl Into<String>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        self.retry_pending_secret_cleanup()?;
        let revoked_at = require_text(revoked_at.into(), "revoked_at")?;
        let mut previous_public = self
            .read_public_snapshot(&previous.session_id, &previous.local_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh pairwise durable previous snapshot is missing"))?;
        let previous_secret_handle = self.secret_snapshot_handle(
            &previous_public.secret_store_namespace,
            &previous_public.secret_store_key,
        )?;
        previous_public.revoked = true;
        let revoked_public_json = serde_json::to_string(&previous_public)
            .context("secure mesh pairwise revoked snapshot serialization failed")?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh pairwise durable revoke transaction failed")?;
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_pairwise_sessions
            SET revoked_at = ?1,
                state_version = state_version + 1,
                snapshot_json = ?2,
                updated_at = ?1
            WHERE session_id = ?3
              AND local_endpoint_id = ?4
              AND state_version = ?5
              AND revoked_at IS NULL
            "#,
            params![
                revoked_at,
                revoked_public_json,
                previous.session_id,
                previous.local_endpoint_id,
                previous.state_version as i64
            ],
        )?;
        ensure!(
            changed == 1,
            "secure mesh pairwise durable revoke compare-and-swap failed"
        );
        tx.commit()
            .context("secure mesh pairwise durable revoke commit failed")?;
        let revoke_session =
            self.secret_store
                .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                    "Secure Mesh pairwise durable revoke cleanup",
                    1,
                ))?;
        self.delete_secret_or_enqueue_cleanup(&revoke_session, &previous_secret_handle)
            .context("secure mesh pairwise revoked secret cleanup is incomplete")?;
        self.read_record(&previous.session_id, &previous.local_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh pairwise durable record disappeared after revoke"))
    }

    pub fn load_session(
        &self,
        session_id: &str,
        local_endpoint_id: &str,
    ) -> Result<Option<SecureMeshPairwiseSession>> {
        self.load_session_with_optional_authorization(session_id, local_endpoint_id, None)
    }

    pub fn load_session_with_authorized_session(
        &self,
        session_id: &str,
        local_endpoint_id: &str,
        secret_store_session: &SecretStoreAuthorizationSession,
    ) -> Result<Option<SecureMeshPairwiseSession>> {
        self.load_session_with_optional_authorization(
            session_id,
            local_endpoint_id,
            Some(secret_store_session),
        )
    }

    fn load_session_with_optional_authorization(
        &self,
        session_id: &str,
        local_endpoint_id: &str,
        secret_store_session: Option<&SecretStoreAuthorizationSession>,
    ) -> Result<Option<SecureMeshPairwiseSession>> {
        let snapshot_record: Option<(String, Option<String>, i64)> = self
            .connection
            .query_row(
                r#"
                SELECT snapshot_json, revoked_at, state_version
                FROM secure_mesh_pairwise_sessions
                WHERE session_id = ?1
                  AND local_endpoint_id = ?2
                "#,
                params![session_id, local_endpoint_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .context("secure mesh pairwise durable snapshot read failed")?;
        snapshot_record
            .map(|(value, revoked_at, state_version)| {
                if revoked_at.is_some() {
                    return Ok(None);
                }
                let public: PersistedPairwisePublicSession = serde_json::from_str(&value)
                    .context("secure mesh pairwise public snapshot deserialization failed")?;
                ensure!(
                    u64::try_from(state_version).ok() == Some(public.state_version)
                        && public.session_id == session_id
                        && public.local_endpoint_id == local_endpoint_id
                        && public.secret_store_namespace == self.secret_store_namespace
                        && pairwise_secret_store_key_is_bound(
                            &public.secret_store_key,
                            session_id,
                            local_endpoint_id,
                            public.state_version,
                        ),
                    "secure mesh pairwise public snapshot row binding verification failed"
                );
                let secrets = self.load_secret_snapshot(&public, secret_store_session)?;
                SecureMeshPairwiseSession::from_persisted_snapshots(public, secrets).map(Some)
            })
            .transpose()
            .map(Option::flatten)
    }

    pub fn read_record(
        &self,
        session_id: &str,
        local_endpoint_id: &str,
    ) -> Result<Option<SecureMeshPairwiseDurableRecord>> {
        self.connection
            .query_row(
                r#"
                SELECT
                    session_id,
                    local_endpoint_id,
                    remote_endpoint_id,
                    state_version,
                    dh_epoch,
                    sent_count,
                    received_count,
                    revoked_at,
                    updated_at
                FROM secure_mesh_pairwise_sessions
                WHERE session_id = ?1
                  AND local_endpoint_id = ?2
                "#,
                params![session_id, local_endpoint_id],
                |row| {
                    Ok(SecureMeshPairwiseDurableRecord {
                        session_id: row.get(0)?,
                        local_endpoint_id: row.get(1)?,
                        remote_endpoint_id: row.get(2)?,
                        state_version: row.get::<_, i64>(3)? as u64,
                        dh_epoch: row.get::<_, i64>(4)? as u64,
                        sent_count: row.get::<_, i64>(5)? as u64,
                        received_count: row.get::<_, i64>(6)? as u64,
                        revoked_at: row.get(7)?,
                        updated_at: row.get(8)?,
                    })
                },
            )
            .optional()
            .map_err(Into::into)
    }

    /// Enumerates the platform-secret-store handles referenced by this durable store.
    ///
    /// The public SQLite snapshot is untrusted input for cleanup purposes. Every handle is
    /// therefore rebound to the row identity, state version, and this store's namespace before it
    /// is returned. Callers can safely delete the returned handles in a single externally-owned
    /// authorization session and remove the disposable database only after all deletes succeed.
    pub fn referenced_secret_snapshot_handles(&self) -> Result<Vec<SecretStoreHandle>> {
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT session_id, local_endpoint_id, state_version, snapshot_json
                FROM secure_mesh_pairwise_sessions
                ORDER BY session_id, local_endpoint_id
                "#,
            )
            .context("secure mesh pairwise cleanup snapshot query prepare failed")?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .context("secure mesh pairwise cleanup snapshot query failed")?;
        let mut handles = Vec::new();
        for row in rows {
            let (session_id, local_endpoint_id, state_version, snapshot_json) =
                row.context("secure mesh pairwise cleanup snapshot row read failed")?;
            let state_version = u64::try_from(state_version)
                .context("secure mesh pairwise cleanup snapshot state version is invalid")?;
            ensure!(
                state_version > 0,
                "secure mesh pairwise cleanup snapshot state version is invalid"
            );
            let public: PersistedPairwisePublicSession = serde_json::from_str(&snapshot_json)
                .context("secure mesh pairwise cleanup public snapshot is invalid")?;
            ensure!(
                public.schema_version == PAIRWISE_SNAPSHOT_SCHEMA_VERSION,
                "secure mesh pairwise cleanup snapshot schema is unsupported"
            );
            ensure!(
                public.secret_store_class == PAIRWISE_SECRET_STORE_CLASS,
                "secure mesh pairwise cleanup secret class mismatch"
            );
            ensure!(
                public.session_id == session_id && public.local_endpoint_id == local_endpoint_id,
                "secure mesh pairwise cleanup snapshot subject mismatch"
            );
            ensure!(
                public.secret_store_namespace == self.secret_store_namespace,
                "secure mesh pairwise cleanup secret namespace mismatch"
            );
            ensure!(
                public.state_version == state_version
                    && pairwise_secret_store_key_is_bound(
                        &public.secret_store_key,
                        &session_id,
                        &local_endpoint_id,
                        state_version,
                    ),
                "secure mesh pairwise cleanup secret key mismatch"
            );
            handles.push(self.secret_snapshot_handle(
                &public.secret_store_namespace,
                &public.secret_store_key,
            )?);
        }
        handles.sort_by(|left, right| {
            left.namespace()
                .cmp(right.namespace())
                .then_with(|| left.key().cmp(right.key()))
        });
        handles.dedup();
        Ok(handles)
    }

    pub fn purge_sessions_preserving_prekey_history(&mut self) -> Result<usize> {
        self.retry_pending_secret_cleanup()?;
        let handles = self.referenced_secret_snapshot_handles()?;
        if !handles.is_empty() {
            let authorization = self.secret_store.begin_authorized_session(
                &SecretStoreAuthorizationRequest::new(
                    "Secure Mesh pairwise session purge",
                    handles.len(),
                ),
            )?;
            for handle in &handles {
                self.secret_store
                    .delete_secret_with_session(&authorization, handle)
                    .context("secure mesh pairwise session secret purge failed")?;
            }
        }
        let tx = self
            .connection
            .transaction()
            .context("secure mesh pairwise session purge transaction failed")?;
        let deleted = tx
            .execute("DELETE FROM secure_mesh_pairwise_sessions", [])
            .context("secure mesh pairwise session purge failed")?;
        tx.commit()
            .context("secure mesh pairwise session purge commit failed")?;
        Ok(deleted)
    }

    fn read_public_snapshot(
        &self,
        session_id: &str,
        local_endpoint_id: &str,
    ) -> Result<Option<PersistedPairwisePublicSession>> {
        let record = self
            .connection
            .query_row(
                r#"
                SELECT snapshot_json, state_version
                FROM secure_mesh_pairwise_sessions
                WHERE session_id = ?1
                  AND local_endpoint_id = ?2
                "#,
                params![session_id, local_endpoint_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()
            .context("secure mesh pairwise public snapshot read failed")?;
        record
            .map(|(snapshot_json, state_version)| {
                let public: PersistedPairwisePublicSession =
                    serde_json::from_str(&snapshot_json)
                        .context("secure mesh pairwise public snapshot deserialization failed")?;
                ensure!(
                    u64::try_from(state_version).ok() == Some(public.state_version)
                        && public.session_id == session_id
                        && public.local_endpoint_id == local_endpoint_id
                        && public.secret_store_namespace == self.secret_store_namespace
                        && pairwise_secret_store_key_is_bound(
                            &public.secret_store_key,
                            session_id,
                            local_endpoint_id,
                            public.state_version,
                        ),
                    "secure mesh pairwise public snapshot row binding verification failed"
                );
                Ok(public)
            })
            .transpose()
    }

    fn prepare_secret_bound_snapshot(
        &self,
        session: &SecureMeshPairwiseSession,
        state_version: u64,
    ) -> Result<PendingPairwiseSnapshot> {
        self.prepare_secret_bound_snapshot_with_optional_authorization(session, state_version, None)
    }

    fn prepare_secret_bound_snapshot_with_optional_authorization(
        &self,
        session: &SecureMeshPairwiseSession,
        state_version: u64,
        secret_store_session: Option<&SecretStoreAuthorizationSession>,
    ) -> Result<PendingPairwiseSnapshot> {
        self.retry_pending_secret_cleanup()?;
        let secret_store_key = pairwise_secret_store_key(
            &session.session_id,
            &session.local_endpoint_id,
            state_version,
        );
        let public = session.to_public_snapshot(
            state_version,
            self.secret_store_namespace.clone(),
            secret_store_key.clone(),
        );
        let public_json = serde_json::to_string(&public)
            .context("secure mesh pairwise public snapshot serialization failed")?;
        let secrets =
            session.to_secret_snapshot(state_version, sha256_hex(public_json.as_bytes()))?;
        let secret_json = Zeroizing::new(
            serde_json::to_string(&secrets)
                .context("secure mesh pairwise secret snapshot serialization failed")?,
        );
        ensure!(
            secret_json.len() <= MAX_PERSISTED_SECRET_SNAPSHOT_BYTES,
            "secure mesh pairwise secret snapshot exceeds the resource limit"
        );
        let secret_handle =
            self.secret_snapshot_handle(&public.secret_store_namespace, &public.secret_store_key)?;
        let secret_store_session = match secret_store_session {
            Some(session) => session.clone(),
            None => self.secret_store.begin_authorized_session(
                &SecretStoreAuthorizationRequest::new(
                    "Secure Mesh pairwise durable snapshot commit",
                    2,
                ),
            )?,
        };
        self.secret_store
            .set_secret_with_session(&secret_store_session, &secret_handle, secret_json.as_str())
            .context("secure mesh pairwise secret snapshot write failed")?;
        Ok(PendingPairwiseSnapshot {
            public_json,
            secret_handle,
            secret_store_session,
        })
    }

    fn load_secret_snapshot(
        &self,
        public: &PersistedPairwisePublicSession,
        secret_store_session: Option<&SecretStoreAuthorizationSession>,
    ) -> Result<PersistedPairwiseSessionSecrets> {
        let secret_handle =
            self.secret_snapshot_handle(&public.secret_store_namespace, &public.secret_store_key)?;
        let secret_store_session = match secret_store_session {
            Some(session) => session.clone(),
            None => self.secret_store.begin_authorized_session(
                &SecretStoreAuthorizationRequest::new(
                    "Secure Mesh pairwise durable snapshot load",
                    1,
                ),
            )?,
        };
        let secret_json = Zeroizing::new(
            self.secret_store
                .get_secret_with_session(&secret_store_session, &secret_handle)
                .context("secure mesh pairwise secret snapshot read failed")?
                .ok_or_else(|| anyhow!("secure mesh pairwise secret snapshot is unavailable"))?,
        );
        ensure!(
            secret_json.len() <= MAX_PERSISTED_SECRET_SNAPSHOT_BYTES,
            "secure mesh pairwise secret snapshot exceeds the resource limit"
        );
        let secrets: PersistedPairwiseSessionSecrets =
            serde_json::from_str(secret_json.as_str())
                .context("secure mesh pairwise secret snapshot deserialization failed")?;
        let public_json = serde_json::to_string(public)
            .context("secure mesh pairwise public snapshot binding serialization failed")?;
        ensure!(
            secrets.schema_version == PAIRWISE_SNAPSHOT_SCHEMA_VERSION
                && secrets.state_version == public.state_version
                && secrets.session_id == public.session_id
                && secrets.local_endpoint_id == public.local_endpoint_id
                && secrets.remote_endpoint_id == public.remote_endpoint_id
                && secrets.public_snapshot_digest == sha256_hex(public_json.as_bytes()),
            "secure mesh pairwise secret snapshot binding verification failed"
        );
        Ok(secrets)
    }

    fn secret_snapshot_handle(&self, namespace: &str, key: &str) -> Result<SecretStoreHandle> {
        SecretStoreHandle::new(namespace.to_string(), key.to_string())
    }

    fn enqueue_secret_cleanup(&self, handle: &SecretStoreHandle) -> Result<()> {
        self.connection
            .execute(
                r#"
                INSERT INTO secure_mesh_pairwise_secret_cleanup (
                    secret_store_namespace,
                    secret_store_key,
                    attempt_count
                ) VALUES (?1, ?2, 1)
                ON CONFLICT(secret_store_namespace, secret_store_key) DO UPDATE SET
                    attempt_count = CASE
                        WHEN attempt_count < 9223372036854775807
                        THEN attempt_count + 1
                        ELSE attempt_count
                    END
                "#,
                params![handle.namespace(), handle.key()],
            )
            .context("secure mesh pairwise secret cleanup retry enqueue failed")?;
        Ok(())
    }

    fn delete_secret_or_enqueue_cleanup(
        &self,
        authorization: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
    ) -> Result<()> {
        match self
            .secret_store
            .delete_secret_with_session(authorization, handle)
        {
            Ok(()) => {
                self.connection
                    .execute(
                        r#"
                        DELETE FROM secure_mesh_pairwise_secret_cleanup
                        WHERE secret_store_namespace = ?1
                          AND secret_store_key = ?2
                        "#,
                        params![handle.namespace(), handle.key()],
                    )
                    .context("secure mesh pairwise secret cleanup retry dequeue failed")?;
                Ok(())
            }
            Err(_) => {
                self.enqueue_secret_cleanup(handle)?;
                Err(anyhow!(
                    "secure mesh pairwise secret deletion is pending a bounded retry"
                ))
            }
        }
    }

    fn cleanup_pending_snapshot(&self, pending: &PendingPairwiseSnapshot) -> Result<()> {
        self.delete_secret_or_enqueue_cleanup(&pending.secret_store_session, &pending.secret_handle)
    }

    pub fn retry_pending_secret_cleanup(&self) -> Result<usize> {
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT secret_store_namespace, secret_store_key
                FROM secure_mesh_pairwise_secret_cleanup
                ORDER BY secret_store_namespace, secret_store_key
                "#,
            )
            .context("secure mesh pairwise secret cleanup retry query prepare failed")?;
        let handles = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .context("secure mesh pairwise secret cleanup retry query failed")?
            .map(|row| {
                let (namespace, key) =
                    row.context("secure mesh pairwise secret cleanup retry row read failed")?;
                self.secret_snapshot_handle(&namespace, &key)
            })
            .collect::<Result<Vec<_>>>()?;
        drop(statement);
        if handles.is_empty() {
            return Ok(0);
        }
        let authorization =
            self.secret_store
                .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                    "Secure Mesh pairwise pending secret cleanup retry",
                    handles.len(),
                ))?;
        let mut deleted = 0usize;
        let mut pending = false;
        for handle in handles {
            match self.delete_secret_or_enqueue_cleanup(&authorization, &handle) {
                Ok(()) => deleted += 1,
                Err(_) => pending = true,
            }
        }
        ensure!(
            !pending,
            "secure mesh pairwise secret cleanup remains pending"
        );
        Ok(deleted)
    }

    #[cfg(test)]
    fn pending_secret_cleanup_count(&self) -> Result<usize> {
        let count: i64 = self.connection.query_row(
            "SELECT COUNT(*) FROM secure_mesh_pairwise_secret_cleanup",
            [],
            |row| row.get(0),
        )?;
        usize::try_from(count)
            .map_err(|_| anyhow!("secure mesh pairwise secret cleanup count is invalid"))
    }

    fn initialize(&self) -> Result<()> {
        self.connection
            .execute_batch("PRAGMA secure_delete = ON;")
            .context("secure mesh pairwise secure-delete enable failed")?;
        let schema_version: u32 = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .context("secure mesh pairwise schema version read failed")?;
        let session_table_exists: bool = self
            .connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'secure_mesh_pairwise_sessions')",
                [],
                |row| row.get(0),
            )
            .context("secure mesh pairwise schema existence check failed")?;
        let incompatible_schema =
            session_table_exists && schema_version != PAIRWISE_SNAPSHOT_SCHEMA_VERSION;
        if incompatible_schema {
            self.remove_incompatible_schema_secrets()?;
            self.connection
                .execute_batch(
                    r#"
                    DELETE FROM secure_mesh_pairwise_sessions;
                    DROP TABLE IF EXISTS secure_mesh_pairwise_sessions;
                    "#,
                )
                .context("secure mesh pairwise incompatible schema removal failed")?;
        }
        self.connection.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS secure_mesh_pairwise_sessions (
                session_id TEXT NOT NULL,
                local_endpoint_id TEXT NOT NULL,
                remote_endpoint_id TEXT NOT NULL,
                state_version INTEGER NOT NULL,
                dh_epoch INTEGER NOT NULL,
                sent_count INTEGER NOT NULL,
                received_count INTEGER NOT NULL,
                revoked_at TEXT,
                snapshot_json TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (session_id, local_endpoint_id)
            );
            CREATE INDEX IF NOT EXISTS secure_mesh_pairwise_sessions_remote_idx
                ON secure_mesh_pairwise_sessions(remote_endpoint_id, dh_epoch, state_version);
            CREATE TABLE IF NOT EXISTS secure_mesh_pairwise_remote_prekey_uses (
                remote_endpoint_id TEXT NOT NULL,
                remote_identity_fingerprint TEXT NOT NULL,
                signed_prekey_id TEXT NOT NULL,
                one_time_prekey_id TEXT NOT NULL,
                one_time_prekey_public_key_hash TEXT NOT NULL,
                one_time_mlkem1024_prekey_id TEXT NOT NULL,
                one_time_mlkem1024_prekey_public_key_hash TEXT NOT NULL,
                directory_authorization_digest TEXT NOT NULL,
                session_id TEXT NOT NULL,
                local_endpoint_id TEXT NOT NULL,
                used_at TEXT NOT NULL,
                PRIMARY KEY (
                    remote_endpoint_id,
                    remote_identity_fingerprint,
                    one_time_prekey_id,
                    one_time_prekey_public_key_hash
                ),
                UNIQUE (
                    remote_endpoint_id,
                    remote_identity_fingerprint,
                    one_time_prekey_id
                ),
                UNIQUE (
                    remote_endpoint_id,
                    remote_identity_fingerprint,
                    one_time_prekey_public_key_hash
                ),
                UNIQUE (
                    remote_endpoint_id,
                    remote_identity_fingerprint,
                    one_time_mlkem1024_prekey_id
                ),
                UNIQUE (
                    remote_endpoint_id,
                    remote_identity_fingerprint,
                    one_time_mlkem1024_prekey_public_key_hash
                )
            );
            CREATE INDEX IF NOT EXISTS secure_mesh_pairwise_remote_prekey_uses_local_idx
                ON secure_mesh_pairwise_remote_prekey_uses(local_endpoint_id, session_id);
            CREATE TABLE IF NOT EXISTS secure_mesh_pairwise_local_prekey_uses (
                local_endpoint_id TEXT NOT NULL,
                local_identity_fingerprint TEXT NOT NULL,
                one_time_prekey_id TEXT NOT NULL,
                one_time_prekey_public_key_hash TEXT NOT NULL,
                one_time_mlkem1024_prekey_id TEXT NOT NULL,
                one_time_mlkem1024_prekey_public_key_hash TEXT NOT NULL,
                session_id TEXT NOT NULL,
                used_at TEXT NOT NULL,
                PRIMARY KEY (
                    local_endpoint_id,
                    local_identity_fingerprint,
                    one_time_prekey_id,
                    one_time_prekey_public_key_hash
                ),
                UNIQUE (
                    local_endpoint_id,
                    local_identity_fingerprint,
                    one_time_prekey_id
                ),
                UNIQUE (
                    local_endpoint_id,
                    local_identity_fingerprint,
                    one_time_prekey_public_key_hash
                ),
                UNIQUE (
                    local_endpoint_id,
                    local_identity_fingerprint,
                    one_time_mlkem1024_prekey_id
                ),
                UNIQUE (
                    local_endpoint_id,
                    local_identity_fingerprint,
                    one_time_mlkem1024_prekey_public_key_hash
                )
            );
            CREATE INDEX IF NOT EXISTS secure_mesh_pairwise_local_prekey_uses_session_idx
                ON secure_mesh_pairwise_local_prekey_uses(session_id, local_endpoint_id);
            CREATE TABLE IF NOT EXISTS secure_mesh_pairwise_capability_proof_uses (
                local_endpoint_scope_hash TEXT NOT NULL,
                proof_digest TEXT NOT NULL,
                expires_at_unix_seconds INTEGER NOT NULL,
                consumed_at_unix_seconds INTEGER NOT NULL,
                PRIMARY KEY (local_endpoint_scope_hash, proof_digest)
            );
            CREATE INDEX IF NOT EXISTS secure_mesh_pairwise_capability_proof_expiry_idx
                ON secure_mesh_pairwise_capability_proof_uses(expires_at_unix_seconds);
            CREATE TABLE IF NOT EXISTS secure_mesh_pairwise_secret_cleanup (
                secret_store_namespace TEXT NOT NULL,
                secret_store_key TEXT NOT NULL,
                attempt_count INTEGER NOT NULL CHECK (attempt_count > 0),
                PRIMARY KEY (secret_store_namespace, secret_store_key)
            );
            CREATE TABLE IF NOT EXISTS secure_mesh_pairwise_time_guard (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                max_observed_unix_seconds INTEGER NOT NULL CHECK (
                    max_observed_unix_seconds >= 0
                )
            );
            INSERT OR IGNORE INTO secure_mesh_pairwise_time_guard (
                singleton,
                max_observed_unix_seconds
            ) VALUES (1, 0);
            PRAGMA user_version = 10;
            "#,
        )?;
        if incompatible_schema {
            self.connection
                .execute_batch("VACUUM;")
                .context("secure mesh pairwise incompatible schema secure purge failed")?;
        }
        Ok(())
    }

    fn remove_incompatible_schema_secrets(&self) -> Result<()> {
        let mut statement = self
            .connection
            .prepare("SELECT snapshot_json FROM secure_mesh_pairwise_sessions")
            .context("secure mesh pairwise incompatible snapshot query prepare failed")?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .context("secure mesh pairwise incompatible snapshot query failed")?;
        let mut handles = Vec::new();
        for row in rows {
            let Ok(snapshot_json) = row else {
                continue;
            };
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&snapshot_json) else {
                continue;
            };
            let namespace = value
                .get("secret_store_namespace")
                .and_then(serde_json::Value::as_str);
            let key = value
                .get("secret_store_key")
                .and_then(serde_json::Value::as_str);
            if let (Some(namespace), Some(key)) = (namespace, key) {
                if namespace == self.secret_store_namespace {
                    if let Ok(handle) = self.secret_snapshot_handle(namespace, key) {
                        handles.push(handle);
                    }
                }
            }
        }
        if handles.is_empty() {
            return Ok(());
        }
        let authorization =
            self.secret_store
                .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                    "Secure Mesh incompatible pairwise session removal",
                    handles.len(),
                ))?;
        for handle in handles {
            self.secret_store
                .delete_secret_with_session(&authorization, &handle)
                .context("secure mesh pairwise incompatible secret removal failed")?;
        }
        Ok(())
    }
}

struct PendingPairwiseSnapshot {
    public_json: String,
    secret_handle: SecretStoreHandle,
    secret_store_session: SecretStoreAuthorizationSession,
}

#[derive(Clone, Serialize, Deserialize)]
struct PersistedPairwisePublicSession {
    schema_version: u32,
    state_version: u64,
    secret_store_class: String,
    secret_store_namespace: String,
    secret_store_key: String,
    session_id: String,
    local_endpoint_id: String,
    remote_endpoint_id: String,
    role: String,
    local_ratchet_public_key: String,
    remote_ratchet_public_key: String,
    handshake_transcript_hash: String,
    dh_epoch: u64,
    receiving_ratchet_epoch: u64,
    sending_chain_index: u64,
    receiving_chain_index: u64,
    previous_chain_length: u64,
    skipped_keys: Vec<PersistedSkippedMessageKeyPublic>,
    received_message_ids: Vec<String>,
    #[serde(default)]
    pending_sending_ratchet: bool,
    initiator_key_confirmed: bool,
    local_capability_proof: SignedCapabilityProof,
    capability_binding: Option<NegotiatedCapabilityBinding>,
    capability_projection: Option<ClientCapabilityProjection>,
    revoked: bool,
}

#[derive(Serialize, Deserialize)]
struct PersistedPairwiseSessionSecrets {
    schema_version: u32,
    state_version: u64,
    session_id: String,
    local_endpoint_id: String,
    remote_endpoint_id: String,
    public_snapshot_digest: String,
    root_key: PairwiseSecretString,
    sending_chain_key: PairwiseSecretString,
    receiving_chain_key: PairwiseSecretString,
    sending_header_key: PairwiseSecretString,
    receiving_header_key: PairwiseSecretString,
    next_sending_header_key: PairwiseSecretString,
    next_receiving_header_key: PairwiseSecretString,
    skipped_receiving_header_keys: Vec<PairwiseSecretString>,
    local_ratchet_secret: PairwiseSecretString,
    sparse_pq_ratchet: PairwiseSecretString,
    skipped_keys: Vec<PersistedSkippedMessageKeySecret>,
}

#[derive(Serialize, Deserialize)]
#[serde(transparent)]
struct PairwiseSecretString(String);

impl PairwiseSecretString {
    fn new(value: String) -> Self {
        Self(value)
    }

    fn as_str(&self) -> &str {
        &self.0
    }
}

impl Drop for PairwiseSecretString {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct PersistedSkippedMessageKeyPublic {
    message_id: String,
    dh_epoch: u64,
    chain_index: u64,
    sender_ratchet_public_key: String,
}

#[derive(Serialize, Deserialize)]
struct PersistedSkippedMessageKeySecret {
    message_key: PairwiseSecretString,
}

impl From<&SkippedMessageKey> for PersistedSkippedMessageKeyPublic {
    fn from(value: &SkippedMessageKey) -> Self {
        Self {
            message_id: value.message_id.clone(),
            dh_epoch: value.dh_epoch,
            chain_index: value.chain_index,
            sender_ratchet_public_key: encode_secret(&value.sender_ratchet_public_key),
        }
    }
}

impl From<&SkippedMessageKey> for PersistedSkippedMessageKeySecret {
    fn from(value: &SkippedMessageKey) -> Self {
        Self {
            message_key: PairwiseSecretString::new(encode_secret(&value.message_key)),
        }
    }
}

impl
    TryFrom<(
        PersistedSkippedMessageKeyPublic,
        &PersistedSkippedMessageKeySecret,
    )> for SkippedMessageKey
{
    type Error = anyhow::Error;

    fn try_from(
        value: (
            PersistedSkippedMessageKeyPublic,
            &PersistedSkippedMessageKeySecret,
        ),
    ) -> Result<Self> {
        let (public, secret) = value;
        Ok(Self {
            message_id: public.message_id,
            dh_epoch: public.dh_epoch,
            chain_index: public.chain_index,
            sender_ratchet_public_key: decode_secret_32(&public.sender_ratchet_public_key)?,
            message_key: Zeroizing::new(decode_secret_32(secret.message_key.as_str())?),
        })
    }
}

struct InitialPairwiseKeys {
    root_key: [u8; ROOT_KEY_LEN],
    initiator_chain_key: [u8; CHAIN_KEY_LEN],
    responder_chain_key: [u8; CHAIN_KEY_LEN],
    initiator_header_key: [u8; HEADER_KEY_LEN],
    responder_header_key: [u8; HEADER_KEY_LEN],
    initiator_next_header_key: [u8; HEADER_KEY_LEN],
    responder_next_header_key: [u8; HEADER_KEY_LEN],
}

fn derive_pqxdh_classical_initiator_secret(
    local_identity: &DeviceTrustPublicIdentity,
    local_identity_secret: &SecureMeshPairwisePrivateKey,
    local_ephemeral: &SecureMeshPairwisePrivateKey,
    remote_bundle: &SecureMeshPairwisePreKeyBundle,
) -> Result<Zeroizing<Vec<u8>>> {
    let dh1 = local_identity_secret.diffie_hellman(&remote_bundle.signed_prekey.public_key)?;
    let dh2 =
        local_ephemeral.diffie_hellman(&remote_bundle.endpoint_identity.identity_public_key)?;
    let dh3 = local_ephemeral.diffie_hellman(&remote_bundle.signed_prekey.public_key)?;
    let dh4 = remote_bundle
        .one_time_prekey
        .as_ref()
        .map(|record| local_ephemeral.diffie_hellman(&record.public_key))
        .transpose()?;
    collect_pqxdh_classical_secret(
        &local_identity.endpoint_id,
        &remote_bundle.endpoint_identity.endpoint_id,
        &dh1,
        &dh2,
        &dh3,
        dh4.as_ref().map(|value| &**value),
    )
}

fn derive_pqxdh_classical_responder_secret(
    local_identity_secret: &SecureMeshPairwisePrivateKey,
    local_signed_prekey_secret: &SecureMeshPairwisePrivateKey,
    local_one_time_prekey_secret: Option<&SecureMeshPairwisePrivateKey>,
    intro: &SecureMeshPairwiseSessionIntro,
) -> Result<Zeroizing<Vec<u8>>> {
    let dh1 = local_signed_prekey_secret.diffie_hellman(&intro.initiator_identity_public_key)?;
    let dh2 = local_identity_secret.diffie_hellman(&intro.initiator_ephemeral_public_key)?;
    let dh3 = local_signed_prekey_secret.diffie_hellman(&intro.initiator_ephemeral_public_key)?;
    let dh4 = match (
        &intro.responder_one_time_prekey_id,
        local_one_time_prekey_secret,
    ) {
        (Some(_), Some(secret)) => {
            Some(secret.diffie_hellman(&intro.initiator_ephemeral_public_key)?)
        }
        (Some(_), None) => {
            return Err(anyhow!(
                "secure mesh pairwise one-time prekey secret is required"
            ));
        }
        (None, _) => None,
    };
    collect_pqxdh_classical_secret(
        &intro.initiator_endpoint_id,
        &intro.responder_endpoint_id,
        &dh1,
        &dh2,
        &dh3,
        dh4.as_ref().map(|value| &**value),
    )
}

fn collect_pqxdh_classical_secret(
    initiator_endpoint_id: &str,
    responder_endpoint_id: &str,
    dh1: &[u8; PUBLIC_KEY_LEN],
    dh2: &[u8; PUBLIC_KEY_LEN],
    dh3: &[u8; PUBLIC_KEY_LEN],
    dh4: Option<&[u8; PUBLIC_KEY_LEN]>,
) -> Result<Zeroizing<Vec<u8>>> {
    let mut secret = Zeroizing::new(Vec::new());
    secret.extend_from_slice(SECRET_DOMAIN);
    append_len_prefixed_bytes(secret.as_mut(), initiator_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(secret.as_mut(), responder_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(secret.as_mut(), dh1)?;
    append_len_prefixed_bytes(secret.as_mut(), dh2)?;
    append_len_prefixed_bytes(secret.as_mut(), dh3)?;
    if let Some(dh4) = dh4 {
        append_len_prefixed_bytes(secret.as_mut(), dh4)?;
    }
    Ok(secret)
}

fn derive_initial_keys(
    shared_secret: &[u8],
    session_id: &str,
    initiator_endpoint_id: &str,
    responder_endpoint_id: &str,
) -> Result<InitialPairwiseKeys> {
    let mut salt_hasher = Sha256::new();
    salt_hasher.update(PQXDH_CLASSICAL_SALT_DOMAIN);
    salt_hasher.update(session_id.as_bytes());
    let salt = salt_hasher.finalize();
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), shared_secret);
    let mut info = Vec::new();
    info.extend_from_slice(PQXDH_CLASSICAL_INFO_DOMAIN);
    append_len_prefixed_bytes(&mut info, SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut info, initiator_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut info, responder_endpoint_id.as_bytes())?;
    let mut out = [0u8; ROOT_KEY_LEN + (2 * CHAIN_KEY_LEN) + (4 * HEADER_KEY_LEN)];
    hkdf.expand(&info, &mut out)
        .map_err(|_| anyhow!("secure mesh pairwise initial key derivation failed"))?;
    let mut root_key = [0u8; ROOT_KEY_LEN];
    let mut initiator_chain_key = [0u8; CHAIN_KEY_LEN];
    let mut responder_chain_key = [0u8; CHAIN_KEY_LEN];
    let mut initiator_header_key = [0u8; HEADER_KEY_LEN];
    let mut responder_header_key = [0u8; HEADER_KEY_LEN];
    let mut initiator_next_header_key = [0u8; HEADER_KEY_LEN];
    let mut responder_next_header_key = [0u8; HEADER_KEY_LEN];
    root_key.copy_from_slice(&out[0..ROOT_KEY_LEN]);
    initiator_chain_key.copy_from_slice(&out[ROOT_KEY_LEN..ROOT_KEY_LEN + CHAIN_KEY_LEN]);
    let mut offset = ROOT_KEY_LEN + CHAIN_KEY_LEN;
    responder_chain_key.copy_from_slice(&out[offset..offset + CHAIN_KEY_LEN]);
    offset += CHAIN_KEY_LEN;
    initiator_header_key.copy_from_slice(&out[offset..offset + HEADER_KEY_LEN]);
    offset += HEADER_KEY_LEN;
    responder_header_key.copy_from_slice(&out[offset..offset + HEADER_KEY_LEN]);
    offset += HEADER_KEY_LEN;
    initiator_next_header_key.copy_from_slice(&out[offset..offset + HEADER_KEY_LEN]);
    offset += HEADER_KEY_LEN;
    responder_next_header_key.copy_from_slice(&out[offset..offset + HEADER_KEY_LEN]);
    out.zeroize();
    Ok(InitialPairwiseKeys {
        root_key,
        initiator_chain_key,
        responder_chain_key,
        initiator_header_key,
        responder_header_key,
        initiator_next_header_key,
        responder_next_header_key,
    })
}

fn derive_capability_bound_initial_keys(
    initial_root_key: &[u8; ROOT_KEY_LEN],
    capability_transcript_digest: &str,
    session_id: &str,
    initiator_endpoint_id: &str,
    responder_endpoint_id: &str,
) -> Result<InitialPairwiseKeys> {
    let capability_digest = crate::core::secure_mesh_capability_proof::decode_sha256_digest(
        capability_transcript_digest,
        "capability-bound key schedule transcript digest",
    )?;
    let mut salt = Sha256::new();
    salt.update(CAPABILITY_BOUND_KEY_SCHEDULE_MAGIC);
    salt.update(capability_digest);
    let hkdf = Hkdf::<Sha256>::new(Some(&salt.finalize()), initial_root_key);
    let mut info = Vec::new();
    append_len_prefixed_bytes(&mut info, SECURE_MESH_PROTOCOL_VERSION.as_bytes())?;
    append_len_prefixed_bytes(&mut info, SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut info, session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut info, initiator_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut info, responder_endpoint_id.as_bytes())?;
    let mut out = [0u8; ROOT_KEY_LEN + (2 * CHAIN_KEY_LEN) + (4 * HEADER_KEY_LEN)];
    hkdf.expand(&info, &mut out)
        .map_err(|_| anyhow!("secure mesh pairwise capability-bound key derivation failed"))?;
    let mut root_key = [0u8; ROOT_KEY_LEN];
    let mut initiator_chain_key = [0u8; CHAIN_KEY_LEN];
    let mut responder_chain_key = [0u8; CHAIN_KEY_LEN];
    let mut initiator_header_key = [0u8; HEADER_KEY_LEN];
    let mut responder_header_key = [0u8; HEADER_KEY_LEN];
    let mut initiator_next_header_key = [0u8; HEADER_KEY_LEN];
    let mut responder_next_header_key = [0u8; HEADER_KEY_LEN];
    let mut offset = 0;
    root_key.copy_from_slice(&out[offset..offset + ROOT_KEY_LEN]);
    offset += ROOT_KEY_LEN;
    initiator_chain_key.copy_from_slice(&out[offset..offset + CHAIN_KEY_LEN]);
    offset += CHAIN_KEY_LEN;
    responder_chain_key.copy_from_slice(&out[offset..offset + CHAIN_KEY_LEN]);
    offset += CHAIN_KEY_LEN;
    initiator_header_key.copy_from_slice(&out[offset..offset + HEADER_KEY_LEN]);
    offset += HEADER_KEY_LEN;
    responder_header_key.copy_from_slice(&out[offset..offset + HEADER_KEY_LEN]);
    offset += HEADER_KEY_LEN;
    initiator_next_header_key.copy_from_slice(&out[offset..offset + HEADER_KEY_LEN]);
    offset += HEADER_KEY_LEN;
    responder_next_header_key.copy_from_slice(&out[offset..offset + HEADER_KEY_LEN]);
    out.zeroize();
    Ok(InitialPairwiseKeys {
        root_key,
        initiator_chain_key,
        responder_chain_key,
        initiator_header_key,
        responder_header_key,
        initiator_next_header_key,
        responder_next_header_key,
    })
}

fn derive_ratchet_root(
    root_key: &[u8; ROOT_KEY_LEN],
    dh_secret: &[u8; PUBLIC_KEY_LEN],
    dh_epoch: u64,
) -> Result<(
    [u8; ROOT_KEY_LEN],
    [u8; CHAIN_KEY_LEN],
    [u8; HEADER_KEY_LEN],
)> {
    let mut salt_hasher = Sha256::new();
    salt_hasher.update(ROOT_INFO_DOMAIN);
    salt_hasher.update(root_key);
    salt_hasher.update(dh_epoch.to_be_bytes());
    let salt = salt_hasher.finalize();
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), dh_secret);
    let mut info = Vec::new();
    append_len_prefixed_bytes(&mut info, SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut info, b"dh-ratchet")?;
    let mut out = [0u8; ROOT_KEY_LEN + CHAIN_KEY_LEN + HEADER_KEY_LEN];
    hkdf.expand(&info, &mut out)
        .map_err(|_| anyhow!("secure mesh pairwise root ratchet failed"))?;
    let mut new_root = [0u8; ROOT_KEY_LEN];
    let mut chain_key = [0u8; CHAIN_KEY_LEN];
    let mut next_header_key = [0u8; HEADER_KEY_LEN];
    new_root.copy_from_slice(&out[0..ROOT_KEY_LEN]);
    chain_key.copy_from_slice(&out[ROOT_KEY_LEN..ROOT_KEY_LEN + CHAIN_KEY_LEN]);
    next_header_key.copy_from_slice(&out[ROOT_KEY_LEN + CHAIN_KEY_LEN..]);
    out.zeroize();
    Ok((new_root, chain_key, next_header_key))
}

fn advance_chain(
    chain_key: &[u8; CHAIN_KEY_LEN],
    dh_epoch: u64,
    chain_index: u64,
    label: &str,
) -> Result<(
    Zeroizing<[u8; CHAIN_KEY_LEN]>,
    Zeroizing<[u8; MESSAGE_KEY_LEN]>,
)> {
    let mut salt_hasher = Sha256::new();
    salt_hasher.update(CHAIN_INFO_DOMAIN);
    salt_hasher.update(chain_key);
    salt_hasher.update(dh_epoch.to_be_bytes());
    salt_hasher.update(chain_index.to_be_bytes());
    let salt = salt_hasher.finalize();
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), chain_key);
    let mut info = Vec::new();
    append_len_prefixed_bytes(&mut info, SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut info, label.as_bytes())?;
    let mut out = [0u8; CHAIN_KEY_LEN + MESSAGE_KEY_LEN];
    hkdf.expand(&info, &mut out)
        .map_err(|_| anyhow!("secure mesh pairwise chain advance failed"))?;
    let mut next_chain_key = [0u8; CHAIN_KEY_LEN];
    let mut message_key = [0u8; MESSAGE_KEY_LEN];
    next_chain_key.copy_from_slice(&out[0..CHAIN_KEY_LEN]);
    message_key.copy_from_slice(&out[CHAIN_KEY_LEN..]);
    out.zeroize();
    Ok((Zeroizing::new(next_chain_key), Zeroizing::new(message_key)))
}

fn replay_window_preserved(
    previous_ids: &[String],
    current_ids: &[String],
    received_advance: u64,
) -> bool {
    let received_advance = usize::try_from(received_advance).unwrap_or(usize::MAX);
    let retained_count = previous_ids.len().saturating_sub(received_advance);
    if retained_count == 0 {
        return true;
    }
    previous_ids[previous_ids.len() - retained_count..]
        .iter()
        .all(|id| current_ids.iter().any(|candidate| candidate == id))
}

fn skipped_keys_not_reintroduced(
    previous_skipped: &[PersistedSkippedMessageKeyPublic],
    session: &SecureMeshPairwiseSession,
    previous: &SecureMeshPairwiseDurableRecord,
) -> bool {
    if session.dh_epoch > previous.dh_epoch
        || session.receiving_chain_index > previous.received_count
    {
        return true;
    }
    session.skipped_keys.iter().all(|skipped| {
        previous_skipped.iter().any(|previous| {
            previous.dh_epoch == skipped.dh_epoch
                && previous.chain_index == skipped.chain_index
                && decode_secret_32(&previous.sender_ratchet_public_key)
                    .map(|key| key == skipped.sender_ratchet_public_key)
                    .unwrap_or(false)
        })
    })
}

fn ensure_local_identity_key_material(
    identity: &DeviceTrustPublicIdentity,
    identity_secret: &SecureMeshPairwisePrivateKey,
    signing_key: &SigningKey,
) -> Result<()> {
    ensure!(
        identity_secret.public_key() == identity.identity_public_key,
        "secure mesh pairwise identity secret does not match public identity"
    );
    ensure!(
        signing_key.verifying_key().to_bytes() == identity.signing_public_key,
        "secure mesh pairwise signing secret does not match public identity"
    );
    Ok(())
}

fn intro_signature_payload(intro: &SecureMeshPairwiseSessionIntro) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(INTRO_SIGNATURE_MAGIC);
    append_len_prefixed_bytes(&mut out, intro.protocol_version.as_bytes())?;
    append_len_prefixed_bytes(&mut out, intro.cipher_suite.as_bytes())?;
    append_len_prefixed_bytes(&mut out, intro.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, intro.initiator_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, intro.responder_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, &intro.initiator_identity_public_key)?;
    append_len_prefixed_bytes(&mut out, &intro.initiator_ephemeral_public_key)?;
    append_len_prefixed_bytes(&mut out, &intro.initiator_initial_ratchet_public_key)?;
    append_len_prefixed_bytes(&mut out, intro.responder_signed_prekey_id.as_bytes())?;
    match &intro.responder_one_time_prekey_id {
        Some(prekey_id) => {
            out.push(1);
            append_len_prefixed_bytes(&mut out, prekey_id.as_bytes())?;
        }
        None => out.push(0),
    }
    append_len_prefixed_bytes(
        &mut out,
        intro.responder_one_time_mlkem1024_prekey_id.as_bytes(),
    )?;
    append_len_prefixed_bytes(&mut out, &intro.mlkem1024_ciphertext)?;
    append_len_prefixed_bytes(&mut out, intro.directory_authorization_digest.as_bytes())?;
    append_len_prefixed_bytes(
        &mut out,
        &encode_signed_capability_proof_json(&intro.initiator_capability_proof)?,
    )?;
    Ok(out)
}

fn accept_signature_payload(accepted: &SecureMeshPairwiseSessionAccepted) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(ACCEPT_SIGNATURE_MAGIC);
    append_len_prefixed_bytes(&mut out, accepted.protocol_version.as_bytes())?;
    append_len_prefixed_bytes(&mut out, accepted.cipher_suite.as_bytes())?;
    append_len_prefixed_bytes(&mut out, accepted.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, accepted.responder_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, &accepted.responder_initial_ratchet_public_key)?;
    append_len_prefixed_bytes(&mut out, accepted.handshake_transcript_hash.as_bytes())?;
    append_len_prefixed_bytes(
        &mut out,
        &encode_signed_capability_proof_json(&accepted.responder_capability_proof)?,
    )?;
    append_len_prefixed_bytes(
        &mut out,
        &serde_json::to_vec(&accepted.capability_binding)
            .context("secure mesh pairwise capability binding serialization failed")?,
    )?;
    Ok(out)
}

fn sign_pairwise_transcript(signing_key: &SigningKey, payload: &[u8]) -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(signing_key.sign(payload).to_bytes())
}

fn verify_pairwise_transcript_signature(
    identity: &DeviceTrustPublicIdentity,
    payload: &[u8],
    signature: &str,
    label: &str,
) -> Result<()> {
    let signature_bytes =
        decode_fixed_base64url::<SIGNATURE_LEN>(signature, &format!("{label} signature"))?;
    let signature = Signature::from_bytes(&signature_bytes);
    identity
        .signing_verifying_key()?
        .verify_strict(payload, &signature)
        .map_err(|_| anyhow!("secure mesh pairwise {label} signature verification failed"))
}

fn handshake_transcript_hash(
    intro: &SecureMeshPairwiseSessionIntro,
) -> Result<[u8; HANDSHAKE_HASH_LEN]> {
    let signature =
        decode_fixed_base64url::<SIGNATURE_LEN>(&intro.initiator_signature, "intro signature")?;
    let mut hasher = Sha256::new();
    hasher.update(HANDSHAKE_TRANSCRIPT_MAGIC);
    hasher.update(intro_signature_payload(intro)?);
    hasher.update(signature);
    Ok(hasher.finalize().into())
}

fn key_confirmation_payload(accepted: &SecureMeshPairwiseSessionAccepted) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(KEY_CONFIRMATION_MAGIC);
    append_len_prefixed_bytes(&mut out, &accept_signature_payload(accepted)?)?;
    append_len_prefixed_bytes(&mut out, accepted.responder_signature.as_bytes())?;
    Ok(out)
}

fn pairwise_key_confirmation(
    root_key: &[u8; ROOT_KEY_LEN],
    accepted: &SecureMeshPairwiseSessionAccepted,
) -> Result<String> {
    let confirmation_key = derive_key_confirmation_key(root_key, accepted)?;
    let mut mac = <HmacSha256 as Mac>::new_from_slice(confirmation_key.as_ref())
        .map_err(|_| anyhow!("secure mesh pairwise key confirmation initialization failed"))?;
    mac.update(&key_confirmation_payload(accepted)?);
    Ok(general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

fn verify_pairwise_key_confirmation(
    root_key: &[u8; ROOT_KEY_LEN],
    accepted: &SecureMeshPairwiseSessionAccepted,
) -> Result<()> {
    let confirmation = decode_fixed_base64url::<KEY_CONFIRMATION_LEN>(
        &accepted.key_confirmation,
        "accept key confirmation",
    )?;
    let confirmation_key = derive_key_confirmation_key(root_key, accepted)?;
    let mut mac = <HmacSha256 as Mac>::new_from_slice(confirmation_key.as_ref())
        .map_err(|_| anyhow!("secure mesh pairwise key confirmation initialization failed"))?;
    mac.update(&key_confirmation_payload(accepted)?);
    mac.verify_slice(&confirmation)
        .map_err(|_| anyhow!("secure mesh pairwise key confirmation failed"))
}

fn initiator_finished_payload(finished: &SecureMeshPairwiseSessionFinished) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(INITIATOR_FINISHED_MAGIC);
    append_len_prefixed_bytes(&mut out, finished.protocol_version.as_bytes())?;
    append_len_prefixed_bytes(&mut out, finished.cipher_suite.as_bytes())?;
    append_len_prefixed_bytes(&mut out, finished.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, finished.initiator_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, finished.responder_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, finished.handshake_transcript_hash.as_bytes())?;
    append_len_prefixed_bytes(&mut out, finished.capability_transcript_digest.as_bytes())?;
    Ok(out)
}

fn initiator_finished_key_confirmation(
    root_key: &[u8; ROOT_KEY_LEN],
    finished: &SecureMeshPairwiseSessionFinished,
) -> Result<String> {
    let confirmation_key = derive_initiator_finished_key(root_key, finished)?;
    let mut mac = <HmacSha256 as Mac>::new_from_slice(confirmation_key.as_ref())
        .map_err(|_| anyhow!("secure mesh pairwise finished initialization failed"))?;
    mac.update(&initiator_finished_payload(finished)?);
    Ok(general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

fn verify_initiator_finished_key_confirmation(
    root_key: &[u8; ROOT_KEY_LEN],
    finished: &SecureMeshPairwiseSessionFinished,
) -> Result<()> {
    let confirmation = decode_fixed_base64url::<KEY_CONFIRMATION_LEN>(
        &finished.key_confirmation,
        "finished key confirmation",
    )?;
    let confirmation_key = derive_initiator_finished_key(root_key, finished)?;
    let mut mac = <HmacSha256 as Mac>::new_from_slice(confirmation_key.as_ref())
        .map_err(|_| anyhow!("secure mesh pairwise finished initialization failed"))?;
    mac.update(&initiator_finished_payload(finished)?);
    mac.verify_slice(&confirmation)
        .map_err(|_| anyhow!("secure mesh pairwise initiator finished verification failed"))
}

fn derive_initiator_finished_key(
    root_key: &[u8; ROOT_KEY_LEN],
    finished: &SecureMeshPairwiseSessionFinished,
) -> Result<Zeroizing<[u8; KEY_CONFIRMATION_LEN]>> {
    let handshake_hash = decode_fixed_base64url::<HANDSHAKE_HASH_LEN>(
        &finished.handshake_transcript_hash,
        "finished handshake transcript hash",
    )?;
    let capability_digest = crate::core::secure_mesh_capability_proof::decode_sha256_digest(
        &finished.capability_transcript_digest,
        "finished capability transcript digest",
    )?;
    let mut salt = Sha256::new();
    salt.update(INITIATOR_FINISHED_MAGIC);
    salt.update(handshake_hash);
    salt.update(capability_digest);
    let hkdf = Hkdf::<Sha256>::new(Some(&salt.finalize()), root_key);
    let mut info = Vec::new();
    append_len_prefixed_bytes(&mut info, finished.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut info, finished.initiator_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut info, finished.responder_endpoint_id.as_bytes())?;
    let mut key = Zeroizing::new([0u8; KEY_CONFIRMATION_LEN]);
    hkdf.expand(&info, key.as_mut())
        .map_err(|_| anyhow!("secure mesh pairwise finished key derivation failed"))?;
    Ok(key)
}

fn derive_key_confirmation_key(
    root_key: &[u8; ROOT_KEY_LEN],
    accepted: &SecureMeshPairwiseSessionAccepted,
) -> Result<Zeroizing<[u8; KEY_CONFIRMATION_LEN]>> {
    let handshake_hash = decode_fixed_base64url::<HANDSHAKE_HASH_LEN>(
        &accepted.handshake_transcript_hash,
        "accept handshake transcript hash",
    )?;
    let hkdf = Hkdf::<Sha256>::new(Some(&handshake_hash), root_key);
    let mut info = Vec::new();
    info.extend_from_slice(KEY_CONFIRMATION_MAGIC);
    append_len_prefixed_bytes(&mut info, accepted.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut info, accepted.responder_endpoint_id.as_bytes())?;
    let mut key = Zeroizing::new([0u8; KEY_CONFIRMATION_LEN]);
    hkdf.expand(&info, key.as_mut())
        .map_err(|_| anyhow!("secure mesh pairwise key confirmation derivation failed"))?;
    Ok(key)
}

fn decode_fixed_base64url<const N: usize>(value: &str, label: &str) -> Result<[u8; N]> {
    let encoded_length = (N * 8 + 5) / 6;
    ensure!(
        value.len() == encoded_length,
        "secure mesh pairwise {label} length is invalid"
    );
    let mut bytes = [0u8; N];
    let decoded_length = general_purpose::URL_SAFE_NO_PAD
        .decode_slice(value.as_bytes(), &mut bytes)
        .with_context(|| format!("secure mesh pairwise {label} is not base64url"))?;
    ensure!(
        decoded_length == N && general_purpose::URL_SAFE_NO_PAD.encode(bytes) == value,
        "secure mesh pairwise {label} encoding is non-canonical"
    );
    Ok(bytes)
}

fn derive_session_id(
    initiator_identity: &DeviceTrustPublicIdentity,
    responder_identity: &DeviceTrustPublicIdentity,
    initiator_ephemeral_public_key: &[u8],
    responder_signed_prekey_id: &str,
    responder_signed_prekey_public_key: &[u8],
    one_time_prekey_id: Option<&str>,
    one_time_prekey_public_key: Option<&[u8]>,
    one_time_mlkem1024_prekey_id: &str,
    one_time_mlkem1024_prekey_public_key: &[u8],
    mlkem1024_ciphertext: &[u8],
    directory_authorization_digest: &str,
) -> Result<String> {
    ensure!(
        one_time_prekey_id.is_some() == one_time_prekey_public_key.is_some(),
        "secure mesh pairwise one-time prekey transcript is inconsistent"
    );
    let mut out = Vec::new();
    append_len_prefixed_bytes(&mut out, SECURE_MESH_PROTOCOL_VERSION.as_bytes())?;
    append_len_prefixed_bytes(&mut out, SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut out, initiator_identity.endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, initiator_identity.fingerprint()?.as_bytes())?;
    append_len_prefixed_bytes(&mut out, responder_identity.endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, responder_identity.fingerprint()?.as_bytes())?;
    append_len_prefixed_bytes(&mut out, initiator_ephemeral_public_key)?;
    append_len_prefixed_bytes(&mut out, responder_signed_prekey_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, responder_signed_prekey_public_key)?;
    append_len_prefixed_bytes(&mut out, one_time_prekey_id.unwrap_or("").as_bytes())?;
    let one_time_prekey_public_key_digest = one_time_prekey_public_key
        .map(|public_key| Sha256::digest(public_key).to_vec())
        .unwrap_or_default();
    append_len_prefixed_bytes(&mut out, &one_time_prekey_public_key_digest)?;
    append_len_prefixed_bytes(&mut out, one_time_mlkem1024_prekey_id.as_bytes())?;
    append_len_prefixed_bytes(
        &mut out,
        &Sha256::digest(one_time_mlkem1024_prekey_public_key),
    )?;
    append_len_prefixed_bytes(&mut out, &Sha256::digest(mlkem1024_ciphertext))?;
    append_len_prefixed_bytes(&mut out, directory_authorization_digest.as_bytes())?;
    Ok(hash_bytes(&out))
}

fn ensure_intro(intro: &SecureMeshPairwiseSessionIntro) -> Result<()> {
    ensure!(
        intro.protocol_version == SECURE_MESH_PROTOCOL_VERSION,
        "secure mesh pairwise intro protocol is unsupported"
    );
    ensure!(
        intro.cipher_suite == SECURE_MESH_PAIRWISE_CIPHER_SUITE,
        "secure mesh pairwise intro cipher suite is unsupported"
    );
    validate_endpoint_id(&intro.initiator_endpoint_id)?;
    validate_endpoint_id(&intro.responder_endpoint_id)?;
    ensure!(
        intro.initiator_endpoint_id != intro.responder_endpoint_id,
        "secure mesh pairwise intro endpoints must be distinct"
    );
    require_text(intro.session_id.clone(), "session id")?;
    require_text(intro.responder_signed_prekey_id.clone(), "signed prekey id")?;
    require_sha256_hex(
        intro.directory_authorization_digest.clone(),
        "directory authorization digest",
    )?;
    if let Some(one_time_prekey_id) = &intro.responder_one_time_prekey_id {
        require_text(one_time_prekey_id.clone(), "one-time prekey id")?;
    }
    require_text(
        intro.responder_one_time_mlkem1024_prekey_id.clone(),
        "one-time ML-KEM-1024 prekey id",
    )?;
    ensure!(
        intro.mlkem1024_ciphertext.len() == ML_KEM_1024_CIPHERTEXT_BYTES,
        "secure mesh pairwise ML-KEM-1024 ciphertext length is invalid"
    );
    parse_key_bytes(
        &intro.initiator_identity_public_key,
        "initiator identity public key",
    )?;
    parse_key_bytes(
        &intro.initiator_ephemeral_public_key,
        "initiator ephemeral public key",
    )?;
    parse_key_bytes(
        &intro.initiator_initial_ratchet_public_key,
        "initiator ratchet public key",
    )?;
    decode_fixed_base64url::<SIGNATURE_LEN>(&intro.initiator_signature, "intro signature")?;
    encode_signed_capability_proof_json(&intro.initiator_capability_proof)?;
    Ok(())
}

fn ensure_message_for_session(
    session: &SecureMeshPairwiseSession,
    message: &SecureMeshPairwiseMessage,
) -> Result<()> {
    ensure!(
        message.protocol_version == SECURE_MESH_PROTOCOL_VERSION
            && message.cipher_suite == SECURE_MESH_PAIRWISE_CIPHER_SUITE,
        "secure mesh pairwise message protocol is unsupported"
    );
    ensure!(
        message.session_id == session.session_id,
        "secure mesh pairwise message session mismatch"
    );
    ensure!(
        message.sender_endpoint_id == session.remote_endpoint_id
            && message.recipient_endpoint_id == session.local_endpoint_id,
        "secure mesh pairwise message endpoint mismatch"
    );
    validate_message_id(&message.message_id)?;
    ensure!(
        message.ciphertext_size > 0 && message.ciphertext_size <= MAX_CIPHERTEXT_BYTES,
        "secure mesh pairwise ciphertext size is outside bounds"
    );
    ensure!(
        message.ciphertext.len() <= encoded_len_limit(MAX_CIPHERTEXT_BYTES),
        "secure mesh pairwise encoded ciphertext is too large"
    );
    ensure!(
        message.encrypted_header.len() <= encoded_len_limit(MAX_CONTENT_ENCRYPTED_HEADER_BYTES),
        "secure mesh pairwise encrypted header is too large"
    );
    sparse_pq_header_bytes(&message.sparse_pq_header)?;
    Ok(())
}

fn ensure_pairwise_context_for_send(
    session: &SecureMeshPairwiseSession,
    context: &SecureMeshContentContext,
) -> Result<()> {
    ensure!(
        context.session_id == session.session_id,
        "secure mesh pairwise payload context session mismatch"
    );
    ensure!(
        context.sender_endpoint_id == session.local_endpoint_id
            && context.recipient_endpoint_id == session.remote_endpoint_id,
        "secure mesh pairwise payload context endpoint mismatch"
    );
    validate_message_id(&context.message_id)?;
    Ok(())
}

fn ensure_pairwise_context_for_open(
    session: &SecureMeshPairwiseSession,
    context: &SecureMeshContentContext,
    message: &SecureMeshPairwiseMessage,
) -> Result<()> {
    ensure!(
        context.session_id == message.session_id && context.session_id == session.session_id,
        "secure mesh pairwise payload context session mismatch"
    );
    ensure!(
        context.message_id == message.message_id,
        "secure mesh pairwise payload context message mismatch"
    );
    ensure!(
        context.sender_endpoint_id == message.sender_endpoint_id
            && context.recipient_endpoint_id == message.recipient_endpoint_id,
        "secure mesh pairwise payload context endpoint mismatch"
    );
    ensure!(
        context.sender_endpoint_id == session.remote_endpoint_id
            && context.recipient_endpoint_id == session.local_endpoint_id,
        "secure mesh pairwise payload context local endpoint mismatch"
    );
    Ok(())
}

fn message_aad(message: &SecureMeshPairwiseMessage) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(MESSAGE_AAD_MAGIC);
    append_len_prefixed_bytes(&mut out, message.protocol_version.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.cipher_suite.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.message_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.sender_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.recipient_endpoint_id.as_bytes())?;
    out.extend_from_slice(&message.dh_epoch.to_be_bytes());
    out.extend_from_slice(&message.chain_index.to_be_bytes());
    out.extend_from_slice(&message.previous_chain_length.to_be_bytes());
    append_len_prefixed_bytes(&mut out, &message.sender_ratchet_public_key)?;
    append_len_prefixed_bytes(
        &mut out,
        &sparse_pq_header_bytes(&message.sparse_pq_header)?,
    )?;
    append_len_prefixed_bytes(&mut out, message.encrypted_header.as_bytes())?;
    Ok(out)
}

fn pairwise_payload_aad_binding(message: &SecureMeshPairwiseMessage) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(PAYLOAD_AAD_BINDING_MAGIC);
    append_len_prefixed_bytes(&mut out, message.protocol_version.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.cipher_suite.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.message_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.sender_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, message.recipient_endpoint_id.as_bytes())?;
    out.extend_from_slice(&message.dh_epoch.to_be_bytes());
    out.extend_from_slice(&message.chain_index.to_be_bytes());
    out.extend_from_slice(&message.previous_chain_length.to_be_bytes());
    append_len_prefixed_bytes(&mut out, &message.sender_ratchet_public_key)?;
    append_len_prefixed_bytes(
        &mut out,
        &sparse_pq_header_bytes(&message.sparse_pq_header)?,
    )?;
    Ok(out)
}

fn sparse_pq_header_bytes(header: &SecureMeshSparsePqHeader) -> Result<Vec<u8>> {
    ensure!(
        header.message_number > 0,
        "secure mesh pairwise sparse PQ message number is invalid"
    );
    let encoded = serde_json::to_vec(header)
        .context("secure mesh pairwise sparse PQ header serialization failed")?;
    ensure!(
        encoded.len() <= MAX_SPARSE_PQ_HEADER_BYTES,
        "secure mesh pairwise sparse PQ header is too large"
    );
    Ok(encoded)
}

fn combine_pairwise_and_extra_aad(
    message: &SecureMeshPairwiseMessage,
    extra_aad: &[u8],
) -> Result<Vec<u8>> {
    let mut out = pairwise_payload_aad_binding(message)?;
    if !extra_aad.is_empty() {
        out.extend_from_slice(extra_aad);
    }
    Ok(out)
}

fn message_replay_fingerprint(message: &SecureMeshPairwiseMessage) -> Result<String> {
    validate_message_id(&message.message_id)?;
    let sender_ratchet_public_key = parse_key_bytes(
        &message.sender_ratchet_public_key,
        "replay sender ratchet public key",
    )?;
    let ciphertext_hash = hash_bytes(message.ciphertext.as_bytes());
    let mut out = Vec::new();
    append_len_prefixed_bytes(&mut out, message.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, &sender_ratchet_public_key)?;
    out.extend_from_slice(&message.dh_epoch.to_be_bytes());
    out.extend_from_slice(&message.chain_index.to_be_bytes());
    append_len_prefixed_bytes(&mut out, message.message_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, ciphertext_hash.as_bytes())?;
    Ok(hash_bytes(&out))
}

fn parse_key_bytes(bytes: &[u8], label: &str) -> Result<[u8; PUBLIC_KEY_LEN]> {
    ensure!(
        bytes.len() == PUBLIC_KEY_LEN,
        "secure mesh pairwise {label} length is invalid"
    );
    let mut out = [0u8; PUBLIC_KEY_LEN];
    out.copy_from_slice(bytes);
    Ok(out)
}

fn decode_secret_32(value: &str) -> Result<[u8; PUBLIC_KEY_LEN]> {
    let expected_encoded_length = (PUBLIC_KEY_LEN * 8 + 5) / 6;
    ensure!(
        value.len() == expected_encoded_length,
        "secure mesh pairwise persisted secret length is invalid"
    );
    let mut bytes = [0u8; PUBLIC_KEY_LEN];
    let decoded_length = general_purpose::URL_SAFE_NO_PAD
        .decode_slice(value.as_bytes(), &mut bytes)
        .context("secure mesh pairwise persisted secret is not base64url")?;
    ensure!(
        decoded_length == PUBLIC_KEY_LEN,
        "secure mesh pairwise persisted secret length is invalid"
    );
    let canonical = Zeroizing::new(general_purpose::URL_SAFE_NO_PAD.encode(bytes));
    ensure!(
        canonical.as_str() == value,
        "secure mesh pairwise persisted secret encoding is non-canonical"
    );
    Ok(bytes)
}

fn encode_secret(bytes: &[u8; PUBLIC_KEY_LEN]) -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub(crate) fn pairwise_secret_store_namespace(path: &Path) -> String {
    format!(
        "{PAIRWISE_SECRET_STORE_CLASS}:{}",
        sha256_hex(path.to_string_lossy().as_bytes())
    )
}

fn pairwise_secret_store_key(
    session_id: &str,
    local_endpoint_id: &str,
    state_version: u64,
) -> String {
    format!(
        "{}.{}",
        pairwise_secret_store_key_prefix(session_id, local_endpoint_id, state_version),
        Uuid::new_v4().simple()
    )
}

fn pairwise_secret_store_key_prefix(
    session_id: &str,
    local_endpoint_id: &str,
    state_version: u64,
) -> String {
    let mut material = Vec::new();
    material.extend_from_slice(b"LCOSM-PAIRWISE-SECRET-STORE-KEY-v2");
    let _ = append_len_prefixed_bytes(&mut material, session_id.as_bytes());
    let _ = append_len_prefixed_bytes(&mut material, local_endpoint_id.as_bytes());
    material.extend_from_slice(&state_version.to_be_bytes());
    format!("snapshot.v2.{}", sha256_hex(&material))
}

fn pairwise_secret_store_key_is_bound(
    key: &str,
    session_id: &str,
    local_endpoint_id: &str,
    state_version: u64,
) -> bool {
    let prefix = format!(
        "{}.",
        pairwise_secret_store_key_prefix(session_id, local_endpoint_id, state_version)
    );
    key.strip_prefix(&prefix).is_some_and(|nonce| {
        nonce.len() == 32 && nonce.bytes().all(|byte| byte.is_ascii_hexdigit())
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn append_len_prefixed_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len = u32::try_from(value.len())
        .map_err(|_| anyhow!("secure mesh pairwise field is too large"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

fn encoded_len_limit(decoded_bytes: usize) -> usize {
    decoded_bytes.div_ceil(3).saturating_mul(4)
}

fn validate_endpoint_id(value: &str) -> Result<()> {
    let value = require_text(value.to_string(), "endpoint id")?;
    ensure!(
        value.len() <= MAX_ENDPOINT_ID_LEN,
        "secure mesh pairwise endpoint id is too large"
    );
    Ok(())
}

fn validate_message_id(value: &str) -> Result<()> {
    let value = require_text(value.to_string(), "message id")?;
    ensure!(
        value.len() <= MAX_MESSAGE_ID_LEN,
        "secure mesh pairwise message id is too large"
    );
    Ok(())
}

fn require_text(value: String, label: &str) -> Result<String> {
    ensure!(
        !value.trim().is_empty(),
        "secure mesh pairwise {label} is required"
    );
    Ok(value)
}

fn require_sha256_hex(value: String, label: &str) -> Result<String> {
    ensure!(
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "secure mesh pairwise {label} must be canonical lowercase SHA-256 hex"
    );
    Ok(value)
}

fn push_bounded_inactive(values: &mut Vec<String>, value: String, limit: usize) {
    values.retain(|candidate| candidate != &value);
    values.push(value);
    while values.len() > limit {
        values.remove(0);
    }
}

fn hash_bytes(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
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
    use crate::core::secure_mesh_command::{
        SecureCommandEvaluationContext, SecureCommandLocalExecutor, SecureCommandPayload,
        SecureCommandReplayLedger, evaluate_secure_command, execute_evaluated_secure_command,
    };
    use crate::core::secure_mesh_prekey::{
        SecureMeshPairwisePreKeyBundle, SecureMeshPreKeyKind,
        authorize_test_pairwise_prekey_bundle, sign_prekey_record,
    };
    use crate::core::secure_mesh_trust::DeviceTrustState;
    use crate::platform::secure_mesh_secret_store::{
        EphemeralSecretStore, SecretStoreHandle, SecureMeshSecretStore,
    };
    use ed25519_dalek::SigningKey;
    use rusqlite::{Connection as TestConnection, params};
    use serde_json::{Value, json};
    use std::path::{Path, PathBuf};
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    use std::time::{SystemTime, UNIX_EPOCH};

    struct EndpointFixture {
        identity: DeviceTrustPublicIdentity,
        identity_secret: SecureMeshPairwisePrivateKey,
        signing_key: SigningKey,
    }

    struct PrekeyFixture {
        signed_secret: SecureMeshPairwisePrivateKey,
        one_time_secret: SecureMeshPairwisePrivateKey,
        one_time_mlkem1024_seed: SecureMeshMlKem1024PreKeySeed,
        bundle: SecureMeshPairwisePreKeyBundle,
    }

    struct HandshakeFixture {
        alice: EndpointFixture,
        bob: EndpointFixture,
        bob_prekeys: PrekeyFixture,
        alice_session: SecureMeshPairwiseSession,
        intro: SecureMeshPairwiseSessionIntro,
        bob_session: SecureMeshPairwiseSession,
        accepted: SecureMeshPairwiseSessionAccepted,
    }

    fn endpoint(endpoint_id: &str) -> EndpointFixture {
        let identity_secret = SecureMeshPairwisePrivateKey::generate();
        let signing_key = SigningKey::generate(&mut OsRng);
        let identity = DeviceTrustPublicIdentity::new(
            endpoint_id,
            identity_secret.public_key(),
            signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        EndpointFixture {
            identity,
            identity_secret,
            signing_key,
        }
    }

    fn prekeys(endpoint: &EndpointFixture) -> PrekeyFixture {
        let signed_secret = SecureMeshPairwisePrivateKey::generate();
        let one_time_secret = SecureMeshPairwisePrivateKey::generate();
        let one_time_mlkem1024_seed = SecureMeshMlKem1024PreKeySeed::generate();
        let signed_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::SignedPreKey,
            "spk-1",
            signed_secret.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        let one_time_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::OneTimePreKey,
            "otpk-1",
            one_time_secret.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        let one_time_mlkem1024_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::OneTimeMlKem1024PreKey,
            "pqotpk-1",
            one_time_mlkem1024_seed.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        PrekeyFixture {
            signed_secret,
            one_time_secret,
            one_time_mlkem1024_seed,
            bundle: SecureMeshPairwisePreKeyBundle {
                endpoint_identity: endpoint.identity.clone(),
                trust_state: DeviceTrustState::Verified,
                signed_prekey,
                one_time_prekey: Some(one_time_prekey),
                one_time_mlkem1024_prekey,
                prekey_publication_version: 1,
            },
        }
    }

    fn pairwise_sessions() -> (SecureMeshPairwiseSession, SecureMeshPairwiseSession) {
        pairwise_sessions_between("desktop_gui:alice", "mobile:bob")
    }

    fn handshake_now() -> OffsetDateTime {
        OffsetDateTime::parse(
            "2026-06-26T00:00:01Z",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap()
    }

    fn handshake_fixture() -> HandshakeFixture {
        let alice = endpoint("desktop_gui:alice");
        let bob = endpoint("mobile:bob");
        let bob_prekeys = prekeys(&bob);
        let bob_directory = authorize_test_pairwise_prekey_bundle(&bob_prekeys.bundle);
        let now = handshake_now();
        let (alice_session, intro) = SecureMeshPairwiseSession::initiate(
            &alice.identity,
            &alice.identity_secret,
            &alice.signing_key,
            &bob_prekeys.bundle,
            &bob_directory,
            &SecureMeshPreKeyValidationPolicy::default(),
            &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
            now,
        )
        .unwrap();
        let (bob_session, accepted) = SecureMeshPairwiseSession::accept(
            &bob.identity,
            &bob.identity_secret,
            &bob.signing_key,
            &alice.identity,
            &bob_prekeys.signed_secret,
            Some(&bob_prekeys.one_time_secret),
            &bob_prekeys.one_time_mlkem1024_seed,
            &intro,
            &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
            now,
            &mut CapabilityProofReplayGuard::default(),
        )
        .unwrap();
        HandshakeFixture {
            alice,
            bob,
            bob_prekeys,
            alice_session,
            intro,
            bob_session,
            accepted,
        }
    }

    fn pairwise_sessions_between(
        initiator_endpoint_id: &str,
        responder_endpoint_id: &str,
    ) -> (SecureMeshPairwiseSession, SecureMeshPairwiseSession) {
        let alice = endpoint(initiator_endpoint_id);
        let bob = endpoint(responder_endpoint_id);
        let bob_prekeys = prekeys(&bob);
        let bob_directory = authorize_test_pairwise_prekey_bundle(&bob_prekeys.bundle);
        let now = handshake_now();
        let (mut alice_session, intro) = SecureMeshPairwiseSession::initiate(
            &alice.identity,
            &alice.identity_secret,
            &alice.signing_key,
            &bob_prekeys.bundle,
            &bob_directory,
            &SecureMeshPreKeyValidationPolicy::default(),
            &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
            now,
        )
        .unwrap();
        let (mut bob_session, accepted) = SecureMeshPairwiseSession::accept(
            &bob.identity,
            &bob.identity_secret,
            &bob.signing_key,
            &alice.identity,
            &bob_prekeys.signed_secret,
            Some(&bob_prekeys.one_time_secret),
            &bob_prekeys.one_time_mlkem1024_seed,
            &intro,
            &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
            now,
            &mut CapabilityProofReplayGuard::default(),
        )
        .unwrap();
        let finished = alice_session
            .complete_initiator_handshake(
                &alice.identity,
                &bob.identity,
                &accepted,
                now,
                &mut CapabilityProofReplayGuard::default(),
            )
            .unwrap();
        bob_session.complete_responder_handshake(&finished).unwrap();
        assert_eq!(alice_session.session_id, bob_session.session_id);
        (alice_session, bob_session)
    }

    fn fixed_pairwise_key(seed: u8) -> SecureMeshPairwisePrivateKey {
        SecureMeshPairwisePrivateKey::from_bytes([seed; PUBLIC_KEY_LEN])
    }

    fn deterministic_test_capability_negotiation(
        local_endpoint_id: &str,
        remote_endpoint_id: &str,
        handshake_transcript_hash: &[u8; HANDSHAKE_HASH_LEN],
    ) -> (SignedCapabilityProof, VerifiedSessionNegotiation) {
        fn deterministic_identity(
            endpoint_id: &str,
            label: &[u8],
        ) -> (DeviceTrustPublicIdentity, SigningKey) {
            let mut signing_material = Vec::from(label);
            signing_material.extend_from_slice(endpoint_id.as_bytes());
            let signing_seed: [u8; 32] = Sha256::digest(&signing_material).into();
            let signing_key = SigningKey::from_bytes(&signing_seed);
            let mut identity_material = Vec::from(b"pairwise-test-identity".as_slice());
            identity_material.extend_from_slice(endpoint_id.as_bytes());
            let identity_public_key: [u8; 32] = Sha256::digest(identity_material).into();
            (
                DeviceTrustPublicIdentity::new(
                    endpoint_id,
                    identity_public_key,
                    signing_key.verifying_key().to_bytes(),
                    1,
                )
                .unwrap(),
                signing_key,
            )
        }

        let (local_identity, local_signing_key) =
            deterministic_identity(local_endpoint_id, b"pairwise-test-local-signing");
        let (remote_identity, remote_signing_key) =
            deterministic_identity(remote_endpoint_id, b"pairwise-test-remote-signing");
        let evaluation = secure_mesh_pairwise_test_capability_evaluation().unwrap();
        let now = handshake_now();
        let challenge = [0x42; 32];
        let request = capability_proof_request(challenge, now).unwrap();
        let local_proof =
            sign_capability_proof(&local_identity, &local_signing_key, &evaluation, &request)
                .unwrap();
        let remote_proof =
            sign_capability_proof(&remote_identity, &remote_signing_key, &evaluation, &request)
                .unwrap();
        let context = capability_verification_context(challenge, now).unwrap();
        let local_verified = crate::core::secure_mesh_capability_proof::verify_capability_proof(
            &local_identity,
            &local_proof,
            &context,
        )
        .unwrap();
        let remote_verified = crate::core::secure_mesh_capability_proof::verify_capability_proof(
            &remote_identity,
            &remote_proof,
            &context,
        )
        .unwrap();
        let base_transcript_digest =
            crate::core::secure_mesh_capability_proof::encode_sha256_digest(
                handshake_transcript_hash,
            );
        let binding = create_pairwise_capability_binding(
            &local_verified,
            &remote_verified,
            &base_transcript_digest,
        )
        .unwrap();
        let mut replay_guard = CapabilityProofReplayGuard::default();
        let negotiation = accept_pairwise_capability_binding(
            CapabilityProofPeer {
                identity: &local_identity,
                proof: &local_proof,
                verification_context: &context,
            },
            CapabilityProofPeer {
                identity: &remote_identity,
                proof: &remote_proof,
                verification_context: &context,
            },
            &base_transcript_digest,
            &binding,
            &mut replay_guard,
        )
        .unwrap();
        (local_proof, negotiation)
    }

    fn deterministic_pairwise_session(
        session_id: &str,
        local_endpoint_id: &str,
        remote_endpoint_id: &str,
        initiator_endpoint_id: &str,
        responder_endpoint_id: &str,
        shared_secret: [u8; PUBLIC_KEY_LEN],
        local_ratchet_secret: SecureMeshPairwisePrivateKey,
        remote_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    ) -> Result<SecureMeshPairwiseSession> {
        validate_endpoint_id(local_endpoint_id)?;
        validate_endpoint_id(remote_endpoint_id)?;
        ensure!(
            local_endpoint_id != remote_endpoint_id,
            "secure mesh pairwise deterministic vector requires distinct endpoints"
        );
        ensure!(
            (local_endpoint_id == initiator_endpoint_id
                && remote_endpoint_id == responder_endpoint_id)
                || (local_endpoint_id == responder_endpoint_id
                    && remote_endpoint_id == initiator_endpoint_id),
            "secure mesh pairwise deterministic vector endpoint order mismatch"
        );
        let role = if local_endpoint_id == initiator_endpoint_id {
            SecureMeshPairwiseRole::Initiator
        } else {
            SecureMeshPairwiseRole::Responder
        };
        let keys = derive_initial_keys(
            &shared_secret,
            session_id,
            initiator_endpoint_id,
            responder_endpoint_id,
        )?;
        let local_ratchet_public_key = local_ratchet_secret.public_key();
        let (sending_chain_key, receiving_chain_key) = if role == SecureMeshPairwiseRole::Initiator
        {
            (keys.initiator_chain_key, keys.responder_chain_key)
        } else {
            (keys.responder_chain_key, keys.initiator_chain_key)
        };
        let (
            sending_header_key,
            receiving_header_key,
            next_sending_header_key,
            next_receiving_header_key,
        ) = if role == SecureMeshPairwiseRole::Initiator {
            (
                keys.initiator_header_key,
                keys.responder_header_key,
                keys.initiator_next_header_key,
                keys.responder_next_header_key,
            )
        } else {
            (
                keys.responder_header_key,
                keys.initiator_header_key,
                keys.responder_next_header_key,
                keys.initiator_next_header_key,
            )
        };
        let handshake_transcript_hash: [u8; HANDSHAKE_HASH_LEN] =
            Sha256::digest(session_id.as_bytes()).into();
        let (local_capability_proof, capability_negotiation) =
            deterministic_test_capability_negotiation(
                local_endpoint_id,
                remote_endpoint_id,
                &handshake_transcript_hash,
            );
        let sparse_pq_seed: [u8; 32] = Sha256::digest(
            [
                b"licolite.secure-mesh.test.sparse-pq.v1".as_slice(),
                shared_secret.as_slice(),
            ]
            .concat(),
        )
        .into();
        let sparse_pq_ratchet = match role {
            SecureMeshPairwiseRole::Initiator => {
                SecureMeshSparsePqRatchet::new_initiator(&sparse_pq_seed)?
            }
            SecureMeshPairwiseRole::Responder => {
                SecureMeshSparsePqRatchet::new_responder(&sparse_pq_seed)?
            }
        };
        Ok(SecureMeshPairwiseSession {
            session_id: session_id.to_string(),
            local_endpoint_id: local_endpoint_id.to_string(),
            remote_endpoint_id: remote_endpoint_id.to_string(),
            role,
            root_key: Zeroizing::new(keys.root_key),
            sending_chain_key: Zeroizing::new(sending_chain_key),
            receiving_chain_key: Zeroizing::new(receiving_chain_key),
            sending_header_key: Zeroizing::new(sending_header_key),
            receiving_header_key: Zeroizing::new(receiving_header_key),
            next_sending_header_key: Zeroizing::new(next_sending_header_key),
            next_receiving_header_key: Zeroizing::new(next_receiving_header_key),
            skipped_receiving_header_keys: Vec::new(),
            local_ratchet_secret,
            local_ratchet_public_key,
            remote_ratchet_public_key,
            handshake_transcript_hash,
            dh_epoch: 0,
            receiving_ratchet_epoch: 0,
            sending_chain_index: 0,
            receiving_chain_index: 0,
            previous_chain_length: 0,
            skipped_keys: Vec::new(),
            received_message_ids: Vec::new(),
            pending_sending_ratchet: false,
            initiator_key_confirmed: true,
            local_capability_proof,
            capability_negotiation: Some(capability_negotiation),
            sparse_pq_ratchet,
            revoked: false,
        })
    }

    fn fixed_signing_key(seed: u8) -> SigningKey {
        SigningKey::from_bytes(&[seed; 32])
    }

    #[test]
    fn secure_mesh_pairwise_runtime_self_test_covers_pqxdh_and_triple_ratchet() {
        assert!(runtime_crypto_self_test());
    }

    fn fixed_endpoint(endpoint_id: &str, identity_seed: u8, signing_seed: u8) -> EndpointFixture {
        let identity_secret = fixed_pairwise_key(identity_seed);
        let signing_key = fixed_signing_key(signing_seed);
        let identity = DeviceTrustPublicIdentity::new(
            endpoint_id,
            identity_secret.public_key(),
            signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        EndpointFixture {
            identity,
            identity_secret,
            signing_key,
        }
    }

    fn fixed_prekeys(
        endpoint: &EndpointFixture,
        signed_seed: u8,
        one_time_seed: u8,
    ) -> PrekeyFixture {
        let signed_secret = fixed_pairwise_key(signed_seed);
        let one_time_secret = fixed_pairwise_key(one_time_seed);
        let one_time_mlkem1024_seed = SecureMeshMlKem1024PreKeySeed::from_bytes(
            [signed_seed.wrapping_add(one_time_seed); ML_KEM_1024_KEY_GENERATION_SEED_BYTES],
        );
        let signed_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::SignedPreKey,
            "spk-vector",
            signed_secret.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        let one_time_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::OneTimePreKey,
            "otpk-vector",
            one_time_secret.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        let one_time_mlkem1024_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::OneTimeMlKem1024PreKey,
            "pqotpk-vector",
            one_time_mlkem1024_seed.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        PrekeyFixture {
            signed_secret,
            one_time_secret,
            one_time_mlkem1024_seed,
            bundle: SecureMeshPairwisePreKeyBundle {
                endpoint_identity: endpoint.identity.clone(),
                trust_state: DeviceTrustState::Verified,
                signed_prekey,
                one_time_prekey: Some(one_time_prekey),
                one_time_mlkem1024_prekey,
                prekey_publication_version: 1,
            },
        }
    }

    #[test]
    fn secure_mesh_pairwise_session_id_binds_classical_and_pq_one_time_prekeys() {
        let alice = fixed_endpoint("desktop_gui:alice-vector", 1, 91);
        let bob = fixed_endpoint("mobile:bob-vector", 2, 92);
        let alice_ephemeral = fixed_pairwise_key(5);
        let bob_signed_prekey = fixed_pairwise_key(3);
        let bob_one_time_prekey = fixed_pairwise_key(4);
        let replaced_one_time_prekey = fixed_pairwise_key(44);
        let alice_ephemeral_public_key = alice_ephemeral.public_key();
        let bob_signed_prekey_public_key = bob_signed_prekey.public_key();
        let bob_one_time_prekey_public_key = bob_one_time_prekey.public_key();
        let replaced_one_time_prekey_public_key = replaced_one_time_prekey.public_key();
        let pq_seed = SecureMeshMlKem1024PreKeySeed::from_bytes(
            [0x71; ML_KEM_1024_KEY_GENERATION_SEED_BYTES],
        );
        let pq_public_key = pq_seed.public_key();
        let mlkem1024_ciphertext = [0x81; ML_KEM_1024_CIPHERTEXT_BYTES];
        let original_session_id = derive_session_id(
            &alice.identity,
            &bob.identity,
            &alice_ephemeral_public_key,
            "spk-vector",
            &bob_signed_prekey_public_key,
            Some("otpk-vector"),
            Some(&bob_one_time_prekey_public_key),
            "pqotpk-vector",
            &pq_public_key,
            &mlkem1024_ciphertext,
            "sha256:vector-tree-head",
        )
        .unwrap();
        let repeated_session_id = derive_session_id(
            &alice.identity,
            &bob.identity,
            &alice_ephemeral_public_key,
            "spk-vector",
            &bob_signed_prekey_public_key,
            Some("otpk-vector"),
            Some(&bob_one_time_prekey_public_key),
            "pqotpk-vector",
            &pq_public_key,
            &mlkem1024_ciphertext,
            "sha256:vector-tree-head",
        )
        .unwrap();
        let replaced_session_id = derive_session_id(
            &alice.identity,
            &bob.identity,
            &alice_ephemeral_public_key,
            "spk-vector",
            &bob_signed_prekey_public_key,
            Some("otpk-vector"),
            Some(&replaced_one_time_prekey_public_key),
            "pqotpk-vector",
            &pq_public_key,
            &mlkem1024_ciphertext,
            "sha256:vector-tree-head",
        )
        .unwrap();
        let replaced_pq_seed = SecureMeshMlKem1024PreKeySeed::from_bytes(
            [0x72; ML_KEM_1024_KEY_GENERATION_SEED_BYTES],
        );
        let replaced_pq_session_id = derive_session_id(
            &alice.identity,
            &bob.identity,
            &alice_ephemeral_public_key,
            "spk-vector",
            &bob_signed_prekey_public_key,
            Some("otpk-vector"),
            Some(&bob_one_time_prekey_public_key),
            "pqotpk-vector",
            &replaced_pq_seed.public_key(),
            &mlkem1024_ciphertext,
            "sha256:vector-tree-head",
        )
        .unwrap();
        let replaced_ciphertext_session_id = derive_session_id(
            &alice.identity,
            &bob.identity,
            &alice_ephemeral_public_key,
            "spk-vector",
            &bob_signed_prekey_public_key,
            Some("otpk-vector"),
            Some(&bob_one_time_prekey_public_key),
            "pqotpk-vector",
            &pq_public_key,
            &[0x82; ML_KEM_1024_CIPHERTEXT_BYTES],
            "sha256:vector-tree-head",
        )
        .unwrap();

        assert_eq!(original_session_id, repeated_session_id);
        assert_ne!(original_session_id, replaced_session_id);
        assert_ne!(original_session_id, replaced_pq_session_id);
        assert_ne!(original_session_id, replaced_ciphertext_session_id);
    }

    #[test]
    fn secure_mesh_pairwise_rejects_non_contributory_x25519_keys() {
        let local_key = fixed_pairwise_key(7);
        let low_order_public_key = [0u8; PUBLIC_KEY_LEN];
        let error = local_key.diffie_hellman(&low_order_public_key).unwrap_err();
        assert!(error.to_string().contains("non-contributory"));

        let alice = endpoint("desktop_gui:alice-low-order");
        let bob = endpoint("mobile:bob-low-order");
        let mut bob_prekeys = prekeys(&bob);
        bob_prekeys.bundle.signed_prekey = sign_prekey_record(
            &bob.signing_key,
            &bob.identity,
            SecureMeshPreKeyKind::SignedPreKey,
            "spk-low-order",
            low_order_public_key,
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        let bob_directory = authorize_test_pairwise_prekey_bundle(&bob_prekeys.bundle);
        let now = OffsetDateTime::parse(
            "2026-06-26T00:00:01Z",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap();
        let handshake_error = SecureMeshPairwiseSession::initiate(
            &alice.identity,
            &alice.identity_secret,
            &alice.signing_key,
            &bob_prekeys.bundle,
            &bob_directory,
            &SecureMeshPreKeyValidationPolicy::default(),
            &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
            now,
        )
        .err()
        .expect("low-order signed prekey must fail");
        assert!(handshake_error.to_string().contains("non-contributory"));

        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first = alice_session
            .seal_message("msg-low-order-ratchet", b"valid first message")
            .unwrap();
        let mut malicious = first.clone();
        malicious.sender_ratchet_public_key = low_order_public_key.to_vec();
        let ratchet_error = bob_session.open_message(&malicious).unwrap_err();
        assert!(ratchet_error.to_string().contains("non-contributory"));
        assert_eq!(bob_session.dh_epoch(), 0);
        assert_eq!(bob_session.received_count(), 0);
        assert!(bob_session.initiator_key_confirmed);
        assert_eq!(
            bob_session.open_message(&first).unwrap().body,
            b"valid first message"
        );
    }

    #[test]
    fn secure_mesh_pairwise_rejects_server_tampering_with_signed_handshake_transcript() {
        let fixture = handshake_fixture();
        let mut tampered_intros = Vec::new();

        let mut changed_session = fixture.intro.clone();
        changed_session.session_id.push_str("-server-substitution");
        tampered_intros.push(changed_session);

        let mut changed_endpoint = fixture.intro.clone();
        changed_endpoint.responder_endpoint_id = "mobile:attacker".to_string();
        tampered_intros.push(changed_endpoint);

        let mut changed_ephemeral = fixture.intro.clone();
        changed_ephemeral.initiator_ephemeral_public_key =
            fixed_pairwise_key(73).public_key().to_vec();
        tampered_intros.push(changed_ephemeral);

        let mut changed_directory_authorization = fixture.intro.clone();
        changed_directory_authorization.directory_authorization_digest = "cd".repeat(32);
        tampered_intros.push(changed_directory_authorization);

        let mut changed_signature = fixture.intro.clone();
        let mut signature = general_purpose::URL_SAFE_NO_PAD
            .decode(&changed_signature.initiator_signature)
            .unwrap();
        signature[0] ^= 1;
        changed_signature.initiator_signature = general_purpose::URL_SAFE_NO_PAD.encode(signature);
        tampered_intros.push(changed_signature);

        for tampered in tampered_intros {
            assert!(
                SecureMeshPairwiseSession::accept(
                    &fixture.bob.identity,
                    &fixture.bob.identity_secret,
                    &fixture.bob.signing_key,
                    &fixture.alice.identity,
                    &fixture.bob_prekeys.signed_secret,
                    Some(&fixture.bob_prekeys.one_time_secret),
                    &fixture.bob_prekeys.one_time_mlkem1024_seed,
                    &tampered,
                    &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
                    handshake_now(),
                    &mut CapabilityProofReplayGuard::default(),
                )
                .is_err(),
                "server-modified intro was accepted"
            );
        }

        let mut tampered_accepts = Vec::new();
        let mut changed_ratchet = fixture.accepted.clone();
        changed_ratchet.responder_initial_ratchet_public_key =
            fixed_pairwise_key(74).public_key().to_vec();
        tampered_accepts.push(changed_ratchet);

        let mut changed_hash = fixture.accepted.clone();
        changed_hash.handshake_transcript_hash =
            general_purpose::URL_SAFE_NO_PAD.encode([9u8; HANDSHAKE_HASH_LEN]);
        tampered_accepts.push(changed_hash);

        let mut changed_accept_signature = fixture.accepted.clone();
        let mut signature = general_purpose::URL_SAFE_NO_PAD
            .decode(&changed_accept_signature.responder_signature)
            .unwrap();
        signature[0] ^= 1;
        changed_accept_signature.responder_signature =
            general_purpose::URL_SAFE_NO_PAD.encode(signature);
        tampered_accepts.push(changed_accept_signature);

        let mut changed_confirmation = fixture.accepted.clone();
        let mut confirmation = general_purpose::URL_SAFE_NO_PAD
            .decode(&changed_confirmation.key_confirmation)
            .unwrap();
        confirmation[0] ^= 1;
        changed_confirmation.key_confirmation =
            general_purpose::URL_SAFE_NO_PAD.encode(confirmation);
        tampered_accepts.push(changed_confirmation);

        for tampered in tampered_accepts {
            let mut candidate = fixture.alice_session.clone();
            assert!(
                candidate
                    .complete_initiator_handshake(
                        &fixture.alice.identity,
                        &fixture.bob.identity,
                        &tampered,
                        handshake_now(),
                        &mut CapabilityProofReplayGuard::default(),
                    )
                    .is_err(),
                "server-modified accept was accepted"
            );
            assert!(!candidate.initiator_key_confirmed);
            assert_eq!(candidate.remote_ratchet_public_key, [0u8; PUBLIC_KEY_LEN]);
            assert!(
                candidate
                    .seal_message("msg-before-confirmation", b"blocked")
                    .is_err()
            );
        }
    }

    #[test]
    fn secure_mesh_pairwise_capability_proofs_gate_production_handshake_and_replay() {
        let fixture = handshake_fixture();
        let responder_projection = fixture
            .bob_session
            .capability_projection()
            .expect("responder capability negotiation must be verified during accept");
        assert!(responder_projection.peer.is_some());
        assert!(
            responder_projection
                .negotiated_protocol_capabilities
                .iter()
                .all(|capability| capability.id().starts_with("protocol."))
        );

        let mut pending = fixture.alice_session.clone();
        let blocked = pending
            .seal_message("msg-capability-pending", b"blocked")
            .unwrap_err();
        assert!(blocked.to_string().contains("capability negotiation"));

        let mut tampered_intro = fixture.intro.clone();
        tampered_intro
            .initiator_capability_proof
            .claims
            .policy_revision += 1;
        tampered_intro.initiator_signature = sign_pairwise_transcript(
            &fixture.alice.signing_key,
            &intro_signature_payload(&tampered_intro).unwrap(),
        );
        let rejected_intro = SecureMeshPairwiseSession::accept(
            &fixture.bob.identity,
            &fixture.bob.identity_secret,
            &fixture.bob.signing_key,
            &fixture.alice.identity,
            &fixture.bob_prekeys.signed_secret,
            Some(&fixture.bob_prekeys.one_time_secret),
            &fixture.bob_prekeys.one_time_mlkem1024_seed,
            &tampered_intro,
            &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
            handshake_now(),
            &mut CapabilityProofReplayGuard::default(),
        )
        .err()
        .expect("tampered capability proof must be rejected");
        assert!(rejected_intro.to_string().contains("capability proof"));

        let mut tampered_accepted = fixture.accepted.clone();
        tampered_accepted
            .capability_binding
            .negotiated_protocol_capabilities
            .remove(
                &crate::core::secure_mesh_capability::SecurityCapability::AuthenticatedEncryption,
            );
        tampered_accepted.responder_signature = sign_pairwise_transcript(
            &fixture.bob.signing_key,
            &accept_signature_payload(&tampered_accepted).unwrap(),
        );
        tampered_accepted.key_confirmation =
            pairwise_key_confirmation(&fixture.alice_session.root_key, &tampered_accepted).unwrap();
        let rejected_binding = pending
            .complete_initiator_handshake(
                &fixture.alice.identity,
                &fixture.bob.identity,
                &tampered_accepted,
                handshake_now(),
                &mut CapabilityProofReplayGuard::default(),
            )
            .unwrap_err();
        assert!(
            rejected_binding
                .to_string()
                .contains("capability transcript binding")
        );

        let mut first = fixture.alice_session.clone();
        let mut replay = fixture.alice_session.clone();
        let mut replay_guard = CapabilityProofReplayGuard::default();
        first
            .complete_initiator_handshake(
                &fixture.alice.identity,
                &fixture.bob.identity,
                &fixture.accepted,
                handshake_now(),
                &mut replay_guard,
            )
            .unwrap();
        let initiator_projection = first
            .capability_projection()
            .expect("initiator capability negotiation must be verified during completion");
        assert_eq!(
            initiator_projection.negotiated_protocol_capabilities,
            fixture
                .accepted
                .capability_binding
                .negotiated_protocol_capabilities
        );
        let replay_error = replay
            .complete_initiator_handshake(
                &fixture.alice.identity,
                &fixture.bob.identity,
                &fixture.accepted,
                handshake_now(),
                &mut replay_guard,
            )
            .unwrap_err();
        assert!(replay_error.to_string().contains("replay rejected"));
    }

    #[test]
    fn secure_mesh_pairwise_replay_guards_are_explicitly_owned_and_parallel_isolated() {
        let fixture = handshake_fixture();
        let mut workers = (0..16)
            .map(|index| {
                let mut session = fixture.alice_session.clone();
                let local_identity = fixture.alice.identity.clone();
                let remote_identity = fixture.bob.identity.clone();
                let accepted = fixture.accepted.clone();
                std::thread::spawn(move || {
                    if index % 3 == 0 {
                        std::thread::yield_now();
                    }
                    let mut replay_guard = CapabilityProofReplayGuard::default();
                    session.complete_initiator_handshake(
                        &local_identity,
                        &remote_identity,
                        &accepted,
                        handshake_now(),
                        &mut replay_guard,
                    )
                })
            })
            .collect::<Vec<_>>();
        if workers.len() % 2 == 0 {
            workers.reverse();
        }
        for worker in workers {
            worker
                .join()
                .expect("parallel replay-guard worker must not panic")
                .expect("independently owned replay guard must not inherit another worker's state");
        }
    }

    #[test]
    fn secure_mesh_pairwise_responder_requires_valid_initiator_finished_message() {
        let mut fixture = handshake_fixture();
        let finished = fixture
            .alice_session
            .complete_initiator_handshake(
                &fixture.alice.identity,
                &fixture.bob.identity,
                &fixture.accepted,
                handshake_now(),
                &mut CapabilityProofReplayGuard::default(),
            )
            .unwrap();
        assert!(
            fixture
                .bob_session
                .seal_message("msg-responder-too-early", b"blocked")
                .is_err()
        );

        let first = fixture
            .alice_session
            .seal_message("msg-after-finished", b"initiator application data")
            .unwrap();
        let early_error = fixture.bob_session.open_message(&first).unwrap_err();
        assert!(
            early_error
                .to_string()
                .contains("confirmation is incomplete")
        );
        assert!(!fixture.bob_session.initiator_key_confirmed);
        assert_eq!(fixture.bob_session.dh_epoch(), 0);

        let mut wrong_binding = finished.clone();
        wrong_binding.capability_transcript_digest =
            crate::core::secure_mesh_capability_proof::encode_sha256_digest(&[0x5a; 32]);
        let wrong_binding_error = fixture
            .bob_session
            .complete_responder_handshake(&wrong_binding)
            .unwrap_err();
        assert!(
            wrong_binding_error
                .to_string()
                .contains("capability transcript mismatch")
        );

        let mut forged_finished = finished.clone();
        let mut confirmation = general_purpose::URL_SAFE_NO_PAD
            .decode(&forged_finished.key_confirmation)
            .unwrap();
        confirmation[0] ^= 1;
        forged_finished.key_confirmation = general_purpose::URL_SAFE_NO_PAD.encode(confirmation);
        let forged_error = fixture
            .bob_session
            .complete_responder_handshake(&forged_finished)
            .unwrap_err();
        assert!(forged_error.to_string().contains("verification failed"));
        assert!(
            fixture
                .bob_session
                .seal_message("msg-responder-still-too-early", b"blocked")
                .is_err()
        );

        fixture
            .bob_session
            .complete_responder_handshake(&finished)
            .unwrap();
        assert!(fixture.bob_session.initiator_key_confirmed);
        assert!(!fixture.bob_session.pending_sending_ratchet());
        assert_eq!(
            fixture.bob_session.open_message(&first).unwrap().body,
            b"initiator application data"
        );
        assert!(fixture.bob_session.initiator_key_confirmed);
        assert!(fixture.bob_session.pending_sending_ratchet());
        assert_eq!(
            fixture
                .bob_session
                .seal_message("msg-responder-confirmed", b"allowed")
                .unwrap()
                .dh_epoch,
            2
        );
    }

    #[test]
    fn secure_mesh_pairwise_rejects_unbounded_headers_and_chain_gaps_without_state_advance() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first = alice_session
            .seal_message("msg-bounds", b"bounded")
            .unwrap();

        let mut huge_gap = first.clone();
        huge_gap.chain_index = u64::MAX;
        assert!(
            bob_session
                .open_message(&huge_gap)
                .unwrap_err()
                .to_string()
                .contains("skipped-key limit exceeded")
        );
        assert_eq!(bob_session.dh_epoch(), 0);
        assert_eq!(bob_session.received_count(), 0);

        let mut huge_header = first.clone();
        huge_header.encrypted_header =
            "A".repeat(encoded_len_limit(MAX_CONTENT_ENCRYPTED_HEADER_BYTES).saturating_add(1));
        assert_eq!(
            bob_session
                .open_message(&huge_header)
                .unwrap_err()
                .to_string(),
            "secure mesh pairwise encrypted header is too large"
        );
        assert_eq!(bob_session.dh_epoch(), 0);
        assert_eq!(bob_session.received_count(), 0);

        let mut impossible_ciphertext = first.clone();
        impossible_ciphertext.ciphertext_size = MAX_CIPHERTEXT_BYTES.saturating_add(1);
        assert_eq!(
            bob_session
                .open_message(&impossible_ciphertext)
                .unwrap_err()
                .to_string(),
            "secure mesh pairwise ciphertext size is outside bounds"
        );
        assert_eq!(bob_session.dh_epoch(), 0);
        assert_eq!(bob_session.received_count(), 0);
        assert_eq!(bob_session.open_message(&first).unwrap().body, b"bounded");
    }

    #[test]
    fn secure_mesh_pairwise_pqxdh_derives_matching_independent_triple_ratchet_secrets() {
        let alice = fixed_endpoint("desktop_gui:alice-vector", 1, 91);
        let bob = fixed_endpoint("mobile:bob-vector", 2, 92);
        let bob_prekeys = fixed_prekeys(&bob, 3, 4);
        let alice_ephemeral = fixed_pairwise_key(5);
        let alice_ratchet = fixed_pairwise_key(6);
        let initiator_classical_secret = derive_pqxdh_classical_initiator_secret(
            &alice.identity,
            &alice.identity_secret,
            &alice_ephemeral,
            &bob_prekeys.bundle,
        )
        .unwrap();
        let mlkem1024 =
            encapsulate_ml_kem_1024(&bob_prekeys.bundle.one_time_mlkem1024_prekey.public_key)
                .unwrap();
        let session_id = derive_session_id(
            &alice.identity,
            &bob.identity,
            &alice_ephemeral.public_key(),
            "spk-vector",
            &bob_prekeys.bundle.signed_prekey.public_key,
            Some("otpk-vector"),
            bob_prekeys
                .bundle
                .one_time_prekey
                .as_ref()
                .map(|record| record.public_key.as_slice()),
            "pqotpk-vector",
            &bob_prekeys.bundle.one_time_mlkem1024_prekey.public_key,
            &mlkem1024.ciphertext,
            "sha256:vector-tree-head",
        )
        .unwrap();
        let mut intro = SecureMeshPairwiseSessionIntro {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: session_id.clone(),
            initiator_endpoint_id: alice.identity.endpoint_id.clone(),
            responder_endpoint_id: bob.identity.endpoint_id.clone(),
            initiator_identity_public_key: alice.identity.identity_public_key.to_vec(),
            initiator_ephemeral_public_key: alice_ephemeral.public_key().to_vec(),
            initiator_initial_ratchet_public_key: alice_ratchet.public_key().to_vec(),
            responder_signed_prekey_id: "spk-vector".to_string(),
            responder_one_time_prekey_id: Some("otpk-vector".to_string()),
            responder_one_time_mlkem1024_prekey_id: "pqotpk-vector".to_string(),
            mlkem1024_ciphertext: mlkem1024.ciphertext.clone(),
            directory_authorization_digest: "42".repeat(32),
            initiator_capability_proof: sign_capability_proof(
                &alice.identity,
                &alice.signing_key,
                &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
                &capability_proof_request([0x42; 32], handshake_now()).unwrap(),
            )
            .unwrap(),
            initiator_signature: String::new(),
        };
        intro.initiator_signature = sign_pairwise_transcript(
            &alice.signing_key,
            &intro_signature_payload(&intro).unwrap(),
        );
        let responder_classical_secret = derive_pqxdh_classical_responder_secret(
            &bob.identity_secret,
            &bob_prekeys.signed_secret,
            Some(&bob_prekeys.one_time_secret),
            &intro,
        )
        .unwrap();
        assert_eq!(
            initiator_classical_secret.as_slice(),
            responder_classical_secret.as_slice()
        );
        let responder_mlkem1024_secret = decapsulate_ml_kem_1024(
            &bob_prekeys.one_time_mlkem1024_seed,
            &bob_prekeys.bundle.one_time_mlkem1024_prekey.public_key,
            &intro.mlkem1024_ciphertext,
        )
        .unwrap();
        let initiator_triple_secrets = derive_triple_ratchet_initial_secrets(
            initiator_classical_secret.as_slice(),
            mlkem1024.shared_secret(),
            &alice.identity.identity_public_key,
            &bob.identity.identity_public_key,
            session_id.as_bytes(),
        )
        .unwrap();
        let responder_triple_secrets = derive_triple_ratchet_initial_secrets(
            responder_classical_secret.as_slice(),
            &responder_mlkem1024_secret,
            &alice.identity.identity_public_key,
            &bob.identity.identity_public_key,
            session_id.as_bytes(),
        )
        .unwrap();
        assert_eq!(
            initiator_triple_secrets.ec_secret(),
            responder_triple_secrets.ec_secret()
        );
        assert_eq!(
            initiator_triple_secrets.scka_secret(),
            responder_triple_secrets.scka_secret()
        );
        assert_ne!(
            initiator_triple_secrets.ec_secret(),
            initiator_triple_secrets.scka_secret()
        );
    }

    #[test]
    fn secure_mesh_pairwise_triple_ratchet_combines_ec_and_sparse_pq_messages() {
        let alice_ratchet = fixed_pairwise_key(34);
        let bob_ratchet = fixed_pairwise_key(35);
        let mut alice_session = deterministic_pairwise_session(
            "pairwise-vector-session",
            "desktop_gui:alice-vector",
            "mobile:bob-vector",
            "desktop_gui:alice-vector",
            "mobile:bob-vector",
            [33u8; PUBLIC_KEY_LEN],
            alice_ratchet.clone(),
            bob_ratchet.public_key(),
        )
        .unwrap();
        let mut bob_session = deterministic_pairwise_session(
            "pairwise-vector-session",
            "mobile:bob-vector",
            "desktop_gui:alice-vector",
            "desktop_gui:alice-vector",
            "mobile:bob-vector",
            [33u8; PUBLIC_KEY_LEN],
            bob_ratchet,
            alice_ratchet.public_key(),
        )
        .unwrap();
        let first = alice_session
            .seal_message_with_nonce(
                "msg-vector-1",
                b"pairwise deterministic vector",
                [44u8; NONCE_LEN],
            )
            .unwrap();
        assert_eq!(first.dh_epoch, 0);
        assert_eq!(first.chain_index, 0);
        assert_eq!(first.previous_chain_length, 0);
        assert_eq!(first.sparse_pq_header.message_number, 1);
        assert!(!message_aad(&first).unwrap().is_empty());
        assert_eq!(first.encrypted_header, "LCwsLCwsLCwsLCws");
        assert_eq!(first.ciphertext_size, 45);
        assert!(!first.ciphertext.contains("pairwise deterministic vector"));
        let opened_first = bob_session.open_message(&first).unwrap();
        assert_eq!(opened_first.body, b"pairwise deterministic vector");

        alice_session
            .rotate_sending_ratchet_with_secret(fixed_pairwise_key(36))
            .unwrap();
        let after_ratchet = alice_session
            .seal_message_with_nonce("msg-vector-2", b"dh ratchet vector", [45u8; NONCE_LEN])
            .unwrap();
        assert_eq!(after_ratchet.dh_epoch, 1);
        assert_eq!(after_ratchet.chain_index, 0);
        assert_eq!(after_ratchet.previous_chain_length, 1);
        assert_eq!(after_ratchet.sparse_pq_header.message_number, 2);
        assert_eq!(after_ratchet.encrypted_header, "LS0tLS0tLS0tLS0t");
        assert_eq!(after_ratchet.ciphertext_size, 33);
        let opened_after_ratchet = bob_session.open_message(&after_ratchet).unwrap();
        assert_eq!(opened_after_ratchet.body, b"dh ratchet vector");
    }

    fn durable_store_path(test_name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let mut path = std::env::temp_dir();
        path.push(format!(
            "lico-secure-mesh-pairwise-{test_name}-{}-{nonce}.sqlite3",
            std::process::id()
        ));
        path
    }

    fn test_secret_store() -> Arc<dyn SecureMeshSecretStore> {
        Arc::new(EphemeralSecretStore::new())
    }

    struct FailOnceDeleteSecretStore {
        inner: EphemeralSecretStore,
        fail_next_delete: AtomicBool,
    }

    impl FailOnceDeleteSecretStore {
        fn new() -> Self {
            Self {
                inner: EphemeralSecretStore::new(),
                fail_next_delete: AtomicBool::new(true),
            }
        }
    }

    impl SecureMeshSecretStore for FailOnceDeleteSecretStore {
        fn backend(&self) -> &'static str {
            self.inner.backend()
        }

        fn supported(&self) -> bool {
            self.inner.supported()
        }

        fn capability_facts(
            &self,
        ) -> Result<Vec<crate::core::secure_mesh_capability::CapabilityFact>> {
            self.inner.capability_facts()
        }

        fn begin_authorized_session(
            &self,
            request: &SecretStoreAuthorizationRequest,
        ) -> Result<SecretStoreAuthorizationSession> {
            self.inner.begin_authorized_session(request)
        }

        fn set_secret(&self, handle: &SecretStoreHandle, secret: &str) -> Result<()> {
            self.inner.set_secret(handle, secret)
        }

        fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<String>> {
            self.inner.get_secret(handle)
        }

        fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
            if self.fail_next_delete.swap(false, Ordering::SeqCst) {
                return Err(anyhow!("injected secret deletion failure"));
            }
            self.inner.delete_secret(handle)
        }
    }

    fn durable_store_namespace(test_name: &str) -> String {
        format!("pairwise-test-{test_name}")
    }

    fn open_test_durable_store(
        store_path: &Path,
        secret_store: Arc<dyn SecureMeshSecretStore>,
        test_name: &str,
    ) -> SecureMeshPairwiseDurableStore {
        SecureMeshPairwiseDurableStore::open_with_secret_store(
            store_path,
            secret_store,
            durable_store_namespace(test_name),
        )
        .unwrap()
    }

    #[test]
    fn secure_mesh_pairwise_wire_profile_ignores_app_version_and_rejects_revision_mismatch() {
        let simulated_app_versions = ["0.0.1-alpha", "0.0.2", "27.4.9"];
        let digests = simulated_app_versions
            .iter()
            .map(|_| secure_mesh_pairwise_build_protocol_digest().unwrap())
            .collect::<Vec<_>>();
        assert!(digests.windows(2).all(|pair| pair[0] == pair[1]));

        let endpoint = endpoint("desktop_gui:wire-profile-revision");
        for incompatible_revision in [
            SECURE_MESH_PROTOCOL_BUILD_REVISION - 1,
            SECURE_MESH_PROTOCOL_BUILD_REVISION + 1,
        ] {
            let incompatible_digest =
                secure_mesh_pairwise_build_protocol_digest_for_revision(incompatible_revision)
                    .unwrap();
            assert_ne!(digests[0], incompatible_digest);
            let request = CapabilityProofRequest {
                build_protocol_digest: incompatible_digest,
                policy_revision: SECURE_MESH_PAIRWISE_CAPABILITY_POLICY_REVISION,
                challenge: [0x6d; 32],
                issued_at_unix_seconds: handshake_now().unix_timestamp() - 1,
                expires_at_unix_seconds: handshake_now().unix_timestamp() + 60,
            };
            let proof = sign_capability_proof(
                &endpoint.identity,
                &endpoint.signing_key,
                &secure_mesh_pairwise_test_capability_evaluation().unwrap(),
                &request,
            )
            .unwrap();
            let context = CapabilityProofVerificationContext {
                expected_build_protocol_digest: digests[0].clone(),
                expected_policy_revision: SECURE_MESH_PAIRWISE_CAPABILITY_POLICY_REVISION,
                expected_challenge: request.challenge,
                now_unix_seconds: handshake_now().unix_timestamp(),
            };
            let error = crate::core::secure_mesh_capability_proof::verify_capability_proof(
                &endpoint.identity,
                &proof,
                &context,
            )
            .unwrap_err();
            assert!(error.to_string().contains("build protocol binding"));
        }
    }

    #[test]
    fn secure_mesh_pairwise_durable_capability_replay_ledger_survives_reopen_and_is_redacted() {
        let store_path = durable_store_path("capability-replay");
        let _ = std::fs::remove_file(&store_path);
        let fixture = handshake_fixture();
        let namespace = "pairwise-test-capability-replay";
        let now = handshake_now().unix_timestamp();
        {
            let mut store = SecureMeshPairwiseDurableStore::open_with_secret_store(
                &store_path,
                test_secret_store(),
                namespace,
            )
            .unwrap();
            store
                .consume_capability_proof_pair(
                    &fixture.bob.identity.endpoint_id,
                    &fixture.accepted.responder_capability_proof,
                    &fixture.intro.initiator_capability_proof,
                    now,
                )
                .unwrap();
        }
        let mut reopened = SecureMeshPairwiseDurableStore::open_with_secret_store(
            &store_path,
            test_secret_store(),
            namespace,
        )
        .unwrap();
        let replay = reopened
            .consume_capability_proof_pair(
                &fixture.bob.identity.endpoint_id,
                &fixture.accepted.responder_capability_proof,
                &fixture.intro.initiator_capability_proof,
                now,
            )
            .unwrap_err();
        assert!(replay.to_string().contains("replay rejected"));

        let connection = TestConnection::open(&store_path).unwrap();
        let count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM secure_mesh_pairwise_capability_proof_uses",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 2);
        let rows = connection
            .prepare(
                "SELECT local_endpoint_scope_hash, proof_digest, expires_at_unix_seconds FROM secure_mesh_pairwise_capability_proof_uses ORDER BY proof_digest",
            )
            .unwrap()
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        assert!(rows.iter().all(|(scope, digest, expiry)| {
            scope.len() == 64
                && digest.starts_with("sha256:")
                && *expiry >= now
                && !scope.contains(&fixture.bob.identity.endpoint_id)
                && !digest.contains(&fixture.bob.identity.endpoint_id)
        }));
        drop(connection);
        let database_bytes = std::fs::read(&store_path).unwrap();
        for forbidden in [
            fixture.bob.identity.endpoint_id.as_bytes(),
            fixture.alice.identity.endpoint_id.as_bytes(),
            fixture
                .accepted
                .responder_capability_proof
                .signature
                .as_bytes(),
            fixture
                .intro
                .initiator_capability_proof
                .signature
                .as_bytes(),
        ] {
            assert!(
                !database_bytes
                    .windows(forbidden.len())
                    .any(|window| window == forbidden)
            );
        }
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_capability_replay_and_session_commit_are_atomic() {
        let store_path = durable_store_path("capability-session-atomic");
        let _ = std::fs::remove_file(&store_path);
        let fixture = handshake_fixture();
        let mut store = open_test_durable_store(
            &store_path,
            test_secret_store(),
            "capability-session-atomic",
        );
        let mut session = fixture.alice_session;
        let initial = store
            .upsert_initial(&session, "2026-06-26T00:00:01Z")
            .unwrap();
        session
            .complete_initiator_handshake(
                &fixture.alice.identity,
                &fixture.bob.identity,
                &fixture.accepted,
                handshake_now(),
                &mut CapabilityProofReplayGuard::default(),
            )
            .unwrap();
        let authorization = store
            .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                "pairwise atomic capability commit test",
                6,
            ))
            .unwrap();
        let committed = store
            .commit_session_with_authorized_session_and_capability_proofs(
                &initial,
                &session,
                session.local_capability_proof(),
                &fixture.accepted.responder_capability_proof,
                handshake_now().unix_timestamp(),
                "2026-06-26T00:00:02Z",
                &authorization,
            )
            .unwrap();
        let replay = store
            .commit_session_with_authorized_session_and_capability_proofs(
                &committed,
                &session,
                session.local_capability_proof(),
                &fixture.accepted.responder_capability_proof,
                handshake_now().unix_timestamp(),
                "2026-06-26T00:00:03Z",
                &authorization,
            )
            .unwrap_err();
        assert!(replay.to_string().contains("replay rejected"));
        assert_eq!(
            store
                .read_record(&session.session_id, &session.local_endpoint_id)
                .unwrap()
                .unwrap(),
            committed
        );
        let _ = std::fs::remove_file(store_path);
    }

    #[test]
    fn secure_mesh_pairwise_replay_watermark_rejects_expiry_revival_after_clock_rollback() {
        let store_path = durable_store_path("capability-replay-clock-rollback");
        let _ = std::fs::remove_file(&store_path);
        let alice = endpoint("desktop_gui:watermark-alice");
        let bob = endpoint("mobile:watermark-bob");
        let evaluation = secure_mesh_pairwise_test_capability_evaluation().unwrap();
        let sign = |endpoint: &EndpointFixture,
                    challenge: [u8; 32],
                    issued_at_unix_seconds: i64,
                    expires_at_unix_seconds: i64| {
            sign_capability_proof(
                &endpoint.identity,
                &endpoint.signing_key,
                &evaluation,
                &CapabilityProofRequest {
                    build_protocol_digest: secure_mesh_pairwise_build_protocol_digest().unwrap(),
                    policy_revision: SECURE_MESH_PAIRWISE_CAPABILITY_POLICY_REVISION,
                    challenge,
                    issued_at_unix_seconds,
                    expires_at_unix_seconds,
                },
            )
            .unwrap()
        };
        let old_first = sign(&alice, [0x31; 32], 900, 1_000);
        let old_second = sign(&bob, [0x32; 32], 900, 1_000);
        let new_first = sign(&alice, [0x41; 32], 2_000, 2_100);
        let new_second = sign(&bob, [0x42; 32], 2_000, 2_100);
        let namespace = "pairwise-test-capability-replay-clock-rollback";
        {
            let mut store = SecureMeshPairwiseDurableStore::open_with_secret_store(
                &store_path,
                test_secret_store(),
                namespace,
            )
            .unwrap();
            store
                .consume_capability_proof_pair(
                    &bob.identity.endpoint_id,
                    &old_first,
                    &old_second,
                    900,
                )
                .unwrap();
            store
                .consume_capability_proof_pair(
                    &bob.identity.endpoint_id,
                    &new_first,
                    &new_second,
                    2_000,
                )
                .unwrap();
        }
        let mut reopened = SecureMeshPairwiseDurableStore::open_with_secret_store(
            &store_path,
            test_secret_store(),
            namespace,
        )
        .unwrap();
        let revived = reopened
            .consume_capability_proof_pair(&bob.identity.endpoint_id, &old_first, &old_second, 950)
            .unwrap_err();
        assert!(revived.to_string().contains("clock rollback"));
        let _ = std::fs::remove_file(store_path);
    }

    #[test]
    fn secure_mesh_pairwise_local_prekey_proofs_and_initial_session_are_atomic() {
        let store_path = durable_store_path("prekey-proof-session-atomic");
        let _ = std::fs::remove_file(&store_path);
        let fixture = handshake_fixture();
        let mut store = open_test_durable_store(
            &store_path,
            test_secret_store(),
            "prekey-proof-session-atomic",
        );
        let session = fixture.bob_session;
        let original_claim = SecureMeshLocalPreKeyUse {
            local_endpoint_id: session.local_endpoint_id.clone(),
            local_identity_fingerprint: fixture.bob.identity.fingerprint().unwrap(),
            one_time_prekey_id: "atomic-local-prekey-1".to_string(),
            one_time_prekey_public_key_hash: "sha256:atomic-local-prekey-1".to_string(),
            one_time_mlkem1024_prekey_id: "atomic-local-pq-prekey-1".to_string(),
            one_time_mlkem1024_prekey_public_key_hash: "sha256:atomic-local-pq-prekey-1"
                .to_string(),
        };
        store
            .upsert_initial_with_local_prekey_claim_and_capability_proofs(
                &session,
                &original_claim,
                &fixture.accepted.responder_capability_proof,
                &fixture.intro.initiator_capability_proof,
                handshake_now().unix_timestamp(),
                "2026-06-26T00:00:01Z",
            )
            .unwrap();

        let mut replay_session = session.clone();
        replay_session.session_id.push_str("-replay");
        let replay_claim = SecureMeshLocalPreKeyUse {
            local_endpoint_id: replay_session.local_endpoint_id.clone(),
            local_identity_fingerprint: fixture.bob.identity.fingerprint().unwrap(),
            one_time_prekey_id: "atomic-local-prekey-must-rollback".to_string(),
            one_time_prekey_public_key_hash: "sha256:atomic-local-prekey-must-rollback".to_string(),
            one_time_mlkem1024_prekey_id: "atomic-local-pq-prekey-must-rollback".to_string(),
            one_time_mlkem1024_prekey_public_key_hash:
                "sha256:atomic-local-pq-prekey-must-rollback".to_string(),
        };
        let replay = store
            .upsert_initial_with_local_prekey_claim_and_capability_proofs(
                &replay_session,
                &replay_claim,
                &fixture.accepted.responder_capability_proof,
                &fixture.intro.initiator_capability_proof,
                handshake_now().unix_timestamp(),
                "2026-06-26T00:00:02Z",
            )
            .unwrap_err();
        assert!(replay.to_string().contains("replay rejected"));
        assert!(
            store
                .read_record(
                    &replay_session.session_id,
                    &replay_session.local_endpoint_id,
                )
                .unwrap()
                .is_none()
        );
        let connection = TestConnection::open(&store_path).unwrap();
        let rolled_back_prekeys: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM secure_mesh_pairwise_local_prekey_uses WHERE one_time_prekey_id = ?1",
                params![replay_claim.one_time_prekey_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rolled_back_prekeys, 0);
        let _ = std::fs::remove_file(store_path);
    }

    #[test]
    fn secure_mesh_pairwise_remote_prekey_and_initial_session_are_atomic() {
        let store_path = durable_store_path("remote-prekey-session-atomic");
        let _ = std::fs::remove_file(&store_path);
        let (session, _) = pairwise_sessions();
        let mut store = open_test_durable_store(
            &store_path,
            test_secret_store(),
            "remote-prekey-session-atomic",
        );
        let original = SecureMeshRemotePreKeyUse {
            session_id: session.session_id.clone(),
            local_endpoint_id: session.local_endpoint_id.clone(),
            remote_endpoint_id: session.remote_endpoint_id.clone(),
            remote_identity_fingerprint: "sha256:remote-identity-atomic".to_string(),
            signed_prekey_id: "spk-remote-atomic".to_string(),
            one_time_prekey_id: "otpk-remote-atomic".to_string(),
            one_time_prekey_public_key_hash: "sha256:remote-prekey-atomic".to_string(),
            one_time_mlkem1024_prekey_id: "pqotpk-remote-atomic".to_string(),
            one_time_mlkem1024_prekey_public_key_hash: "sha256:remote-pq-prekey-atomic".to_string(),
            directory_authorization_digest: "11".repeat(32),
        };
        store
            .upsert_initial_with_remote_prekey_claim(&session, &original, "2026-06-26T00:00:01Z")
            .unwrap();

        let mut replay_session = session.clone();
        replay_session.session_id.push_str("-replay");
        let mut replay = original.clone();
        replay.session_id = replay_session.session_id.clone();
        let error = store
            .upsert_initial_with_remote_prekey_claim(
                &replay_session,
                &replay,
                "2026-06-26T00:00:02Z",
            )
            .unwrap_err();
        assert!(error.to_string().contains("already used"));
        assert!(
            store
                .read_record(
                    &replay_session.session_id,
                    &replay_session.local_endpoint_id,
                )
                .unwrap()
                .is_none()
        );
        let _ = std::fs::remove_file(store_path);
    }

    #[test]
    fn secure_mesh_pairwise_memory_only_restart_purges_unrecoverable_public_session() {
        let store_path = durable_store_path("memory-restart-purge");
        let _ = std::fs::remove_file(&store_path);
        let (alice_session, _) = pairwise_sessions();
        let namespace = durable_store_namespace("memory-restart-purge");
        {
            let mut store = SecureMeshPairwiseDurableStore::open_with_secret_store(
                &store_path,
                Arc::new(EphemeralSecretStore::new()),
                namespace.clone(),
            )
            .unwrap();
            store
                .upsert_initial(&alice_session, "2026-06-26T00:02:00Z")
                .unwrap();
            assert!(
                store
                    .read_record(&alice_session.session_id, &alice_session.local_endpoint_id)
                    .unwrap()
                    .is_some()
            );
        }
        let mut restarted = SecureMeshPairwiseDurableStore::open_with_secret_store(
            &store_path,
            Arc::new(EphemeralSecretStore::new()),
            namespace,
        )
        .unwrap();
        assert_eq!(
            restarted
                .purge_unrecoverable_memory_only_sessions()
                .unwrap(),
            1
        );
        assert!(
            restarted
                .read_record(&alice_session.session_id, &alice_session.local_endpoint_id)
                .unwrap()
                .is_none()
        );
        assert!(
            restarted
                .load_session(&alice_session.session_id, &alice_session.local_endpoint_id)
                .unwrap()
                .is_none()
        );
        let _ = std::fs::remove_file(&store_path);
    }

    fn stored_snapshot_json(
        store_path: &Path,
        session_id: &str,
        local_endpoint_id: &str,
    ) -> String {
        TestConnection::open(store_path)
            .unwrap()
            .query_row(
                r#"
                SELECT snapshot_json
                FROM secure_mesh_pairwise_sessions
                WHERE session_id = ?1 AND local_endpoint_id = ?2
                "#,
                params![session_id, local_endpoint_id],
                |row| row.get(0),
            )
            .unwrap()
    }

    fn payload_context(
        session: &SecureMeshPairwiseSession,
        message_id: &str,
        sender: &str,
        recipient: &str,
    ) -> SecureMeshContentContext {
        payload_context_with_mailbox(
            session,
            message_id,
            "mailbox-pairwise-payload",
            sender,
            recipient,
        )
    }

    fn payload_context_with_mailbox(
        session: &SecureMeshPairwiseSession,
        message_id: &str,
        mailbox_id: &str,
        sender: &str,
        recipient: &str,
    ) -> SecureMeshContentContext {
        SecureMeshContentContext::new(
            relay_delivery_id(message_id),
            message_id,
            relay_mailbox_token(mailbox_id),
            sender,
            recipient,
            session.session_id.clone(),
            "2026-06-26T00:00:00Z",
            "2026-06-26T00:10:00Z",
        )
    }

    fn relay_delivery_id(label: &str) -> String {
        general_purpose::URL_SAFE_NO_PAD.encode(&Sha256::digest(label.as_bytes())[..24])
    }

    fn relay_mailbox_token(label: &str) -> String {
        general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(label.as_bytes()))
    }

    #[derive(Default)]
    struct OpaquePairwiseRelay {
        pending: Vec<SecureMeshRelayEnvelope>,
        acked_delivery_ids: Vec<String>,
    }

    impl OpaquePairwiseRelay {
        fn send(&mut self, envelope: SecureMeshRelayEnvelope, forbidden_plaintext: &str) {
            assert_eq!(
                envelope.schema(),
                crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_ENVELOPE_SCHEMA
            );
            assert!(!envelope.delivery_id().contains(forbidden_plaintext));
            assert!(!envelope.mailbox_token().contains(forbidden_plaintext));
            assert!(!envelope.encrypted_header().contains(forbidden_plaintext));
            assert!(!envelope.ciphertext().contains(forbidden_plaintext));
            self.pending.push(envelope);
        }

        fn sync(&self, mailbox_token: &str) -> Vec<SecureMeshRelayEnvelope> {
            let mailbox_token = if mailbox_token.len() == 43 {
                mailbox_token.to_string()
            } else {
                relay_mailbox_token(mailbox_token)
            };
            self.pending
                .iter()
                .filter(|envelope| envelope.mailbox_token() == mailbox_token)
                .cloned()
                .collect()
        }

        fn ack(&mut self, message_label: &str) -> bool {
            let delivery_id = relay_delivery_id(message_label);
            let before = self.pending.len();
            self.pending
                .retain(|envelope| envelope.delivery_id() != delivery_id);
            let idempotent = before == self.pending.len();
            if !self.acked_delivery_ids.iter().any(|id| id == &delivery_id) {
                self.acked_delivery_ids.push(delivery_id);
            }
            idempotent
        }

        fn queue_len(&self) -> usize {
            self.pending.len()
        }
    }

    #[derive(Default)]
    struct PcRelayExecutor {
        calls: usize,
    }

    impl SecureCommandLocalExecutor for PcRelayExecutor {
        fn execute_secure_command(&mut self, payload: &SecureCommandPayload) -> Result<Value> {
            self.calls += 1;
            assert_eq!(payload.command_kind, "agent.message.send");
            Ok(json!({
                "accepted": true,
                "message": payload.body().get("message").and_then(Value::as_str).unwrap_or_default(),
            }))
        }
    }

    fn pc_pc_command_fixture(command_id: &str, idempotency_key: &str, message: &str) -> Value {
        json!({
            "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "commandId": command_id,
            "commandKind": "agent.message.send",
            "senderIdentity": {
                "endpointId": "desktop_sidecar:pc-a",
                "identityFingerprint": "fingerprint-pc-a",
                "trustState": "verified",
                "endpointKind": "desktop_sidecar"
            },
            "targetBinding": {
                "targetEndpointId": "desktop_sidecar:pc-b",
                "targetAgentId": "agent-pc-b",
                "workspaceId": "workspace-a"
            },
            "riskClass": "safe_write",
            "requiresUserConfirmation": false,
            "idempotencyKey": idempotency_key,
            "createdAt": "2026-06-26T00:00:00Z",
            "expiresAt": "2026-06-26T00:10:00Z",
            "body": {"message": message}
        })
    }

    fn pc_pc_command_context_fixture() -> Value {
        json!({
            "localEndpointId": "desktop_sidecar:pc-b",
            "senderEndpointId": "desktop_sidecar:pc-a",
            "senderIdentityFingerprint": "fingerprint-pc-a",
            "senderTrustState": "verified",
            "senderEndpointKind": "desktop_sidecar",
            "senderRosterActive": true,
            "targetRosterActive": true,
            "sessionOrEpochValid": true,
            "userConfirmed": false,
            "allowedWorkspaceIds": ["workspace-a"],
            "allowedAgentIds": ["agent-pc-b"],
            "now": "2026-06-26T00:01:00Z"
        })
    }

    fn command_fixture_for_endpoints(
        command_id: &str,
        idempotency_key: &str,
        sender_endpoint_id: &str,
        sender_endpoint_kind: &str,
        sender_fingerprint: &str,
        target_endpoint_id: &str,
        target_agent_id: &str,
        workspace_id: &str,
        message: &str,
    ) -> Value {
        json!({
            "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "commandId": command_id,
            "commandKind": "agent.message.send",
            "senderIdentity": {
                "endpointId": sender_endpoint_id,
                "identityFingerprint": sender_fingerprint,
                "trustState": "verified",
                "endpointKind": sender_endpoint_kind
            },
            "targetBinding": {
                "targetEndpointId": target_endpoint_id,
                "targetAgentId": target_agent_id,
                "workspaceId": workspace_id
            },
            "riskClass": "safe_write",
            "requiresUserConfirmation": false,
            "idempotencyKey": idempotency_key,
            "createdAt": "2026-06-26T00:00:00Z",
            "expiresAt": "2026-06-26T00:10:00Z",
            "body": {"message": message}
        })
    }

    fn command_context_for_endpoints(
        local_endpoint_id: &str,
        sender_endpoint_id: &str,
        sender_endpoint_kind: &str,
        sender_fingerprint: &str,
        target_agent_id: &str,
        workspace_id: &str,
    ) -> Value {
        json!({
            "localEndpointId": local_endpoint_id,
            "senderEndpointId": sender_endpoint_id,
            "senderIdentityFingerprint": sender_fingerprint,
            "senderTrustState": "verified",
            "senderEndpointKind": sender_endpoint_kind,
            "senderRosterActive": true,
            "targetRosterActive": true,
            "sessionOrEpochValid": true,
            "userConfirmed": false,
            "allowedWorkspaceIds": [workspace_id],
            "allowedAgentIds": [target_agent_id],
            "now": "2026-06-26T00:01:00Z"
        })
    }

    fn assert_relay_envelope_hides(
        envelope: &SecureMeshRelayEnvelope,
        forbidden_plaintext: &[&str],
    ) {
        for forbidden in forbidden_plaintext {
            assert!(
                !envelope.delivery_id().contains(forbidden),
                "delivery id leaked {forbidden}"
            );
            assert!(
                !envelope.mailbox_token().contains(forbidden),
                "mailbox token leaked {forbidden}"
            );
            assert!(
                !envelope.encrypted_header().contains(forbidden),
                "encrypted header leaked {forbidden}"
            );
            assert!(
                !envelope.ciphertext().contains(forbidden),
                "ciphertext leaked {forbidden}"
            );
        }
    }

    #[test]
    fn secure_mesh_pairwise_relay_header_public_boundary_is_explicit_and_payload_free() {
        let (mut sender_session, mut receiver_session) = pairwise_sessions_between(
            "desktop_sidecar:relay-header-sender-private-canary",
            "mobile:relay-header-recipient-private-canary",
        );
        let context = payload_context_with_mailbox(
            &sender_session,
            "msg-relay-header-boundary",
            "mailbox-relay-header-boundary",
            &sender_session.local_endpoint_id,
            &sender_session.remote_endpoint_id,
        );
        let plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Command,
            serde_json::to_vec(&json!({
                "commandKind": "agent.message.send",
                "targetEndpointId": "mobile:relay-header-recipient-private-canary",
                "targetAgentId": "agent-relay-header-private-canary",
                "token": (["relay", "header", "private", "token", "canary"].join("-")),
                "fileName": "relay-header-private-file-canary.txt",
                "path": "/tmp/relay-header-private-path-canary",
                "body": {"message": "relay-header-private-payload-canary"}
            }))
            .unwrap(),
        )
        .with_content_type("application/json");
        let envelope = sender_session
            .seal_payload_envelope(&context, &plaintext)
            .unwrap();
        let relay_header_bytes = envelope.decoded_encrypted_header().unwrap();
        let relay_header_wire = String::from_utf8_lossy(&relay_header_bytes);
        for forbidden in [
            "relay-header-sender-private-canary",
            "relay-header-recipient-private-canary",
            "agent-relay-header-private-canary",
            "relay-header-private-token-canary",
            "relay-header-private-file-canary.txt",
            "relay-header-private-path-canary",
            "relay-header-private-payload-canary",
            "agent.message.send",
        ] {
            assert!(
                !relay_header_wire.contains(forbidden),
                "pairwise relay header leaked {forbidden}"
            );
        }
        assert_relay_envelope_hides(
            &envelope,
            &[
                "relay-header-sender-private-canary",
                "relay-header-recipient-private-canary",
                "agent-relay-header-private-canary",
                "relay-header-private-token-canary",
                "relay-header-private-file-canary.txt",
                "relay-header-private-path-canary",
                "relay-header-private-payload-canary",
                "agent.message.send",
            ],
        );
        let opened = receiver_session
            .open_payload_envelope(&envelope, SecureMeshPayloadKind::Command)
            .unwrap();
        assert_eq!(opened.body, plaintext.body);
    }

    #[test]
    fn secure_mesh_pairwise_envelope_failure_rolls_back_complete_triple_ratchet_state() {
        let (mut sender, _) = pairwise_sessions();
        let mut context = payload_context_with_mailbox(
            &sender,
            "msg-envelope-transaction",
            "mailbox-envelope-transaction",
            &sender.local_endpoint_id,
            &sender.remote_endpoint_id,
        );
        context.created_at = "x".repeat(4096);
        let before = Zeroizing::new(
            serde_json::to_vec(
                &sender
                    .to_secret_snapshot(1, "transaction-test".to_string())
                    .unwrap(),
            )
            .unwrap(),
        );

        let error = sender
            .seal_payload_envelope(
                &context,
                &SecureMeshPlaintext::new(
                    SecureMeshPayloadKind::Command,
                    b"must not advance state",
                ),
            )
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("private relay header payload is too large")
        );

        let after = Zeroizing::new(
            serde_json::to_vec(
                &sender
                    .to_secret_snapshot(1, "transaction-test".to_string())
                    .unwrap(),
            )
            .unwrap(),
        );
        assert_eq!(before.as_slice(), after.as_slice());
    }

    struct CommandRelayScenario<'a> {
        label: &'a str,
        sender_endpoint_id: &'a str,
        sender_endpoint_kind: &'a str,
        recipient_endpoint_id: &'a str,
        target_agent_id: &'a str,
        workspace_id: &'a str,
        sender_mailbox_id: &'a str,
        recipient_mailbox_id: &'a str,
        canary: &'a str,
    }

    fn assert_pairwise_command_result_relay_round_trip(scenario: CommandRelayScenario<'_>) {
        let (mut sender_session, mut recipient_session) =
            pairwise_sessions_between(scenario.sender_endpoint_id, scenario.recipient_endpoint_id);
        let mut relay = OpaquePairwiseRelay::default();
        let sender_fingerprint = format!("fingerprint-{}-sender", scenario.label);
        let command_id = format!("cmd-{}-1", scenario.label);
        let idempotency_key = format!("idem-{}-1", scenario.label);
        let command_message_id = format!("msg-{}-command", scenario.label);
        let result_message_id = format!("msg-{}-result", scenario.label);
        let command = command_fixture_for_endpoints(
            &command_id,
            &idempotency_key,
            scenario.sender_endpoint_id,
            scenario.sender_endpoint_kind,
            &sender_fingerprint,
            scenario.recipient_endpoint_id,
            scenario.target_agent_id,
            scenario.workspace_id,
            scenario.canary,
        );
        let command_context = payload_context_with_mailbox(
            &sender_session,
            &command_message_id,
            scenario.recipient_mailbox_id,
            scenario.sender_endpoint_id,
            scenario.recipient_endpoint_id,
        );
        let command_plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Command,
            serde_json::to_vec(&command).unwrap(),
        )
        .with_content_type("application/json");
        let command_envelope = sender_session
            .seal_payload_envelope(&command_context, &command_plaintext)
            .unwrap();
        assert_relay_envelope_hides(
            &command_envelope,
            &[
                scenario.canary,
                scenario.sender_endpoint_id,
                scenario.recipient_endpoint_id,
                scenario.target_agent_id,
                "agent.message.send",
            ],
        );
        relay.send(command_envelope, scenario.canary);
        let synced_for_recipient = relay.sync(scenario.recipient_mailbox_id);
        assert_eq!(synced_for_recipient.len(), 1);
        let opened_command = recipient_session
            .open_payload_envelope(&synced_for_recipient[0], SecureMeshPayloadKind::Command)
            .unwrap();
        let command_value: Value = serde_json::from_slice(&opened_command.body).unwrap();
        assert_eq!(command_value["body"]["message"], scenario.canary);
        assert_eq!(
            command_value["targetBinding"]["targetEndpointId"],
            scenario.recipient_endpoint_id
        );

        let command_payload = SecureCommandPayload::from_value(&command_value).unwrap();
        let command_gate =
            SecureCommandEvaluationContext::from_value(&command_context_for_endpoints(
                scenario.recipient_endpoint_id,
                scenario.sender_endpoint_id,
                scenario.sender_endpoint_kind,
                &sender_fingerprint,
                scenario.target_agent_id,
                scenario.workspace_id,
            ))
            .unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation =
            evaluate_secure_command(&command_payload, &command_gate, &mut ledger).unwrap();
        assert!(evaluation.accepted);
        assert!(evaluation.should_execute);
        let mut executor = PcRelayExecutor::default();
        let execution = execute_evaluated_secure_command(
            &command_payload,
            &evaluation,
            &mut executor,
            "2026-06-26T00:02:00Z",
        )
        .unwrap();
        assert_eq!(executor.calls, 1);
        assert!(!relay.ack(&command_message_id));
        assert!(relay.ack(&command_message_id));
        assert_eq!(relay.queue_len(), 0);

        let result = execution.result().unwrap();
        let result_context = payload_context_with_mailbox(
            &recipient_session,
            &result_message_id,
            scenario.sender_mailbox_id,
            scenario.recipient_endpoint_id,
            scenario.sender_endpoint_id,
        );
        let result_plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, result.output.clone())
                .with_content_type("application/json");
        let result_envelope = recipient_session
            .seal_payload_envelope(&result_context, &result_plaintext)
            .unwrap();
        assert_relay_envelope_hides(
            &result_envelope,
            &[
                scenario.canary,
                scenario.sender_endpoint_id,
                scenario.recipient_endpoint_id,
                scenario.target_agent_id,
                "agent.message.send",
            ],
        );
        relay.send(result_envelope, scenario.canary);
        let synced_for_sender = relay.sync(scenario.sender_mailbox_id);
        assert_eq!(synced_for_sender.len(), 1);
        let opened_result = sender_session
            .open_payload_envelope(&synced_for_sender[0], SecureMeshPayloadKind::ResultPayload)
            .unwrap();
        let result_value: Value = serde_json::from_slice(&opened_result.body).unwrap();
        assert_eq!(result_value["ok"], true);
        assert_eq!(result_value["commandKind"], "agent.message.send");
        assert_eq!(result_value["output"]["message"], scenario.canary);
        assert!(!relay.ack(&result_message_id));
        assert!(relay.sync(scenario.sender_mailbox_id).is_empty());
        assert_eq!(relay.queue_len(), 0);
    }

    #[test]
    fn secure_mesh_pairwise_pqxdh_triple_ratchet_round_trips() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first = alice_session
            .seal_message("msg-1", b"hello bob without server plaintext")
            .unwrap();
        assert_eq!(first.dh_epoch, 1);
        assert!(!first.ciphertext.contains("hello"));
        let opened = bob_session.open_message(&first).unwrap();
        assert_eq!(opened.body, b"hello bob without server plaintext");

        let reply = bob_session
            .seal_message("msg-2", b"hello alice encrypted")
            .unwrap();
        assert_eq!(reply.dh_epoch, 2);
        let opened_reply = alice_session.open_message(&reply).unwrap();
        assert_eq!(opened_reply.body, b"hello alice encrypted");

        alice_session.rotate_sending_ratchet().unwrap();
        let after_ratchet = alice_session
            .seal_message("msg-3", b"post compromise recovery direction")
            .unwrap();
        assert_eq!(after_ratchet.dh_epoch, 3);
        let opened_after_ratchet = bob_session.open_message(&after_ratchet).unwrap();
        assert_eq!(
            opened_after_ratchet.body,
            b"post compromise recovery direction"
        );
    }

    #[test]
    fn secure_mesh_pairwise_dh_ratchet_reply_auto_rotates_after_remote_ratchet() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first = alice_session.seal_message("msg-auto-1", b"first").unwrap();
        assert_eq!(first.dh_epoch, 1);
        bob_session.open_message(&first).unwrap();
        assert!(bob_session.pending_sending_ratchet());

        let reply = bob_session
            .seal_message("msg-auto-2", b"bob auto ratchet reply")
            .unwrap();
        assert_eq!(reply.dh_epoch, 2);
        assert_eq!(reply.chain_index, 0);
        assert_eq!(reply.previous_chain_length, 0);
        assert!(!bob_session.pending_sending_ratchet());
        let opened_reply = alice_session.open_message(&reply).unwrap();
        assert_eq!(opened_reply.body, b"bob auto ratchet reply");
        assert!(alice_session.pending_sending_ratchet());

        let next = alice_session
            .seal_message("msg-auto-3", b"alice auto ratchet reply")
            .unwrap();
        assert_eq!(next.dh_epoch, 3);
        assert_eq!(next.chain_index, 0);
        assert_eq!(
            bob_session.open_message(&next).unwrap().body,
            b"alice auto ratchet reply"
        );
    }

    #[test]
    fn secure_mesh_pairwise_dh_ratchet_preserves_old_chain_in_flight_messages() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let old_first = alice_session
            .seal_message("msg-inflight-1", b"old chain first")
            .unwrap();
        let old_second = alice_session
            .seal_message("msg-inflight-2", b"old chain delayed")
            .unwrap();
        assert_eq!(
            bob_session.open_message(&old_first).unwrap().body,
            b"old chain first"
        );
        let bob_reply = bob_session
            .seal_message("msg-inflight-reply", b"ratchet trigger")
            .unwrap();
        alice_session.open_message(&bob_reply).unwrap();
        let new_epoch = alice_session
            .seal_message("msg-inflight-3", b"new epoch arrives first")
            .unwrap();
        assert_eq!(new_epoch.dh_epoch, 3);
        assert_eq!(new_epoch.previous_chain_length, 2);
        assert_eq!(
            bob_session.open_message(&new_epoch).unwrap().body,
            b"new epoch arrives first"
        );
        assert_eq!(bob_session.skipped_key_count(), 1);

        let opened_delayed = bob_session.open_message(&old_second).unwrap();
        assert_eq!(opened_delayed.body, b"old chain delayed");
        assert_eq!(bob_session.skipped_key_count(), 0);
    }

    #[test]
    fn secure_mesh_pairwise_encrypted_headers_preserve_old_chain_envelope_out_of_order() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let old_first_context = payload_context(
            &alice_session,
            "msg-header-inflight-1",
            &alice_session.local_endpoint_id,
            &alice_session.remote_endpoint_id,
        );
        let old_second_context = payload_context(
            &alice_session,
            "msg-header-inflight-2",
            &alice_session.local_endpoint_id,
            &alice_session.remote_endpoint_id,
        );
        let old_first = alice_session
            .seal_payload_envelope(
                &old_first_context,
                &SecureMeshPlaintext::new(SecureMeshPayloadKind::Error, b"old first"),
            )
            .unwrap();
        let old_second = alice_session
            .seal_payload_envelope(
                &old_second_context,
                &SecureMeshPlaintext::new(SecureMeshPayloadKind::Error, b"old delayed"),
            )
            .unwrap();
        bob_session
            .open_payload_envelope(&old_first, SecureMeshPayloadKind::Error)
            .unwrap();

        let reply_context = payload_context(
            &bob_session,
            "msg-header-inflight-reply",
            &bob_session.local_endpoint_id,
            &bob_session.remote_endpoint_id,
        );
        let reply = bob_session
            .seal_payload_envelope(
                &reply_context,
                &SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, b"ratchet"),
            )
            .unwrap();
        alice_session
            .open_payload_envelope(&reply, SecureMeshPayloadKind::ResultPayload)
            .unwrap();

        let new_context = payload_context(
            &alice_session,
            "msg-header-inflight-new",
            &alice_session.local_endpoint_id,
            &alice_session.remote_endpoint_id,
        );
        let new_epoch = alice_session
            .seal_payload_envelope(
                &new_context,
                &SecureMeshPlaintext::new(SecureMeshPayloadKind::Error, b"new first"),
            )
            .unwrap();
        bob_session
            .open_payload_envelope(&new_epoch, SecureMeshPayloadKind::Error)
            .unwrap();
        assert_eq!(bob_session.skipped_key_count(), 1);
        assert_eq!(bob_session.skipped_receiving_header_keys.len(), 2);
        assert_eq!(
            bob_session
                .open_payload_envelope(&old_second, SecureMeshPayloadKind::Error,)
                .unwrap()
                .body,
            b"old delayed"
        );
        assert_eq!(bob_session.skipped_key_count(), 0);
    }

    #[test]
    fn secure_mesh_pairwise_dh_ratchet_skip_limit_fails_closed_without_state_advance() {
        // Deliver the first message from the chain to authenticate the initiator, while
        // intentionally leaving more than MAX_SKIPPED_KEYS later messages in flight.
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first = alice_session
            .seal_message("msg-skip-limit-0", b"first delivered")
            .unwrap();
        bob_session.open_message(&first).unwrap();
        for index in 1..=(MAX_SKIPPED_KEYS + 1) {
            alice_session
                .seal_message(format!("msg-skip-limit-{index}"), b"queued old chain")
                .unwrap();
        }
        let reply = bob_session
            .seal_message("msg-skip-limit-reply", b"ratchet trigger")
            .unwrap();
        alice_session.open_message(&reply).unwrap();
        let new_epoch = alice_session
            .seal_message("msg-skip-limit-new", b"new epoch")
            .unwrap();

        let error = bob_session.open_message(&new_epoch).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("skipped-key limit exceeded before ratchet"),
            "unexpected skip-limit error: {error}"
        );
        assert_eq!(bob_session.dh_epoch(), 2);
        assert_eq!(bob_session.received_count(), 1);
        assert_eq!(bob_session.skipped_key_count(), 0);
        assert!(!bob_session.pending_sending_ratchet());
    }

    #[test]
    fn secure_mesh_pairwise_pc_pc_command_result_relay_round_trip() {
        let canary = "pc-pc-command-canary-secret";
        let (mut pc_a_session, mut pc_b_session) =
            pairwise_sessions_between("desktop_sidecar:pc-a", "desktop_sidecar:pc-b");
        let mut relay = OpaquePairwiseRelay::default();

        let command = pc_pc_command_fixture("cmd-pcpc-1", "idem-pcpc-1", canary);
        let command_context = payload_context_with_mailbox(
            &pc_a_session,
            "msg-pcpc-command",
            "mailbox-pc-b",
            "desktop_sidecar:pc-a",
            "desktop_sidecar:pc-b",
        );
        let command_plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Command,
            serde_json::to_vec(&command).unwrap(),
        )
        .with_content_type("application/json");
        let command_envelope = pc_a_session
            .seal_payload_envelope(&command_context, &command_plaintext)
            .unwrap();
        relay.send(command_envelope, canary);
        assert_eq!(relay.queue_len(), 1);

        let synced_for_pc_b = relay.sync("mailbox-pc-b");
        assert_eq!(synced_for_pc_b.len(), 1);
        let opened_command = pc_b_session
            .open_payload_envelope(&synced_for_pc_b[0], SecureMeshPayloadKind::Command)
            .unwrap();
        assert_eq!(opened_command.kind, SecureMeshPayloadKind::Command);
        assert_eq!(
            opened_command.content_type.as_deref(),
            Some("application/json")
        );
        let command_value: Value = serde_json::from_slice(&opened_command.body).unwrap();
        assert_eq!(command_value["body"]["message"], canary);

        let command_payload = SecureCommandPayload::from_value(&command_value).unwrap();
        let command_gate =
            SecureCommandEvaluationContext::from_value(&pc_pc_command_context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation =
            evaluate_secure_command(&command_payload, &command_gate, &mut ledger).unwrap();
        assert!(evaluation.accepted);
        assert!(evaluation.should_execute);
        let mut executor = PcRelayExecutor::default();
        let execution = execute_evaluated_secure_command(
            &command_payload,
            &evaluation,
            &mut executor,
            "2026-06-26T00:02:00Z",
        )
        .unwrap();
        assert_eq!(executor.calls, 1);
        let result = execution.result().unwrap();
        assert!(!String::from_utf8_lossy(&result.output).contains("requiresUserConfirmation"));

        assert!(!relay.ack("msg-pcpc-command"));
        assert!(relay.ack("msg-pcpc-command"));
        assert_eq!(relay.queue_len(), 0);

        let result_context = payload_context_with_mailbox(
            &pc_b_session,
            "msg-pcpc-result",
            "mailbox-pc-a",
            "desktop_sidecar:pc-b",
            "desktop_sidecar:pc-a",
        );
        let result_plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, result.output.clone())
                .with_content_type("application/json");
        let result_envelope = pc_b_session
            .seal_payload_envelope(&result_context, &result_plaintext)
            .unwrap();
        relay.send(result_envelope, canary);
        let synced_for_pc_a = relay.sync("mailbox-pc-a");
        assert_eq!(synced_for_pc_a.len(), 1);
        let opened_result = pc_a_session
            .open_payload_envelope(&synced_for_pc_a[0], SecureMeshPayloadKind::ResultPayload)
            .unwrap();
        assert_eq!(opened_result.kind, SecureMeshPayloadKind::ResultPayload);
        assert_eq!(
            opened_result.content_type.as_deref(),
            Some("application/json")
        );
        let result_value: Value = serde_json::from_slice(&opened_result.body).unwrap();
        assert_eq!(result_value["ok"], true);
        assert_eq!(result_value["commandKind"], "agent.message.send");
        assert_eq!(result_value["output"]["message"], canary);

        assert!(!relay.ack("msg-pcpc-result"));
        assert_eq!(relay.queue_len(), 0);
    }

    #[test]
    fn secure_mesh_pairwise_mobile_pc_command_result_relay_round_trip() {
        assert_pairwise_command_result_relay_round_trip(CommandRelayScenario {
            label: "mobile-pc",
            sender_endpoint_id: "mobile:phone-a",
            sender_endpoint_kind: "mobile",
            recipient_endpoint_id: "desktop_sidecar:pc-b",
            target_agent_id: "agent-pc-b",
            workspace_id: "workspace-a",
            sender_mailbox_id: "mbx-mobile-pc-sender",
            recipient_mailbox_id: "mbx-mobile-pc-recipient",
            canary: "mobile-pc-command-canary-secret",
        });
    }

    #[test]
    fn secure_mesh_pairwise_pc_mobile_command_result_relay_round_trip() {
        assert_pairwise_command_result_relay_round_trip(CommandRelayScenario {
            label: "pc-mobile",
            sender_endpoint_id: "desktop_sidecar:pc-a",
            sender_endpoint_kind: "desktop_sidecar",
            recipient_endpoint_id: "mobile:phone-b",
            target_agent_id: "agent-mobile-b",
            workspace_id: "workspace-a",
            sender_mailbox_id: "mbx-pc-mobile-sender",
            recipient_mailbox_id: "mbx-pc-mobile-recipient",
            canary: "pc-mobile-command-canary-secret",
        });
    }

    #[test]
    fn secure_mesh_pairwise_mobile_mobile_command_result_relay_round_trip() {
        assert_pairwise_command_result_relay_round_trip(CommandRelayScenario {
            label: "mobile-mobile",
            sender_endpoint_id: "mobile:phone-a",
            sender_endpoint_kind: "mobile",
            recipient_endpoint_id: "mobile:phone-b",
            target_agent_id: "agent-mobile-b",
            workspace_id: "workspace-a",
            sender_mailbox_id: "mbx-mobile-mobile-sender",
            recipient_mailbox_id: "mbx-mobile-mobile-recipient",
            canary: "mobile-mobile-command-canary-secret",
        });
    }

    #[test]
    fn secure_mesh_pairwise_cli_desktop_command_result_relay_round_trip() {
        assert_pairwise_command_result_relay_round_trip(CommandRelayScenario {
            label: "cli-desktop",
            sender_endpoint_id: "cli:cli-a",
            sender_endpoint_kind: "cli",
            recipient_endpoint_id: "desktop_gui:desktop-b",
            target_agent_id: "agent-desktop-b",
            workspace_id: "workspace-a",
            sender_mailbox_id: "mbx-cli-desktop-sender",
            recipient_mailbox_id: "mbx-cli-desktop-recipient",
            canary: "cli-desktop-command-canary-secret",
        });
    }

    #[test]
    fn secure_mesh_pairwise_client_local_runtime_command_result_relay_round_trip() {
        assert_pairwise_command_result_relay_round_trip(CommandRelayScenario {
            label: "client-local-runtime",
            sender_endpoint_id: "desktop_sidecar:pc-a",
            sender_endpoint_kind: "desktop_sidecar",
            recipient_endpoint_id: "client_local_runtime:runtime-b",
            target_agent_id: "agent-runtime-b",
            workspace_id: "workspace-a",
            sender_mailbox_id: "mbx-client-runtime-sender",
            recipient_mailbox_id: "mbx-client-runtime-recipient",
            canary: "client-local-runtime-command-canary-secret",
        });
    }

    #[test]
    fn secure_mesh_sesame_multi_device_fanout_uses_independent_pairwise_envelopes_and_ack_purge() {
        let canary = "multi-device-fanout-canary-secret";
        let (mut sender_to_desktop, mut desktop_receiver) =
            pairwise_sessions_between("desktop_sidecar:alice-pc-a", "desktop_sidecar:bob-pc-b");
        let (mut sender_to_mobile, mut mobile_receiver) =
            pairwise_sessions_between("desktop_sidecar:alice-pc-a", "mobile:bob-mobile-c");
        let mut manager = SecureMeshSesameSessionManager::new(2);
        manager
            .activate_session(
                "bob",
                "desktop_sidecar:bob-pc-b",
                sender_to_desktop.session_id.clone(),
            )
            .unwrap();
        manager
            .activate_session(
                "bob",
                "mobile:bob-mobile-c",
                sender_to_mobile.session_id.clone(),
            )
            .unwrap();
        assert_eq!(
            manager.fanout_targets_for_user("bob"),
            vec![
                (
                    "desktop_sidecar:bob-pc-b".to_string(),
                    sender_to_desktop.session_id.clone()
                ),
                (
                    "mobile:bob-mobile-c".to_string(),
                    sender_to_mobile.session_id.clone()
                )
            ]
        );

        let mut relay = OpaquePairwiseRelay::default();
        let desktop_context = payload_context_with_mailbox(
            &sender_to_desktop,
            "msg-fanout-1",
            "mbx-fanout-a13f",
            "desktop_sidecar:alice-pc-a",
            "desktop_sidecar:bob-pc-b",
        );
        let mobile_context = payload_context_with_mailbox(
            &sender_to_mobile,
            "msg-fanout-2",
            "mbx-fanout-b94c",
            "desktop_sidecar:alice-pc-a",
            "mobile:bob-mobile-c",
        );
        let desktop_plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Command,
            serde_json::to_vec(&json!({
                "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
                "commandKind": "client.activity.sync",
                "targetEndpointId": "desktop_sidecar:bob-pc-b",
                "body": {"message": canary}
            }))
            .unwrap(),
        )
        .with_content_type("application/json");
        let mobile_plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Command,
            serde_json::to_vec(&json!({
                "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
                "commandKind": "client.activity.sync",
                "targetEndpointId": "mobile:bob-mobile-c",
                "body": {"message": canary}
            }))
            .unwrap(),
        )
        .with_content_type("application/json");

        let desktop_envelope = sender_to_desktop
            .seal_payload_envelope(&desktop_context, &desktop_plaintext)
            .unwrap();
        let mobile_envelope = sender_to_mobile
            .seal_payload_envelope(&mobile_context, &mobile_plaintext)
            .unwrap();
        assert_ne!(desktop_envelope.ciphertext(), mobile_envelope.ciphertext());
        assert_ne!(
            desktop_envelope.encrypted_header(),
            mobile_envelope.encrypted_header()
        );
        for forbidden in [
            canary,
            "desktop_sidecar:alice-pc-a",
            "desktop_sidecar:bob-pc-b",
            "mobile:bob-mobile-c",
            "client.activity.sync",
        ] {
            assert!(!desktop_envelope.delivery_id().contains(forbidden));
            assert!(!desktop_envelope.mailbox_token().contains(forbidden));
            assert!(!desktop_envelope.encrypted_header().contains(forbidden));
            assert!(!desktop_envelope.ciphertext().contains(forbidden));
            assert!(!mobile_envelope.delivery_id().contains(forbidden));
            assert!(!mobile_envelope.mailbox_token().contains(forbidden));
            assert!(!mobile_envelope.encrypted_header().contains(forbidden));
            assert!(!mobile_envelope.ciphertext().contains(forbidden));
        }

        relay.send(desktop_envelope, canary);
        relay.send(mobile_envelope, canary);
        assert_eq!(relay.queue_len(), 2);

        let desktop_synced = relay.sync("mbx-fanout-a13f");
        let mobile_synced = relay.sync("mbx-fanout-b94c");
        assert_eq!(desktop_synced.len(), 1);
        assert_eq!(mobile_synced.len(), 1);
        let wrong_recipient = mobile_receiver
            .open_payload_envelope(&desktop_synced[0], SecureMeshPayloadKind::Command)
            .unwrap_err();
        assert!(
            wrong_recipient
                .to_string()
                .contains("header authentication failed")
        );

        let opened_desktop = desktop_receiver
            .open_payload_envelope(&desktop_synced[0], SecureMeshPayloadKind::Command)
            .unwrap();
        let opened_mobile = mobile_receiver
            .open_payload_envelope(&mobile_synced[0], SecureMeshPayloadKind::Command)
            .unwrap();
        let desktop_value: Value = serde_json::from_slice(&opened_desktop.body).unwrap();
        let mobile_value: Value = serde_json::from_slice(&opened_mobile.body).unwrap();
        assert_eq!(
            desktop_value["targetEndpointId"],
            "desktop_sidecar:bob-pc-b"
        );
        assert_eq!(mobile_value["targetEndpointId"], "mobile:bob-mobile-c");
        assert_eq!(desktop_value["body"]["message"], canary);
        assert_eq!(mobile_value["body"]["message"], canary);

        assert!(!relay.ack("msg-fanout-1"));
        assert!(relay.sync("mbx-fanout-a13f").is_empty());
        assert_eq!(relay.queue_len(), 1);
        assert!(!relay.ack("msg-fanout-2"));
        assert!(relay.ack("msg-fanout-2"));
        assert_eq!(relay.queue_len(), 0);
    }

    #[test]
    fn secure_mesh_pairwise_payload_codec_uses_ratchet_message_key() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let context = payload_context(
            &alice_session,
            "payload-1",
            &alice_session.local_endpoint_id,
            &alice_session.remote_endpoint_id,
        );
        let plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Command,
            serde_json::to_vec(&json!({
                "commandKind": "client.activity.sync",
                "secret": (["session", "derived"].join("-"))
            }))
            .unwrap(),
        )
        .with_content_type("application/json");
        let sealed = alice_session.seal_payload(&context, &plaintext).unwrap();
        assert_eq!(sealed.cipher_suite, SECURE_MESH_PAIRWISE_CIPHER_SUITE);
        assert_eq!(sealed.session_id, alice_session.session_id);
        assert_eq!(sealed.message_id, context.message_id);
        assert!(!sealed.ciphertext.contains("session-derived"));
        assert_eq!(alice_session.sent_count(), 1);

        let opened = bob_session
            .open_payload(&context, &sealed, SecureMeshPayloadKind::Command)
            .unwrap();
        assert_eq!(opened.kind, SecureMeshPayloadKind::Command);
        assert_eq!(opened.body, plaintext.body);
        assert_eq!(opened.content_type.as_deref(), Some("application/json"));
        assert_eq!(bob_session.received_count(), 1);

        let replay = bob_session
            .open_payload(&context, &sealed, SecureMeshPayloadKind::Command)
            .unwrap_err();
        assert!(replay.to_string().contains("replay detected"));
    }

    #[test]
    fn secure_mesh_pairwise_payload_open_failure_does_not_advance_ratchet() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let context = payload_context(
            &alice_session,
            "payload-atomic",
            &alice_session.local_endpoint_id,
            &alice_session.remote_endpoint_id,
        );
        let plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, br#"{"ok":true}"#);
        let sealed = alice_session.seal_payload(&context, &plaintext).unwrap();
        let mut wrong_context = context.clone();
        wrong_context.message_id = "payload-atomic-tampered".to_string();
        let received_before = bob_session.received_count();
        let error = bob_session
            .open_payload(
                &wrong_context,
                &sealed,
                SecureMeshPayloadKind::ResultPayload,
            )
            .unwrap_err();
        assert!(error.to_string().contains("context message mismatch"));
        assert_eq!(bob_session.received_count(), received_before);

        let opened = bob_session
            .open_payload(&context, &sealed, SecureMeshPayloadKind::ResultPayload)
            .unwrap();
        assert_eq!(opened.body, plaintext.body);
        assert_eq!(bob_session.received_count(), received_before + 1);
    }

    #[test]
    fn secure_mesh_pairwise_payload_authenticates_complete_ratchet_header_without_state_advance() {
        let (mut alice_session, bob_session) = pairwise_sessions();
        let context = payload_context(
            &alice_session,
            "payload-ratchet-header-aad",
            &alice_session.local_endpoint_id,
            &alice_session.remote_endpoint_id,
        );
        let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, br#"{"ok":true}"#);
        let sealed = alice_session.seal_payload(&context, &plaintext).unwrap();

        let mut changed_previous_chain_length = sealed.clone();
        changed_previous_chain_length.previous_chain_length = changed_previous_chain_length
            .previous_chain_length
            .checked_add(1)
            .unwrap();
        let mut changed_chain_index = sealed.clone();
        changed_chain_index.chain_index = changed_chain_index.chain_index.checked_add(1).unwrap();
        let mut changed_epoch = sealed.clone();
        changed_epoch.dh_epoch = changed_epoch.dh_epoch.checked_add(1).unwrap();
        let mut changed_ratchet_key = sealed.clone();
        changed_ratchet_key.sender_ratchet_public_key = SecureMeshPairwisePrivateKey::generate()
            .public_key()
            .to_vec();
        let mut changed_sparse_pq_number = sealed.clone();
        changed_sparse_pq_number.sparse_pq_header.message_number = changed_sparse_pq_number
            .sparse_pq_header
            .message_number
            .checked_add(1)
            .unwrap();

        for (label, tampered) in [
            ("previous-chain-length", changed_previous_chain_length),
            ("chain-index", changed_chain_index),
            ("dh-epoch", changed_epoch),
            ("ratchet-public-key", changed_ratchet_key),
            ("sparse-pq-message-number", changed_sparse_pq_number),
        ] {
            let mut receiver = bob_session.clone();
            let before = (
                receiver.receiving_chain_index,
                receiver.receiving_ratchet_epoch,
                receiver.dh_epoch,
                receiver.skipped_key_count(),
                receiver.pending_sending_ratchet,
                receiver.remote_ratchet_public_key,
            );
            let error = receiver
                .open_payload(&context, &tampered, SecureMeshPayloadKind::Command)
                .unwrap_err();
            assert!(!error.to_string().is_empty(), "{label} tamper was accepted");
            assert_eq!(
                (
                    receiver.receiving_chain_index,
                    receiver.receiving_ratchet_epoch,
                    receiver.dh_epoch,
                    receiver.skipped_key_count(),
                    receiver.pending_sending_ratchet,
                    receiver.remote_ratchet_public_key,
                ),
                before,
                "{label} tamper advanced authenticated state"
            );
            let opened = receiver
                .open_payload(&context, &sealed, SecureMeshPayloadKind::Command)
                .unwrap();
            assert_eq!(opened.body, plaintext.body, "{label} damaged valid state");
        }
    }

    #[test]
    fn secure_mesh_pairwise_encrypted_relay_header_hides_ratchet_structure_and_rejects_tamper() {
        let (mut sender, mut receiver) = pairwise_sessions();
        let context = payload_context_with_mailbox(
            &sender,
            "msg-encrypted-header-tamper",
            "mailbox-encrypted-header-tamper",
            &sender.local_endpoint_id,
            &sender.remote_endpoint_id,
        );
        let envelope = sender
            .seal_payload_envelope(
                &context,
                &SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, b"opaque command"),
            )
            .unwrap();
        let wire = envelope.decoded_encrypted_header().unwrap();
        assert_eq!(
            wire.len(),
            crate::core::secure_mesh_relay_envelope::SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
        );
        assert!(!wire.windows(8).any(|window| window == 1u64.to_be_bytes()));
        assert!(
            !wire
                .windows(sender.local_ratchet_public_key.len())
                .any(|window| window == sender.local_ratchet_public_key)
        );

        let mut tampered_value: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
        let mut tampered_wire = wire.clone();
        let last = tampered_wire.len() - 1;
        tampered_wire[last] ^= 1;
        tampered_value["encryptedHeader"] =
            Value::String(general_purpose::URL_SAFE_NO_PAD.encode(tampered_wire));
        let tampered =
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&tampered_value).unwrap())
                .unwrap();
        assert!(
            receiver
                .open_payload_envelope(&tampered, SecureMeshPayloadKind::Command)
                .unwrap_err()
                .to_string()
                .contains("header authentication failed")
        );
        assert_eq!(receiver.received_count(), 0);

        let mut rebound_value: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
        rebound_value["deliveryId"] =
            Value::String(general_purpose::URL_SAFE_NO_PAD.encode([0x7fu8; 24]));
        let rebound =
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&rebound_value).unwrap())
                .unwrap();
        assert!(
            receiver
                .open_payload_envelope(&rebound, SecureMeshPayloadKind::Command)
                .unwrap_err()
                .to_string()
                .contains("header authentication failed")
        );
        assert_eq!(receiver.received_count(), 0);
        assert_eq!(
            receiver
                .open_payload_envelope(&envelope, SecureMeshPayloadKind::Command)
                .unwrap()
                .body,
            b"opaque command"
        );
    }

    #[test]
    fn secure_mesh_pairwise_payload_out_of_order_uses_bounded_skipped_keys() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first_context = payload_context(
            &alice_session,
            "payload-first",
            &alice_session.local_endpoint_id,
            &alice_session.remote_endpoint_id,
        );
        let second_context = payload_context(
            &alice_session,
            "payload-second",
            &alice_session.local_endpoint_id,
            &alice_session.remote_endpoint_id,
        );
        let first_plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::Error, b"first-error");
        let second_plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::Error, b"second-error");
        let first = alice_session
            .seal_payload(&first_context, &first_plaintext)
            .unwrap();
        let second = alice_session
            .seal_payload(&second_context, &second_plaintext)
            .unwrap();

        let opened_second = bob_session
            .open_payload(&second_context, &second, SecureMeshPayloadKind::Error)
            .unwrap();
        assert_eq!(opened_second.body, b"second-error");
        assert_eq!(bob_session.skipped_key_count(), 1);
        let opened_first = bob_session
            .open_payload(&first_context, &first, SecureMeshPayloadKind::Error)
            .unwrap();
        assert_eq!(opened_first.body, b"first-error");
        assert_eq!(bob_session.skipped_key_count(), 0);
    }

    #[test]
    fn secure_mesh_pairwise_rejects_replay_and_supports_out_of_order_skipped_key() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first = alice_session.seal_message("msg-1", b"one").unwrap();
        let second = alice_session.seal_message("msg-2", b"two").unwrap();

        let opened_second = bob_session.open_message(&second).unwrap();
        assert_eq!(opened_second.body, b"two");
        assert_eq!(bob_session.skipped_key_count(), 1);
        let opened_first = bob_session.open_message(&first).unwrap();
        assert_eq!(opened_first.body, b"one");
        assert_eq!(bob_session.skipped_key_count(), 0);

        let replay_error = bob_session.open_message(&second).unwrap_err();
        assert!(replay_error.to_string().contains("replay detected"));
    }

    #[test]
    fn secure_mesh_pairwise_replay_cache_uses_message_tuple_fingerprint() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let message = alice_session
            .seal_message("msg-replay-fingerprint", b"tuple-bound")
            .unwrap();
        let fingerprint = message_replay_fingerprint(&message).unwrap();

        bob_session.open_message(&message).unwrap();

        assert_eq!(bob_session.received_message_ids.len(), 1);
        assert_eq!(bob_session.received_message_ids[0], fingerprint);
        assert_ne!(bob_session.received_message_ids[0], message.message_id);
        assert!(bob_session.received_message_ids[0].starts_with("sha256:"));
    }

    #[test]
    fn secure_mesh_pairwise_skipped_key_gap_limit_rejects_without_state_advance() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let mut messages = Vec::new();
        for index in 0..(MAX_SKIPPED_KEYS + 2) {
            messages.push(
                alice_session
                    .seal_message(format!("msg-{index}"), format!("body-{index}"))
                    .unwrap(),
            );
        }
        let last = messages.last().unwrap().clone();
        let gap_error = bob_session.open_message(&last).unwrap_err();
        assert_eq!(
            gap_error.to_string(),
            "secure mesh pairwise skipped-key limit exceeded"
        );
        assert_eq!(bob_session.received_count(), 0);
        assert_eq!(bob_session.skipped_key_count(), 0);
        assert_eq!(
            bob_session.open_message(&messages[0]).unwrap().body,
            b"body-0"
        );
    }

    #[test]
    fn secure_mesh_pairwise_stale_and_replayed_relay_acks_do_not_advance_ratchet() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let before_epoch = alice_session.dh_epoch();
        let before_pending = alice_session.pending_sending_ratchet();
        let before_sent = alice_session.sent_count();
        let before_received = alice_session.received_count();

        let mut relay = OpaquePairwiseRelay::default();
        // Stale ACK for a message never queued, and a replayed ACK, are both outside crypto.
        assert!(relay.ack("msg-stale-ack"));
        assert!(relay.ack("msg-stale-ack"));
        assert!(relay.ack("msg-other-ack"));

        assert_eq!(alice_session.dh_epoch(), before_epoch);
        assert_eq!(alice_session.pending_sending_ratchet(), before_pending);
        assert_eq!(alice_session.sent_count(), before_sent);
        assert_eq!(alice_session.received_count(), before_received);
        assert_eq!(bob_session.dh_epoch(), 0);
        assert!(!bob_session.pending_sending_ratchet());

        // Authenticated remote ratchet still schedules rotation; ACKs never do.
        let first = alice_session
            .seal_message("msg-ack-crypto-1", b"authenticated body")
            .unwrap();
        bob_session.open_message(&first).unwrap();
        assert!(bob_session.pending_sending_ratchet());
        assert!(relay.ack("msg-ack-crypto-1"));
        assert!(relay.ack("msg-ack-crypto-1"));
        assert!(bob_session.pending_sending_ratchet());
        assert_eq!(bob_session.dh_epoch(), 1);
    }

    #[test]
    fn secure_mesh_pairwise_revoked_session_fail_closed_for_seal_and_open() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let sealed = alice_session
            .seal_message("msg-before-revoke", b"before revoke")
            .unwrap();
        bob_session.revoke();
        let open_error = bob_session.open_message(&sealed).unwrap_err();
        assert!(open_error.to_string().contains("revoked"));
        let seal_error = bob_session
            .seal_message("msg-after-revoke", b"should fail")
            .unwrap_err();
        assert!(seal_error.to_string().contains("revoked"));
    }

    #[test]
    fn secure_mesh_pairwise_pending_authenticated_ratchet_survives_restart() {
        let store_path = durable_store_path("pending-authenticated-ratchet");
        let _ = std::fs::remove_file(&store_path);
        let (alice_session, mut bob_session) = pairwise_sessions();
        assert!(alice_session.pending_sending_ratchet());
        let secret_store = test_secret_store();
        let mut store = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "pending-authenticated-ratchet",
        );
        let initial = store
            .upsert_initial(&alice_session, "2026-06-26T00:01:00Z")
            .unwrap();
        let pending_snapshot = stored_snapshot_json(
            &store_path,
            &alice_session.session_id,
            &alice_session.local_endpoint_id,
        );
        assert!(pending_snapshot.contains("\"pending_sending_ratchet\":true"));
        assert!(!pending_snapshot.contains("ack_barrier"));
        for forbidden in [
            "root_key",
            "sending_chain_key",
            "receiving_chain_key",
            "sending_header_key",
            "receiving_header_key",
            "next_sending_header_key",
            "next_receiving_header_key",
            "skipped_receiving_header_keys",
            "local_ratchet_secret",
            "pending_ratchet_secret_handle",
            "pending_commit_secret_handle",
        ] {
            assert!(
                !pending_snapshot.contains(forbidden),
                "pending commit snapshot leaked {forbidden}"
            );
        }
        drop(store);

        let mut reopened = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "pending-authenticated-ratchet",
        );
        let mut restored = reopened
            .load_session(&alice_session.session_id, &alice_session.local_endpoint_id)
            .unwrap()
            .unwrap();
        assert!(restored.pending_sending_ratchet());
        let first = restored
            .seal_message("msg-pending-authenticated-1", b"restart ratchet")
            .unwrap();
        assert_eq!(first.dh_epoch, 1);
        assert_eq!(first.chain_index, 0);
        let committed = reopened
            .commit_session(&initial, &restored, "2026-06-26T00:01:01Z")
            .unwrap();
        drop(reopened);

        let reopened_after_send = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "pending-authenticated-ratchet",
        );
        let restored_after_send = reopened_after_send
            .load_session(&alice_session.session_id, &alice_session.local_endpoint_id)
            .unwrap()
            .unwrap();
        assert_eq!(committed.state_version, 2);
        assert_eq!(restored_after_send.dh_epoch(), 1);
        assert!(!restored_after_send.pending_sending_ratchet());
        assert_eq!(
            bob_session.open_message(&first).unwrap().body,
            b"restart ratchet"
        );
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_local_one_time_prekey_ledger_is_atomic_and_survives_session_purge() {
        let store_path = durable_store_path("local-prekey-ledger");
        let _ = std::fs::remove_file(&store_path);
        let (session, _) = pairwise_sessions();
        let secret_store = test_secret_store();
        let mut store = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "local-prekey-ledger",
        );
        let original_claim = SecureMeshLocalPreKeyUse {
            local_endpoint_id: session.local_endpoint_id.clone(),
            local_identity_fingerprint: "sha256:local-identity".to_string(),
            one_time_prekey_id: "otpk-local-1".to_string(),
            one_time_prekey_public_key_hash: "sha256:local-prekey-1".to_string(),
            one_time_mlkem1024_prekey_id: "pqotpk-local-1".to_string(),
            one_time_mlkem1024_prekey_public_key_hash: "sha256:local-pq-prekey-1".to_string(),
        };
        store
            .upsert_initial_with_local_prekey_claim(
                &session,
                &original_claim,
                "2026-06-26T00:02:00Z",
            )
            .unwrap();

        let mut reused_id_session = session.clone();
        reused_id_session.session_id.push_str("-reused-id");
        let mut reused_id_claim = original_claim.clone();
        reused_id_claim.one_time_prekey_public_key_hash =
            "sha256:different-local-prekey".to_string();
        assert!(
            store
                .upsert_initial_with_local_prekey_claim(
                    &reused_id_session,
                    &reused_id_claim,
                    "2026-06-26T00:02:01Z",
                )
                .unwrap_err()
                .to_string()
                .contains("already consumed")
        );
        assert!(
            store
                .read_record(
                    &reused_id_session.session_id,
                    &reused_id_session.local_endpoint_id,
                )
                .unwrap()
                .is_none()
        );

        let mut reused_key_session = session.clone();
        reused_key_session.session_id.push_str("-reused-key");
        let mut reused_key_claim = original_claim.clone();
        reused_key_claim.one_time_prekey_id = "otpk-local-2".to_string();
        assert!(
            store
                .upsert_initial_with_local_prekey_claim(
                    &reused_key_session,
                    &reused_key_claim,
                    "2026-06-26T00:02:02Z",
                )
                .unwrap_err()
                .to_string()
                .contains("already consumed")
        );

        store.purge_sessions_preserving_prekey_history().unwrap();
        assert!(
            store
                .read_record(&session.session_id, &session.local_endpoint_id)
                .unwrap()
                .is_none()
        );
        let mut after_purge_session = session.clone();
        after_purge_session.session_id.push_str("-after-purge");
        assert!(
            store
                .upsert_initial_with_local_prekey_claim(
                    &after_purge_session,
                    &original_claim,
                    "2026-06-26T00:02:03Z",
                )
                .unwrap_err()
                .to_string()
                .contains("already consumed")
        );
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_remote_one_time_prekey_reuse_ignores_authorization_digest_changes() {
        let store_path = durable_store_path("remote-prekey-ledger");
        let _ = std::fs::remove_file(&store_path);
        let secret_store = test_secret_store();
        let mut store = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "remote-prekey-ledger",
        );
        let original = SecureMeshRemotePreKeyUse {
            session_id: "session-remote-prekey-1".to_string(),
            local_endpoint_id: "mobile:local".to_string(),
            remote_endpoint_id: "desktop_gui:remote".to_string(),
            remote_identity_fingerprint: "sha256:remote-identity".to_string(),
            signed_prekey_id: "spk-remote-1".to_string(),
            one_time_prekey_id: "otpk-remote-1".to_string(),
            one_time_prekey_public_key_hash: "sha256:remote-prekey-1".to_string(),
            one_time_mlkem1024_prekey_id: "pqotpk-remote-1".to_string(),
            one_time_mlkem1024_prekey_public_key_hash: "sha256:remote-pq-prekey-1".to_string(),
            directory_authorization_digest: "21".repeat(32),
        };
        store
            .record_remote_prekey_use(&original, "2026-06-26T00:02:10Z")
            .unwrap();

        let mut reused_id = original.clone();
        reused_id.session_id = "session-remote-prekey-2".to_string();
        reused_id.one_time_prekey_public_key_hash = "sha256:different-remote-prekey".to_string();
        reused_id.directory_authorization_digest = "22".repeat(32);
        assert!(
            store
                .record_remote_prekey_use(&reused_id, "2026-06-26T00:02:11Z")
                .unwrap_err()
                .to_string()
                .contains("already used")
        );

        let mut reused_key = original.clone();
        reused_key.session_id = "session-remote-prekey-3".to_string();
        reused_key.one_time_prekey_id = "otpk-remote-2".to_string();
        reused_key.directory_authorization_digest = "23".repeat(32);
        assert!(
            store
                .record_remote_prekey_use(&reused_key, "2026-06-26T00:02:12Z")
                .unwrap_err()
                .to_string()
                .contains("already used")
        );

        store.purge_sessions_preserving_prekey_history().unwrap();
        assert!(
            store
                .record_remote_prekey_use(&original, "2026-06-26T00:02:13Z")
                .unwrap_err()
                .to_string()
                .contains("already used")
        );
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_schema_upgrade_preserves_prekey_reuse_tombstones() {
        let store_path = durable_store_path("schema-prekey-tombstones");
        let _ = std::fs::remove_file(&store_path);
        let secret_store = test_secret_store();
        let original = SecureMeshRemotePreKeyUse {
            session_id: "session-schema-prekey-1".to_string(),
            local_endpoint_id: "mobile:schema-local".to_string(),
            remote_endpoint_id: "desktop_gui:schema-remote".to_string(),
            remote_identity_fingerprint: "sha256:schema-remote-identity".to_string(),
            signed_prekey_id: "spk-schema-1".to_string(),
            one_time_prekey_id: "otpk-schema-1".to_string(),
            one_time_prekey_public_key_hash: "sha256:schema-prekey-1".to_string(),
            one_time_mlkem1024_prekey_id: "pqotpk-schema-1".to_string(),
            one_time_mlkem1024_prekey_public_key_hash: "sha256:schema-pq-prekey-1".to_string(),
            directory_authorization_digest: "31".repeat(32),
        };
        {
            let mut store = open_test_durable_store(
                &store_path,
                Arc::clone(&secret_store),
                "schema-prekey-tombstones",
            );
            store
                .record_remote_prekey_use(&original, "2026-06-26T00:02:30Z")
                .unwrap();
        }
        let connection = TestConnection::open(&store_path).unwrap();
        connection
            .execute_batch("PRAGMA user_version = 3;")
            .unwrap();
        drop(connection);

        let mut upgraded = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "schema-prekey-tombstones",
        );
        let error = upgraded
            .record_remote_prekey_use(&original, "2026-06-26T00:02:31Z")
            .unwrap_err();
        assert!(error.to_string().contains("already used"));
        let schema_version: u32 = TestConnection::open(&store_path)
            .unwrap()
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(schema_version, PAIRWISE_SNAPSHOT_SCHEMA_VERSION);
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_projection_schema_change_requires_clean_repair() {
        let store_path = durable_store_path("projection-schema-repair");
        let _ = std::fs::remove_file(&store_path);
        let secret_store = test_secret_store();
        let (session, _) = pairwise_sessions();
        let secret_handle = {
            let mut store = open_test_durable_store(
                &store_path,
                Arc::clone(&secret_store),
                "projection-schema-repair",
            );
            store
                .upsert_initial(&session, "2026-06-26T00:02:40Z")
                .unwrap();
            let snapshot: PersistedPairwisePublicSession = serde_json::from_str(
                &stored_snapshot_json(&store_path, &session.session_id, &session.local_endpoint_id),
            )
            .unwrap();
            SecretStoreHandle::new(snapshot.secret_store_namespace, snapshot.secret_store_key)
                .unwrap()
        };

        TestConnection::open(&store_path)
            .unwrap()
            .execute_batch("PRAGMA user_version = 7;")
            .unwrap();

        let mut repaired = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "projection-schema-repair",
        );
        assert!(
            repaired
                .read_record(&session.session_id, &session.local_endpoint_id)
                .unwrap()
                .is_none()
        );
        let authorization = secret_store
            .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                "Secure Mesh pairwise schema repair verification",
                1,
            ))
            .unwrap();
        assert!(
            secret_store
                .get_secret_with_session(&authorization, &secret_handle)
                .unwrap()
                .is_none()
        );
        repaired
            .upsert_initial(&session, "2026-06-26T00:02:41Z")
            .unwrap();
        assert!(
            repaired
                .load_session(&session.session_id, &session.local_endpoint_id)
                .unwrap()
                .is_some()
        );
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_durable_store_keeps_secret_material_out_of_sqlite_snapshot() {
        let store_path = durable_store_path("redacted-snapshot");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, _) = pairwise_sessions();
        let initial_root_key = encode_secret(&alice_session.root_key);
        let initial_sending_chain_key = encode_secret(&alice_session.sending_chain_key);
        let initial_receiving_chain_key = encode_secret(&alice_session.receiving_chain_key);
        let initial_local_ratchet_secret =
            encode_secret(&alice_session.local_ratchet_secret.to_bytes());
        let secret_store = test_secret_store();
        let mut store =
            open_test_durable_store(&store_path, Arc::clone(&secret_store), "redacted-snapshot");
        let initial = store
            .upsert_initial(&alice_session, "2026-06-26T00:02:00Z")
            .unwrap();
        let initial_snapshot = stored_snapshot_json(
            &store_path,
            &alice_session.session_id,
            &alice_session.local_endpoint_id,
        );
        assert!(initial_snapshot.contains("secret_store_key"));
        for forbidden_field in [
            "root_key",
            "sending_chain_key",
            "receiving_chain_key",
            "sending_header_key",
            "receiving_header_key",
            "next_sending_header_key",
            "next_receiving_header_key",
            "skipped_receiving_header_keys",
            "local_ratchet_secret",
            "message_key",
        ] {
            assert!(!initial_snapshot.contains(forbidden_field));
        }
        for forbidden_value in [
            initial_root_key.as_str(),
            initial_sending_chain_key.as_str(),
            initial_receiving_chain_key.as_str(),
            initial_local_ratchet_secret.as_str(),
        ] {
            assert!(!initial_snapshot.contains(forbidden_value));
        }
        let initial_public: PersistedPairwisePublicSession =
            serde_json::from_str(&initial_snapshot).unwrap();
        let initial_handle = SecretStoreHandle::new(
            initial_public.secret_store_namespace.clone(),
            initial_public.secret_store_key.clone(),
        )
        .unwrap();
        assert!(secret_store.get_secret(&initial_handle).unwrap().is_some());

        alice_session.seal_message("msg-1", b"persist me").unwrap();
        let committed_sending_chain_key = encode_secret(&alice_session.sending_chain_key);
        store
            .commit_session(&initial, &alice_session, "2026-06-26T00:02:01Z")
            .unwrap();
        let committed_snapshot = stored_snapshot_json(
            &store_path,
            &alice_session.session_id,
            &alice_session.local_endpoint_id,
        );
        assert!(!committed_snapshot.contains("sending_chain_key"));
        assert!(!committed_snapshot.contains(committed_sending_chain_key.as_str()));
        assert!(secret_store.get_secret(&initial_handle).unwrap().is_none());
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_durable_store_keeps_skipped_message_keys_out_of_sqlite_snapshot() {
        let store_path = durable_store_path("redacted-skipped-key");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first = alice_session.seal_message("msg-skipped-1", b"one").unwrap();
        let second = alice_session.seal_message("msg-skipped-2", b"two").unwrap();
        let opened_second = bob_session.open_message(&second).unwrap();
        assert_eq!(opened_second.body, b"two");
        assert_eq!(bob_session.skipped_key_count(), 1);
        let skipped_message_key = encode_secret(&bob_session.skipped_keys[0].message_key);

        let secret_store = test_secret_store();
        let mut store = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "redacted-skipped-key",
        );
        store
            .upsert_initial(&bob_session, "2026-06-26T00:02:15Z")
            .unwrap();
        let snapshot = stored_snapshot_json(
            &store_path,
            &bob_session.session_id,
            &bob_session.local_endpoint_id,
        );
        assert!(snapshot.contains("skipped_keys"));
        assert!(snapshot.contains("secret_store_key"));
        assert!(!snapshot.contains("message_key"));
        assert!(!snapshot.contains(skipped_message_key.as_str()));
        let public: PersistedPairwisePublicSession = serde_json::from_str(&snapshot).unwrap();
        assert_eq!(public.skipped_keys.len(), 1);
        let handle =
            SecretStoreHandle::new(public.secret_store_namespace, public.secret_store_key).unwrap();
        assert!(secret_store.get_secret(&handle).unwrap().is_some());

        drop(store);
        let reopened = open_test_durable_store(
            &store_path,
            Arc::clone(&secret_store),
            "redacted-skipped-key",
        );
        let mut restored = reopened
            .load_session(&bob_session.session_id, &bob_session.local_endpoint_id)
            .unwrap()
            .unwrap();
        let opened_first = restored.open_message(&first).unwrap();
        assert_eq!(opened_first.body, b"one");
        assert_eq!(restored.skipped_key_count(), 0);
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_durable_store_commits_reopens_and_rejects_stale_cas() {
        let store_path = durable_store_path("commit");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let secret_store = test_secret_store();
        let mut store = open_test_durable_store(&store_path, Arc::clone(&secret_store), "commit");
        let initial = store
            .upsert_initial(&alice_session, "2026-06-26T00:03:00Z")
            .unwrap();
        let initial_snapshot = stored_snapshot_json(
            &store_path,
            &alice_session.session_id,
            &alice_session.local_endpoint_id,
        );
        let initial_public: PersistedPairwisePublicSession =
            serde_json::from_str(&initial_snapshot).unwrap();
        let initial_handle = SecretStoreHandle::new(
            initial_public.secret_store_namespace.clone(),
            initial_public.secret_store_key.clone(),
        )
        .unwrap();
        assert!(secret_store.get_secret(&initial_handle).unwrap().is_some());
        let message = alice_session.seal_message("msg-1", b"persist me").unwrap();
        assert_eq!(
            bob_session.open_message(&message).unwrap().body,
            b"persist me"
        );
        let committed = store
            .commit_session(&initial, &alice_session, "2026-06-26T00:03:01Z")
            .unwrap();
        assert_eq!(committed.state_version, 2);
        assert_eq!(committed.sent_count, 1);
        assert!(secret_store.get_secret(&initial_handle).unwrap().is_none());

        drop(store);
        let reopened = open_test_durable_store(&store_path, Arc::clone(&secret_store), "commit");
        let restored = reopened
            .load_session(&alice_session.session_id, &alice_session.local_endpoint_id)
            .unwrap()
            .unwrap();
        assert_eq!(restored.sent_count(), 1);
        assert_eq!(restored.session_id, alice_session.session_id);

        let mut reopened_mut =
            open_test_durable_store(&store_path, Arc::clone(&secret_store), "commit");
        let stale_error = reopened_mut
            .commit_session(&initial, &alice_session, "2026-06-26T00:03:02Z")
            .unwrap_err();
        assert!(stale_error.to_string().contains("compare-and-swap failed"));
        let winner = reopened_mut
            .load_session(&alice_session.session_id, &alice_session.local_endpoint_id)
            .unwrap()
            .unwrap();
        assert_eq!(winner.sent_count(), 1);
        assert_eq!(winner.dh_epoch(), 1);
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_failed_secret_deletion_is_queued_and_retried() {
        let store_path = durable_store_path("secret-cleanup-retry");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, _) = pairwise_sessions();
        let secret_store = Arc::new(FailOnceDeleteSecretStore::new());
        let secret_store_trait: Arc<dyn SecureMeshSecretStore> = secret_store;
        let mut store =
            open_test_durable_store(&store_path, secret_store_trait, "secret-cleanup-retry");
        let initial = store
            .upsert_initial(&alice_session, "2026-06-26T00:04:00Z")
            .unwrap();
        alice_session
            .seal_message("msg-secret-cleanup-retry", b"advance snapshot")
            .unwrap();

        let cleanup_error = store
            .commit_session(&initial, &alice_session, "2026-06-26T00:04:01Z")
            .unwrap_err();
        assert!(cleanup_error.to_string().contains("cleanup is incomplete"));
        assert_eq!(store.pending_secret_cleanup_count().unwrap(), 1);
        let committed = store
            .read_record(&alice_session.session_id, &alice_session.local_endpoint_id)
            .unwrap()
            .unwrap();
        assert_eq!(committed.state_version, 2);

        assert_eq!(store.retry_pending_secret_cleanup().unwrap(), 1);
        assert_eq!(store.pending_secret_cleanup_count().unwrap(), 0);
        assert!(
            store
                .load_session(&alice_session.session_id, &alice_session.local_endpoint_id)
                .unwrap()
                .is_some()
        );
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_durable_store_rejects_stale_receive_snapshot_with_current_record() {
        let store_path = durable_store_path("receive-rollback");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let stale_bob_session = bob_session.clone();
        let secret_store = test_secret_store();
        let mut store =
            open_test_durable_store(&store_path, Arc::clone(&secret_store), "receive-rollback");
        let initial = store
            .upsert_initial(&bob_session, "2026-06-26T00:05:00Z")
            .unwrap();
        let message = alice_session
            .seal_message("msg-receive-rollback", b"receive once")
            .unwrap();
        assert_eq!(
            bob_session.open_message(&message).unwrap().body,
            b"receive once"
        );
        let committed = store
            .commit_session(&initial, &bob_session, "2026-06-26T00:05:01Z")
            .unwrap();

        let rollback = store
            .commit_session(&committed, &stale_bob_session, "2026-06-26T00:05:02Z")
            .unwrap_err();

        assert!(rollback.to_string().contains("durable rollback detected"));
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_durable_store_rejects_skipped_key_replay_window_rollback() {
        let store_path = durable_store_path("skipped-rollback");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let secret_store = test_secret_store();
        let mut store =
            open_test_durable_store(&store_path, Arc::clone(&secret_store), "skipped-rollback");
        let initial = store
            .upsert_initial(&bob_session, "2026-06-26T00:05:10Z")
            .unwrap();
        let first = alice_session
            .seal_message("msg-skipped-rollback-1", b"first")
            .unwrap();
        let second = alice_session
            .seal_message("msg-skipped-rollback-2", b"second")
            .unwrap();
        assert_eq!(bob_session.open_message(&second).unwrap().body, b"second");
        assert_eq!(bob_session.skipped_key_count(), 1);
        let stale_with_skipped_key = bob_session.clone();
        let committed_second = store
            .commit_session(&initial, &bob_session, "2026-06-26T00:05:11Z")
            .unwrap();
        assert_eq!(bob_session.open_message(&first).unwrap().body, b"first");
        assert_eq!(bob_session.skipped_key_count(), 0);
        let committed_first = store
            .commit_session(&committed_second, &bob_session, "2026-06-26T00:05:12Z")
            .unwrap();

        let rollback = store
            .commit_session(
                &committed_first,
                &stale_with_skipped_key,
                "2026-06-26T00:05:13Z",
            )
            .unwrap_err();

        assert!(
            rollback
                .to_string()
                .contains("replay cache rollback detected")
                || rollback
                    .to_string()
                    .contains("skipped-key rollback detected")
        );
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_durable_store_marks_revoked_and_blocks_commit() {
        let store_path = durable_store_path("revoke");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, _) = pairwise_sessions();
        let secret_store = test_secret_store();
        let mut store = open_test_durable_store(&store_path, Arc::clone(&secret_store), "revoke");
        let initial = store
            .upsert_initial(&alice_session, "2026-06-26T00:04:00Z")
            .unwrap();
        let initial_snapshot = stored_snapshot_json(
            &store_path,
            &alice_session.session_id,
            &alice_session.local_endpoint_id,
        );
        let initial_public: PersistedPairwisePublicSession =
            serde_json::from_str(&initial_snapshot).unwrap();
        let initial_handle = SecretStoreHandle::new(
            initial_public.secret_store_namespace.clone(),
            initial_public.secret_store_key.clone(),
        )
        .unwrap();
        assert!(secret_store.get_secret(&initial_handle).unwrap().is_some());
        let revoked = store
            .mark_revoked(&initial, "2026-06-26T00:04:01Z")
            .unwrap();
        assert!(revoked.revoked_at.is_some());
        assert!(secret_store.get_secret(&initial_handle).unwrap().is_none());
        assert!(
            store
                .load_session(&alice_session.session_id, &alice_session.local_endpoint_id)
                .unwrap()
                .is_none()
        );
        alice_session
            .seal_message("msg-1", b"local state changed")
            .unwrap();
        let commit_error = store
            .commit_session(&revoked, &alice_session, "2026-06-26T00:04:02Z")
            .unwrap_err();
        assert!(
            commit_error
                .to_string()
                .contains("durable session is revoked")
        );
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_sesame_session_manager_tracks_devices_convergence_and_revoke() {
        let mut manager = SecureMeshSesameSessionManager::new(2);
        manager
            .activate_session("alice", "desktop_gui:alice", "session-b")
            .unwrap();
        manager
            .activate_session("alice", "mobile:alice", "session-mobile")
            .unwrap();
        assert_eq!(
            manager.active_sessions_for_user("alice"),
            vec!["session-b".to_string(), "session-mobile".to_string()]
        );

        let chosen = manager
            .converge_session_collision("alice", "desktop_gui:alice", "session-a")
            .unwrap();
        assert_eq!(chosen, "session-a");
        manager
            .activate_session("alice", "desktop_gui:alice", "session-c")
            .unwrap();
        manager
            .activate_session("alice", "desktop_gui:alice", "session-d")
            .unwrap();
        let desktop = manager.device_record("alice", "desktop_gui:alice").unwrap();
        assert_eq!(desktop.active_session_id.as_deref(), Some("session-d"));
        assert_eq!(
            desktop.inactive_session_ids,
            vec!["session-a".to_string(), "session-c".to_string()]
        );

        let fanout = manager.fanout_targets_for_user("alice");
        assert_eq!(fanout.len(), 2);
        manager.revoke_device("alice", "mobile:alice").unwrap();
        let fanout_after_revoke = manager.fanout_targets_for_user("alice");
        assert_eq!(
            fanout_after_revoke,
            vec![("desktop_gui:alice".to_string(), "session-d".to_string())]
        );
        let mobile = manager.device_record("alice", "mobile:alice").unwrap();
        assert!(mobile.revoked);
        assert!(mobile.stale);
        assert!(mobile.inactive_session_ids.is_empty());
    }
}
