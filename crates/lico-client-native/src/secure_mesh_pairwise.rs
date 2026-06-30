use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit, Payload as AeadPayload},
};
use hkdf::Hkdf;
use rand::{RngCore, rngs::OsRng};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, Zeroizing};

use crate::secure_mesh::SECURE_MESH_PROTOCOL_VERSION;
use crate::secure_mesh_crypto::{
    ContentKey, OpenedSecureMeshPayload, SECURE_MESH_CONTENT_CIPHER_SUITE, SealedSecureMeshPayload,
    SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
};
use crate::secure_mesh_prekey::{
    SecureMeshPairwisePreKeyBundle, SecureMeshPreKeyValidationPolicy,
    validate_pairwise_prekey_bundle,
};
use crate::secure_mesh_trust::DeviceTrustPublicIdentity;
use time::OffsetDateTime;

pub const SECURE_MESH_PAIRWISE_CIPHER_SUITE: &str = "licolite.signal-x3dh-dr.v1.classical";
pub const SECURE_MESH_PAIRWISE_PQ_READY_CIPHER_SUITE: &str = "licolite.signal-pqxdh-dr.v1.pq-ready";
pub const SECURE_MESH_PAIRWISE_STATUS: &str = "x3dh_ready_double_ratchet_pairwise_runtime_sesame_session_manager_multi_device_fanout_session_key_payload_codec_cross_endpoint_command_result_relay_available_mls_cross_implementation_interop_verified_reviewed_signal_audit_blocked";

const ROOT_KEY_LEN: usize = 32;
const CHAIN_KEY_LEN: usize = 32;
const MESSAGE_KEY_LEN: usize = 32;
const NONCE_LEN: usize = 12;
const PUBLIC_KEY_LEN: usize = 32;
const MAX_SKIPPED_KEYS: usize = 32;
const MAX_REPLAY_IDS: usize = 256;
const MAX_CIPHERTEXT_BYTES: usize = 16 * 1024 * 1024;
const MAX_ENDPOINT_ID_LEN: usize = 255;
const MAX_MESSAGE_ID_LEN: usize = 255;

const X3DH_SALT_DOMAIN: &[u8] = b"licolite.secure-mesh.x3dh-ready.salt.v1";
const X3DH_INFO_DOMAIN: &[u8] = b"licolite.secure-mesh.x3dh-ready.info.v1";
const CHAIN_INFO_DOMAIN: &[u8] = b"licolite.secure-mesh.double-ratchet.chain.v1";
const ROOT_INFO_DOMAIN: &[u8] = b"licolite.secure-mesh.double-ratchet.root.v1";
const MESSAGE_AAD_MAGIC: &[u8] = b"LCOSM-PAIRWISE-AAD-v1";
const SECRET_DOMAIN: &[u8] = b"LCOSM-PAIRWISE-SECRET-v1";
const RELAY_HEADER_MAGIC: &[u8] = b"LCOSM-PAIRWISE-RELAY-v1";

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

    fn diffie_hellman(&self, remote_public_key: &[u8]) -> Result<[u8; PUBLIC_KEY_LEN]> {
        let remote = PublicKey::from(parse_key_bytes(remote_public_key, "remote public key")?);
        Ok(self.0.diffie_hellman(&remote).to_bytes())
    }

    fn to_bytes(&self) -> [u8; PUBLIC_KEY_LEN] {
        self.0.to_bytes()
    }
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
    pub transparency_tree_head: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPairwiseSessionAccepted {
    pub protocol_version: String,
    pub cipher_suite: String,
    pub session_id: String,
    pub responder_endpoint_id: String,
    pub responder_initial_ratchet_public_key: Vec<u8>,
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
    pub encrypted_header: String,
    pub ciphertext: String,
    pub ciphertext_size: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPairwiseRelayEnvelope {
    pub protocol_version: String,
    pub envelope_id: String,
    pub opaque_mailbox_id: String,
    pub message_id: String,
    pub cipher_suite: String,
    pub created_at: String,
    pub expires_at: String,
    pub encrypted_header: String,
    pub ciphertext: String,
    pub ciphertext_size: usize,
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

#[derive(Clone)]
pub struct SecureMeshPairwiseSession {
    pub session_id: String,
    pub local_endpoint_id: String,
    pub remote_endpoint_id: String,
    role: SecureMeshPairwiseRole,
    root_key: Zeroizing<[u8; ROOT_KEY_LEN]>,
    sending_chain_key: Zeroizing<[u8; CHAIN_KEY_LEN]>,
    receiving_chain_key: Zeroizing<[u8; CHAIN_KEY_LEN]>,
    local_ratchet_secret: SecureMeshPairwisePrivateKey,
    local_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    remote_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    dh_epoch: u64,
    sending_chain_index: u64,
    receiving_chain_index: u64,
    previous_chain_length: u64,
    skipped_keys: Vec<SkippedMessageKey>,
    received_message_ids: Vec<String>,
    revoked: bool,
}

impl SecureMeshPairwiseSession {
    pub fn initiate(
        local_identity: &DeviceTrustPublicIdentity,
        local_identity_secret: &SecureMeshPairwisePrivateKey,
        remote_bundle: &SecureMeshPairwisePreKeyBundle,
        policy: &SecureMeshPreKeyValidationPolicy,
        now: OffsetDateTime,
    ) -> Result<(Self, SecureMeshPairwiseSessionIntro)> {
        validate_endpoint_id(&local_identity.endpoint_id)?;
        let validation = validate_pairwise_prekey_bundle(remote_bundle, policy, now)?;
        let local_ephemeral = SecureMeshPairwisePrivateKey::generate();
        let local_ratchet_secret = SecureMeshPairwisePrivateKey::generate();
        let shared_secret = derive_x3dh_initiator_secret(
            local_identity,
            local_identity_secret,
            &local_ephemeral,
            remote_bundle,
        )?;
        let session_id = derive_session_id(
            &local_identity.endpoint_id,
            &remote_bundle.endpoint_identity.endpoint_id,
            &local_identity.identity_public_key,
            &remote_bundle.endpoint_identity.identity_public_key,
            &local_ephemeral.public_key(),
            &remote_bundle.signed_prekey.public_key,
            validation.one_time_prekey_id.as_deref(),
        )?;
        let keys = derive_initial_keys(
            &shared_secret,
            &session_id,
            &local_identity.endpoint_id,
            &remote_bundle.endpoint_identity.endpoint_id,
        )?;
        let local_ratchet_public_key = local_ratchet_secret.public_key();
        let session = Self {
            session_id: session_id.clone(),
            local_endpoint_id: local_identity.endpoint_id.clone(),
            remote_endpoint_id: remote_bundle.endpoint_identity.endpoint_id.clone(),
            role: SecureMeshPairwiseRole::Initiator,
            root_key: Zeroizing::new(keys.root_key),
            sending_chain_key: Zeroizing::new(keys.initiator_chain_key),
            receiving_chain_key: Zeroizing::new(keys.responder_chain_key),
            local_ratchet_secret,
            local_ratchet_public_key,
            remote_ratchet_public_key: [0u8; PUBLIC_KEY_LEN],
            dh_epoch: 0,
            sending_chain_index: 0,
            receiving_chain_index: 0,
            previous_chain_length: 0,
            skipped_keys: Vec::new(),
            received_message_ids: Vec::new(),
            revoked: false,
        };
        let intro = SecureMeshPairwiseSessionIntro {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id,
            initiator_endpoint_id: local_identity.endpoint_id.clone(),
            responder_endpoint_id: remote_bundle.endpoint_identity.endpoint_id.clone(),
            initiator_identity_public_key: local_identity.identity_public_key.to_vec(),
            initiator_ephemeral_public_key: local_ephemeral.public_key().to_vec(),
            initiator_initial_ratchet_public_key: local_ratchet_public_key.to_vec(),
            responder_signed_prekey_id: validation.signed_prekey_id,
            responder_one_time_prekey_id: validation.one_time_prekey_id,
            transparency_tree_head: validation.transparency_tree_head,
        };
        Ok((session, intro))
    }

    pub fn accept(
        local_identity: &DeviceTrustPublicIdentity,
        local_identity_secret: &SecureMeshPairwisePrivateKey,
        local_signed_prekey_secret: &SecureMeshPairwisePrivateKey,
        local_one_time_prekey_secret: Option<&SecureMeshPairwisePrivateKey>,
        intro: &SecureMeshPairwiseSessionIntro,
    ) -> Result<(Self, SecureMeshPairwiseSessionAccepted)> {
        ensure_intro(intro)?;
        ensure!(
            intro.responder_endpoint_id == local_identity.endpoint_id,
            "secure mesh pairwise intro responder mismatch"
        );
        let shared_secret = derive_x3dh_responder_secret(
            local_identity_secret,
            local_signed_prekey_secret,
            local_one_time_prekey_secret,
            intro,
        )?;
        let keys = derive_initial_keys(
            &shared_secret,
            &intro.session_id,
            &intro.initiator_endpoint_id,
            &intro.responder_endpoint_id,
        )?;
        let local_ratchet_secret = SecureMeshPairwisePrivateKey::generate();
        let local_ratchet_public_key = local_ratchet_secret.public_key();
        let remote_ratchet_public_key = parse_key_bytes(
            &intro.initiator_initial_ratchet_public_key,
            "initiator ratchet public key",
        )?;
        let session = Self {
            session_id: intro.session_id.clone(),
            local_endpoint_id: local_identity.endpoint_id.clone(),
            remote_endpoint_id: intro.initiator_endpoint_id.clone(),
            role: SecureMeshPairwiseRole::Responder,
            root_key: Zeroizing::new(keys.root_key),
            sending_chain_key: Zeroizing::new(keys.responder_chain_key),
            receiving_chain_key: Zeroizing::new(keys.initiator_chain_key),
            local_ratchet_secret,
            local_ratchet_public_key,
            remote_ratchet_public_key,
            dh_epoch: 0,
            sending_chain_index: 0,
            receiving_chain_index: 0,
            previous_chain_length: 0,
            skipped_keys: Vec::new(),
            received_message_ids: Vec::new(),
            revoked: false,
        };
        let accepted = SecureMeshPairwiseSessionAccepted {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: intro.session_id.clone(),
            responder_endpoint_id: local_identity.endpoint_id.clone(),
            responder_initial_ratchet_public_key: local_ratchet_public_key.to_vec(),
        };
        Ok((session, accepted))
    }

    pub fn complete_initiator_handshake(
        &mut self,
        accepted: &SecureMeshPairwiseSessionAccepted,
    ) -> Result<()> {
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
                && accepted.responder_endpoint_id == self.remote_endpoint_id,
            "secure mesh pairwise accept subject mismatch"
        );
        self.remote_ratchet_public_key = parse_key_bytes(
            &accepted.responder_initial_ratchet_public_key,
            "responder ratchet public key",
        )?;
        Ok(())
    }

    pub fn seal_message(
        &mut self,
        message_id: impl Into<String>,
        body: impl AsRef<[u8]>,
    ) -> Result<SecureMeshPairwiseMessage> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        let message_id = require_text(message_id.into(), "message id")?;
        validate_message_id(&message_id)?;
        let body = body.as_ref();
        ensure!(
            body.len() <= MAX_CIPHERTEXT_BYTES,
            "secure mesh pairwise message body is too large"
        );
        let chain_index = self.sending_chain_index;
        let (next_chain_key, message_key) = advance_chain(
            &self.sending_chain_key,
            self.dh_epoch,
            chain_index,
            "message",
        )?;
        let mut nonce = [0u8; NONCE_LEN];
        OsRng.fill_bytes(&mut nonce);
        let mut message = SecureMeshPairwiseMessage {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: self.session_id.clone(),
            message_id,
            sender_endpoint_id: self.local_endpoint_id.clone(),
            recipient_endpoint_id: self.remote_endpoint_id.clone(),
            dh_epoch: self.dh_epoch,
            chain_index,
            previous_chain_length: self.previous_chain_length,
            sender_ratchet_public_key: self.local_ratchet_public_key.to_vec(),
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
        *self.sending_chain_key = *next_chain_key;
        self.sending_chain_index += 1;
        Ok(message)
    }

    pub fn open_message(
        &mut self,
        message: &SecureMeshPairwiseMessage,
    ) -> Result<OpenedPairwiseMessage> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        ensure_message_for_session(self, message)?;
        ensure!(
            !self
                .received_message_ids
                .iter()
                .any(|id| id == &message.message_id),
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

        let mut candidate = self.clone();
        let message_key = candidate.message_key_for_open(message)?;
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
        candidate.record_received_message_id(message.message_id.clone());
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
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        ensure_pairwise_context_for_send(self, context)?;
        let chain_index = self.sending_chain_index;
        let (next_chain_key, message_key) = advance_chain(
            &self.sending_chain_key,
            self.dh_epoch,
            chain_index,
            "message",
        )?;
        let content_key = ContentKey::from_bytes(*message_key);
        let sealed = crate::secure_mesh_crypto::seal_payload(&content_key, context, plaintext)?;
        let message = SecureMeshPairwiseMessage {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: self.session_id.clone(),
            message_id: context.message_id.clone(),
            sender_endpoint_id: self.local_endpoint_id.clone(),
            recipient_endpoint_id: self.remote_endpoint_id.clone(),
            dh_epoch: self.dh_epoch,
            chain_index,
            previous_chain_length: self.previous_chain_length,
            sender_ratchet_public_key: self.local_ratchet_public_key.to_vec(),
            encrypted_header: sealed.encrypted_header,
            ciphertext: sealed.ciphertext,
            ciphertext_size: sealed.ciphertext_size,
        };
        *self.sending_chain_key = *next_chain_key;
        self.sending_chain_index += 1;
        Ok(message)
    }

    pub fn seal_payload_envelope(
        &mut self,
        context: &SecureMeshContentContext,
        plaintext: &SecureMeshPlaintext,
    ) -> Result<SecureMeshPairwiseRelayEnvelope> {
        let message = self.seal_payload(context, plaintext)?;
        SecureMeshPairwiseRelayEnvelope::from_pairwise_message(context, &message)
    }

    pub fn open_payload(
        &mut self,
        context: &SecureMeshContentContext,
        message: &SecureMeshPairwiseMessage,
        expected_kind: SecureMeshPayloadKind,
    ) -> Result<OpenedSecureMeshPayload> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        ensure_message_for_session(self, message)?;
        ensure_pairwise_context_for_open(self, context, message)?;
        ensure!(
            !self
                .received_message_ids
                .iter()
                .any(|id| id == &message.message_id),
            "secure mesh pairwise message replay detected"
        );
        let mut candidate = self.clone();
        let message_key = candidate.message_key_for_open(message)?;
        let content_key = ContentKey::from_bytes(*message_key);
        let sealed = SealedSecureMeshPayload {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_CONTENT_CIPHER_SUITE.to_string(),
            encrypted_header: message.encrypted_header.clone(),
            ciphertext: message.ciphertext.clone(),
            ciphertext_size: message.ciphertext_size,
        };
        let opened =
            crate::secure_mesh_crypto::open_payload(&content_key, context, &sealed, expected_kind)?;
        candidate.record_received_message_id(message.message_id.clone());
        *self = candidate;
        Ok(opened)
    }

    pub fn open_payload_envelope(
        &mut self,
        context: &SecureMeshContentContext,
        envelope: &SecureMeshPairwiseRelayEnvelope,
        expected_kind: SecureMeshPayloadKind,
    ) -> Result<OpenedSecureMeshPayload> {
        let message = envelope.to_pairwise_message_for_receiver(self, context)?;
        self.open_payload(context, &message, expected_kind)
    }

    pub fn rotate_sending_ratchet(&mut self) -> Result<()> {
        ensure!(!self.revoked, "secure mesh pairwise session is revoked");
        ensure!(
            self.remote_ratchet_public_key != [0u8; PUBLIC_KEY_LEN],
            "secure mesh pairwise remote ratchet public key is unavailable"
        );
        self.previous_chain_length = self.sending_chain_index;
        self.local_ratchet_secret = SecureMeshPairwisePrivateKey::generate();
        self.local_ratchet_public_key = self.local_ratchet_secret.public_key();
        let dh_secret = self
            .local_ratchet_secret
            .diffie_hellman(&self.remote_ratchet_public_key)?;
        let (root_key, chain_key) =
            derive_ratchet_root(&self.root_key, &dh_secret, self.dh_epoch + 1)?;
        *self.root_key = root_key;
        *self.sending_chain_key = chain_key;
        self.dh_epoch += 1;
        self.sending_chain_index = 0;
        Ok(())
    }

    pub fn revoke(&mut self) {
        self.revoked = true;
        self.root_key.zeroize();
        self.sending_chain_key.zeroize();
        self.receiving_chain_key.zeroize();
        for skipped in &mut self.skipped_keys {
            skipped.message_key.zeroize();
        }
        self.skipped_keys.clear();
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

    fn advance_receiving_chain_to(
        &mut self,
        message: &SecureMeshPairwiseMessage,
        sender_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    ) -> Result<Zeroizing<[u8; MESSAGE_KEY_LEN]>> {
        if sender_ratchet_public_key != self.remote_ratchet_public_key {
            ensure!(
                message.chain_index == 0,
                "secure mesh pairwise new ratchet message must start a chain"
            );
            ensure!(
                message.dh_epoch > self.dh_epoch,
                "secure mesh pairwise stale ratchet epoch"
            );
            let dh_secret = self
                .local_ratchet_secret
                .diffie_hellman(&sender_ratchet_public_key)?;
            let (root_key, chain_key) =
                derive_ratchet_root(&self.root_key, &dh_secret, message.dh_epoch)?;
            *self.root_key = root_key;
            *self.receiving_chain_key = chain_key;
            self.remote_ratchet_public_key = sender_ratchet_public_key;
            self.dh_epoch = message.dh_epoch;
            self.receiving_chain_index = 0;
        } else {
            ensure!(
                message.dh_epoch == self.dh_epoch,
                "secure mesh pairwise message epoch mismatch"
            );
        }
        ensure!(
            message.chain_index >= self.receiving_chain_index,
            "secure mesh pairwise stale chain index"
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
        if sender_ratchet_public_key != self.remote_ratchet_public_key {
            self.advance_receiving_chain_to(message, sender_ratchet_public_key)
        } else if message.chain_index < self.receiving_chain_index {
            self.take_skipped_message_key(
                &message.message_id,
                message.dh_epoch,
                message.chain_index,
                sender_ratchet_public_key,
            )
        } else {
            self.advance_receiving_chain_to(message, sender_ratchet_public_key)
        }
    }

    fn take_skipped_message_key(
        &mut self,
        message_id: &str,
        dh_epoch: u64,
        chain_index: u64,
        sender_ratchet_public_key: [u8; PUBLIC_KEY_LEN],
    ) -> Result<Zeroizing<[u8; MESSAGE_KEY_LEN]>> {
        let position = self.skipped_keys.iter().position(|candidate| {
            candidate.dh_epoch == dh_epoch
                && candidate.chain_index == chain_index
                && candidate.sender_ratchet_public_key == sender_ratchet_public_key
        });
        match position {
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

    fn to_snapshot(&self) -> PersistedPairwiseSession {
        PersistedPairwiseSession {
            session_id: self.session_id.clone(),
            local_endpoint_id: self.local_endpoint_id.clone(),
            remote_endpoint_id: self.remote_endpoint_id.clone(),
            role: self.role.as_str().to_string(),
            root_key: encode_secret(&self.root_key),
            sending_chain_key: encode_secret(&self.sending_chain_key),
            receiving_chain_key: encode_secret(&self.receiving_chain_key),
            local_ratchet_secret: encode_secret(&self.local_ratchet_secret.to_bytes()),
            local_ratchet_public_key: encode_secret(&self.local_ratchet_public_key),
            remote_ratchet_public_key: encode_secret(&self.remote_ratchet_public_key),
            dh_epoch: self.dh_epoch,
            sending_chain_index: self.sending_chain_index,
            receiving_chain_index: self.receiving_chain_index,
            previous_chain_length: self.previous_chain_length,
            skipped_keys: self
                .skipped_keys
                .iter()
                .map(PersistedSkippedMessageKey::from)
                .collect(),
            received_message_ids: self.received_message_ids.clone(),
            revoked: self.revoked,
        }
    }

    fn from_snapshot(snapshot: PersistedPairwiseSession) -> Result<Self> {
        validate_endpoint_id(&snapshot.local_endpoint_id)?;
        validate_endpoint_id(&snapshot.remote_endpoint_id)?;
        let local_ratchet_secret = SecureMeshPairwisePrivateKey::from_bytes(decode_secret_32(
            &snapshot.local_ratchet_secret,
        )?);
        Ok(Self {
            session_id: require_text(snapshot.session_id, "session id")?,
            local_endpoint_id: snapshot.local_endpoint_id,
            remote_endpoint_id: snapshot.remote_endpoint_id,
            role: SecureMeshPairwiseRole::from_str(&snapshot.role)?,
            root_key: Zeroizing::new(decode_secret_32(&snapshot.root_key)?),
            sending_chain_key: Zeroizing::new(decode_secret_32(&snapshot.sending_chain_key)?),
            receiving_chain_key: Zeroizing::new(decode_secret_32(&snapshot.receiving_chain_key)?),
            local_ratchet_secret,
            local_ratchet_public_key: decode_secret_32(&snapshot.local_ratchet_public_key)?,
            remote_ratchet_public_key: decode_secret_32(&snapshot.remote_ratchet_public_key)?,
            dh_epoch: snapshot.dh_epoch,
            sending_chain_index: snapshot.sending_chain_index,
            receiving_chain_index: snapshot.receiving_chain_index,
            previous_chain_length: snapshot.previous_chain_length,
            skipped_keys: snapshot
                .skipped_keys
                .into_iter()
                .map(SkippedMessageKey::try_from)
                .collect::<Result<Vec<_>>>()?,
            received_message_ids: snapshot.received_message_ids,
            revoked: snapshot.revoked,
        })
    }
}

impl SecureMeshPairwiseRelayEnvelope {
    fn from_pairwise_message(
        context: &SecureMeshContentContext,
        message: &SecureMeshPairwiseMessage,
    ) -> Result<Self> {
        ensure!(
            context.message_id == message.message_id
                && context.session_id == message.session_id
                && context.sender_endpoint_id == message.sender_endpoint_id
                && context.recipient_endpoint_id == message.recipient_endpoint_id,
            "secure mesh pairwise relay context does not match message"
        );
        Ok(Self {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            envelope_id: context.envelope_id.clone(),
            opaque_mailbox_id: context.opaque_mailbox_id.clone(),
            message_id: context.message_id.clone(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            created_at: context.created_at.clone(),
            expires_at: context.expires_at.clone(),
            encrypted_header: encode_pairwise_relay_header(message)?,
            ciphertext: message.ciphertext.clone(),
            ciphertext_size: message.ciphertext_size,
        })
    }

    fn to_pairwise_message_for_receiver(
        &self,
        session: &SecureMeshPairwiseSession,
        context: &SecureMeshContentContext,
    ) -> Result<SecureMeshPairwiseMessage> {
        ensure!(
            self.protocol_version == SECURE_MESH_PROTOCOL_VERSION
                && self.cipher_suite == SECURE_MESH_PAIRWISE_CIPHER_SUITE,
            "secure mesh pairwise relay envelope protocol is unsupported"
        );
        ensure!(
            self.envelope_id == context.envelope_id
                && self.opaque_mailbox_id == context.opaque_mailbox_id
                && self.message_id == context.message_id
                && self.created_at == context.created_at
                && self.expires_at == context.expires_at,
            "secure mesh pairwise relay envelope context mismatch"
        );
        ensure!(
            context.session_id == session.session_id
                && context.sender_endpoint_id == session.remote_endpoint_id
                && context.recipient_endpoint_id == session.local_endpoint_id,
            "secure mesh pairwise relay envelope receiver context mismatch"
        );
        let header = decode_pairwise_relay_header(&self.encrypted_header)?;
        Ok(SecureMeshPairwiseMessage {
            protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
            cipher_suite: SECURE_MESH_PAIRWISE_CIPHER_SUITE.to_string(),
            session_id: session.session_id.clone(),
            message_id: self.message_id.clone(),
            sender_endpoint_id: session.remote_endpoint_id.clone(),
            recipient_endpoint_id: session.local_endpoint_id.clone(),
            dh_epoch: header.dh_epoch,
            chain_index: header.chain_index,
            previous_chain_length: header.previous_chain_length,
            sender_ratchet_public_key: header.sender_ratchet_public_key,
            encrypted_header: header.content_encrypted_header,
            ciphertext: self.ciphertext.clone(),
            ciphertext_size: self.ciphertext_size,
        })
    }
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

pub struct SecureMeshPairwiseDurableStore {
    connection: Connection,
}

impl SecureMeshPairwiseDurableStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path.as_ref())
            .context("secure mesh pairwise durable store open failed")?;
        let store = Self { connection };
        store.initialize()?;
        Ok(store)
    }

    pub fn upsert_initial(
        &mut self,
        session: &SecureMeshPairwiseSession,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        let updated_at = require_text(updated_at.into(), "updated_at")?;
        let snapshot = serde_json::to_string(&session.to_snapshot())
            .context("secure mesh pairwise session snapshot serialization failed")?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh pairwise initial durable transaction failed")?;
        let existing: Option<i64> = tx
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
        tx.execute(
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
                snapshot,
                updated_at
            ],
        )?;
        tx.commit()
            .context("secure mesh pairwise initial durable commit failed")?;
        self.read_record(&session.session_id, &session.local_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh pairwise durable record disappeared after insert"))
    }

    pub fn commit_session(
        &mut self,
        previous: &SecureMeshPairwiseDurableRecord,
        session: &SecureMeshPairwiseSession,
        updated_at: impl Into<String>,
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
        ensure!(
            session.dh_epoch > previous.dh_epoch
                || session.sending_chain_index >= previous.sent_count
                || session.receiving_chain_index >= previous.received_count,
            "secure mesh pairwise durable state regression detected"
        );
        let updated_at = require_text(updated_at.into(), "updated_at")?;
        let snapshot = serde_json::to_string(&session.to_snapshot())
            .context("secure mesh pairwise session snapshot serialization failed")?;
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
                snapshot,
                updated_at,
                previous.session_id,
                previous.local_endpoint_id,
                previous.state_version as i64
            ],
        )?;
        ensure!(
            changed == 1,
            "secure mesh pairwise durable compare-and-swap failed"
        );
        tx.commit()
            .context("secure mesh pairwise durable commit failed")?;
        self.read_record(&session.session_id, &session.local_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh pairwise durable record disappeared after commit"))
    }

    pub fn mark_revoked(
        &mut self,
        previous: &SecureMeshPairwiseDurableRecord,
        revoked_at: impl Into<String>,
    ) -> Result<SecureMeshPairwiseDurableRecord> {
        let revoked_at = require_text(revoked_at.into(), "revoked_at")?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh pairwise durable revoke transaction failed")?;
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_pairwise_sessions
            SET revoked_at = ?1,
                state_version = state_version + 1,
                updated_at = ?1
            WHERE session_id = ?2
              AND local_endpoint_id = ?3
              AND state_version = ?4
              AND revoked_at IS NULL
            "#,
            params![
                revoked_at,
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
        self.read_record(&previous.session_id, &previous.local_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh pairwise durable record disappeared after revoke"))
    }

    pub fn load_session(
        &self,
        session_id: &str,
        local_endpoint_id: &str,
    ) -> Result<Option<SecureMeshPairwiseSession>> {
        let snapshot_json: Option<String> = self
            .connection
            .query_row(
                r#"
                SELECT snapshot_json
                FROM secure_mesh_pairwise_sessions
                WHERE session_id = ?1
                  AND local_endpoint_id = ?2
                "#,
                params![session_id, local_endpoint_id],
                |row| row.get(0),
            )
            .optional()
            .context("secure mesh pairwise durable snapshot read failed")?;
        snapshot_json
            .map(|value| {
                let snapshot: PersistedPairwiseSession = serde_json::from_str(&value)
                    .context("secure mesh pairwise session snapshot deserialization failed")?;
                SecureMeshPairwiseSession::from_snapshot(snapshot)
            })
            .transpose()
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

    fn initialize(&self) -> Result<()> {
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
            "#,
        )?;
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct PersistedPairwiseSession {
    session_id: String,
    local_endpoint_id: String,
    remote_endpoint_id: String,
    role: String,
    root_key: String,
    sending_chain_key: String,
    receiving_chain_key: String,
    local_ratchet_secret: String,
    local_ratchet_public_key: String,
    remote_ratchet_public_key: String,
    dh_epoch: u64,
    sending_chain_index: u64,
    receiving_chain_index: u64,
    previous_chain_length: u64,
    skipped_keys: Vec<PersistedSkippedMessageKey>,
    received_message_ids: Vec<String>,
    revoked: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct PersistedSkippedMessageKey {
    message_id: String,
    dh_epoch: u64,
    chain_index: u64,
    sender_ratchet_public_key: String,
    message_key: String,
}

impl From<&SkippedMessageKey> for PersistedSkippedMessageKey {
    fn from(value: &SkippedMessageKey) -> Self {
        Self {
            message_id: value.message_id.clone(),
            dh_epoch: value.dh_epoch,
            chain_index: value.chain_index,
            sender_ratchet_public_key: encode_secret(&value.sender_ratchet_public_key),
            message_key: encode_secret(&value.message_key),
        }
    }
}

impl TryFrom<PersistedSkippedMessageKey> for SkippedMessageKey {
    type Error = anyhow::Error;

    fn try_from(value: PersistedSkippedMessageKey) -> Result<Self> {
        Ok(Self {
            message_id: value.message_id,
            dh_epoch: value.dh_epoch,
            chain_index: value.chain_index,
            sender_ratchet_public_key: decode_secret_32(&value.sender_ratchet_public_key)?,
            message_key: Zeroizing::new(decode_secret_32(&value.message_key)?),
        })
    }
}

struct InitialPairwiseKeys {
    root_key: [u8; ROOT_KEY_LEN],
    initiator_chain_key: [u8; CHAIN_KEY_LEN],
    responder_chain_key: [u8; CHAIN_KEY_LEN],
}

fn derive_x3dh_initiator_secret(
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
    collect_x3dh_secret(
        &local_identity.endpoint_id,
        &remote_bundle.endpoint_identity.endpoint_id,
        &dh1,
        &dh2,
        &dh3,
        dh4.as_ref(),
    )
}

fn derive_x3dh_responder_secret(
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
    collect_x3dh_secret(
        &intro.initiator_endpoint_id,
        &intro.responder_endpoint_id,
        &dh1,
        &dh2,
        &dh3,
        dh4.as_ref(),
    )
}

fn collect_x3dh_secret(
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
    salt_hasher.update(X3DH_SALT_DOMAIN);
    salt_hasher.update(session_id.as_bytes());
    let salt = salt_hasher.finalize();
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), shared_secret);
    let mut info = Vec::new();
    info.extend_from_slice(X3DH_INFO_DOMAIN);
    append_len_prefixed_bytes(&mut info, SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut info, initiator_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut info, responder_endpoint_id.as_bytes())?;
    let mut out = [0u8; ROOT_KEY_LEN + CHAIN_KEY_LEN + CHAIN_KEY_LEN];
    hkdf.expand(&info, &mut out)
        .map_err(|_| anyhow!("secure mesh pairwise initial key derivation failed"))?;
    let mut root_key = [0u8; ROOT_KEY_LEN];
    let mut initiator_chain_key = [0u8; CHAIN_KEY_LEN];
    let mut responder_chain_key = [0u8; CHAIN_KEY_LEN];
    root_key.copy_from_slice(&out[0..ROOT_KEY_LEN]);
    initiator_chain_key.copy_from_slice(&out[ROOT_KEY_LEN..ROOT_KEY_LEN + CHAIN_KEY_LEN]);
    responder_chain_key.copy_from_slice(&out[ROOT_KEY_LEN + CHAIN_KEY_LEN..]);
    out.zeroize();
    Ok(InitialPairwiseKeys {
        root_key,
        initiator_chain_key,
        responder_chain_key,
    })
}

fn derive_ratchet_root(
    root_key: &[u8; ROOT_KEY_LEN],
    dh_secret: &[u8; PUBLIC_KEY_LEN],
    dh_epoch: u64,
) -> Result<([u8; ROOT_KEY_LEN], [u8; CHAIN_KEY_LEN])> {
    let mut salt_hasher = Sha256::new();
    salt_hasher.update(ROOT_INFO_DOMAIN);
    salt_hasher.update(root_key);
    salt_hasher.update(dh_epoch.to_be_bytes());
    let salt = salt_hasher.finalize();
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), dh_secret);
    let mut info = Vec::new();
    append_len_prefixed_bytes(&mut info, SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut info, b"dh-ratchet")?;
    let mut out = [0u8; ROOT_KEY_LEN + CHAIN_KEY_LEN];
    hkdf.expand(&info, &mut out)
        .map_err(|_| anyhow!("secure mesh pairwise root ratchet failed"))?;
    let mut new_root = [0u8; ROOT_KEY_LEN];
    let mut chain_key = [0u8; CHAIN_KEY_LEN];
    new_root.copy_from_slice(&out[0..ROOT_KEY_LEN]);
    chain_key.copy_from_slice(&out[ROOT_KEY_LEN..]);
    out.zeroize();
    Ok((new_root, chain_key))
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

fn derive_session_id(
    initiator_endpoint_id: &str,
    responder_endpoint_id: &str,
    initiator_identity_public_key: &[u8],
    responder_identity_public_key: &[u8],
    initiator_ephemeral_public_key: &[u8],
    responder_signed_prekey_public_key: &[u8],
    one_time_prekey_id: Option<&str>,
) -> Result<String> {
    let mut out = Vec::new();
    append_len_prefixed_bytes(&mut out, SECURE_MESH_PAIRWISE_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut out, initiator_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, responder_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, initiator_identity_public_key)?;
    append_len_prefixed_bytes(&mut out, responder_identity_public_key)?;
    append_len_prefixed_bytes(&mut out, initiator_ephemeral_public_key)?;
    append_len_prefixed_bytes(&mut out, responder_signed_prekey_public_key)?;
    append_len_prefixed_bytes(&mut out, one_time_prekey_id.unwrap_or("").as_bytes())?;
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
    append_len_prefixed_bytes(&mut out, message.encrypted_header.as_bytes())?;
    Ok(out)
}

struct PairwiseRelayHeader {
    dh_epoch: u64,
    chain_index: u64,
    previous_chain_length: u64,
    sender_ratchet_public_key: Vec<u8>,
    content_encrypted_header: String,
}

fn encode_pairwise_relay_header(message: &SecureMeshPairwiseMessage) -> Result<String> {
    let mut out = Vec::new();
    out.extend_from_slice(RELAY_HEADER_MAGIC);
    out.extend_from_slice(&message.dh_epoch.to_be_bytes());
    out.extend_from_slice(&message.chain_index.to_be_bytes());
    out.extend_from_slice(&message.previous_chain_length.to_be_bytes());
    append_len_prefixed_bytes(&mut out, &message.sender_ratchet_public_key)?;
    append_len_prefixed_bytes(&mut out, message.encrypted_header.as_bytes())?;
    Ok(general_purpose::URL_SAFE_NO_PAD.encode(out))
}

fn decode_pairwise_relay_header(value: &str) -> Result<PairwiseRelayHeader> {
    let bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .context("secure mesh pairwise relay encrypted header is not base64url")?;
    let mut reader = PairwiseRelayHeaderReader::new(&bytes);
    reader.expect_bytes(RELAY_HEADER_MAGIC)?;
    let dh_epoch = reader.read_u64()?;
    let chain_index = reader.read_u64()?;
    let previous_chain_length = reader.read_u64()?;
    let sender_ratchet_public_key = reader.read_len_prefixed_bytes()?.to_vec();
    parse_key_bytes(
        &sender_ratchet_public_key,
        "relay sender ratchet public key",
    )?;
    let content_encrypted_header = String::from_utf8(reader.read_len_prefixed_bytes()?.to_vec())
        .map_err(|_| anyhow!("secure mesh pairwise relay content header is not utf-8"))?;
    ensure!(
        reader.is_empty(),
        "secure mesh pairwise relay encrypted header has trailing bytes"
    );
    Ok(PairwiseRelayHeader {
        dh_epoch,
        chain_index,
        previous_chain_length,
        sender_ratchet_public_key,
        content_encrypted_header,
    })
}

struct PairwiseRelayHeaderReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> PairwiseRelayHeaderReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn expect_bytes(&mut self, expected: &[u8]) -> Result<()> {
        let actual = self.read_exact(expected.len())?;
        ensure!(
            actual == expected,
            "secure mesh pairwise relay encrypted header magic is invalid"
        );
        Ok(())
    }

    fn read_u64(&mut self) -> Result<u64> {
        let bytes = self.read_exact(8)?;
        Ok(u64::from_be_bytes(bytes.try_into().map_err(|_| {
            anyhow!("secure mesh pairwise relay integer is invalid")
        })?))
    }

    fn read_len_prefixed_bytes(&mut self) -> Result<&'a [u8]> {
        let len_bytes = self.read_exact(4)?;
        let len = u32::from_be_bytes(
            len_bytes
                .try_into()
                .map_err(|_| anyhow!("secure mesh pairwise relay length is invalid"))?,
        ) as usize;
        self.read_exact(len)
    }

    fn read_exact(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(len)
            .ok_or_else(|| anyhow!("secure mesh pairwise relay length overflow"))?;
        ensure!(
            end <= self.bytes.len(),
            "secure mesh pairwise relay header is truncated"
        );
        let out = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(out)
    }

    fn is_empty(&self) -> bool {
        self.offset == self.bytes.len()
    }
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
    let bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .context("secure mesh pairwise persisted secret is not base64url")?;
    parse_key_bytes(&bytes, "persisted secret")
}

fn encode_secret(bytes: &[u8; PUBLIC_KEY_LEN]) -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn append_len_prefixed_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len = u32::try_from(value.len())
        .map_err(|_| anyhow!("secure mesh pairwise field is too large"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
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
    use crate::secure_mesh_command::{
        SecureCommandEvaluationContext, SecureCommandLocalExecutor, SecureCommandPayload,
        SecureCommandReplayLedger, evaluate_secure_command, execute_evaluated_secure_command,
    };
    use crate::secure_mesh_prekey::{
        SecureMeshPairwisePreKeyBundle, SecureMeshPreKeyKind, sign_prekey_record,
    };
    use crate::secure_mesh_trust::DeviceTrustState;
    use ed25519_dalek::SigningKey;
    use serde_json::{Value, json};
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct EndpointFixture {
        identity: DeviceTrustPublicIdentity,
        identity_secret: SecureMeshPairwisePrivateKey,
        signing_key: SigningKey,
    }

    struct PrekeyFixture {
        signed_secret: SecureMeshPairwisePrivateKey,
        one_time_secret: SecureMeshPairwisePrivateKey,
        bundle: SecureMeshPairwisePreKeyBundle,
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
        PrekeyFixture {
            signed_secret,
            one_time_secret,
            bundle: SecureMeshPairwisePreKeyBundle {
                endpoint_identity: endpoint.identity.clone(),
                trust_state: DeviceTrustState::Verified,
                signed_prekey,
                one_time_prekey: Some(one_time_prekey),
                transparency_tree_head: "sha256:tree-head".to_string(),
            },
        }
    }

    fn pairwise_sessions() -> (SecureMeshPairwiseSession, SecureMeshPairwiseSession) {
        pairwise_sessions_between("desktop_gui:alice", "mobile:bob")
    }

    fn pairwise_sessions_between(
        initiator_endpoint_id: &str,
        responder_endpoint_id: &str,
    ) -> (SecureMeshPairwiseSession, SecureMeshPairwiseSession) {
        let alice = endpoint(initiator_endpoint_id);
        let bob = endpoint(responder_endpoint_id);
        let bob_prekeys = prekeys(&bob);
        let now = OffsetDateTime::parse(
            "2026-06-26T00:00:01Z",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap();
        let (mut alice_session, intro) = SecureMeshPairwiseSession::initiate(
            &alice.identity,
            &alice.identity_secret,
            &bob_prekeys.bundle,
            &SecureMeshPreKeyValidationPolicy::default(),
            now,
        )
        .unwrap();
        let (bob_session, accepted) = SecureMeshPairwiseSession::accept(
            &bob.identity,
            &bob.identity_secret,
            &bob_prekeys.signed_secret,
            Some(&bob_prekeys.one_time_secret),
            &intro,
        )
        .unwrap();
        alice_session
            .complete_initiator_handshake(&accepted)
            .unwrap();
        assert_eq!(alice_session.session_id, bob_session.session_id);
        (alice_session, bob_session)
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
            format!("env-{message_id}"),
            message_id,
            mailbox_id,
            sender,
            recipient,
            session.session_id.clone(),
            "2026-06-26T00:00:00Z",
            "2026-06-26T00:10:00Z",
        )
    }

    #[derive(Default)]
    struct OpaquePairwiseRelay {
        pending: Vec<SecureMeshPairwiseRelayEnvelope>,
        acked_message_ids: Vec<String>,
    }

    impl OpaquePairwiseRelay {
        fn send(&mut self, envelope: SecureMeshPairwiseRelayEnvelope, forbidden_plaintext: &str) {
            assert_eq!(envelope.protocol_version, SECURE_MESH_PROTOCOL_VERSION);
            assert_eq!(envelope.cipher_suite, SECURE_MESH_PAIRWISE_CIPHER_SUITE);
            assert!(!envelope.envelope_id.contains(forbidden_plaintext));
            assert!(!envelope.opaque_mailbox_id.contains(forbidden_plaintext));
            assert!(!envelope.message_id.contains(forbidden_plaintext));
            assert!(!envelope.encrypted_header.contains(forbidden_plaintext));
            assert!(!envelope.ciphertext.contains(forbidden_plaintext));
            self.pending.push(envelope);
        }

        fn sync(&self, opaque_mailbox_id: &str) -> Vec<SecureMeshPairwiseRelayEnvelope> {
            self.pending
                .iter()
                .filter(|envelope| envelope.opaque_mailbox_id == opaque_mailbox_id)
                .cloned()
                .collect()
        }

        fn ack(&mut self, message_id: &str) -> bool {
            let before = self.pending.len();
            self.pending
                .retain(|envelope| envelope.message_id != message_id);
            let idempotent = before == self.pending.len();
            if !self.acked_message_ids.iter().any(|id| id == message_id) {
                self.acked_message_ids.push(message_id.to_string());
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
            "schema": crate::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
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
            "riskClass": "read_only",
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
            "schema": crate::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
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
            "riskClass": "read_only",
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
        envelope: &SecureMeshPairwiseRelayEnvelope,
        forbidden_plaintext: &[&str],
    ) {
        for forbidden in forbidden_plaintext {
            assert!(
                !envelope.envelope_id.contains(forbidden),
                "envelope id leaked {forbidden}"
            );
            assert!(
                !envelope.opaque_mailbox_id.contains(forbidden),
                "mailbox id leaked {forbidden}"
            );
            assert!(
                !envelope.message_id.contains(forbidden),
                "message id leaked {forbidden}"
            );
            assert!(
                !envelope.encrypted_header.contains(forbidden),
                "encrypted header leaked {forbidden}"
            );
            assert!(
                !envelope.ciphertext.contains(forbidden),
                "ciphertext leaked {forbidden}"
            );
        }
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
            .open_payload_envelope(
                &command_context,
                &synced_for_recipient[0],
                SecureMeshPayloadKind::Command,
            )
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
            .open_payload_envelope(
                &result_context,
                &synced_for_sender[0],
                SecureMeshPayloadKind::ResultPayload,
            )
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
    fn secure_mesh_pairwise_x3dh_double_ratchet_round_trips() {
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let first = alice_session
            .seal_message("msg-1", b"hello bob without server plaintext")
            .unwrap();
        assert!(!first.ciphertext.contains("hello"));
        let opened = bob_session.open_message(&first).unwrap();
        assert_eq!(opened.body, b"hello bob without server plaintext");

        let reply = bob_session
            .seal_message("msg-2", b"hello alice encrypted")
            .unwrap();
        let opened_reply = alice_session.open_message(&reply).unwrap();
        assert_eq!(opened_reply.body, b"hello alice encrypted");

        alice_session.rotate_sending_ratchet().unwrap();
        let after_ratchet = alice_session
            .seal_message("msg-3", b"post compromise recovery direction")
            .unwrap();
        assert_eq!(after_ratchet.dh_epoch, 1);
        let opened_after_ratchet = bob_session.open_message(&after_ratchet).unwrap();
        assert_eq!(
            opened_after_ratchet.body,
            b"post compromise recovery direction"
        );
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
            .open_payload_envelope(
                &command_context,
                &synced_for_pc_b[0],
                SecureMeshPayloadKind::Command,
            )
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
            .open_payload_envelope(
                &result_context,
                &synced_for_pc_a[0],
                SecureMeshPayloadKind::ResultPayload,
            )
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
                "schema": crate::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
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
                "schema": crate::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
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
        assert_ne!(desktop_envelope.ciphertext, mobile_envelope.ciphertext);
        assert_ne!(
            desktop_envelope.encrypted_header,
            mobile_envelope.encrypted_header
        );
        for forbidden in [
            canary,
            "desktop_sidecar:alice-pc-a",
            "desktop_sidecar:bob-pc-b",
            "mobile:bob-mobile-c",
            "client.activity.sync",
        ] {
            assert!(!desktop_envelope.envelope_id.contains(forbidden));
            assert!(!desktop_envelope.opaque_mailbox_id.contains(forbidden));
            assert!(!desktop_envelope.message_id.contains(forbidden));
            assert!(!desktop_envelope.encrypted_header.contains(forbidden));
            assert!(!desktop_envelope.ciphertext.contains(forbidden));
            assert!(!mobile_envelope.envelope_id.contains(forbidden));
            assert!(!mobile_envelope.opaque_mailbox_id.contains(forbidden));
            assert!(!mobile_envelope.message_id.contains(forbidden));
            assert!(!mobile_envelope.encrypted_header.contains(forbidden));
            assert!(!mobile_envelope.ciphertext.contains(forbidden));
        }

        relay.send(desktop_envelope, canary);
        relay.send(mobile_envelope, canary);
        assert_eq!(relay.queue_len(), 2);

        let desktop_synced = relay.sync("mbx-fanout-a13f");
        let mobile_synced = relay.sync("mbx-fanout-b94c");
        assert_eq!(desktop_synced.len(), 1);
        assert_eq!(mobile_synced.len(), 1);
        let wrong_recipient = mobile_receiver
            .open_payload_envelope(
                &desktop_context,
                &desktop_synced[0],
                SecureMeshPayloadKind::Command,
            )
            .unwrap_err();
        assert!(
            wrong_recipient
                .to_string()
                .contains("receiver context mismatch")
        );

        let opened_desktop = desktop_receiver
            .open_payload_envelope(
                &desktop_context,
                &desktop_synced[0],
                SecureMeshPayloadKind::Command,
            )
            .unwrap();
        let opened_mobile = mobile_receiver
            .open_payload_envelope(
                &mobile_context,
                &mobile_synced[0],
                SecureMeshPayloadKind::Command,
            )
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
            br#"{"commandKind":"client.activity.sync","secret":"session-derived"}"#,
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
    fn secure_mesh_pairwise_skipped_key_store_is_bounded_and_eviction_fails_closed() {
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
        let opened_last = bob_session.open_message(&last).unwrap();
        assert_eq!(
            opened_last.body,
            format!("body-{}", MAX_SKIPPED_KEYS + 1).as_bytes()
        );
        assert_eq!(bob_session.skipped_key_count(), MAX_SKIPPED_KEYS);
        let evicted_error = bob_session.open_message(&messages[0]).unwrap_err();
        assert!(
            evicted_error
                .to_string()
                .contains("skipped message key is unavailable")
        );
    }

    #[test]
    fn secure_mesh_pairwise_durable_store_commits_reopens_and_rejects_stale_cas() {
        let store_path = durable_store_path("commit");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, mut bob_session) = pairwise_sessions();
        let mut store = SecureMeshPairwiseDurableStore::open(&store_path).unwrap();
        let initial = store
            .upsert_initial(&alice_session, "2026-06-26T00:03:00Z")
            .unwrap();
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

        drop(store);
        let reopened = SecureMeshPairwiseDurableStore::open(&store_path).unwrap();
        let restored = reopened
            .load_session(&alice_session.session_id, &alice_session.local_endpoint_id)
            .unwrap()
            .unwrap();
        assert_eq!(restored.sent_count(), 1);
        assert_eq!(restored.session_id, alice_session.session_id);

        let mut reopened_mut = SecureMeshPairwiseDurableStore::open(&store_path).unwrap();
        let stale_error = reopened_mut
            .commit_session(&initial, &alice_session, "2026-06-26T00:03:02Z")
            .unwrap_err();
        assert!(stale_error.to_string().contains("compare-and-swap failed"));
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_pairwise_durable_store_marks_revoked_and_blocks_commit() {
        let store_path = durable_store_path("revoke");
        let _ = std::fs::remove_file(&store_path);
        let (mut alice_session, _) = pairwise_sessions();
        let mut store = SecureMeshPairwiseDurableStore::open(&store_path).unwrap();
        let initial = store
            .upsert_initial(&alice_session, "2026-06-26T00:04:00Z")
            .unwrap();
        let revoked = store
            .mark_revoked(&initial, "2026-06-26T00:04:01Z")
            .unwrap();
        assert!(revoked.revoked_at.is_some());
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
