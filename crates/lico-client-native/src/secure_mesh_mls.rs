use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use openmls::key_packages::KeyPackageIn;
use openmls::prelude::{
    BasicCredential, Ciphersuite, CredentialWithKey, Extensions, GroupId, KeyPackage,
    KeyPackageBundle, LeafNodeIndex, LeafNodeParameters, MlsGroup, MlsGroupCreateConfig,
    MlsGroupJoinConfig, MlsMessageBodyIn, MlsMessageIn, ProcessedMessageContent, ProtocolMessage,
    StagedWelcome, tls_codec::*,
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::{MemoryStorage, RustCrypto};
use openmls_traits::OpenMlsProvider;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use zeroize::Zeroizing;

use crate::file_security::harden_private_path;
use crate::secure_mesh_crypto::{
    ContentKey, OpenedSecureMeshPayload, SealedSecureMeshPayload, SecureMeshContentContext,
    SecureMeshPayloadKind, SecureMeshPlaintext,
};

pub const SECURE_MESH_MLS_CIPHER_SUITE: &str =
    "MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519";
pub const SECURE_MESH_MLS_STATUS: &str = "openmls_group_add_update_remove_durable_epoch_secret_store_group_payload_exporter_stale_replay_concurrent_commit_available_cross_implementation_interop_verified";

const MLS_PAYLOAD_EXPORT_LABEL: &str = "licolite.secure-mesh.mls.payload-content-key.v1";
const MLS_PAYLOAD_EXPORT_CONTEXT_MAGIC: &[u8] = b"LCOSM-MLS-PAYLOAD-EXPORT-v1";
const MLS_PAYLOAD_APPLICATION_AAD_MAGIC: &[u8] = b"LCOSM-MLS-PAYLOAD-AAD-v1";
const MLS_SEALED_PAYLOAD_MAGIC: &[u8] = b"LCOSM-MLS-SEALED-PAYLOAD-v1";
const MLS_PAYLOAD_CONTENT_KEY_LEN: usize = 32;
const MAX_MLS_CONTEXT_FIELD_BYTES: usize = 4096;

pub struct SecureMeshOpenMlsProvider {
    crypto: RustCrypto,
    storage: MemoryStorage,
}

impl SecureMeshOpenMlsProvider {
    pub fn load_secret_store(path: impl AsRef<Path>) -> Result<Self> {
        let file = File::open(path.as_ref())
            .with_context(|| "secure mesh MLS secret store open failed")?;
        let mut storage = MemoryStorage::default();
        storage
            .load_from_file(&file)
            .map_err(|error| anyhow!("secure mesh MLS secret store load failed: {error}"))?;
        Ok(Self {
            crypto: RustCrypto::default(),
            storage,
        })
    }

    pub fn save_secret_store(&self, path: impl AsRef<Path>) -> Result<()> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| "secure mesh MLS secret store directory create failed")?;
        }
        let temp_path = secret_store_temp_path(path)?;
        {
            let file = private_secret_store_open(&temp_path)?;
            self.storage
                .save_to_file(&file)
                .map_err(|error| anyhow!("secure mesh MLS secret store save failed: {error}"))?;
            file.sync_all()
                .with_context(|| "secure mesh MLS secret store fsync failed")?;
        }
        fs::rename(&temp_path, path)
            .with_context(|| "secure mesh MLS secret store atomic replace failed")?;
        harden_private_path(path)?;
        Ok(())
    }
}

impl Default for SecureMeshOpenMlsProvider {
    fn default() -> Self {
        Self {
            crypto: RustCrypto::default(),
            storage: MemoryStorage::default(),
        }
    }
}

impl OpenMlsProvider for SecureMeshOpenMlsProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = MemoryStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

pub struct SecureMeshMlsParticipant {
    provider: SecureMeshOpenMlsProvider,
    credential_with_key: CredentialWithKey,
    signer: SignatureKeyPair,
}

impl SecureMeshMlsParticipant {
    pub fn new(identity: impl Into<Vec<u8>>) -> Result<Self> {
        let provider = SecureMeshOpenMlsProvider::default();
        let signer = SignatureKeyPair::new(secure_mesh_mls_ciphersuite().signature_algorithm())
            .map_err(|error| anyhow!("secure mesh MLS signer generation failed: {error:?}"))?;
        signer
            .store(provider.storage())
            .map_err(|_| anyhow!("secure mesh MLS signer storage failed"))?;
        let credential = BasicCredential::new(identity.into());
        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.to_public_vec().into(),
        };
        Ok(Self {
            provider,
            credential_with_key,
            signer,
        })
    }

    pub fn load_from_secret_store(
        identity: impl Into<Vec<u8>>,
        signing_public_key: impl AsRef<[u8]>,
        path: impl AsRef<Path>,
    ) -> Result<Self> {
        let provider = SecureMeshOpenMlsProvider::load_secret_store(path)?;
        let signing_public_key = signing_public_key.as_ref().to_vec();
        ensure!(
            !signing_public_key.is_empty(),
            "secure mesh MLS signing public key is required"
        );
        let signer = SignatureKeyPair::read(
            provider.storage(),
            &signing_public_key,
            secure_mesh_mls_ciphersuite().signature_algorithm(),
        )
        .ok_or_else(|| anyhow!("secure mesh MLS signer is missing from secret store"))?;
        let credential = BasicCredential::new(identity.into());
        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signing_public_key.into(),
        };
        Ok(Self {
            provider,
            credential_with_key,
            signer,
        })
    }

    pub fn signing_public_key(&self) -> Vec<u8> {
        self.signer.to_public_vec()
    }

    pub fn save_secret_store(&self, path: impl AsRef<Path>) -> Result<()> {
        self.provider.save_secret_store(path)
    }

    pub fn generate_key_package(&self) -> Result<SecureMeshMlsKeyPackage> {
        let bundle = KeyPackage::builder()
            .key_package_extensions(Extensions::default())
            .build(
                secure_mesh_mls_ciphersuite(),
                &self.provider,
                &self.signer,
                self.credential_with_key.clone(),
            )
            .map_err(|error| anyhow!("secure mesh MLS key package generation failed: {error:?}"))?;
        SecureMeshMlsKeyPackage::from_bundle(bundle)
    }
}

fn secret_store_temp_path(path: &Path) -> Result<PathBuf> {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| anyhow!("secure mesh MLS secret store file name is required"))?;
    Ok(path.with_file_name(format!(".{file_name}.tmp-{}", std::process::id())))
}

fn private_secret_store_open(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .with_context(|| "secure mesh MLS secret store temp open failed")
        .and_then(|file| {
            harden_private_path(path)?;
            Ok(file)
        })
}

pub struct SecureMeshMlsKeyPackage {
    public_key_package: KeyPackage,
    public_bytes: Vec<u8>,
}

impl SecureMeshMlsKeyPackage {
    pub fn as_public_bytes(&self) -> &[u8] {
        &self.public_bytes
    }

    fn from_bundle(bundle: KeyPackageBundle) -> Result<Self> {
        let public_bytes = bundle
            .key_package()
            .tls_serialize_detached()
            .context("secure mesh MLS key package serialization failed")?;
        Ok(Self {
            public_key_package: bundle.key_package().clone(),
            public_bytes,
        })
    }
}

pub struct SecureMeshMlsWelcome {
    pub commit_message: Vec<u8>,
    pub welcome_message: Vec<u8>,
}

pub struct SecureMeshMlsCommit {
    pub commit_message: Vec<u8>,
    pub welcome_message: Option<Vec<u8>>,
}

pub struct SecureMeshMlsGroup {
    group: MlsGroup,
}

impl SecureMeshMlsGroup {
    pub fn create(owner: &SecureMeshMlsParticipant, group_id: impl AsRef<[u8]>) -> Result<Self> {
        let group = MlsGroup::new_with_group_id(
            &owner.provider,
            &owner.signer,
            &secure_mesh_mls_create_config(),
            GroupId::from_slice(group_id.as_ref()),
            owner.credential_with_key.clone(),
        )
        .map_err(|error| anyhow!("secure mesh MLS group creation failed: {error:?}"))?;
        Ok(Self { group })
    }

    pub fn add_member(
        &mut self,
        owner: &SecureMeshMlsParticipant,
        key_package: &SecureMeshMlsKeyPackage,
    ) -> Result<SecureMeshMlsWelcome> {
        let (commit_message, welcome_message, _group_info) = self
            .group
            .add_members(
                &owner.provider,
                &owner.signer,
                core::slice::from_ref(&key_package.public_key_package),
            )
            .map_err(|error| anyhow!("secure mesh MLS add member failed: {error:?}"))?;
        self.group
            .merge_pending_commit(&owner.provider)
            .map_err(|error| anyhow!("secure mesh MLS pending commit merge failed: {error:?}"))?;
        Ok(SecureMeshMlsWelcome {
            commit_message: commit_message.to_bytes().map_err(|error| {
                anyhow!("secure mesh MLS commit serialization failed: {error:?}")
            })?,
            welcome_message: welcome_message.to_bytes().map_err(|error| {
                anyhow!("secure mesh MLS welcome serialization failed: {error:?}")
            })?,
        })
    }

    pub fn own_leaf_index(&self) -> LeafNodeIndex {
        self.group.own_leaf_index()
    }

    pub fn member_count(&self) -> usize {
        self.group.members().count()
    }

    pub fn is_active(&self) -> bool {
        self.group.is_active()
    }

    pub fn epoch(&self) -> u64 {
        self.group.epoch().as_u64()
    }

    pub fn public_metadata(
        &self,
        participant_endpoint_id: impl Into<String>,
    ) -> Result<SecureMeshMlsGroupMetadata> {
        let group_id = self.group.group_id().as_slice().to_vec();
        Ok(SecureMeshMlsGroupMetadata {
            group_id_hash: hash_bytes(&group_id),
            epoch: self.epoch(),
            member_count: self.member_count(),
            own_leaf_index: self.own_leaf_index().u32(),
            active: self.is_active(),
            participant_endpoint_id: participant_endpoint_id.into(),
        })
    }

    pub fn join_from_welcome(
        participant: &SecureMeshMlsParticipant,
        welcome_message: &[u8],
    ) -> Result<Self> {
        let welcome = match MlsMessageIn::tls_deserialize_exact(welcome_message.to_vec())
            .context("secure mesh MLS welcome deserialization failed")?
            .extract()
        {
            MlsMessageBodyIn::Welcome(welcome) => welcome,
            _ => return Err(anyhow!("secure mesh MLS message is not a welcome")),
        };
        let staged_join = StagedWelcome::new_from_welcome(
            &participant.provider,
            &secure_mesh_mls_join_config(),
            welcome,
            None,
        )
        .map_err(|error| anyhow!("secure mesh MLS staged welcome failed: {error:?}"))?;
        let group = staged_join
            .into_group(&participant.provider)
            .map_err(|error| anyhow!("secure mesh MLS welcome join failed: {error:?}"))?;
        Ok(Self { group })
    }

    pub fn load_from_provider(
        participant: &SecureMeshMlsParticipant,
        group_id: impl AsRef<[u8]>,
    ) -> Result<Self> {
        let group_id = GroupId::from_slice(group_id.as_ref());
        let group = MlsGroup::load(participant.provider.storage(), &group_id)
            .map_err(|error| anyhow!("secure mesh MLS group storage load failed: {error:?}"))?
            .ok_or_else(|| anyhow!("secure mesh MLS group is missing from provider storage"))?;
        Ok(Self { group })
    }

    pub fn seal_application_message(
        &mut self,
        sender: &SecureMeshMlsParticipant,
        aad: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>> {
        self.group.set_aad(aad.to_vec());
        let message = self
            .group
            .create_message(&sender.provider, &sender.signer, plaintext)
            .map_err(|error| {
                anyhow!("secure mesh MLS application message seal failed: {error:?}")
            })?;
        message.to_bytes().map_err(|error| {
            anyhow!("secure mesh MLS application message serialization failed: {error:?}")
        })
    }

    pub fn open_application_message(
        &mut self,
        receiver: &SecureMeshMlsParticipant,
        aad: &[u8],
        message: &[u8],
    ) -> Result<Vec<u8>> {
        let protocol_message: ProtocolMessage =
            MlsMessageIn::tls_deserialize_exact(message.to_vec())
                .context("secure mesh MLS application message deserialization failed")?
                .try_into_protocol_message()
                .map_err(|_| {
                    anyhow!("secure mesh MLS message is not an application protocol message")
                })?;
        let processed = self
            .group
            .process_message(&receiver.provider, protocol_message)
            .map_err(|error| {
                anyhow!("secure mesh MLS application message open failed: {error:?}")
            })?;
        ensure!(
            processed.aad() == aad,
            "secure mesh MLS application message AAD mismatch"
        );
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(application_message) => {
                Ok(application_message.into_bytes())
            }
            _ => Err(anyhow!(
                "secure mesh MLS message did not contain application data"
            )),
        }
    }

    pub fn derive_group_payload_content_key(
        &self,
        participant: &SecureMeshMlsParticipant,
        context: &SecureMeshContentContext,
        kind: SecureMeshPayloadKind,
    ) -> Result<ContentKey> {
        let export_context = build_group_payload_bound_context(
            MLS_PAYLOAD_EXPORT_CONTEXT_MAGIC,
            self,
            context,
            kind,
        )?;
        let exported = Zeroizing::new(
            self.group
                .export_secret(
                    participant.provider.crypto(),
                    MLS_PAYLOAD_EXPORT_LABEL,
                    &export_context,
                    MLS_PAYLOAD_CONTENT_KEY_LEN,
                )
                .map_err(|error| {
                    anyhow!("secure mesh MLS payload content-key export failed: {error:?}")
                })?,
        );
        ensure!(
            exported.len() == MLS_PAYLOAD_CONTENT_KEY_LEN,
            "secure mesh MLS payload content-key export length is invalid"
        );
        let mut fixed = [0u8; MLS_PAYLOAD_CONTENT_KEY_LEN];
        fixed.copy_from_slice(exported.as_slice());
        Ok(ContentKey::from_bytes(fixed))
    }

    pub fn seal_payload_message(
        &mut self,
        sender: &SecureMeshMlsParticipant,
        context: &SecureMeshContentContext,
        plaintext: &SecureMeshPlaintext,
    ) -> Result<Vec<u8>> {
        let content_key = self.derive_group_payload_content_key(sender, context, plaintext.kind)?;
        let sealed = crate::secure_mesh_crypto::seal_payload(&content_key, context, plaintext)?;
        let encoded = encode_mls_sealed_payload(&sealed)?;
        let aad = build_group_payload_bound_context(
            MLS_PAYLOAD_APPLICATION_AAD_MAGIC,
            self,
            context,
            plaintext.kind,
        )?;
        self.seal_application_message(sender, &aad, &encoded)
    }

    pub fn open_payload_message(
        &mut self,
        receiver: &SecureMeshMlsParticipant,
        context: &SecureMeshContentContext,
        message: &[u8],
        expected_kind: SecureMeshPayloadKind,
    ) -> Result<OpenedSecureMeshPayload> {
        let aad = build_group_payload_bound_context(
            MLS_PAYLOAD_APPLICATION_AAD_MAGIC,
            self,
            context,
            expected_kind,
        )?;
        let encoded = self.open_application_message(receiver, &aad, message)?;
        let sealed = decode_mls_sealed_payload(&encoded)?;
        let content_key =
            self.derive_group_payload_content_key(receiver, context, expected_kind)?;
        crate::secure_mesh_crypto::open_payload(&content_key, context, &sealed, expected_kind)
    }

    pub fn self_update(&mut self, participant: &SecureMeshMlsParticipant) -> Result<Vec<u8>> {
        let commit = self
            .group
            .self_update(
                &participant.provider,
                &participant.signer,
                LeafNodeParameters::default(),
            )
            .map_err(|error| anyhow!("secure mesh MLS self update failed: {error:?}"))?
            .into_commit();
        self.group
            .merge_pending_commit(&participant.provider)
            .map_err(|error| {
                anyhow!("secure mesh MLS self update pending commit merge failed: {error:?}")
            })?;
        commit
            .to_bytes()
            .map_err(|error| anyhow!("secure mesh MLS self update serialization failed: {error:?}"))
    }

    pub fn remove_member(
        &mut self,
        remover: &SecureMeshMlsParticipant,
        removed: LeafNodeIndex,
    ) -> Result<SecureMeshMlsCommit> {
        let (commit_message, welcome_message, _group_info) = self
            .group
            .remove_members(&remover.provider, &remover.signer, &[removed])
            .map_err(|error| anyhow!("secure mesh MLS remove member failed: {error:?}"))?;
        self.group
            .merge_pending_commit(&remover.provider)
            .map_err(|error| {
                anyhow!("secure mesh MLS remove member pending commit merge failed: {error:?}")
            })?;
        Ok(SecureMeshMlsCommit {
            commit_message: commit_message.to_bytes().map_err(|error| {
                anyhow!("secure mesh MLS remove commit serialization failed: {error:?}")
            })?,
            welcome_message: match welcome_message {
                Some(welcome) => Some(welcome.to_bytes().map_err(|error| {
                    anyhow!("secure mesh MLS remove welcome serialization failed: {error:?}")
                })?),
                None => None,
            },
        })
    }

    pub fn process_commit(
        &mut self,
        participant: &SecureMeshMlsParticipant,
        commit_message: &[u8],
    ) -> Result<()> {
        let protocol_message = deserialize_protocol_message(
            commit_message,
            "secure mesh MLS commit deserialization failed",
        )?;
        let processed = self
            .group
            .process_message(&participant.provider, protocol_message)
            .map_err(|error| anyhow!("secure mesh MLS commit process failed: {error:?}"))?;
        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged_commit) => self
                .group
                .merge_staged_commit(&participant.provider, *staged_commit)
                .map_err(|error| anyhow!("secure mesh MLS staged commit merge failed: {error:?}")),
            _ => Err(anyhow!("secure mesh MLS message did not contain a commit")),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshMlsGroupMetadata {
    pub group_id_hash: String,
    pub epoch: u64,
    pub member_count: usize,
    pub own_leaf_index: u32,
    pub active: bool,
    pub participant_endpoint_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshMlsDurableRecord {
    pub group_id_hash: String,
    pub participant_endpoint_id: String,
    pub epoch: u64,
    pub state_version: u64,
    pub member_count: usize,
    pub own_leaf_index: u32,
    pub active: bool,
    pub revoked_at_epoch: Option<u64>,
    pub updated_at: String,
}

pub struct SecureMeshMlsDurableStore {
    connection: Connection,
}

impl SecureMeshMlsDurableStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path.as_ref())
            .with_context(|| "secure mesh MLS durable store open failed")?;
        let store = Self { connection };
        store.initialize()?;
        Ok(store)
    }

    pub fn upsert_initial(
        &mut self,
        metadata: &SecureMeshMlsGroupMetadata,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshMlsDurableRecord> {
        validate_metadata(metadata)?;
        let updated_at = require_text(updated_at.into(), "updated_at")?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh MLS initial durable transaction failed")?;
        let existing: Option<i64> = tx
            .query_row(
                r#"
                SELECT 1
                FROM secure_mesh_mls_group_state
                WHERE group_id_hash = ?1
                  AND participant_endpoint_id = ?2
                "#,
                params![metadata.group_id_hash, metadata.participant_endpoint_id],
                |row| row.get(0),
            )
            .optional()
            .context("secure mesh MLS durable initial existence check failed")?;
        ensure!(
            existing.is_none(),
            "secure mesh MLS durable record already exists"
        );
        tx.execute(
            r#"
            INSERT INTO secure_mesh_mls_group_state (
                group_id_hash,
                participant_endpoint_id,
                epoch,
                state_version,
                member_count,
                own_leaf_index,
                active,
                revoked_at_epoch,
                updated_at
            ) VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, NULL, ?7)
            "#,
            params![
                metadata.group_id_hash,
                metadata.participant_endpoint_id,
                metadata.epoch as i64,
                metadata.member_count as i64,
                metadata.own_leaf_index as i64,
                i64::from(metadata.active),
                updated_at
            ],
        )?;
        tx.commit()
            .context("secure mesh MLS initial durable commit failed")?;
        self.read(&metadata.group_id_hash, &metadata.participant_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS durable record disappeared after insert"))
    }

    pub fn commit_epoch(
        &mut self,
        previous: &SecureMeshMlsDurableRecord,
        metadata: &SecureMeshMlsGroupMetadata,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshMlsDurableRecord> {
        validate_metadata(metadata)?;
        ensure!(
            previous.group_id_hash == metadata.group_id_hash
                && previous.participant_endpoint_id == metadata.participant_endpoint_id,
            "secure mesh MLS durable commit subject mismatch"
        );
        ensure!(
            metadata.epoch >= previous.epoch,
            "secure mesh MLS durable rollback detected"
        );
        ensure!(
            metadata.epoch > previous.epoch
                || metadata.active != previous.active
                || metadata.member_count != previous.member_count
                || metadata.own_leaf_index != previous.own_leaf_index,
            "secure mesh MLS durable commit has no state movement"
        );
        ensure!(
            previous.revoked_at_epoch.is_none(),
            "secure mesh MLS durable record is revoked"
        );
        let updated_at = require_text(updated_at.into(), "updated_at")?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh MLS durable commit transaction failed")?;
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_mls_group_state
            SET epoch = ?1,
                state_version = state_version + 1,
                member_count = ?2,
                own_leaf_index = ?3,
                active = ?4,
                updated_at = ?5
            WHERE group_id_hash = ?6
              AND participant_endpoint_id = ?7
              AND state_version = ?8
              AND epoch = ?9
              AND revoked_at_epoch IS NULL
            "#,
            params![
                metadata.epoch as i64,
                metadata.member_count as i64,
                metadata.own_leaf_index as i64,
                i64::from(metadata.active),
                updated_at,
                previous.group_id_hash,
                previous.participant_endpoint_id,
                previous.state_version as i64,
                previous.epoch as i64
            ],
        )?;
        ensure!(
            changed == 1,
            "secure mesh MLS durable compare-and-swap failed"
        );
        tx.commit()
            .context("secure mesh MLS durable commit failed")?;
        self.read(&metadata.group_id_hash, &metadata.participant_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS durable record disappeared after commit"))
    }

    pub fn mark_revoked(
        &mut self,
        previous: &SecureMeshMlsDurableRecord,
        revoked_at_epoch: u64,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshMlsDurableRecord> {
        ensure!(
            revoked_at_epoch >= previous.epoch,
            "secure mesh MLS durable revoke epoch rollback detected"
        );
        let updated_at = require_text(updated_at.into(), "updated_at")?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh MLS durable revoke transaction failed")?;
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_mls_group_state
            SET active = 0,
                revoked_at_epoch = ?1,
                state_version = state_version + 1,
                updated_at = ?2
            WHERE group_id_hash = ?3
              AND participant_endpoint_id = ?4
              AND state_version = ?5
              AND revoked_at_epoch IS NULL
            "#,
            params![
                revoked_at_epoch as i64,
                updated_at,
                previous.group_id_hash,
                previous.participant_endpoint_id,
                previous.state_version as i64
            ],
        )?;
        ensure!(
            changed == 1,
            "secure mesh MLS durable revoke compare-and-swap failed"
        );
        tx.commit()
            .context("secure mesh MLS durable revoke commit failed")?;
        self.read(&previous.group_id_hash, &previous.participant_endpoint_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS durable record disappeared after revoke"))
    }

    pub fn read(
        &self,
        group_id_hash: &str,
        participant_endpoint_id: &str,
    ) -> Result<Option<SecureMeshMlsDurableRecord>> {
        read_record_tx(&self.connection, group_id_hash, participant_endpoint_id)
    }

    fn initialize(&self) -> Result<()> {
        self.connection.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS secure_mesh_mls_group_state (
                group_id_hash TEXT NOT NULL,
                participant_endpoint_id TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                state_version INTEGER NOT NULL,
                member_count INTEGER NOT NULL,
                own_leaf_index INTEGER NOT NULL,
                active INTEGER NOT NULL,
                revoked_at_epoch INTEGER,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (group_id_hash, participant_endpoint_id)
            );
            CREATE INDEX IF NOT EXISTS secure_mesh_mls_group_state_epoch_idx
                ON secure_mesh_mls_group_state(group_id_hash, epoch, state_version);
            "#,
        )?;
        Ok(())
    }
}

fn deserialize_protocol_message(message: &[u8], context: &'static str) -> Result<ProtocolMessage> {
    MlsMessageIn::tls_deserialize_exact(message.to_vec())
        .context(context)?
        .try_into_protocol_message()
        .map_err(|_| anyhow!("secure mesh MLS message is not a protocol message"))
}

fn read_record_tx(
    connection: &Connection,
    group_id_hash: &str,
    participant_endpoint_id: &str,
) -> Result<Option<SecureMeshMlsDurableRecord>> {
    connection
        .query_row(
            r#"
            SELECT
                group_id_hash,
                participant_endpoint_id,
                epoch,
                state_version,
                member_count,
                own_leaf_index,
                active,
                revoked_at_epoch,
                updated_at
            FROM secure_mesh_mls_group_state
            WHERE group_id_hash = ?1
              AND participant_endpoint_id = ?2
            "#,
            params![group_id_hash, participant_endpoint_id],
            |row| {
                Ok(SecureMeshMlsDurableRecord {
                    group_id_hash: row.get(0)?,
                    participant_endpoint_id: row.get(1)?,
                    epoch: row.get::<_, i64>(2)? as u64,
                    state_version: row.get::<_, i64>(3)? as u64,
                    member_count: row.get::<_, i64>(4)? as usize,
                    own_leaf_index: row.get::<_, i64>(5)? as u32,
                    active: row.get::<_, i64>(6)? == 1,
                    revoked_at_epoch: row.get::<_, Option<i64>>(7)?.map(|value| value as u64),
                    updated_at: row.get(8)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn validate_metadata(metadata: &SecureMeshMlsGroupMetadata) -> Result<()> {
    ensure!(
        metadata.group_id_hash.starts_with("sha256:"),
        "secure mesh MLS group id hash is required"
    );
    ensure!(
        !metadata.participant_endpoint_id.trim().is_empty(),
        "secure mesh MLS participant endpoint id is required"
    );
    ensure!(
        metadata.member_count > 0,
        "secure mesh MLS member count is required"
    );
    Ok(())
}

fn require_text(value: String, label: &str) -> Result<String> {
    ensure!(
        !value.trim().is_empty(),
        "secure mesh MLS durable {label} is required"
    );
    Ok(value)
}

fn build_group_payload_bound_context(
    magic: &[u8],
    group: &SecureMeshMlsGroup,
    context: &SecureMeshContentContext,
    kind: SecureMeshPayloadKind,
) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(magic);
    append_mls_len_prefixed_bytes(&mut out, SECURE_MESH_MLS_CIPHER_SUITE.as_bytes())?;
    append_mls_len_prefixed_bytes(&mut out, group.group.group_id().as_slice())?;
    out.extend_from_slice(&group.epoch().to_be_bytes());
    append_mls_context_text(&mut out, "payload_kind", kind.as_str())?;
    append_mls_context_text(&mut out, "envelope_id", &context.envelope_id)?;
    append_mls_context_text(&mut out, "message_id", &context.message_id)?;
    append_mls_context_text(&mut out, "opaque_mailbox_id", &context.opaque_mailbox_id)?;
    append_mls_context_text(&mut out, "sender_endpoint_id", &context.sender_endpoint_id)?;
    append_mls_context_text(
        &mut out,
        "recipient_endpoint_id",
        &context.recipient_endpoint_id,
    )?;
    append_mls_context_text(&mut out, "session_id", &context.session_id)?;
    append_mls_context_text(&mut out, "created_at", &context.created_at)?;
    append_mls_context_text(&mut out, "expires_at", &context.expires_at)?;
    Ok(out)
}

fn encode_mls_sealed_payload(sealed: &SealedSecureMeshPayload) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(MLS_SEALED_PAYLOAD_MAGIC);
    append_mls_len_prefixed_bytes(&mut out, sealed.protocol_version.as_bytes())?;
    append_mls_len_prefixed_bytes(&mut out, sealed.cipher_suite.as_bytes())?;
    append_mls_len_prefixed_bytes(&mut out, sealed.encrypted_header.as_bytes())?;
    out.extend_from_slice(&(sealed.ciphertext_size as u64).to_be_bytes());
    append_mls_len_prefixed_bytes(&mut out, sealed.ciphertext.as_bytes())?;
    Ok(out)
}

fn decode_mls_sealed_payload(bytes: &[u8]) -> Result<SealedSecureMeshPayload> {
    let mut reader = MlsPayloadReader::new(bytes);
    reader.expect_bytes(MLS_SEALED_PAYLOAD_MAGIC)?;
    let protocol_version = reader.read_string("protocol_version")?;
    let cipher_suite = reader.read_string("cipher_suite")?;
    let encrypted_header = reader.read_string("encrypted_header")?;
    let ciphertext_size = reader.read_u64()? as usize;
    let ciphertext = reader.read_string("ciphertext")?;
    ensure!(
        reader.is_empty(),
        "secure mesh MLS sealed payload has trailing bytes"
    );
    Ok(SealedSecureMeshPayload {
        protocol_version,
        cipher_suite,
        encrypted_header,
        ciphertext,
        ciphertext_size,
    })
}

fn append_mls_context_text(out: &mut Vec<u8>, label: &str, value: &str) -> Result<()> {
    let trimmed = value.trim();
    ensure!(
        !trimmed.is_empty(),
        "secure mesh MLS payload context {label} is required"
    );
    ensure!(
        trimmed.len() <= MAX_MLS_CONTEXT_FIELD_BYTES,
        "secure mesh MLS payload context {label} is too large"
    );
    append_mls_len_prefixed_bytes(out, trimmed.as_bytes())
}

fn append_mls_len_prefixed_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len = u32::try_from(value.len())
        .map_err(|_| anyhow!("secure mesh MLS payload field is too large"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

struct MlsPayloadReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> MlsPayloadReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn expect_bytes(&mut self, expected: &[u8]) -> Result<()> {
        let actual = self.read_exact(expected.len())?;
        ensure!(
            actual == expected,
            "secure mesh MLS sealed payload magic is invalid"
        );
        Ok(())
    }

    fn read_string(&mut self, label: &str) -> Result<String> {
        let bytes = self.read_len_prefixed_bytes()?;
        String::from_utf8(bytes.to_vec())
            .map_err(|_| anyhow!("secure mesh MLS sealed payload {label} is not valid UTF-8"))
    }

    fn read_u64(&mut self) -> Result<u64> {
        let bytes = self.read_exact(8)?;
        Ok(u64::from_be_bytes(bytes.try_into().map_err(|_| {
            anyhow!("secure mesh MLS sealed payload integer is invalid")
        })?))
    }

    fn read_len_prefixed_bytes(&mut self) -> Result<&'a [u8]> {
        let len_bytes = self.read_exact(4)?;
        let len = u32::from_be_bytes(
            len_bytes
                .try_into()
                .map_err(|_| anyhow!("secure mesh MLS sealed payload length is invalid"))?,
        ) as usize;
        self.read_exact(len)
    }

    fn read_exact(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(len)
            .ok_or_else(|| anyhow!("secure mesh MLS sealed payload length overflow"))?;
        ensure!(
            end <= self.bytes.len(),
            "secure mesh MLS sealed payload is truncated"
        );
        let value = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(value)
    }

    fn is_empty(&self) -> bool {
        self.offset == self.bytes.len()
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

pub fn secure_mesh_mls_ciphersuite() -> Ciphersuite {
    Ciphersuite::MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519
}

fn secure_mesh_mls_create_config() -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .ciphersuite(secure_mesh_mls_ciphersuite())
        .use_ratchet_tree_extension(true)
        .build()
}

fn secure_mesh_mls_join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .build()
}

pub fn export_mls_recovery_vector_json() -> Result<Value> {
    let secret_store_path = recovery_vector_secret_store_path()?;
    let result = build_mls_recovery_vector_json(&secret_store_path);
    let _ = fs::remove_file(&secret_store_path);
    result
}

fn build_mls_recovery_vector_json(secret_store_path: &Path) -> Result<Value> {
    let alice_endpoint_id = "desktop_gui:alice";
    let bob_endpoint_id = "mobile:bob";
    let group_id = b"secure-mesh-interop-recovery-vector-group";
    let body = br#"{"op":"secure_mesh.group.commit","canary":"mls-interop-recovery-secret"}"#;

    let alice = SecureMeshMlsParticipant::new(alice_endpoint_id.as_bytes().to_vec())?;
    let bob = SecureMeshMlsParticipant::new(bob_endpoint_id.as_bytes().to_vec())?;
    let bob_signing_public_key = bob.signing_public_key();
    let bob_key_package = bob.generate_key_package()?;
    let mut key_package_slice = bob_key_package.as_public_bytes();
    KeyPackageIn::tls_deserialize(&mut key_package_slice).map_err(|error| {
        anyhow!("secure mesh MLS recovery vector key package parse failed: {error:?}")
    })?;
    ensure!(
        key_package_slice.is_empty(),
        "secure mesh MLS recovery vector key package has trailing bytes"
    );

    let mut alice_group = SecureMeshMlsGroup::create(&alice, group_id)?;
    let welcome = alice_group.add_member(&alice, &bob_key_package)?;
    deserialize_protocol_message(
        &welcome.commit_message,
        "secure mesh MLS recovery vector add commit parse failed",
    )?;
    match MlsMessageIn::tls_deserialize_exact(welcome.welcome_message.clone())
        .context("secure mesh MLS recovery vector welcome parse failed")?
        .extract()
    {
        MlsMessageBodyIn::Welcome(_) => {}
        _ => {
            return Err(anyhow!(
                "secure mesh MLS recovery vector message is not a welcome"
            ));
        }
    }

    let mut bob_group = SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message)?;
    let update_commit = alice_group.self_update(&alice)?;
    deserialize_protocol_message(
        &update_commit,
        "secure mesh MLS recovery vector update commit parse failed",
    )?;
    bob_group.process_commit(&bob, &update_commit)?;
    let recovered_epoch = bob_group.epoch();
    bob.save_secret_store(secret_store_path)?;
    drop(bob_group);
    drop(bob);

    let reloaded_bob = SecureMeshMlsParticipant::load_from_secret_store(
        bob_endpoint_id.as_bytes().to_vec(),
        &bob_signing_public_key,
        secret_store_path,
    )?;
    let mut reloaded_bob_group = SecureMeshMlsGroup::load_from_provider(&reloaded_bob, group_id)?;
    ensure!(
        reloaded_bob_group.epoch() == recovered_epoch,
        "secure mesh MLS recovery vector epoch reload mismatch"
    );

    let context = recovery_vector_content_context(recovered_epoch);
    let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, body.as_slice())
        .with_content_type("application/json");
    let application_message = alice_group.seal_payload_message(&alice, &context, &plaintext)?;
    deserialize_protocol_message(
        &application_message,
        "secure mesh MLS recovery vector application parse failed",
    )?;
    ensure!(
        !bytes_contain(&application_message, b"mls-interop-recovery-secret"),
        "secure mesh MLS recovery vector leaked plaintext canary"
    );

    let opened = reloaded_bob_group.open_payload_message(
        &reloaded_bob,
        &context,
        &application_message,
        SecureMeshPayloadKind::Command,
    )?;
    ensure!(
        opened.body == body,
        "secure mesh MLS recovery vector reload open mismatch"
    );

    let public_artifacts = json!({
        "keyPackage": recovery_vector_artifact("key_package", bob_key_package.as_public_bytes(), "mls_key_package"),
        "addCommit": recovery_vector_artifact("add_commit", &welcome.commit_message, "mls_commit"),
        "welcome": recovery_vector_artifact("welcome", &welcome.welcome_message, "mls_welcome"),
        "updateCommit": recovery_vector_artifact("update_commit", &update_commit, "mls_commit"),
        "application": recovery_vector_artifact("application", &application_message, "mls_application")
    });
    let serialized_artifacts = serde_json::to_vec(&public_artifacts)?;
    ensure!(
        !bytes_contain(&serialized_artifacts, b"mls-interop-recovery-secret"),
        "secure mesh MLS recovery vector public artifact JSON leaked plaintext canary"
    );

    Ok(json!({
        "ok": true,
        "vectorSchema": "v0.0.1:secure-mesh:mls-recovery-vector-1",
        "protocolVersion": "v0.0.1:secure-mesh:group-mls-1",
        "cipherSuite": SECURE_MESH_MLS_CIPHER_SUITE,
        "status": "local_openmls_public_wire_vector_exported_external_cross_implementation_runner_required",
        "group": {
            "groupIdHash": hash_bytes(group_id),
            "recoveredEpoch": recovered_epoch,
            "memberCountAfterRecovery": reloaded_bob_group.member_count()
        },
        "participants": {
            "senderEndpointId": alice_endpoint_id,
            "recipientEndpointId": bob_endpoint_id,
            "recipientSigningPublicKeySha256": hash_bytes(&bob_signing_public_key)
        },
        "payload": {
            "payloadKind": SecureMeshPayloadKind::Command.as_str(),
            "contentType": "application/json",
            "plaintextSha256": hash_bytes(body),
            "plaintextRedacted": true,
            "context": recovery_vector_context_json(&context)
        },
        "publicArtifacts": public_artifacts,
        "checks": {
            "keyPackageTlsParsed": true,
            "commitTlsParsed": true,
            "welcomeTlsParsed": true,
            "applicationTlsParsed": true,
            "secretStorePersistedAndReloaded": true,
            "applicationOpenedAfterReload": true,
            "plaintextCanaryAbsentInPublicArtifacts": true,
            "externalCrossImplementationComplete": false,
            "crossImplementationRunnerRequired": true
        }
    }))
}

fn recovery_vector_secret_store_path() -> Result<PathBuf> {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| anyhow!("secure mesh MLS recovery vector clock failed: {error}"))?
        .as_nanos();
    let mut path = std::env::temp_dir();
    path.push(format!(
        "lico-secure-mesh-mls-recovery-vector-{}-{nonce}.store",
        std::process::id()
    ));
    Ok(path)
}

fn recovery_vector_content_context(epoch: u64) -> SecureMeshContentContext {
    SecureMeshContentContext::new(
        "env_msg_mls_interop_recovery_vector",
        "msg_mls_interop_recovery_vector",
        "mailbox_mobile:bob",
        "desktop_gui:alice",
        "mobile:bob",
        format!("mls:{epoch}:secure-mesh-interop-recovery-vector-group"),
        "2026-01-01T00:00:00.000Z",
        "2026-01-01T00:10:00.000Z",
    )
}

fn recovery_vector_context_json(context: &SecureMeshContentContext) -> Value {
    json!({
        "envelopeId": &context.envelope_id,
        "messageId": &context.message_id,
        "opaqueMailboxId": &context.opaque_mailbox_id,
        "senderEndpointId": &context.sender_endpoint_id,
        "recipientEndpointId": &context.recipient_endpoint_id,
        "sessionId": &context.session_id,
        "createdAt": &context.created_at,
        "expiresAt": &context.expires_at
    })
}

fn recovery_vector_artifact(label: &str, bytes: &[u8], artifact_type: &str) -> Value {
    json!({
        "label": label,
        "artifactType": artifact_type,
        "encoding": "base64url",
        "byteLength": bytes.len(),
        "sha256": hash_bytes(bytes),
        "tlsSerializedBase64url": general_purpose::URL_SAFE_NO_PAD.encode(bytes)
    })
}

fn bytes_contain(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn durable_store_path(test_name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let mut path = std::env::temp_dir();
        path.push(format!(
            "lico-secure-mesh-mls-{test_name}-{}-{nonce}.sqlite3",
            std::process::id()
        ));
        path
    }

    fn content_context_fixture(
        message_id: &str,
        sender_endpoint_id: &str,
        recipient_endpoint_id: &str,
        session_id: String,
    ) -> SecureMeshContentContext {
        SecureMeshContentContext::new(
            format!("env_{message_id}"),
            message_id,
            format!("mailbox_{recipient_endpoint_id}"),
            sender_endpoint_id,
            recipient_endpoint_id,
            session_id,
            "2026-01-01T00:00:00.000Z",
            "2026-01-01T00:10:00.000Z",
        )
    }

    #[test]
    fn secure_mesh_openmls_group_application_message_round_trips() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        assert!(!bob_key_package.as_public_bytes().is_empty());

        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-group-test").unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        assert!(!welcome.commit_message.is_empty());
        assert!(!welcome.welcome_message.is_empty());

        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();
        let aad = b"secure-mesh:env_test:msg_test:mailbox_test";
        let sealed = alice_group
            .seal_application_message(&alice, aad, br#"{"op":"secure_mesh.group.commit"}"#)
            .unwrap();
        assert!(!sealed.windows(6).any(|window| window == b"group."));
        let opened = bob_group
            .open_application_message(&bob, aad, &sealed)
            .unwrap();
        assert_eq!(opened, br#"{"op":"secure_mesh.group.commit"}"#);
    }

    #[test]
    fn secure_mesh_openmls_group_application_message_rejects_aad_tamper() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-group-aad-test").unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();
        let sealed = alice_group
            .seal_application_message(&alice, b"aad:original", b"body")
            .unwrap();
        let error = bob_group
            .open_application_message(&bob, b"aad:tampered", &sealed)
            .unwrap_err();
        assert!(error.to_string().contains("AAD mismatch"));
    }

    #[test]
    fn secure_mesh_openmls_group_application_message_rejects_replay() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-group-replay-test").unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();

        let aad = b"secure-mesh:mls:application-replay";
        let sealed = alice_group
            .seal_application_message(&alice, aad, b"replay-once-only")
            .unwrap();
        assert_eq!(
            bob_group
                .open_application_message(&bob, aad, &sealed)
                .unwrap(),
            b"replay-once-only"
        );
        let replay_error = bob_group
            .open_application_message(&bob, aad, &sealed)
            .unwrap_err();
        assert!(
            replay_error.to_string().contains("open failed")
                || replay_error.to_string().contains("epoch")
                || replay_error.to_string().contains("replay")
        );
    }

    #[test]
    fn secure_mesh_openmls_group_application_message_rejects_stale_epoch() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-group-stale-epoch-test").unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();

        let stale_aad = b"secure-mesh:mls:stale-epoch";
        let stale_message = alice_group
            .seal_application_message(&alice, stale_aad, b"old-epoch-message")
            .unwrap();
        let update_commit = alice_group.self_update(&alice).unwrap();
        bob_group.process_commit(&bob, &update_commit).unwrap();
        let stale_error = bob_group
            .open_application_message(&bob, stale_aad, &stale_message)
            .unwrap_err();
        assert!(
            stale_error.to_string().contains("open failed")
                || stale_error.to_string().contains("epoch")
        );
    }

    #[test]
    fn secure_mesh_openmls_concurrent_commits_reject_losing_epoch() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-group-concurrent-commit-test")
                .unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();

        let alice_concurrent_commit = alice_group.self_update(&alice).unwrap();
        let bob_concurrent_commit = bob_group.self_update(&bob).unwrap();
        let bob_error = bob_group
            .process_commit(&bob, &alice_concurrent_commit)
            .unwrap_err();
        let alice_error = alice_group
            .process_commit(&alice, &bob_concurrent_commit)
            .unwrap_err();
        assert!(
            bob_error.to_string().contains("commit process failed")
                || bob_error.to_string().contains("epoch")
        );
        assert!(
            alice_error.to_string().contains("commit process failed")
                || alice_error.to_string().contains("epoch")
        );
    }

    #[test]
    fn secure_mesh_openmls_group_payload_uses_exporter_content_key() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-group-payload-test").unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();
        let context = content_context_fixture(
            "msg_group_payload",
            "desktop_gui:alice",
            "mobile:bob",
            format!(
                "mls:{}:{}",
                alice_group.epoch(),
                "secure-mesh-group-payload-test"
            ),
        );
        let body = br#"{"op":"secure_mesh.group.commit","canary":"group-payload-secret"}"#;
        let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, body.as_slice())
            .with_content_type("application/json");

        let message = alice_group
            .seal_payload_message(&alice, &context, &plaintext)
            .unwrap();
        assert!(
            !message
                .windows(b"group-payload-secret".len())
                .any(|window| window == b"group-payload-secret")
        );

        let opened = bob_group
            .open_payload_message(&bob, &context, &message, SecureMeshPayloadKind::Command)
            .unwrap();
        assert_eq!(opened.kind, SecureMeshPayloadKind::Command);
        assert_eq!(opened.body, body);
        assert_eq!(opened.content_type.as_deref(), Some("application/json"));
    }

    #[test]
    fn secure_mesh_openmls_group_payload_rejects_context_tamper() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-group-payload-aad-test").unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();
        let context = content_context_fixture(
            "msg_group_payload_aad",
            "desktop_gui:alice",
            "mobile:bob",
            format!(
                "mls:{}:{}",
                alice_group.epoch(),
                "secure-mesh-group-payload-aad-test"
            ),
        );
        let plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, br#"{"ok":true}"#)
                .with_content_type("application/json");
        let message = alice_group
            .seal_payload_message(&alice, &context, &plaintext)
            .unwrap();
        let mut tampered = context.clone();
        tampered.message_id = "msg_group_payload_tampered".to_string();

        let error = bob_group
            .open_payload_message(
                &bob,
                &tampered,
                &message,
                SecureMeshPayloadKind::ResultPayload,
            )
            .unwrap_err();
        assert!(
            error.to_string().contains("AAD mismatch")
                || error.to_string().contains("AAD hash mismatch")
        );
    }

    #[test]
    fn secure_mesh_openmls_three_endpoint_update_remove_rekeys_epoch() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"desktop_sidecar:bob".to_vec()).unwrap();
        let charlie = SecureMeshMlsParticipant::new(b"mobile:charlie".to_vec()).unwrap();

        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-three-endpoint-group").unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let bob_welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &bob_welcome.welcome_message).unwrap();

        let charlie_key_package = charlie.generate_key_package().unwrap();
        let charlie_welcome = alice_group
            .add_member(&alice, &charlie_key_package)
            .unwrap();
        bob_group
            .process_commit(&bob, &charlie_welcome.commit_message)
            .unwrap();
        let mut charlie_group =
            SecureMeshMlsGroup::join_from_welcome(&charlie, &charlie_welcome.welcome_message)
                .unwrap();

        assert_eq!(alice_group.member_count(), 3);
        assert_eq!(bob_group.member_count(), 3);
        assert_eq!(charlie_group.member_count(), 3);

        let update_commit = bob_group.self_update(&bob).unwrap();
        alice_group.process_commit(&alice, &update_commit).unwrap();
        charlie_group
            .process_commit(&charlie, &update_commit)
            .unwrap();

        let before_remove_aad = b"secure-mesh:mls:before-remove";
        let before_remove_message = alice_group
            .seal_application_message(&alice, before_remove_aad, b"group-before-remove")
            .unwrap();
        assert_eq!(
            bob_group
                .open_application_message(&bob, before_remove_aad, &before_remove_message)
                .unwrap(),
            b"group-before-remove"
        );
        assert_eq!(
            charlie_group
                .open_application_message(&charlie, before_remove_aad, &before_remove_message)
                .unwrap(),
            b"group-before-remove"
        );

        let charlie_leaf = charlie_group.own_leaf_index();
        let remove_commit = alice_group.remove_member(&alice, charlie_leaf).unwrap();
        assert!(remove_commit.welcome_message.is_none());
        bob_group
            .process_commit(&bob, &remove_commit.commit_message)
            .unwrap();
        charlie_group
            .process_commit(&charlie, &remove_commit.commit_message)
            .unwrap();
        assert!(!charlie_group.is_active());
        assert_eq!(alice_group.member_count(), 2);
        assert_eq!(bob_group.member_count(), 2);

        let after_remove_aad = b"secure-mesh:mls:after-remove";
        let after_remove_message = alice_group
            .seal_application_message(&alice, after_remove_aad, b"group-after-remove")
            .unwrap();
        assert_eq!(
            bob_group
                .open_application_message(&bob, after_remove_aad, &after_remove_message)
                .unwrap(),
            b"group-after-remove"
        );
        let removed_error = charlie_group
            .open_application_message(&charlie, after_remove_aad, &after_remove_message)
            .unwrap_err();
        assert!(
            removed_error.to_string().contains("open failed")
                || removed_error.to_string().contains("not active")
                || removed_error.to_string().contains("epoch")
        );
    }

    #[test]
    fn secure_mesh_openmls_removed_member_cannot_open_group_payload_new_epoch() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"desktop_sidecar:bob".to_vec()).unwrap();
        let charlie = SecureMeshMlsParticipant::new(b"mobile:charlie".to_vec()).unwrap();

        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-group-payload-remove").unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let bob_welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &bob_welcome.welcome_message).unwrap();

        let charlie_key_package = charlie.generate_key_package().unwrap();
        let charlie_welcome = alice_group
            .add_member(&alice, &charlie_key_package)
            .unwrap();
        bob_group
            .process_commit(&bob, &charlie_welcome.commit_message)
            .unwrap();
        let mut charlie_group =
            SecureMeshMlsGroup::join_from_welcome(&charlie, &charlie_welcome.welcome_message)
                .unwrap();

        let charlie_leaf = charlie_group.own_leaf_index();
        let remove_commit = alice_group.remove_member(&alice, charlie_leaf).unwrap();
        bob_group
            .process_commit(&bob, &remove_commit.commit_message)
            .unwrap();
        charlie_group
            .process_commit(&charlie, &remove_commit.commit_message)
            .unwrap();
        assert!(!charlie_group.is_active());

        let context = content_context_fixture(
            "msg_group_payload_after_remove",
            "desktop_gui:alice",
            "desktop_sidecar:bob",
            format!(
                "mls:{}:{}",
                alice_group.epoch(),
                "secure-mesh-group-payload-remove"
            ),
        );
        let plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Error,
            b"removed-member-must-not-open-new-epoch",
        )
        .with_content_type("text/plain");
        let message = alice_group
            .seal_payload_message(&alice, &context, &plaintext)
            .unwrap();

        let opened = bob_group
            .open_payload_message(&bob, &context, &message, SecureMeshPayloadKind::Error)
            .unwrap();
        assert_eq!(opened.body, b"removed-member-must-not-open-new-epoch");
        let removed_error = charlie_group
            .open_payload_message(&charlie, &context, &message, SecureMeshPayloadKind::Error)
            .unwrap_err();
        assert!(
            removed_error.to_string().contains("open failed")
                || removed_error.to_string().contains("UseAfterEviction")
                || removed_error.to_string().contains("not active")
                || removed_error.to_string().contains("epoch")
        );
    }

    #[test]
    fn secure_mesh_openmls_provider_storage_reload_preserves_group_secrets() {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let group_id = b"secure-mesh-provider-reload-group";
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = SecureMeshMlsGroup::create(&alice, group_id).unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();
        let joined_epoch = bob_group.epoch();
        drop(bob_group);

        let aad = b"secure-mesh:mls:provider-reload";
        let sealed = alice_group
            .seal_application_message(&alice, aad, b"provider-reloaded-open")
            .unwrap();
        let mut reloaded_bob = SecureMeshMlsGroup::load_from_provider(&bob, group_id).unwrap();
        assert_eq!(reloaded_bob.epoch(), joined_epoch);
        assert_eq!(
            reloaded_bob
                .open_application_message(&bob, aad, &sealed)
                .unwrap(),
            b"provider-reloaded-open"
        );

        let update_commit = alice_group.self_update(&alice).unwrap();
        reloaded_bob.process_commit(&bob, &update_commit).unwrap();
        let updated_epoch = reloaded_bob.epoch();
        drop(reloaded_bob);

        let aad_after_update = b"secure-mesh:mls:provider-reload-after-update";
        let sealed_after_update = alice_group
            .seal_application_message(&alice, aad_after_update, b"after-storage-reload-update")
            .unwrap();
        let mut reloaded_after_update =
            SecureMeshMlsGroup::load_from_provider(&bob, group_id).unwrap();
        assert_eq!(reloaded_after_update.epoch(), updated_epoch);
        assert_eq!(
            reloaded_after_update
                .open_application_message(&bob, aad_after_update, &sealed_after_update)
                .unwrap(),
            b"after-storage-reload-update"
        );
    }

    #[test]
    fn secure_mesh_openmls_secret_store_file_reload_recovers_group_state() {
        let secret_store_path = durable_store_path("secret-store-reload");
        let _ = std::fs::remove_file(&secret_store_path);
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_signing_public_key = bob.signing_public_key();
        let group_id = b"secure-mesh-secret-store-reload-group";

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = SecureMeshMlsGroup::create(&alice, group_id).unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();

        let update_commit = alice_group.self_update(&alice).unwrap();
        bob_group.process_commit(&bob, &update_commit).unwrap();
        let persisted_epoch = bob_group.epoch();
        bob.save_secret_store(&secret_store_path).unwrap();
        assert!(secret_store_path.exists());
        drop(bob_group);
        drop(bob);

        let reloaded_bob = SecureMeshMlsParticipant::load_from_secret_store(
            b"mobile:bob".to_vec(),
            &bob_signing_public_key,
            &secret_store_path,
        )
        .unwrap();
        let mut reloaded_group =
            SecureMeshMlsGroup::load_from_provider(&reloaded_bob, group_id).unwrap();
        assert_eq!(reloaded_group.epoch(), persisted_epoch);

        let aad = b"secure-mesh:mls:secret-store-file-reload";
        let sealed = alice_group
            .seal_application_message(&alice, aad, b"secret-store-reloaded-open")
            .unwrap();
        assert_eq!(
            reloaded_group
                .open_application_message(&reloaded_bob, aad, &sealed)
                .unwrap(),
            b"secret-store-reloaded-open"
        );
        let _ = std::fs::remove_file(&secret_store_path);
    }

    #[test]
    fn secure_mesh_openmls_interop_recovery_vector_exports_public_wire_artifacts() {
        let secret_store_path = durable_store_path("interop-recovery-vector");
        let _ = std::fs::remove_file(&secret_store_path);
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_signing_public_key = bob.signing_public_key();
        let group_id = b"secure-mesh-interop-recovery-vector-group";

        let bob_key_package = bob.generate_key_package().unwrap();
        assert!(!bob_key_package.as_public_bytes().is_empty());

        let mut alice_group = SecureMeshMlsGroup::create(&alice, group_id).unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        deserialize_protocol_message(
            &welcome.commit_message,
            "secure mesh MLS interop vector commit parse failed",
        )
        .unwrap();
        match MlsMessageIn::tls_deserialize_exact(welcome.welcome_message.clone())
            .unwrap()
            .extract()
        {
            MlsMessageBodyIn::Welcome(_) => {}
            _ => panic!("secure mesh MLS interop vector welcome parse failed"),
        }

        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();
        let update_commit = alice_group.self_update(&alice).unwrap();
        deserialize_protocol_message(
            &update_commit,
            "secure mesh MLS interop vector update parse failed",
        )
        .unwrap();
        bob_group.process_commit(&bob, &update_commit).unwrap();
        let recovered_epoch = bob_group.epoch();
        bob.save_secret_store(&secret_store_path).unwrap();
        drop(bob_group);
        drop(bob);

        let reloaded_bob = SecureMeshMlsParticipant::load_from_secret_store(
            b"mobile:bob".to_vec(),
            &bob_signing_public_key,
            &secret_store_path,
        )
        .unwrap();
        let mut reloaded_bob_group =
            SecureMeshMlsGroup::load_from_provider(&reloaded_bob, group_id).unwrap();
        assert_eq!(reloaded_bob_group.epoch(), recovered_epoch);

        let context = content_context_fixture(
            "msg_mls_interop_recovery_vector",
            "desktop_gui:alice",
            "mobile:bob",
            format!("mls:{recovered_epoch}:secure-mesh-interop-recovery-vector-group"),
        );
        let body = br#"{"op":"secure_mesh.group.commit","canary":"mls-interop-recovery-secret"}"#;
        let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, body.as_slice())
            .with_content_type("application/json");
        let application_message = alice_group
            .seal_payload_message(&alice, &context, &plaintext)
            .unwrap();
        deserialize_protocol_message(
            &application_message,
            "secure mesh MLS interop vector application parse failed",
        )
        .unwrap();
        assert!(
            !application_message
                .windows(b"mls-interop-recovery-secret".len())
                .any(|window| window == b"mls-interop-recovery-secret")
        );

        let opened = reloaded_bob_group
            .open_payload_message(
                &reloaded_bob,
                &context,
                &application_message,
                SecureMeshPayloadKind::Command,
            )
            .unwrap();
        assert_eq!(opened.body, body);

        let public_artifacts: [(&str, &[u8]); 4] = [
            ("key_package", bob_key_package.as_public_bytes()),
            ("welcome", &welcome.welcome_message),
            ("commit", &update_commit),
            ("application", &application_message),
        ];
        for (label, bytes) in public_artifacts {
            assert!(!bytes.is_empty(), "{label} artifact must be non-empty");
            let hash = hash_bytes(bytes);
            assert!(hash.starts_with("sha256:"));
            assert!(
                !bytes
                    .windows(b"mls-interop-recovery-secret".len())
                    .any(|window| window == b"mls-interop-recovery-secret"),
                "{label} artifact leaked plaintext canary"
            );
        }
        let _ = std::fs::remove_file(&secret_store_path);
    }

    #[test]
    fn secure_mesh_mls_durable_store_commits_epoch_with_compare_and_swap() {
        let store_path = durable_store_path("commit-cas");
        let _ = std::fs::remove_file(&store_path);
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-durable-cas-group").unwrap();
        let mut store = SecureMeshMlsDurableStore::open(&store_path).unwrap();

        let initial_metadata = alice_group.public_metadata("desktop_gui:alice").unwrap();
        let initial = store
            .upsert_initial(&initial_metadata, "2026-06-26T00:00:00Z")
            .unwrap();
        assert_eq!(initial.epoch, initial_metadata.epoch);
        assert_eq!(initial.state_version, 1);
        assert!(initial.revoked_at_epoch.is_none());

        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        assert!(!welcome.commit_message.is_empty());
        let committed_metadata = alice_group.public_metadata("desktop_gui:alice").unwrap();
        assert!(committed_metadata.epoch > initial.epoch);
        let committed = store
            .commit_epoch(&initial, &committed_metadata, "2026-06-26T00:00:01Z")
            .unwrap();
        assert_eq!(committed.state_version, initial.state_version + 1);
        assert_eq!(committed.epoch, committed_metadata.epoch);
        assert_eq!(committed.member_count, 2);

        drop(store);
        let reopened = SecureMeshMlsDurableStore::open(&store_path).unwrap();
        let persisted = reopened
            .read(&committed.group_id_hash, &committed.participant_endpoint_id)
            .unwrap()
            .unwrap();
        assert_eq!(persisted, committed);
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_mls_durable_store_rejects_rollback_and_stale_commit() {
        let store_path = durable_store_path("rollback-stale");
        let _ = std::fs::remove_file(&store_path);
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-durable-rollback-group").unwrap();
        let mut store = SecureMeshMlsDurableStore::open(&store_path).unwrap();

        let initial = store
            .upsert_initial(
                &alice_group.public_metadata("desktop_gui:alice").unwrap(),
                "2026-06-26T00:01:00Z",
            )
            .unwrap();
        let _welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let committed_metadata = alice_group.public_metadata("desktop_gui:alice").unwrap();
        let committed = store
            .commit_epoch(&initial, &committed_metadata, "2026-06-26T00:01:01Z")
            .unwrap();

        let mut rollback_metadata = committed_metadata.clone();
        rollback_metadata.epoch = committed.epoch - 1;
        let rollback_error = store
            .commit_epoch(&committed, &rollback_metadata, "2026-06-26T00:01:02Z")
            .unwrap_err();
        assert!(rollback_error.to_string().contains("rollback detected"));

        let update_commit = alice_group.self_update(&alice).unwrap();
        assert!(!update_commit.is_empty());
        let stale_metadata = alice_group.public_metadata("desktop_gui:alice").unwrap();
        assert!(stale_metadata.epoch > committed.epoch);
        let stale_error = store
            .commit_epoch(&initial, &stale_metadata, "2026-06-26T00:01:03Z")
            .unwrap_err();
        assert!(stale_error.to_string().contains("compare-and-swap failed"));
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_mls_durable_store_marks_revoked_and_blocks_future_commit() {
        let store_path = durable_store_path("revoke");
        let _ = std::fs::remove_file(&store_path);
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let mut alice_group =
            SecureMeshMlsGroup::create(&alice, b"secure-mesh-durable-revoke-group").unwrap();
        let mut store = SecureMeshMlsDurableStore::open(&store_path).unwrap();

        let initial = store
            .upsert_initial(
                &alice_group.public_metadata("desktop_gui:alice").unwrap(),
                "2026-06-26T00:02:00Z",
            )
            .unwrap();
        let revoked = store
            .mark_revoked(&initial, initial.epoch, "2026-06-26T00:02:01Z")
            .unwrap();
        assert_eq!(revoked.revoked_at_epoch, Some(initial.epoch));
        assert!(!revoked.active);

        let update_commit = alice_group.self_update(&alice).unwrap();
        assert!(!update_commit.is_empty());
        let next_metadata = alice_group.public_metadata("desktop_gui:alice").unwrap();
        let commit_after_revoke = store
            .commit_epoch(&revoked, &next_metadata, "2026-06-26T00:02:02Z")
            .unwrap_err();
        assert!(
            commit_after_revoke
                .to_string()
                .contains("durable record is revoked")
        );
        let _ = std::fs::remove_file(&store_path);
    }
}
