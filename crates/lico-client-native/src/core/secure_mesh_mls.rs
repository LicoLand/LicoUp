use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
#[cfg(test)]
use openmls::prelude::LeafNodeParameters;
use openmls::prelude::{
    BasicCredential, Ciphersuite, Credential, CredentialWithKey, Extensions, GroupId, KeyPackage,
    KeyPackageBundle, KeyPackageIn, LeafNodeIndex, MlsGroup, MlsGroupCreateConfig,
    MlsGroupJoinConfig, MlsMessageBodyIn, MlsMessageBodyOut, MlsMessageIn, ProcessedMessage,
    ProcessedMessageContent, ProtocolMessage, ProtocolVersion, Sender, StagedWelcome,
    tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize},
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::{MemoryStorage, RustCrypto};
use openmls_traits::OpenMlsProvider;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{OnceLock, RwLock};
use zeroize::{Zeroize, Zeroizing};

use crate::core::secure_mesh_capability::SecurityCapability;
use crate::core::secure_mesh_capability_proof::SignedCapabilityProof;
use crate::core::secure_mesh_crypto::{
    ContentKey, OpenedSecureMeshPayload, SealedSecureMeshPrivateContextPayload,
    SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
    open_private_context_payload, seal_private_context_payload,
};
use crate::core::secure_mesh_mls_pq_epoch::{
    MLS_ML_KEM_1024_EPOCH_EXTENSION_TYPE_ID, SecureMeshMlsMlKem1024EpochExtension,
    create_mlkem1024_epoch_extension, mix_mlkem1024_payload_key, mlkem1024_epoch_extension_digest,
    mlkem1024_member_id, open_mlkem1024_epoch_extension,
};
use crate::core::secure_mesh_pqxdh::{
    ML_KEM_1024_KEY_GENERATION_SEED_BYTES, SecureMeshMlKem1024PreKeySeed,
    validate_ml_kem_1024_public_key,
};
use crate::core::secure_mesh_session_negotiation::NegotiatedCapabilityBinding;
use crate::platform::file_security::harden_private_path;
use crate::platform::secure_mesh_secret_store::{
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession, SecretStoreHandle,
    SecureMeshSecretStore,
};

pub const SECURE_MESH_MLS_CIPHER_SUITE: &str =
    "MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519+ML_KEM_1024_EPOCH_PAYLOAD_HYBRID";
pub const SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION: &str =
    "licolite.secure-mesh.group-mls.mlkem1024-epoch-payload-hybrid.v1";
pub const SECURE_MESH_MLS_STATUS: &str = "openmls_classical_control_plane_mlkem1024_epoch_hybrid_payload_selected_custody_durable_group_state_identity_bound_capability_negotiated";

static MLS_RUNTIME_CRYPTO_SELF_TEST: OnceLock<bool> = OnceLock::new();

/// Exercises a complete in-memory OpenMLS create/add/join/application-message
/// round trip. The cached result is side-effect free with respect to client
/// storage and avoids repeating an expensive provider initialization.
pub fn runtime_crypto_self_test() -> bool {
    *MLS_RUNTIME_CRYPTO_SELF_TEST.get_or_init(|| {
        catch_unwind(AssertUnwindSafe(|| -> Result<()> {
            let alice = SecureMeshMlsParticipant::new(b"runtime-self-test:alice".to_vec())?;
            let bob = SecureMeshMlsParticipant::new(b"runtime-self-test:bob".to_vec())?;
            let bob_key_package = bob.generate_key_package()?;
            ensure!(
                !bob_key_package.as_public_bytes().is_empty(),
                "MLS runtime key package is empty"
            );
            let mut alice_group = SecureMeshMlsGroup::create(&alice, b"runtime-self-test:group")?;
            let welcome =
                alice_group.add_member_for_runtime_crypto_self_test(&alice, &bob_key_package)?;
            ensure!(
                !welcome.commit_message.is_empty() && !welcome.welcome_message.is_empty(),
                "MLS runtime welcome is incomplete"
            );
            let mut bob_group = SecureMeshMlsGroup::join_from_welcome_for_runtime_crypto_self_test(
                &bob,
                &welcome.welcome_message,
            )?;
            let aad = b"licolite-mls-runtime-self-test-aad";
            let plaintext = b"licolite-mls-runtime-self-test-body";
            let sealed = alice_group.seal_application_message(&alice, aad, plaintext)?;
            ensure!(
                !sealed
                    .windows(plaintext.len())
                    .any(|window| window == plaintext),
                "MLS runtime ciphertext exposed plaintext"
            );
            let opened = bob_group
                .open_application_message_for_runtime_crypto_self_test(&bob, aad, &sealed)?;
            ensure!(opened == plaintext, "MLS runtime plaintext mismatch");
            Ok(())
        }))
        .is_ok_and(|result| result.is_ok())
    })
}

const MLS_PAYLOAD_EXPORT_LABEL: &str = "licolite.secure-mesh.mls.payload-content-key.v2";
const MLS_PAYLOAD_EXPORT_CONTEXT_MAGIC: &[u8] = b"LCOSM-MLS-PAYLOAD-EXPORT-v2";
pub(crate) const SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD: &[u8] =
    b"licolite.secure-mesh.mls.application.public-domain-profile.v2";
const MLS_PRIVATE_CONTEXT_PAYLOAD_MAGIC: &[u8] = b"LCOSM-MLS-PRIVATE-CONTEXT-PAYLOAD-v2";
const MLS_PAYLOAD_CONTENT_KEY_LEN: usize = 32;
const MLS_PROVIDER_SECRET_SCHEMA_VERSION: u32 = 2;
const MLS_KEY_PACKAGE_MAGIC: &[u8] = b"LCOSM-MLS-KEYPACKAGE-MLKEM1024-v1";
const MLS_EPOCH_SECRET_STORE_CLASS: &str = "mlsEpochSecret";
const MLS_RECOVERY_SECRET_STORE_CLASS: &str = "recoverySecret";
const MLS_PUBLIC_STATE_DIGEST_AUTHENTICATED_BACKFILL: &str =
    "pending:selected-custody-authenticated-backfill";
pub(crate) const MLS_CAPABILITY_EXTENSION_TYPE_ID: u16 = 0xff10;
pub(crate) const MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION: u32 = 2;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct SecureMeshMlsMemberCapabilityProof {
    pub endpoint_id: String,
    pub accepted_at_unix_seconds: i64,
    pub proof: SignedCapabilityProof,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    deny_unknown_fields,
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub(crate) enum SecureMeshMlsRosterTransition {
    MemberAdded {
        member_endpoint_id: String,
        pair_binding: NegotiatedCapabilityBinding,
    },
    MemberRemoved {
        member_endpoint_id: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    deny_unknown_fields,
    tag = "state",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub(crate) enum SecureMeshMlsCapabilityExtension {
    AwaitingMemberNegotiation {
        schema_version: u32,
    },
    Active {
        schema_version: u32,
        activated_at_epoch: u64,
        previous_extension_digest: Option<String>,
        committer_endpoint_id: String,
        roster_transition: SecureMeshMlsRosterTransition,
        member_capability_proofs: BTreeMap<String, SecureMeshMlsMemberCapabilityProof>,
        group_negotiated_protocol_capabilities: BTreeSet<SecurityCapability>,
    },
}

impl SecureMeshMlsCapabilityExtension {
    fn awaiting_member_negotiation() -> Self {
        Self::AwaitingMemberNegotiation {
            schema_version: MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION,
        }
    }

    pub(crate) fn require_active(&self) -> Result<()> {
        match self {
            Self::Active { schema_version, .. }
                if *schema_version == MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION =>
            {
                Ok(())
            }
            Self::Active { .. } => Err(anyhow!(
                "secure mesh MLS capability extension schema is unsupported"
            )),
            Self::AwaitingMemberNegotiation { .. } => Err(anyhow!(
                "secure mesh MLS member capability negotiation is incomplete"
            )),
        }
    }

    pub(crate) fn group_negotiated_protocol_capabilities(
        &self,
    ) -> Option<&BTreeSet<SecurityCapability>> {
        match self {
            Self::Active {
                group_negotiated_protocol_capabilities,
                ..
            } => Some(group_negotiated_protocol_capabilities),
            Self::AwaitingMemberNegotiation { .. } => None,
        }
    }
}

fn secure_mesh_mls_leaf_capabilities() -> openmls::prelude::Capabilities {
    openmls::prelude::Capabilities::new(
        None,
        None,
        Some(&[
            openmls::prelude::ExtensionType::Unknown(MLS_CAPABILITY_EXTENSION_TYPE_ID),
            openmls::prelude::ExtensionType::Unknown(MLS_ML_KEM_1024_EPOCH_EXTENSION_TYPE_ID),
        ]),
        None,
        Some(&[openmls::prelude::CredentialType::Basic]),
    )
}

fn secure_mesh_mls_group_context_extensions(
    capability_extension: &SecureMeshMlsCapabilityExtension,
) -> Result<Extensions<openmls::prelude::GroupContext>> {
    secure_mesh_mls_group_context_extensions_with_pq(capability_extension, None)
}

fn secure_mesh_mls_group_context_extensions_with_pq(
    capability_extension: &SecureMeshMlsCapabilityExtension,
    pq_epoch_extension: Option<&SecureMeshMlsMlKem1024EpochExtension>,
) -> Result<Extensions<openmls::prelude::GroupContext>> {
    let encoded = serde_json::to_vec(capability_extension)
        .context("secure mesh MLS capability extension serialization failed")?;
    let mut extensions = vec![
        openmls::prelude::Extension::RequiredCapabilities(
            openmls::prelude::RequiredCapabilitiesExtension::new(
                &[
                    openmls::prelude::ExtensionType::Unknown(MLS_CAPABILITY_EXTENSION_TYPE_ID),
                    openmls::prelude::ExtensionType::Unknown(
                        MLS_ML_KEM_1024_EPOCH_EXTENSION_TYPE_ID,
                    ),
                ],
                &[],
                &[openmls::prelude::CredentialType::Basic],
            ),
        ),
        openmls::prelude::Extension::Unknown(
            MLS_CAPABILITY_EXTENSION_TYPE_ID,
            openmls::prelude::UnknownExtension(encoded),
        ),
    ];
    if let Some(pq_epoch_extension) = pq_epoch_extension {
        extensions.push(openmls::prelude::Extension::Unknown(
            MLS_ML_KEM_1024_EPOCH_EXTENSION_TYPE_ID,
            openmls::prelude::UnknownExtension(
                serde_json::to_vec(pq_epoch_extension)
                    .context("secure mesh MLS ML-KEM-1024 epoch extension serialization failed")?,
            ),
        ));
    }
    Extensions::try_from(extensions)
        .map_err(|error| anyhow!("secure mesh MLS capability extensions are invalid: {error:?}"))
}

fn decode_secure_mesh_mls_pq_epoch_extension(
    extensions: &Extensions<openmls::prelude::GroupContext>,
) -> Result<SecureMeshMlsMlKem1024EpochExtension> {
    let encoded = extensions
        .unknown(MLS_ML_KEM_1024_EPOCH_EXTENSION_TYPE_ID)
        .ok_or_else(|| anyhow!("secure mesh MLS ML-KEM-1024 epoch extension is missing"))?;
    serde_json::from_slice(&encoded.0)
        .map_err(|_| anyhow!("secure mesh MLS ML-KEM-1024 epoch extension is invalid"))
}

fn decode_secure_mesh_mls_capability_extension(
    extensions: &Extensions<openmls::prelude::GroupContext>,
) -> Result<SecureMeshMlsCapabilityExtension> {
    let encoded = extensions
        .unknown(MLS_CAPABILITY_EXTENSION_TYPE_ID)
        .ok_or_else(|| anyhow!("secure mesh MLS capability extension is missing"))?;
    let extension: SecureMeshMlsCapabilityExtension = serde_json::from_slice(&encoded.0)
        .map_err(|_| anyhow!("secure mesh MLS capability extension is invalid"))?;
    match &extension {
        SecureMeshMlsCapabilityExtension::AwaitingMemberNegotiation { schema_version }
        | SecureMeshMlsCapabilityExtension::Active { schema_version, .. } => ensure!(
            *schema_version == MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION,
            "secure mesh MLS capability extension schema is unsupported"
        ),
    }
    Ok(extension)
}

pub(crate) fn secure_mesh_mls_capability_extension_digest(
    extension: &SecureMeshMlsCapabilityExtension,
) -> Result<String> {
    let encoded = serde_json::to_vec(extension)
        .context("secure mesh MLS capability extension digest encoding failed")?;
    let digest: [u8; 32] = Sha256::digest(encoded).into();
    Ok(crate::core::secure_mesh_capability_proof::encode_sha256_digest(&digest))
}

pub struct SecureMeshOpenMlsProvider {
    crypto: RustCrypto,
    storage: MemoryStorage,
    mlkem1024_seed: SecureMeshMlKem1024PreKeySeed,
}

impl SecureMeshOpenMlsProvider {
    pub fn load_secret_store(
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
    ) -> Result<Self> {
        let session = secret_store.begin_authorized_session(
            &SecretStoreAuthorizationRequest::new("Secure Mesh MLS provider secret-store load", 1),
        )?;
        Self::load_secret_store_with_session(secret_store, handle, &session)
    }

    fn load_secret_store_with_session(
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
        session: &SecretStoreAuthorizationSession,
    ) -> Result<Self> {
        let persisted_json = secret_store
            .get_secret_with_session(session, handle)
            .context("secure mesh MLS provider secret-store read failed")?
            .ok_or_else(|| anyhow!("secure mesh MLS provider secret-store entry is missing"))?;
        let persisted: PersistedMlsProviderSecrets = serde_json::from_str(&persisted_json)
            .context("secure mesh MLS provider secret-store payload deserialization failed")?;
        ensure!(
            persisted.schema_version == MLS_PROVIDER_SECRET_SCHEMA_VERSION,
            "secure mesh MLS provider secret-store schema is unsupported"
        );
        ensure!(
            persisted.secret_class == MLS_EPOCH_SECRET_STORE_CLASS
                || persisted.secret_class == MLS_RECOVERY_SECRET_STORE_CLASS,
            "secure mesh MLS provider secret-store class is unsupported"
        );
        let storage_bytes = general_purpose::URL_SAFE_NO_PAD
            .decode(&persisted.storage_base64url)
            .context("secure mesh MLS provider secret-store payload is not base64url")?;
        let storage = deserialize_storage_from_bytes(&storage_bytes)?;
        let mut seed_bytes = general_purpose::URL_SAFE_NO_PAD
            .decode(&persisted.mlkem1024_seed_base64url)
            .context("secure mesh MLS ML-KEM-1024 custody seed is not base64url")?;
        ensure!(
            seed_bytes.len() == ML_KEM_1024_KEY_GENERATION_SEED_BYTES,
            "secure mesh MLS ML-KEM-1024 custody seed length is invalid"
        );
        let mut fixed_seed = [0u8; ML_KEM_1024_KEY_GENERATION_SEED_BYTES];
        fixed_seed.copy_from_slice(&seed_bytes);
        seed_bytes.zeroize();
        Ok(Self {
            crypto: RustCrypto::default(),
            storage,
            mlkem1024_seed: SecureMeshMlKem1024PreKeySeed::from_bytes(fixed_seed),
        })
    }

    pub fn save_secret_store(
        &self,
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
    ) -> Result<()> {
        self.save_secret_store_for_class(secret_store, handle, MLS_EPOCH_SECRET_STORE_CLASS)
    }

    fn save_secret_store_for_class(
        &self,
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
        secret_class: &str,
    ) -> Result<()> {
        let session = secret_store.begin_authorized_session(
            &SecretStoreAuthorizationRequest::new("Secure Mesh MLS provider secret-store save", 1),
        )?;
        self.save_secret_store_for_class_with_session(secret_store, handle, secret_class, &session)
    }

    fn save_secret_store_for_class_with_session(
        &self,
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
        secret_class: &str,
        session: &SecretStoreAuthorizationSession,
    ) -> Result<()> {
        ensure!(
            secret_class == MLS_EPOCH_SECRET_STORE_CLASS
                || secret_class == MLS_RECOVERY_SECRET_STORE_CLASS,
            "secure mesh MLS provider secret-store class is unsupported"
        );
        let storage_bytes = self.serialize_storage_to_bytes()?;
        let persisted = PersistedMlsProviderSecrets {
            schema_version: MLS_PROVIDER_SECRET_SCHEMA_VERSION,
            secret_class: secret_class.to_string(),
            storage_base64url: general_purpose::URL_SAFE_NO_PAD.encode(storage_bytes),
            mlkem1024_seed_base64url: general_purpose::URL_SAFE_NO_PAD
                .encode(self.mlkem1024_seed.expose_for_secret_store()),
        };
        let persisted_json = serde_json::to_string(&persisted)
            .context("secure mesh MLS provider secret-store payload serialization failed")?;
        secret_store
            .set_secret_with_session(session, handle, &persisted_json)
            .context("secure mesh MLS provider secret-store write failed")?;
        Ok(())
    }

    pub fn delete_secret_store(
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
    ) -> Result<()> {
        let session =
            secret_store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                "Secure Mesh MLS provider secret-store delete",
                1,
            ))?;
        Self::delete_secret_store_with_session(secret_store, handle, &session)
    }

    fn delete_secret_store_with_session(
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
        session: &SecretStoreAuthorizationSession,
    ) -> Result<()> {
        secret_store
            .delete_secret_with_session(session, handle)
            .context("secure mesh MLS provider secret-store delete failed")?;
        Ok(())
    }

    fn serialize_storage_to_bytes(&self) -> Result<Vec<u8>> {
        let values = self
            .storage
            .values
            .read()
            .map_err(|_| anyhow!("secure mesh MLS memory storage lock is poisoned"))?;
        let mut serializable = SerializableMlsMemoryStorage::default();
        for (key, value) in values.iter() {
            serializable.values.insert(
                general_purpose::URL_SAFE_NO_PAD.encode(key),
                general_purpose::URL_SAFE_NO_PAD.encode(value),
            );
        }
        serde_json::to_vec(&serializable)
            .context("secure mesh MLS provider memory storage serialization failed")
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct PersistedMlsProviderSecrets {
    schema_version: u32,
    secret_class: String,
    storage_base64url: String,
    mlkem1024_seed_base64url: String,
}

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct SerializableMlsMemoryStorage {
    values: HashMap<String, String>,
}

fn deserialize_storage_from_bytes(bytes: &[u8]) -> Result<MemoryStorage> {
    let serializable: SerializableMlsMemoryStorage = serde_json::from_slice(bytes)
        .context("secure mesh MLS provider memory storage deserialization failed")?;
    let mut values = HashMap::new();
    for (key, value) in serializable.values {
        values.insert(
            general_purpose::URL_SAFE_NO_PAD
                .decode(key)
                .context("secure mesh MLS provider memory storage key is not base64url")?,
            general_purpose::URL_SAFE_NO_PAD
                .decode(value)
                .context("secure mesh MLS provider memory storage value is not base64url")?,
        );
    }
    Ok(MemoryStorage {
        values: RwLock::new(values),
    })
}

impl Default for SecureMeshOpenMlsProvider {
    fn default() -> Self {
        Self {
            crypto: RustCrypto::default(),
            storage: MemoryStorage::default(),
            mlkem1024_seed: SecureMeshMlKem1024PreKeySeed::generate(),
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
        Self::from_provider_credential_parts(provider, identity.into(), signer)
    }

    pub fn from_credential_parts(
        credential_identity: impl Into<Vec<u8>>,
        signer: SignatureKeyPair,
    ) -> Result<Self> {
        let provider = SecureMeshOpenMlsProvider::default();
        Self::from_provider_credential_parts(provider, credential_identity.into(), signer)
    }

    fn from_provider_credential_parts(
        provider: SecureMeshOpenMlsProvider,
        credential_identity: Vec<u8>,
        signer: SignatureKeyPair,
    ) -> Result<Self> {
        signer
            .store(provider.storage())
            .map_err(|_| anyhow!("secure mesh MLS signer storage failed"))?;
        let credential = BasicCredential::new(credential_identity);
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

    pub fn credential_identity_bytes(&self) -> Result<Vec<u8>> {
        let basic = BasicCredential::try_from(self.credential_with_key.credential.clone())
            .map_err(|error| anyhow!("secure mesh MLS credential is not basic: {error:?}"))?;
        Ok(basic.identity().to_vec())
    }

    pub fn load_from_secret_store(
        identity: impl Into<Vec<u8>>,
        signing_public_key: impl AsRef<[u8]>,
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
    ) -> Result<Self> {
        Self::load_from_secret_store_with_optional_session(
            identity,
            signing_public_key,
            secret_store,
            handle,
            None,
        )
    }

    pub(crate) fn load_from_secret_store_with_optional_session(
        identity: impl Into<Vec<u8>>,
        signing_public_key: impl AsRef<[u8]>,
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
        session: Option<&SecretStoreAuthorizationSession>,
    ) -> Result<Self> {
        let provider = match session {
            Some(session) => SecureMeshOpenMlsProvider::load_secret_store_with_session(
                secret_store,
                handle,
                session,
            )?,
            None => SecureMeshOpenMlsProvider::load_secret_store(secret_store, handle)?,
        };
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

    pub fn save_secret_store(
        &self,
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
    ) -> Result<()> {
        self.provider.save_secret_store(secret_store, handle)
    }

    pub(crate) fn save_secret_store_with_session(
        &self,
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
        session: &SecretStoreAuthorizationSession,
    ) -> Result<()> {
        self.provider.save_secret_store_for_class_with_session(
            secret_store,
            handle,
            MLS_EPOCH_SECRET_STORE_CLASS,
            session,
        )
    }

    pub(crate) fn secret_store_snapshot_exists_with_session(
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
        session: &SecretStoreAuthorizationSession,
    ) -> Result<bool> {
        let mut snapshot = secret_store.get_secret_with_session(session, handle)?;
        let exists = snapshot.is_some();
        if let Some(secret) = snapshot.as_mut() {
            secret.zeroize();
        }
        Ok(exists)
    }

    #[cfg(test)]
    fn save_recovery_secret_store_with_session(
        &self,
        secret_store: &dyn SecureMeshSecretStore,
        handle: &SecretStoreHandle,
        session: &SecretStoreAuthorizationSession,
    ) -> Result<()> {
        self.provider.save_secret_store_for_class_with_session(
            secret_store,
            handle,
            MLS_RECOVERY_SECRET_STORE_CLASS,
            session,
        )
    }

    pub fn generate_key_package(&self) -> Result<SecureMeshMlsKeyPackage> {
        let bundle = KeyPackage::builder()
            .key_package_extensions(Extensions::default())
            .leaf_node_capabilities(secure_mesh_mls_leaf_capabilities())
            .build(
                secure_mesh_mls_ciphersuite(),
                &self.provider,
                &self.signer,
                self.credential_with_key.clone(),
            )
            .map_err(|error| anyhow!("secure mesh MLS key package generation failed: {error:?}"))?;
        SecureMeshMlsKeyPackage::from_bundle(bundle, self.provider.mlkem1024_seed.public_key())
    }
}

pub struct SecureMeshMlsKeyPackage {
    public_key_package: KeyPackage,
    public_bytes: Vec<u8>,
    mlkem1024_public_key: Vec<u8>,
}

impl SecureMeshMlsKeyPackage {
    pub fn as_public_bytes(&self) -> &[u8] {
        &self.public_bytes
    }

    pub fn credential_identity_bytes(&self) -> Result<Vec<u8>> {
        let basic =
            BasicCredential::try_from(self.public_key_package.leaf_node().credential().clone())
                .map_err(|error| {
                    anyhow!("secure mesh MLS keypackage credential is not basic: {error:?}")
                })?;
        Ok(basic.identity().to_vec())
    }

    pub fn signing_public_key(&self) -> Vec<u8> {
        self.public_key_package
            .leaf_node()
            .signature_key()
            .as_slice()
            .to_vec()
    }

    pub fn mlkem1024_public_key(&self) -> &[u8] {
        &self.mlkem1024_public_key
    }

    pub(crate) fn from_public_bytes(public_bytes: &[u8]) -> Result<Self> {
        ensure!(
            !public_bytes.is_empty(),
            "secure mesh MLS key package is empty"
        );
        let (mlkem1024_public_key, inner_public_bytes) =
            decode_mlkem1024_key_package(public_bytes)?;
        let key_package_in = KeyPackageIn::tls_deserialize_exact(inner_public_bytes)
            .context("secure mesh MLS key package deserialization failed")?;
        let public_key_package = key_package_in
            .validate(&RustCrypto::default(), ProtocolVersion::Mls10)
            .map_err(|error| {
                anyhow!("secure mesh MLS key package verification failed: {error:?}")
            })?;
        ensure!(
            public_key_package.ciphersuite() == secure_mesh_mls_ciphersuite(),
            "secure mesh MLS key package ciphersuite is unsupported"
        );
        Ok(Self {
            public_key_package,
            public_bytes: public_bytes.to_vec(),
            mlkem1024_public_key,
        })
    }

    fn from_bundle(bundle: KeyPackageBundle, mlkem1024_public_key: Vec<u8>) -> Result<Self> {
        validate_ml_kem_1024_public_key(&mlkem1024_public_key)?;
        let inner_public_bytes = bundle
            .key_package()
            .tls_serialize_detached()
            .context("secure mesh MLS key package serialization failed")?;
        let public_bytes =
            encode_mlkem1024_key_package(&mlkem1024_public_key, &inner_public_bytes)?;
        Ok(Self {
            public_key_package: bundle.key_package().clone(),
            public_bytes,
            mlkem1024_public_key,
        })
    }
}

fn encode_mlkem1024_key_package(public_key: &[u8], inner: &[u8]) -> Result<Vec<u8>> {
    validate_ml_kem_1024_public_key(public_key)?;
    let mut out =
        Vec::with_capacity(MLS_KEY_PACKAGE_MAGIC.len() + 8 + public_key.len() + inner.len());
    out.extend_from_slice(MLS_KEY_PACKAGE_MAGIC);
    append_mls_len_prefixed_bytes(&mut out, public_key)?;
    append_mls_len_prefixed_bytes(&mut out, inner)?;
    Ok(out)
}

fn decode_mlkem1024_key_package(bytes: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut reader = MlsPayloadReader::new(bytes);
    reader.expect_bytes(MLS_KEY_PACKAGE_MAGIC).map_err(|_| {
        anyhow!("secure mesh MLS key package requires ML-KEM-1024 protocol migration")
    })?;
    let public_key = reader.read_len_prefixed_bytes()?.to_vec();
    validate_ml_kem_1024_public_key(&public_key)?;
    let inner = reader.read_len_prefixed_bytes()?.to_vec();
    ensure!(
        !inner.is_empty() && reader.is_empty(),
        "secure mesh MLS key package wrapper is invalid"
    );
    Ok((public_key, inner))
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
    authenticated_group_context: Vec<u8>,
    mlkem1024_epoch_extension: Option<SecureMeshMlsMlKem1024EpochExtension>,
    mlkem1024_epoch_secret: Option<Zeroizing<[u8; 32]>>,
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
        Self::from_authenticated_group(owner, group)
    }

    pub(crate) fn load(
        participant: &SecureMeshMlsParticipant,
        group_id: impl AsRef<[u8]>,
    ) -> Result<Self> {
        Self::load_optional(participant, group_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS group is not available in selected custody"))
    }

    pub(crate) fn load_optional(
        participant: &SecureMeshMlsParticipant,
        group_id: impl AsRef<[u8]>,
    ) -> Result<Option<Self>> {
        let group_id = GroupId::from_slice(group_id.as_ref());
        let group = MlsGroup::load(participant.provider.storage(), &group_id)
            .map_err(|error| anyhow!("secure mesh MLS group load failed: {error:?}"))?;
        match group {
            Some(group) => Ok(Some(Self::from_authenticated_group(participant, group)?)),
            None => Ok(None),
        }
    }

    pub(crate) fn capability_extension(&self) -> Result<SecureMeshMlsCapabilityExtension> {
        decode_secure_mesh_mls_capability_extension(self.group.extensions())
    }

    pub(crate) fn mlkem1024_epoch_extension(&self) -> Result<SecureMeshMlsMlKem1024EpochExtension> {
        decode_secure_mesh_mls_pq_epoch_extension(self.group.extensions())
    }

    fn current_mlkem1024_recipient_public_keys(
        &self,
        participant: &SecureMeshMlsParticipant,
    ) -> Result<BTreeMap<String, Vec<u8>>> {
        if let Some(extension) = &self.mlkem1024_epoch_extension {
            return extension
                .recipients
                .iter()
                .map(|(member_id, wrap)| {
                    let public_key = general_purpose::URL_SAFE_NO_PAD
                        .decode(&wrap.public_key_base64url)
                        .context("secure mesh MLS ML-KEM-1024 roster key is not base64url")?;
                    validate_ml_kem_1024_public_key(&public_key)?;
                    Ok((member_id.clone(), public_key))
                })
                .collect();
        }
        ensure!(
            matches!(
                self.capability_extension()?,
                SecureMeshMlsCapabilityExtension::AwaitingMemberNegotiation { .. }
            ) && self.member_count() == 1,
            "secure mesh MLS active group ML-KEM-1024 epoch state is missing"
        );
        Ok(BTreeMap::from([(
            mlkem1024_member_id(&participant.credential_identity_bytes()?)?,
            participant.provider.mlkem1024_seed.public_key(),
        )]))
    }

    pub fn require_active_capability_negotiation(&self) -> Result<()> {
        self.capability_extension()?.require_active()
    }

    #[cfg(test)]
    pub(crate) fn add_member(
        &mut self,
        owner: &SecureMeshMlsParticipant,
        key_package: &SecureMeshMlsKeyPackage,
    ) -> Result<SecureMeshMlsWelcome> {
        self.add_member_for_runtime_crypto_self_test(owner, key_package)
    }

    fn add_member_for_runtime_crypto_self_test(
        &mut self,
        owner: &SecureMeshMlsParticipant,
        key_package: &SecureMeshMlsKeyPackage,
    ) -> Result<SecureMeshMlsWelcome> {
        ensure!(
            matches!(
                self.capability_extension()?,
                SecureMeshMlsCapabilityExtension::AwaitingMemberNegotiation { .. }
            ),
            "secure mesh MLS active group member add requires capability-negotiated product path"
        );
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
        self.refresh_authenticated_group_context(owner)?;
        Ok(SecureMeshMlsWelcome {
            commit_message: commit_message.to_bytes().map_err(|error| {
                anyhow!("secure mesh MLS commit serialization failed: {error:?}")
            })?,
            welcome_message: welcome_message.to_bytes().map_err(|error| {
                anyhow!("secure mesh MLS welcome serialization failed: {error:?}")
            })?,
        })
    }

    pub(crate) fn add_member_with_capability_extension(
        &mut self,
        owner: &SecureMeshMlsParticipant,
        key_package: &SecureMeshMlsKeyPackage,
        capability_extension: &SecureMeshMlsCapabilityExtension,
    ) -> Result<SecureMeshMlsWelcome> {
        capability_extension.require_active()?;
        let mut recipient_public_keys = self.current_mlkem1024_recipient_public_keys(owner)?;
        let added_member_id = mlkem1024_member_id(&key_package.credential_identity_bytes()?)?;
        ensure!(
            recipient_public_keys
                .insert(added_member_id, key_package.mlkem1024_public_key().to_vec())
                .is_none(),
            "secure mesh MLS ML-KEM-1024 member already exists"
        );
        let previous_epoch_digest = self
            .mlkem1024_epoch_extension
            .as_ref()
            .map(mlkem1024_epoch_extension_digest)
            .transpose()?;
        let (pq_epoch_extension, _) = create_mlkem1024_epoch_extension(
            self.group.group_id().as_slice(),
            self.epoch().saturating_add(1),
            previous_epoch_digest,
            &recipient_public_keys,
        )?;
        let commit = self
            .group
            .commit_builder()
            .propose_adds(Some(key_package.public_key_package.clone()))
            .propose_group_context_extensions(secure_mesh_mls_group_context_extensions_with_pq(
                capability_extension,
                Some(&pq_epoch_extension),
            )?)
            .map_err(|error| {
                anyhow!("secure mesh MLS capability extension proposal failed: {error:?}")
            })?
            .load_psks(owner.provider.storage())
            .map_err(|error| anyhow!("secure mesh MLS PSK load failed: {error:?}"))?
            .build(
                owner.provider.rand(),
                owner.provider.crypto(),
                &owner.signer,
                |_| true,
            )
            .map_err(|error| anyhow!("secure mesh MLS capability commit build failed: {error:?}"))?
            .stage_commit(&owner.provider)
            .map_err(|error| {
                anyhow!("secure mesh MLS capability commit staging failed: {error:?}")
            })?;
        let commit_message = commit
            .commit()
            .to_bytes()
            .map_err(|error| anyhow!("secure mesh MLS commit serialization failed: {error:?}"))?;
        let welcome_message = commit
            .to_welcome_msg()
            .ok_or_else(|| anyhow!("secure mesh MLS capability commit welcome is missing"))?
            .to_bytes()
            .map_err(|error| anyhow!("secure mesh MLS welcome serialization failed: {error:?}"))?;
        self.group
            .merge_pending_commit(&owner.provider)
            .map_err(|error| anyhow!("secure mesh MLS pending commit merge failed: {error:?}"))?;
        self.refresh_authenticated_group_context(owner)?;
        ensure!(
            self.capability_extension()? == *capability_extension,
            "secure mesh MLS committed capability extension mismatch"
        );
        ensure!(
            self.mlkem1024_epoch_extension.as_ref() == Some(&pq_epoch_extension),
            "secure mesh MLS committed ML-KEM-1024 epoch extension mismatch"
        );
        Ok(SecureMeshMlsWelcome {
            commit_message,
            welcome_message,
        })
    }

    #[cfg(test)]
    pub(crate) fn stage_test_stripped_capability_extension_commit(
        &mut self,
        participant: &SecureMeshMlsParticipant,
    ) -> Result<Vec<u8>> {
        let (commit, _, _) = self
            .group
            .update_group_context_extensions(
                &participant.provider,
                Extensions::empty(),
                &participant.signer,
            )
            .map_err(|error| {
                anyhow!("secure mesh MLS stripped extension test commit failed: {error:?}")
            })?;
        commit.to_bytes().map_err(|error| {
            anyhow!("secure mesh MLS stripped extension test serialization failed: {error:?}")
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

    pub fn group_id_bytes(&self) -> Result<Vec<u8>> {
        Ok(self.group.group_id().as_slice().to_vec())
    }

    pub(crate) fn capability_add_base_transcript_digest(
        &self,
        key_package: &SecureMeshMlsKeyPackage,
    ) -> Result<String> {
        let mut transcript = Vec::new();
        transcript.extend_from_slice(b"LICO-SM-MLS-CAPABILITY-ADD-BASE-v1");
        append_mls_len_prefixed_bytes(
            &mut transcript,
            SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION.as_bytes(),
        )?;
        append_mls_len_prefixed_bytes(&mut transcript, SECURE_MESH_MLS_CIPHER_SUITE.as_bytes())?;
        append_mls_len_prefixed_bytes(&mut transcript, self.group.group_id().as_slice())?;
        transcript.extend_from_slice(&self.epoch().to_be_bytes());
        let mut member_credentials = self.member_credential_identities()?;
        member_credentials.sort_unstable();
        transcript.extend_from_slice(&(member_credentials.len() as u32).to_be_bytes());
        for credential in member_credentials {
            append_mls_len_prefixed_bytes(&mut transcript, &credential)?;
        }
        append_mls_len_prefixed_bytes(
            &mut transcript,
            secure_mesh_mls_capability_extension_digest(&self.capability_extension()?)?.as_bytes(),
        )?;
        append_mls_len_prefixed_bytes(&mut transcript, key_package.as_public_bytes())?;
        transcript.extend_from_slice(&self.epoch().saturating_add(1).to_be_bytes());
        let digest: [u8; 32] = Sha256::digest(transcript).into();
        Ok(crate::core::secure_mesh_capability_proof::encode_sha256_digest(&digest))
    }

    pub fn member_credential_identities(&self) -> Result<Vec<Vec<u8>>> {
        Ok(self
            .member_credential_signing_pairs()?
            .into_iter()
            .map(|(credential, _)| credential)
            .collect())
    }

    pub fn member_credential_signing_pairs(&self) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
        let mut pairs = Vec::new();
        for member in self.group.members() {
            pairs.push((
                basic_credential_identity(&member.credential)?,
                member.signature_key.as_slice().to_vec(),
            ));
        }
        Ok(pairs)
    }

    pub(crate) fn member_leaf_index_for_identity(
        &self,
        credential_identity: &[u8],
        signing_public_key: &[u8],
    ) -> Result<LeafNodeIndex> {
        let mut matched = None;
        for member in self.group.members() {
            if basic_credential_identity(&member.credential)? == credential_identity
                && member.signature_key.as_slice() == signing_public_key
            {
                ensure!(
                    matched.replace(member.index).is_none(),
                    "secure mesh MLS identity resolves to multiple member leaves"
                );
            }
        }
        matched.ok_or_else(|| {
            anyhow!("secure mesh MLS identity does not resolve to an exact member leaf")
        })
    }

    pub fn public_metadata(
        &self,
        participant_endpoint_id: impl Into<String>,
    ) -> Result<SecureMeshMlsGroupMetadata> {
        let group_id = self.group.group_id().as_slice().to_vec();
        let mut public_state = Vec::new();
        public_state.extend_from_slice(b"LICO-SM-MLS-PUBLIC-STATE-v1");
        append_mls_len_prefixed_bytes(&mut public_state, &group_id)?;
        append_mls_len_prefixed_bytes(&mut public_state, &self.authenticated_group_context)?;
        public_state.extend_from_slice(&self.epoch().to_be_bytes());
        public_state.extend_from_slice(&self.own_leaf_index().u32().to_be_bytes());
        public_state.push(u8::from(self.is_active()));
        append_mls_len_prefixed_bytes(
            &mut public_state,
            secure_mesh_mls_capability_extension_digest(&self.capability_extension()?)?.as_bytes(),
        )?;
        if let Some(pq_epoch_extension) = &self.mlkem1024_epoch_extension {
            append_mls_len_prefixed_bytes(
                &mut public_state,
                mlkem1024_epoch_extension_digest(pq_epoch_extension)?.as_bytes(),
            )?;
        }
        let mut roster = self
            .group
            .members()
            .map(|member| {
                Ok((
                    basic_credential_identity(&member.credential)?,
                    member.signature_key.as_slice().to_vec(),
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        roster.sort_unstable();
        public_state.extend_from_slice(&(roster.len() as u32).to_be_bytes());
        for (credential, signing_public_key) in roster {
            append_mls_len_prefixed_bytes(&mut public_state, &credential)?;
            append_mls_len_prefixed_bytes(&mut public_state, &signing_public_key)?;
        }
        Ok(SecureMeshMlsGroupMetadata {
            group_id_hash: hash_bytes(&group_id),
            public_state_digest: hash_bytes(&public_state),
            epoch: self.epoch(),
            member_count: self.member_count(),
            own_leaf_index: self.own_leaf_index().u32(),
            active: self.is_active(),
            participant_endpoint_id: participant_endpoint_id.into(),
        })
    }

    #[cfg(test)]
    pub(crate) fn join_from_welcome(
        participant: &SecureMeshMlsParticipant,
        welcome_message: &[u8],
    ) -> Result<Self> {
        Self::join_from_welcome_for_runtime_crypto_self_test(participant, welcome_message)
    }

    fn join_from_welcome_for_runtime_crypto_self_test(
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
        ensure!(
            matches!(
                decode_secure_mesh_mls_capability_extension(
                    staged_join.group_context().extensions()
                )?,
                SecureMeshMlsCapabilityExtension::AwaitingMemberNegotiation { .. }
            ),
            "secure mesh MLS active capability extension requires product verification"
        );
        let group = staged_join
            .into_group(&participant.provider)
            .map_err(|error| anyhow!("secure mesh MLS welcome join failed: {error:?}"))?;
        Self::from_authenticated_group(participant, group)
    }

    pub(crate) fn join_from_welcome_with_capability_verifier(
        participant: &SecureMeshMlsParticipant,
        welcome_message: &[u8],
        verifier: impl FnOnce(&SecureMeshMlsCapabilityExtension) -> Result<()>,
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
        let extension =
            decode_secure_mesh_mls_capability_extension(staged_join.group_context().extensions())?;
        extension.require_active()?;
        verifier(&extension)?;
        let group = staged_join
            .into_group(&participant.provider)
            .map_err(|error| anyhow!("secure mesh MLS welcome join failed: {error:?}"))?;
        let joined = Self::from_authenticated_group(participant, group)?;
        ensure!(
            joined.capability_extension()? == extension,
            "secure mesh MLS joined capability extension mismatch"
        );
        Ok(joined)
    }

    pub fn load_from_provider(
        participant: &SecureMeshMlsParticipant,
        group_id: impl AsRef<[u8]>,
    ) -> Result<Self> {
        let group_id = GroupId::from_slice(group_id.as_ref());
        let group = MlsGroup::load(participant.provider.storage(), &group_id)
            .map_err(|error| anyhow!("secure mesh MLS group storage load failed: {error:?}"))?
            .ok_or_else(|| anyhow!("secure mesh MLS group is missing from provider storage"))?;
        Self::from_authenticated_group(participant, group)
    }

    pub(crate) fn seal_application_message(
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

    #[cfg(test)]
    pub(crate) fn open_application_message(
        &mut self,
        receiver: &SecureMeshMlsParticipant,
        aad: &[u8],
        message: &[u8],
    ) -> Result<Vec<u8>> {
        self.open_application_message_for_runtime_crypto_self_test(receiver, aad, message)
    }

    fn open_application_message_for_runtime_crypto_self_test(
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
        self.open_application_message_with_sender_verifier(
            receiver,
            aad,
            protocol_message,
            |_, _, _| Ok(()),
        )
    }

    pub(crate) fn open_application_message_with_sender_verifier(
        &mut self,
        receiver: &SecureMeshMlsParticipant,
        aad: &[u8],
        protocol_message: ProtocolMessage,
        verify_sender: impl FnOnce(&[u8], &[u8], LeafNodeIndex) -> Result<()>,
    ) -> Result<Vec<u8>> {
        let processed = catch_unwind(AssertUnwindSafe(|| {
            self.group
                .process_message(&receiver.provider, protocol_message)
        }))
        .map_err(|_| anyhow!("secure mesh MLS application message rejected"))?
        .map_err(|error| anyhow!("secure mesh MLS application message open failed: {error:?}"))?;
        ensure!(
            processed.aad() == aad,
            "secure mesh MLS application message AAD mismatch"
        );
        let (credential_identity, signing_public_key, leaf_index) =
            self.authenticated_member_sender(&processed)?;
        verify_sender(&credential_identity, &signing_public_key, leaf_index)?;
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(application_message) => {
                Ok(application_message.into_bytes())
            }
            _ => Err(anyhow!(
                "secure mesh MLS message did not contain application data"
            )),
        }
    }

    pub(crate) fn derive_group_payload_content_key(
        &self,
        participant: &SecureMeshMlsParticipant,
    ) -> Result<ContentKey> {
        ensure!(
            self.is_active(),
            "secure mesh MLS inactive member cannot derive the current epoch payload key"
        );
        self.require_active_capability_negotiation()?;
        let export_context = build_group_payload_export_context(self)?;
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
        let pq_epoch_secret = self.mlkem1024_epoch_secret.as_ref().ok_or_else(|| {
            anyhow!("secure mesh MLS ML-KEM-1024 epoch secret is unavailable; re-pair required")
        })?;
        let mut fixed =
            mix_mlkem1024_payload_key(exported.as_slice(), pq_epoch_secret, &export_context)?;
        let content_key = ContentKey::from_bytes(*fixed);
        fixed.zeroize();
        Ok(content_key)
    }

    pub(crate) fn seal_payload_message(
        &mut self,
        sender: &SecureMeshMlsParticipant,
        context: &SecureMeshContentContext,
        plaintext: &SecureMeshPlaintext,
    ) -> Result<Vec<u8>> {
        self.require_active_capability_negotiation()?;
        let content_key = self.derive_group_payload_content_key(sender)?;
        let sealed = seal_private_context_payload(&content_key, context, plaintext)?;
        let encoded = encode_mls_private_context_payload(&sealed)?;
        self.seal_application_message(sender, SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD, &encoded)
    }

    #[cfg(test)]
    pub(crate) fn open_payload_message(
        &mut self,
        receiver: &SecureMeshMlsParticipant,
        context: &SecureMeshContentContext,
        message: &[u8],
        expected_kind: SecureMeshPayloadKind,
    ) -> Result<OpenedSecureMeshPayload> {
        self.require_active_capability_negotiation()?;
        let encoded = self.open_application_message(
            receiver,
            SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD,
            message,
        )?;
        self.open_and_validate_private_context_payload(receiver, context, expected_kind, &encoded)
    }

    pub(crate) fn open_payload_message_with_sender_verifier(
        &mut self,
        receiver: &SecureMeshMlsParticipant,
        context: &SecureMeshContentContext,
        message: &[u8],
        expected_kind: SecureMeshPayloadKind,
        verify_sender: impl FnOnce(&[u8], &[u8], LeafNodeIndex) -> Result<()>,
    ) -> Result<OpenedSecureMeshPayload> {
        self.require_active_capability_negotiation()?;
        let protocol_message = deserialize_protocol_message(
            message,
            "secure mesh MLS application message deserialization failed",
        )?;
        let encoded = self.open_application_message_with_sender_verifier(
            receiver,
            SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD,
            protocol_message,
            verify_sender,
        )?;
        self.open_and_validate_private_context_payload(receiver, context, expected_kind, &encoded)
    }

    fn open_and_validate_private_context_payload(
        &self,
        receiver: &SecureMeshMlsParticipant,
        expected_context: &SecureMeshContentContext,
        expected_kind: SecureMeshPayloadKind,
        encoded: &[u8],
    ) -> Result<OpenedSecureMeshPayload> {
        let sealed = decode_mls_private_context_payload(encoded)?;
        let content_key = self.derive_group_payload_content_key(receiver)?;
        let opened = open_private_context_payload(&content_key, &sealed)?;
        let (actual_context, payload) = opened.into_parts();
        ensure!(
            actual_context == *expected_context,
            "secure mesh MLS encrypted inner context mismatch"
        );
        ensure!(
            payload.kind == expected_kind,
            "secure mesh MLS encrypted inner payload kind mismatch"
        );
        Ok(payload)
    }

    #[cfg(test)]
    pub(crate) fn self_update(
        &mut self,
        participant: &SecureMeshMlsParticipant,
    ) -> Result<Vec<u8>> {
        let capability_extension = self.capability_extension()?;
        let commit = if capability_extension.require_active().is_ok() {
            let recipient_public_keys =
                self.current_mlkem1024_recipient_public_keys(participant)?;
            let previous_epoch_digest = self
                .mlkem1024_epoch_extension
                .as_ref()
                .map(mlkem1024_epoch_extension_digest)
                .transpose()?;
            let (pq_epoch_extension, _) = create_mlkem1024_epoch_extension(
                self.group.group_id().as_slice(),
                self.epoch().saturating_add(1),
                previous_epoch_digest,
                &recipient_public_keys,
            )?;
            self.group
                .update_group_context_extensions(
                    &participant.provider,
                    secure_mesh_mls_group_context_extensions_with_pq(
                        &capability_extension,
                        Some(&pq_epoch_extension),
                    )?,
                    &participant.signer,
                )
                .map_err(|error| anyhow!("secure mesh MLS hybrid epoch update failed: {error:?}"))?
                .0
        } else {
            self.group
                .self_update(
                    &participant.provider,
                    &participant.signer,
                    LeafNodeParameters::default(),
                )
                .map_err(|error| anyhow!("secure mesh MLS self update failed: {error:?}"))?
                .into_commit()
        };
        self.group
            .merge_pending_commit(&participant.provider)
            .map_err(|error| {
                anyhow!("secure mesh MLS self update pending commit merge failed: {error:?}")
            })?;
        self.refresh_authenticated_group_context(participant)?;
        commit
            .to_bytes()
            .map_err(|error| anyhow!("secure mesh MLS self update serialization failed: {error:?}"))
    }

    pub(crate) fn remove_member_with_capability_extension(
        &mut self,
        remover: &SecureMeshMlsParticipant,
        removed: LeafNodeIndex,
        capability_extension: &SecureMeshMlsCapabilityExtension,
    ) -> Result<SecureMeshMlsCommit> {
        capability_extension.require_active()?;
        ensure!(
            removed != self.own_leaf_index(),
            "secure mesh MLS member-remove action cannot remove its own leaf"
        );
        let removed_identity = self
            .group
            .members()
            .find(|member| member.index == removed)
            .ok_or_else(|| anyhow!("secure mesh MLS removed member is missing"))
            .and_then(|member| basic_credential_identity(&member.credential))?;
        let mut recipient_public_keys = self.current_mlkem1024_recipient_public_keys(remover)?;
        let removed_member_id = mlkem1024_member_id(&removed_identity)?;
        ensure!(
            recipient_public_keys.remove(&removed_member_id).is_some(),
            "secure mesh MLS removed member ML-KEM-1024 key is missing"
        );
        let previous_epoch_digest = self
            .mlkem1024_epoch_extension
            .as_ref()
            .map(mlkem1024_epoch_extension_digest)
            .transpose()?;
        let (pq_epoch_extension, _) = create_mlkem1024_epoch_extension(
            self.group.group_id().as_slice(),
            self.epoch().saturating_add(1),
            previous_epoch_digest,
            &recipient_public_keys,
        )?;
        let commit = self
            .group
            .commit_builder()
            .propose_removals([removed])
            .propose_group_context_extensions(secure_mesh_mls_group_context_extensions_with_pq(
                capability_extension,
                Some(&pq_epoch_extension),
            )?)
            .map_err(|error| {
                anyhow!("secure mesh MLS remove capability proposal failed: {error:?}")
            })?
            .load_psks(remover.provider.storage())
            .map_err(|error| anyhow!("secure mesh MLS remove PSK load failed: {error:?}"))?
            .build(
                remover.provider.rand(),
                remover.provider.crypto(),
                &remover.signer,
                |_| true,
            )
            .map_err(|error| anyhow!("secure mesh MLS remove commit build failed: {error:?}"))?
            .stage_commit(&remover.provider)
            .map_err(|error| anyhow!("secure mesh MLS remove commit staging failed: {error:?}"))?;
        let commit_message = commit.commit().to_bytes().map_err(|error| {
            anyhow!("secure mesh MLS remove commit serialization failed: {error:?}")
        })?;
        ensure!(
            commit.to_welcome_msg().is_none(),
            "secure mesh MLS remove commit unexpectedly produced a welcome"
        );
        self.group
            .merge_pending_commit(&remover.provider)
            .map_err(|error| {
                anyhow!("secure mesh MLS remove member pending commit merge failed: {error:?}")
            })?;
        self.refresh_authenticated_group_context(remover)?;
        ensure!(
            self.capability_extension()? == *capability_extension,
            "secure mesh MLS removed-member capability extension mismatch"
        );
        ensure!(
            self.mlkem1024_epoch_extension.as_ref() == Some(&pq_epoch_extension),
            "secure mesh MLS removed-member ML-KEM-1024 epoch extension mismatch"
        );
        Ok(SecureMeshMlsCommit {
            commit_message,
            welcome_message: None,
        })
    }

    #[cfg(test)]
    pub(crate) fn process_commit(
        &mut self,
        participant: &SecureMeshMlsParticipant,
        commit_message: &[u8],
    ) -> Result<()> {
        self.process_commit_with_capability_verifier(
            participant,
            commit_message,
            false,
            |_, _, _| Ok(()),
            |_, _, _, _| Ok(()),
        )
    }

    pub(crate) fn process_commit_with_capability_verifier(
        &mut self,
        participant: &SecureMeshMlsParticipant,
        commit_message: &[u8],
        allow_capability_update: bool,
        verify_sender: impl FnOnce(&[u8], &[u8], LeafNodeIndex) -> Result<()>,
        verifier: impl FnOnce(
            &SecureMeshMlsCapabilityExtension,
            &SecureMeshMlsCapabilityExtension,
            &[LeafNodeIndex],
            usize,
        ) -> Result<()>,
    ) -> Result<()> {
        let current_extension = self.capability_extension()?;
        let protocol_message = deserialize_protocol_message(
            commit_message,
            "secure mesh MLS commit deserialization failed",
        )?;
        let processed = catch_unwind(AssertUnwindSafe(|| {
            self.group
                .process_message(&participant.provider, protocol_message)
        }))
        .map_err(|_| anyhow!("secure mesh MLS commit rejected"))?
        .map_err(|error| anyhow!("secure mesh MLS commit process failed: {error:?}"))?;
        let (credential_identity, signing_public_key, leaf_index) =
            self.authenticated_member_sender(&processed)?;
        verify_sender(&credential_identity, &signing_public_key, leaf_index)?;
        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                let staged_extension = decode_secure_mesh_mls_capability_extension(
                    staged_commit.group_context().extensions(),
                )?;
                if staged_extension != current_extension {
                    ensure!(
                        allow_capability_update,
                        "secure mesh MLS capability extension update requires product verification"
                    );
                    let SecureMeshMlsCapabilityExtension::Active {
                        previous_extension_digest,
                        group_negotiated_protocol_capabilities: staged_group_capabilities,
                        ..
                    } = &staged_extension
                    else {
                        return Err(anyhow!(
                            "secure mesh MLS capability extension downgrade rejected"
                        ));
                    };
                    let expected_previous_digest =
                        secure_mesh_mls_capability_extension_digest(&current_extension)?;
                    ensure!(
                        previous_extension_digest.as_deref()
                            == Some(expected_previous_digest.as_str()),
                        "secure mesh MLS capability extension continuity failed"
                    );
                    let _ = staged_group_capabilities;
                }
                let removed_leaf_indices = staged_commit
                    .remove_proposals()
                    .map(|proposal| proposal.remove_proposal().removed())
                    .collect::<Vec<_>>();
                let added_member_count = staged_commit.add_proposals().count();
                if matches!(
                    staged_extension,
                    SecureMeshMlsCapabilityExtension::Active { .. }
                ) {
                    let staged_pq_extension = decode_secure_mesh_mls_pq_epoch_extension(
                        staged_commit.group_context().extensions(),
                    )?;
                    ensure!(
                        staged_pq_extension.epoch == self.epoch().saturating_add(1),
                        "secure mesh MLS ML-KEM-1024 epoch did not advance"
                    );
                    let expected_previous_pq_digest = self
                        .mlkem1024_epoch_extension
                        .as_ref()
                        .map(mlkem1024_epoch_extension_digest)
                        .transpose()?;
                    ensure!(
                        staged_pq_extension.previous_epoch_digest == expected_previous_pq_digest,
                        "secure mesh MLS ML-KEM-1024 epoch continuity failed"
                    );
                    let expected_member_count = self
                        .member_count()
                        .checked_add(added_member_count)
                        .and_then(|count| count.checked_sub(removed_leaf_indices.len()))
                        .ok_or_else(|| anyhow!("secure mesh MLS staged roster size is invalid"))?;
                    ensure!(
                        staged_pq_extension.recipients.len() == expected_member_count,
                        "secure mesh MLS ML-KEM-1024 recipient count differs from staged roster"
                    );
                    let removed_leaf_set = removed_leaf_indices
                        .iter()
                        .copied()
                        .collect::<BTreeSet<_>>();
                    let mut expected_recipient_ids = self
                        .group
                        .members()
                        .filter(|member| !removed_leaf_set.contains(&member.index))
                        .map(|member| {
                            mlkem1024_member_id(&basic_credential_identity(&member.credential)?)
                        })
                        .collect::<Result<BTreeSet<_>>>()?;
                    for add in staged_commit.add_proposals() {
                        expected_recipient_ids.insert(mlkem1024_member_id(
                            &basic_credential_identity(
                                add.add_proposal().key_package().leaf_node().credential(),
                            )?,
                        )?);
                    }
                    ensure!(
                        staged_pq_extension
                            .recipients
                            .keys()
                            .cloned()
                            .collect::<BTreeSet<_>>()
                            == expected_recipient_ids,
                        "secure mesh MLS ML-KEM-1024 recipient roster differs from staged MLS roster"
                    );
                    let local_is_removed = removed_leaf_indices.contains(&self.own_leaf_index());
                    if !local_is_removed {
                        let local_member_id =
                            mlkem1024_member_id(&participant.credential_identity_bytes()?)?;
                        ensure!(
                            staged_pq_extension
                                .recipients
                                .contains_key(&local_member_id),
                            "secure mesh MLS ML-KEM-1024 local recipient is missing"
                        );
                        let staged_recipient_ids = staged_pq_extension
                            .recipients
                            .keys()
                            .cloned()
                            .collect::<BTreeSet<_>>();
                        open_mlkem1024_epoch_extension(
                            self.group.group_id().as_slice(),
                            staged_pq_extension.epoch,
                            &staged_recipient_ids,
                            &participant.credential_identity_bytes()?,
                            &participant.provider.mlkem1024_seed,
                            &staged_pq_extension,
                        )?;
                    }
                }
                verifier(
                    &current_extension,
                    &staged_extension,
                    &removed_leaf_indices,
                    added_member_count,
                )?;
                self.group
                    .merge_staged_commit(&participant.provider, *staged_commit)
                    .map_err(|error| {
                        anyhow!("secure mesh MLS staged commit merge failed: {error:?}")
                    })?;
                self.refresh_authenticated_group_context(participant)?;
                ensure!(
                    self.capability_extension()? == staged_extension,
                    "secure mesh MLS merged capability extension mismatch"
                );
                Ok(())
            }
            _ => Err(anyhow!("secure mesh MLS message did not contain a commit")),
        }
    }

    fn from_authenticated_group(
        participant: &SecureMeshMlsParticipant,
        group: MlsGroup,
    ) -> Result<Self> {
        let authenticated_group_context = authenticated_group_context_bytes(&group, participant)?;
        let mut result = Self {
            group,
            authenticated_group_context,
            mlkem1024_epoch_extension: None,
            mlkem1024_epoch_secret: None,
        };
        result.refresh_mlkem1024_epoch_state(participant)?;
        Ok(result)
    }

    fn refresh_authenticated_group_context(
        &mut self,
        participant: &SecureMeshMlsParticipant,
    ) -> Result<()> {
        self.authenticated_group_context =
            authenticated_group_context_bytes(&self.group, participant)?;
        self.refresh_mlkem1024_epoch_state(participant)?;
        Ok(())
    }

    fn refresh_mlkem1024_epoch_state(
        &mut self,
        participant: &SecureMeshMlsParticipant,
    ) -> Result<()> {
        let capability_extension = self.capability_extension()?;
        if matches!(
            capability_extension,
            SecureMeshMlsCapabilityExtension::AwaitingMemberNegotiation { .. }
        ) {
            self.mlkem1024_epoch_extension = None;
            self.mlkem1024_epoch_secret = None;
            return Ok(());
        }
        capability_extension.require_active()?;
        let extension = self.mlkem1024_epoch_extension()?;
        if !self.is_active() {
            self.mlkem1024_epoch_extension = Some(extension);
            self.mlkem1024_epoch_secret = None;
            return Ok(());
        }
        let expected_member_ids = self
            .member_credential_identities()?
            .into_iter()
            .map(|identity| mlkem1024_member_id(&identity))
            .collect::<Result<BTreeSet<_>>>()?;
        let secret = open_mlkem1024_epoch_extension(
            self.group.group_id().as_slice(),
            self.epoch(),
            &expected_member_ids,
            &participant.credential_identity_bytes()?,
            &participant.provider.mlkem1024_seed,
            &extension,
        )?;
        self.mlkem1024_epoch_extension = Some(extension);
        self.mlkem1024_epoch_secret = Some(secret);
        Ok(())
    }

    fn authenticated_member_sender(
        &self,
        processed: &ProcessedMessage,
    ) -> Result<(Vec<u8>, Vec<u8>, LeafNodeIndex)> {
        let leaf_index = match processed.sender() {
            Sender::Member(leaf_index) => *leaf_index,
            _ => {
                return Err(anyhow!(
                    "secure mesh MLS product message sender is not a group member"
                ));
            }
        };
        let member = self
            .group
            .members()
            .find(|member| member.index == leaf_index)
            .ok_or_else(|| anyhow!("secure mesh MLS authenticated sender leaf is missing"))?;
        ensure!(
            member.credential == *processed.credential(),
            "secure mesh MLS authenticated sender credential does not match leaf"
        );
        let credential_identity = basic_credential_identity(processed.credential())?;
        Ok((credential_identity, member.signature_key, leaf_index))
    }
}

fn authenticated_group_context_bytes(
    group: &MlsGroup,
    participant: &SecureMeshMlsParticipant,
) -> Result<Vec<u8>> {
    let group_info = group
        .export_group_info(participant.provider.crypto(), &participant.signer, false)
        .map_err(|error| {
            anyhow!("secure mesh MLS authenticated group context export failed: {error:?}")
        })?;
    let MlsMessageBodyOut::GroupInfo(group_info) = group_info.body() else {
        return Err(anyhow!(
            "secure mesh MLS authenticated group context export returned an invalid body"
        ));
    };
    group_info
        .group_context()
        .tls_serialize_detached()
        .context("secure mesh MLS authenticated group context serialization failed")
}

fn basic_credential_identity(credential: &Credential) -> Result<Vec<u8>> {
    let basic = BasicCredential::try_from(credential.clone())
        .map_err(|error| anyhow!("secure mesh MLS sender credential is not basic: {error:?}"))?;
    Ok(basic.identity().to_vec())
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshMlsGroupMetadata {
    pub group_id_hash: String,
    pub public_state_digest: String,
    pub epoch: u64,
    pub member_count: usize,
    pub own_leaf_index: u32,
    pub active: bool,
    pub participant_endpoint_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshMlsDurableRecord {
    pub group_id_hash: String,
    pub public_state_digest: String,
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
        let path = path.as_ref();
        let connection =
            Connection::open(path).with_context(|| "secure mesh MLS durable store open failed")?;
        harden_private_path(path)
            .context("secure mesh MLS durable store private path hardening failed")?;
        let store = Self { connection };
        store.initialize()?;
        harden_private_path(path)
            .context("secure mesh MLS durable store private path hardening failed")?;
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
                public_state_digest,
                participant_endpoint_id,
                epoch,
                state_version,
                member_count,
                own_leaf_index,
                active,
                revoked_at_epoch,
                updated_at
            ) VALUES (?1, ?2, ?3, ?4, 1, ?5, ?6, ?7, NULL, ?8)
            "#,
            params![
                metadata.group_id_hash,
                metadata.public_state_digest,
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
            metadata.epoch > previous.epoch,
            "secure mesh MLS durable commit must strictly advance the epoch"
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
            SET public_state_digest = ?1,
                epoch = ?2,
                state_version = state_version + 1,
                member_count = ?3,
                own_leaf_index = ?4,
                active = ?5,
                updated_at = ?6
            WHERE group_id_hash = ?7
              AND participant_endpoint_id = ?8
              AND state_version = ?9
              AND epoch = ?10
              AND public_state_digest = ?11
              AND revoked_at_epoch IS NULL
            "#,
            params![
                metadata.public_state_digest,
                metadata.epoch as i64,
                metadata.member_count as i64,
                metadata.own_leaf_index as i64,
                i64::from(metadata.active),
                updated_at,
                previous.group_id_hash,
                previous.participant_endpoint_id,
                previous.state_version as i64,
                previous.epoch as i64,
                previous.public_state_digest
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
              AND public_state_digest = ?6
              AND revoked_at_epoch IS NULL
            "#,
            params![
                revoked_at_epoch as i64,
                updated_at,
                previous.group_id_hash,
                previous.participant_endpoint_id,
                previous.state_version as i64,
                previous.public_state_digest
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

    pub fn reconcile_authenticated_snapshot(
        &mut self,
        metadata: &SecureMeshMlsGroupMetadata,
        updated_at: impl Into<String>,
    ) -> Result<SecureMeshMlsDurableRecord> {
        validate_metadata(metadata)?;
        let updated_at = require_text(updated_at.into(), "updated_at")?;
        let tx = self
            .connection
            .transaction()
            .context("secure mesh MLS authenticated metadata reconciliation failed")?;
        let previous = read_record_tx(
            &tx,
            &metadata.group_id_hash,
            &metadata.participant_endpoint_id,
        )?
        .ok_or_else(|| anyhow!("secure mesh MLS durable group authority is missing"))?;
        if previous.public_state_digest != MLS_PUBLIC_STATE_DIGEST_AUTHENTICATED_BACKFILL {
            tx.commit()
                .context("secure mesh MLS authenticated metadata reconciliation commit failed")?;
            return Ok(previous);
        }
        ensure!(
            previous.epoch == metadata.epoch
                && previous.member_count == metadata.member_count
                && previous.own_leaf_index == metadata.own_leaf_index
                && previous.active == metadata.active,
            "secure mesh MLS selected-custody snapshot cannot authenticate durable metadata"
        );
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_mls_group_state
            SET public_state_digest = ?1,
                state_version = state_version + 1,
                updated_at = ?2
            WHERE group_id_hash = ?3
              AND participant_endpoint_id = ?4
              AND state_version = ?5
              AND epoch = ?6
              AND member_count = ?7
              AND own_leaf_index = ?8
              AND active = ?9
              AND public_state_digest = ?10
            "#,
            params![
                metadata.public_state_digest,
                updated_at,
                metadata.group_id_hash,
                metadata.participant_endpoint_id,
                previous.state_version as i64,
                metadata.epoch as i64,
                metadata.member_count as i64,
                metadata.own_leaf_index as i64,
                i64::from(metadata.active),
                MLS_PUBLIC_STATE_DIGEST_AUTHENTICATED_BACKFILL,
            ],
        )?;
        ensure!(
            changed == 1,
            "secure mesh MLS authenticated metadata reconciliation lost authority"
        );
        tx.commit()
            .context("secure mesh MLS authenticated metadata reconciliation commit failed")?;
        self.read(&metadata.group_id_hash, &metadata.participant_endpoint_id)?
            .ok_or_else(|| {
                anyhow!(
                    "secure mesh MLS durable record disappeared after authenticated reconciliation"
                )
            })
    }

    pub fn has_records_for_participant(&self, participant_endpoint_id: &str) -> Result<bool> {
        let found: Option<i64> = self
            .connection
            .query_row(
                "SELECT 1 FROM secure_mesh_mls_group_state WHERE participant_endpoint_id = ?1 LIMIT 1",
                params![participant_endpoint_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(found.is_some())
    }

    pub fn purge_unrecoverable_memory_only_state(&mut self) -> Result<usize> {
        self.connection
            .execute("DELETE FROM secure_mesh_mls_group_state", [])
            .context("secure mesh MLS unrecoverable memory-only group-state purge failed")
    }

    pub fn reset_for_kt_authority_change(&mut self) -> Result<usize> {
        let transaction = self
            .connection
            .transaction()
            .context("secure mesh MLS KT-authority reset transaction failed")?;
        let removed = transaction
            .execute("DELETE FROM secure_mesh_mls_group_state", [])
            .context("secure mesh MLS KT-authority group-state reset failed")?;
        transaction
            .commit()
            .context("secure mesh MLS KT-authority group-state reset commit failed")?;
        Ok(removed)
    }

    fn initialize(&self) -> Result<()> {
        let existing_table: Option<String> = self
            .connection
            .query_row(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'secure_mesh_mls_group_state'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if existing_table.is_some() {
            let mut statement = self
                .connection
                .prepare("PRAGMA table_info(secure_mesh_mls_group_state)")?;
            let columns = statement
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            drop(statement);
            if !columns.iter().any(|column| column == "public_state_digest") {
                self.connection.execute(
                    "ALTER TABLE secure_mesh_mls_group_state ADD COLUMN public_state_digest TEXT NOT NULL DEFAULT 'pending:selected-custody-authenticated-backfill'",
                    [],
                )?;
            }
        }
        self.connection.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS secure_mesh_mls_group_state (
                group_id_hash TEXT NOT NULL,
                public_state_digest TEXT NOT NULL,
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
                public_state_digest,
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
                    public_state_digest: row.get(1)?,
                    participant_endpoint_id: row.get(2)?,
                    epoch: row.get::<_, i64>(3)? as u64,
                    state_version: row.get::<_, i64>(4)? as u64,
                    member_count: row.get::<_, i64>(5)? as usize,
                    own_leaf_index: row.get::<_, i64>(6)? as u32,
                    active: row.get::<_, i64>(7)? == 1,
                    revoked_at_epoch: row.get::<_, Option<i64>>(8)?.map(|value| value as u64),
                    updated_at: row.get(9)?,
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
        metadata.public_state_digest.starts_with("sha256:"),
        "secure mesh MLS public state digest is required"
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

fn build_group_payload_export_context(group: &SecureMeshMlsGroup) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(MLS_PAYLOAD_EXPORT_CONTEXT_MAGIC);
    append_mls_len_prefixed_bytes(&mut out, SECURE_MESH_MLS_CIPHER_SUITE.as_bytes())?;
    append_mls_len_prefixed_bytes(&mut out, group.group.group_id().as_slice())?;
    out.extend_from_slice(&group.epoch().to_be_bytes());
    let capability_extension = group.capability_extension()?;
    capability_extension.require_active()?;
    append_mls_len_prefixed_bytes(
        &mut out,
        secure_mesh_mls_capability_extension_digest(&capability_extension)?.as_bytes(),
    )?;
    let pq_epoch_extension = group
        .mlkem1024_epoch_extension
        .as_ref()
        .ok_or_else(|| anyhow!("secure mesh MLS ML-KEM-1024 epoch extension is unavailable"))?;
    append_mls_len_prefixed_bytes(
        &mut out,
        mlkem1024_epoch_extension_digest(pq_epoch_extension)?.as_bytes(),
    )?;
    Ok(out)
}

fn encode_mls_private_context_payload(
    sealed: &SealedSecureMeshPrivateContextPayload,
) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(MLS_PRIVATE_CONTEXT_PAYLOAD_MAGIC);
    append_mls_len_prefixed_bytes(&mut out, sealed.encrypted_header().as_bytes())?;
    out.extend_from_slice(
        &u64::try_from(sealed.ciphertext_size())
            .map_err(|_| anyhow!("secure mesh MLS ciphertext bucket is outside bounds"))?
            .to_be_bytes(),
    );
    append_mls_len_prefixed_bytes(&mut out, sealed.ciphertext().as_bytes())?;
    Ok(out)
}

fn decode_mls_private_context_payload(
    bytes: &[u8],
) -> Result<SealedSecureMeshPrivateContextPayload> {
    let mut reader = MlsPayloadReader::new(bytes);
    reader.expect_bytes(MLS_PRIVATE_CONTEXT_PAYLOAD_MAGIC)?;
    let encrypted_header = reader.read_string("encrypted_header")?;
    let ciphertext_size = usize::try_from(reader.read_u64()?)
        .map_err(|_| anyhow!("secure mesh MLS ciphertext bucket is outside platform bounds"))?;
    let ciphertext = reader.read_string("ciphertext")?;
    ensure!(
        reader.is_empty(),
        "secure mesh MLS private-context payload has trailing bytes"
    );
    SealedSecureMeshPrivateContextPayload::from_encoded_parts(
        encrypted_header,
        ciphertext,
        ciphertext_size,
    )
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
        .with_group_context_extensions(
            secure_mesh_mls_group_context_extensions(
                &SecureMeshMlsCapabilityExtension::awaiting_member_negotiation(),
            )
            .expect("secure mesh MLS built-in capability extension must be valid"),
        )
        .capabilities(secure_mesh_mls_leaf_capabilities())
        .build()
}

fn secure_mesh_mls_join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_capability::{
        CapabilityEvidenceKind, capability_catalog, mandatory_protocol_facts,
    };
    use crate::core::secure_mesh_capability_proof::{
        CapabilityProofRequest, CapabilityProofVerificationContext, sign_capability_proof,
        verify_capability_proof,
    };
    use crate::core::secure_mesh_session_negotiation::create_mls_capability_binding;
    use crate::core::secure_mesh_trust::DeviceTrustPublicIdentity;
    use crate::platform::secure_mesh_secret_store::{EphemeralSecretStore, SecureMeshSecretStore};
    use ed25519_dalek::SigningKey;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::Arc;
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

    fn test_secret_store() -> Arc<dyn SecureMeshSecretStore> {
        Arc::new(EphemeralSecretStore::new())
    }

    fn activate_test_payload_capabilities(
        group: &mut SecureMeshMlsGroup,
        participant: &SecureMeshMlsParticipant,
        members: &[&SecureMeshMlsParticipant],
    ) -> Vec<u8> {
        let evaluation = capability_catalog()
            .unwrap()
            .evaluate(&mandatory_protocol_facts(CapabilityEvidenceKind::TestFixture).unwrap())
            .unwrap();
        let first_key = SigningKey::from_bytes(&[0x31; 32]);
        let second_key = SigningKey::from_bytes(&[0x32; 32]);
        let first_identity = DeviceTrustPublicIdentity::new(
            "mls:test-capability-first",
            [0x41; 32],
            first_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        let second_identity = DeviceTrustPublicIdentity::new(
            "mls:test-capability-second",
            [0x42; 32],
            second_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        let build_protocol_digest =
            crate::core::secure_mesh_capability_proof::encode_sha256_digest(&[0x51; 32]);
        let request = CapabilityProofRequest {
            build_protocol_digest: build_protocol_digest.clone(),
            policy_revision: 1,
            challenge: [0x61; 32],
            issued_at_unix_seconds: 1_900_000_000,
            expires_at_unix_seconds: 1_900_000_060,
        };
        let first_proof =
            sign_capability_proof(&first_identity, &first_key, &evaluation, &request).unwrap();
        let second_proof =
            sign_capability_proof(&second_identity, &second_key, &evaluation, &request).unwrap();
        let context = CapabilityProofVerificationContext {
            expected_build_protocol_digest: build_protocol_digest,
            expected_policy_revision: 1,
            expected_challenge: [0x61; 32],
            now_unix_seconds: 1_900_000_001,
        };
        let first_verified =
            verify_capability_proof(&first_identity, &first_proof, &context).unwrap();
        let second_verified =
            verify_capability_proof(&second_identity, &second_proof, &context).unwrap();
        let binding = create_mls_capability_binding(
            &first_verified,
            &second_verified,
            &crate::core::secure_mesh_capability_proof::encode_sha256_digest(&[0x71; 32]),
        )
        .unwrap();
        let previous_extension_digest =
            secure_mesh_mls_capability_extension_digest(&group.capability_extension().unwrap())
                .unwrap();
        let extension = SecureMeshMlsCapabilityExtension::Active {
            schema_version: MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION,
            activated_at_epoch: group.epoch().saturating_add(1),
            previous_extension_digest: Some(previous_extension_digest),
            committer_endpoint_id: first_identity.endpoint_id.clone(),
            roster_transition: SecureMeshMlsRosterTransition::MemberAdded {
                member_endpoint_id: second_identity.endpoint_id.clone(),
                pair_binding: binding.clone(),
            },
            member_capability_proofs: BTreeMap::from([
                (
                    first_identity.endpoint_id.clone(),
                    SecureMeshMlsMemberCapabilityProof {
                        endpoint_id: first_identity.endpoint_id.clone(),
                        accepted_at_unix_seconds: request.issued_at_unix_seconds,
                        proof: first_proof,
                    },
                ),
                (
                    second_identity.endpoint_id.clone(),
                    SecureMeshMlsMemberCapabilityProof {
                        endpoint_id: second_identity.endpoint_id.clone(),
                        accepted_at_unix_seconds: request.issued_at_unix_seconds,
                        proof: second_proof,
                    },
                ),
            ]),
            group_negotiated_protocol_capabilities: binding
                .negotiated_protocol_capabilities
                .clone(),
        };
        let member_public_keys = members
            .iter()
            .map(|member| {
                Ok((
                    mlkem1024_member_id(&member.credential_identity_bytes()?)?,
                    member.provider.mlkem1024_seed.public_key(),
                ))
            })
            .collect::<Result<BTreeMap<_, _>>>()
            .unwrap();
        let (pq_epoch_extension, _) = create_mlkem1024_epoch_extension(
            group.group.group_id().as_slice(),
            group.epoch().saturating_add(1),
            None,
            &member_public_keys,
        )
        .unwrap();
        let (commit, _, _) = group
            .group
            .update_group_context_extensions(
                &participant.provider,
                secure_mesh_mls_group_context_extensions_with_pq(
                    &extension,
                    Some(&pq_epoch_extension),
                )
                .unwrap(),
                &participant.signer,
            )
            .unwrap();
        let commit = commit.to_bytes().unwrap();
        group
            .group
            .merge_pending_commit(&participant.provider)
            .unwrap();
        group
            .refresh_authenticated_group_context(participant)
            .unwrap();
        assert_eq!(group.capability_extension().unwrap(), extension);
        commit
    }

    fn process_test_payload_capability_commit(
        group: &mut SecureMeshMlsGroup,
        participant: &SecureMeshMlsParticipant,
        commit: &[u8],
    ) {
        group
            .process_commit_with_capability_verifier(
                participant,
                commit,
                true,
                |_, _, _| Ok(()),
                |_, _, _, _| Ok(()),
            )
            .unwrap();
    }

    fn test_secret_store_handle(test_name: &str, secret_class: &str) -> SecretStoreHandle {
        SecretStoreHandle::new(
            format!("mls-test-{secret_class}-{test_name}"),
            "providerSnapshot",
        )
        .unwrap()
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

    fn active_payload_group_pair(
        group_id: &[u8],
    ) -> (
        SecureMeshMlsParticipant,
        SecureMeshMlsParticipant,
        SecureMeshMlsGroup,
        SecureMeshMlsGroup,
    ) {
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = SecureMeshMlsGroup::create(&alice, group_id).unwrap();
        let welcome = alice_group.add_member(&alice, &bob_key_package).unwrap();
        let mut bob_group =
            SecureMeshMlsGroup::join_from_welcome(&bob, &welcome.welcome_message).unwrap();
        let capability_commit =
            activate_test_payload_capabilities(&mut alice_group, &alice, &[&alice, &bob]);
        process_test_payload_capability_commit(&mut bob_group, &bob, &capability_commit);
        (alice, bob, alice_group, bob_group)
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
    fn secure_mesh_mls_key_package_requires_authenticated_mlkem1024_wrapper() {
        let participant = SecureMeshMlsParticipant::new(b"mobile:key-package".to_vec()).unwrap();
        let key_package = participant.generate_key_package().unwrap();
        assert_eq!(
            key_package.mlkem1024_public_key().len(),
            crate::core::secure_mesh_pqxdh::ML_KEM_1024_PUBLIC_KEY_BYTES
        );
        assert!(SecureMeshMlsKeyPackage::from_public_bytes(key_package.as_public_bytes()).is_ok());
        let unwrapped_openmls_key_package = key_package
            .public_key_package
            .tls_serialize_detached()
            .unwrap();
        assert!(
            SecureMeshMlsKeyPackage::from_public_bytes(&unwrapped_openmls_key_package).is_err()
        );
        let mut tampered = key_package.as_public_bytes().to_vec();
        tampered[0] ^= 0x01;
        assert!(SecureMeshMlsKeyPackage::from_public_bytes(&tampered).is_err());
    }

    #[test]
    fn secure_mesh_mls_active_payload_key_is_mlkem1024_epoch_hybrid() {
        let (alice, bob, alice_group, bob_group) =
            active_payload_group_pair(b"secure-mesh-group-mlkem1024-hybrid-test");
        let _alice_key = alice_group
            .derive_group_payload_content_key(&alice)
            .unwrap();
        let _bob_key = bob_group.derive_group_payload_content_key(&bob).unwrap();
        let extension = alice_group.mlkem1024_epoch_extension().unwrap();
        assert_eq!(extension.epoch, alice_group.epoch());
        assert_eq!(extension.recipients.len(), 2);
        assert_eq!(
            extension.recipients,
            bob_group.mlkem1024_epoch_extension().unwrap().recipients
        );
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
    fn secure_mesh_openmls_group_payload_wire_has_fixed_public_aad_and_private_full_context() {
        let (alice, bob, mut alice_group, mut bob_group) =
            active_payload_group_pair(b"secure-mesh-group-private-context-wire-test");
        let context = SecureMeshContentContext::new(
            "wire-envelope-private-canary",
            "wire-message-private-canary",
            "wire-mailbox-private-canary",
            "wire-sender-private-canary",
            "wire-recipient-private-canary",
            "wire-session-private-canary",
            "2032-05-06T07:08:09.000Z",
            "2032-05-06T07:18:09.000Z",
        );
        let plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::ServiceAction,
            b"wire-body-private-canary".as_slice(),
        )
        .with_content_type("application/x-wire-private-canary");

        let message = alice_group
            .seal_payload_message(&alice, &context, &plaintext)
            .unwrap();
        deserialize_protocol_message(
            &message,
            "secure mesh MLS private-context wire parse failed",
        )
        .unwrap();
        assert!(
            message
                .windows(SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD.len())
                .any(|window| window == SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD),
            "fixed versioned MLS application AAD must be present on the actual wire"
        );
        let business_canaries: [&[u8]; 12] = [
            context.envelope_id.as_bytes(),
            context.message_id.as_bytes(),
            context.opaque_mailbox_id.as_bytes(),
            context.sender_endpoint_id.as_bytes(),
            context.recipient_endpoint_id.as_bytes(),
            context.session_id.as_bytes(),
            context.created_at.as_bytes(),
            context.expires_at.as_bytes(),
            plaintext.kind.as_str().as_bytes(),
            plaintext.content_type.as_deref().unwrap().as_bytes(),
            plaintext.body.as_slice(),
            MLS_PRIVATE_CONTEXT_PAYLOAD_MAGIC,
        ];
        for canary in business_canaries {
            assert!(
                !message.windows(canary.len()).any(|window| window == canary),
                "MLS application wire exposed an encrypted inner-frame canary"
            );
        }

        let protocol_message = deserialize_protocol_message(
            &message,
            "secure mesh MLS private-context wire parse failed",
        )
        .unwrap();
        let processed = bob_group
            .group
            .process_message(&bob.provider, protocol_message)
            .unwrap();
        assert_eq!(
            processed.aad(),
            SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD,
            "OpenMLS authenticated_data must be fixed and business-free"
        );
        let encoded = match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(application_message) => {
                application_message.into_bytes()
            }
            _ => panic!("secure mesh MLS private-context wire was not application data"),
        };
        let sealed = decode_mls_private_context_payload(&encoded).unwrap();
        let content_key = bob_group.derive_group_payload_content_key(&bob).unwrap();
        let opened = open_private_context_payload(&content_key, &sealed).unwrap();
        let (opened_context, opened_payload) = opened.into_parts();
        assert_eq!(opened_context, context);
        assert_eq!(opened_payload.kind, plaintext.kind);
        assert_eq!(opened_payload.body, plaintext.body);
        assert_eq!(opened_payload.content_type, plaintext.content_type);
        assert_eq!(opened_payload.created_at, context.created_at);
        assert_eq!(opened_payload.expires_at, context.expires_at);
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
        let capability_commit =
            activate_test_payload_capabilities(&mut alice_group, &alice, &[&alice, &bob]);
        process_test_payload_capability_commit(&mut bob_group, &bob, &capability_commit);
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
            error
                .to_string()
                .contains("encrypted inner context mismatch")
        );
    }

    #[test]
    fn secure_mesh_openmls_group_payload_rejects_expected_kind_mismatch() {
        let (alice, bob, mut alice_group, mut bob_group) =
            active_payload_group_pair(b"secure-mesh-group-payload-kind-test");
        let context = content_context_fixture(
            "msg_group_payload_kind",
            "desktop_gui:alice",
            "mobile:bob",
            format!(
                "mls:{}:{}",
                alice_group.epoch(),
                "secure-mesh-group-payload-kind-test"
            ),
        );
        let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::Error, b"kind-private");
        let message = alice_group
            .seal_payload_message(&alice, &context, &plaintext)
            .unwrap();

        let error = bob_group
            .open_payload_message(&bob, &context, &message, SecureMeshPayloadKind::Command)
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("encrypted inner payload kind mismatch")
        );
    }

    #[test]
    fn secure_mesh_openmls_group_payload_rejects_authenticated_data_wire_tamper() {
        let (alice, bob, mut alice_group, mut bob_group) =
            active_payload_group_pair(b"secure-mesh-group-payload-public-aad-test");
        let context = content_context_fixture(
            "msg_group_payload_public_aad",
            "desktop_gui:alice",
            "mobile:bob",
            format!(
                "mls:{}:{}",
                alice_group.epoch(),
                "secure-mesh-group-payload-public-aad-test"
            ),
        );
        let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, b"aad-private");
        let mut message = alice_group
            .seal_payload_message(&alice, &context, &plaintext)
            .unwrap();
        let aad_offset = message
            .windows(SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD.len())
            .position(|window| window == SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD)
            .expect("fixed MLS authenticated_data must be serialized on the wire");
        message[aad_offset + SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD.len() - 1] ^= 0x01;
        deserialize_protocol_message(
            &message,
            "secure mesh MLS authenticated_data tamper must remain structurally parseable",
        )
        .unwrap();

        let error = bob_group
            .open_payload_message(&bob, &context, &message, SecureMeshPayloadKind::Command)
            .unwrap_err();
        assert!(
            error.to_string().contains("open failed")
                || error.to_string().contains("rejected")
                || error.to_string().contains("AAD mismatch")
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
    fn secure_mesh_openmls_secret_store_handle_reload_recovers_group_state() {
        let secret_store = test_secret_store();
        let secret_store_handle =
            test_secret_store_handle("secret-store-reload", MLS_EPOCH_SECRET_STORE_CLASS);
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
        bob.save_secret_store(secret_store.as_ref(), &secret_store_handle)
            .unwrap();
        let persisted_secret = secret_store
            .get_secret(&secret_store_handle)
            .unwrap()
            .unwrap();
        assert!(persisted_secret.contains(MLS_EPOCH_SECRET_STORE_CLASS));
        assert!(!persisted_secret.contains("secret-store-reloaded-open"));
        drop(bob_group);
        drop(bob);

        let reloaded_bob = SecureMeshMlsParticipant::load_from_secret_store(
            b"mobile:bob".to_vec(),
            &bob_signing_public_key,
            secret_store.as_ref(),
            &secret_store_handle,
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
        SecureMeshOpenMlsProvider::delete_secret_store(secret_store.as_ref(), &secret_store_handle)
            .unwrap();
        assert!(
            secret_store
                .get_secret(&secret_store_handle)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn secure_mesh_openmls_secret_store_recovery_preserves_authenticated_state() {
        let secret_store = test_secret_store();
        let secret_store_handle =
            test_secret_store_handle("authenticated-recovery", MLS_RECOVERY_SECRET_STORE_CLASS);
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:alice".to_vec()).unwrap();
        let bob = SecureMeshMlsParticipant::new(b"mobile:bob".to_vec()).unwrap();
        let bob_signing_public_key = bob.signing_public_key();
        let group_id = b"secure-mesh-authenticated-recovery-group";

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
        let capability_commit =
            activate_test_payload_capabilities(&mut alice_group, &alice, &[&alice, &bob]);
        process_test_payload_capability_commit(&mut bob_group, &bob, &capability_commit);
        let update_commit = alice_group.self_update(&alice).unwrap();
        deserialize_protocol_message(
            &update_commit,
            "secure mesh MLS interop vector update parse failed",
        )
        .unwrap();
        bob_group.process_commit(&bob, &update_commit).unwrap();
        let recovered_epoch = bob_group.epoch();
        let secret_store_session = secret_store
            .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                "Secure Mesh MLS authenticated recovery secret-store authorization batch",
                2,
            ))
            .unwrap();
        bob.save_recovery_secret_store_with_session(
            secret_store.as_ref(),
            &secret_store_handle,
            &secret_store_session,
        )
        .unwrap();
        drop(bob_group);
        drop(bob);

        let reloaded_bob = SecureMeshMlsParticipant::load_from_secret_store_with_optional_session(
            b"mobile:bob".to_vec(),
            &bob_signing_public_key,
            secret_store.as_ref(),
            &secret_store_handle,
            Some(&secret_store_session),
        )
        .unwrap();
        let mut reloaded_bob_group =
            SecureMeshMlsGroup::load_from_provider(&reloaded_bob, group_id).unwrap();
        assert_eq!(reloaded_bob_group.epoch(), recovered_epoch);

        let context = content_context_fixture(
            "msg_mls_authenticated_recovery",
            "desktop_gui:alice",
            "mobile:bob",
            format!("mls:{recovered_epoch}:secure-mesh-authenticated-recovery-group"),
        );
        let body =
            br#"{"op":"secure_mesh.group.commit","canary":"mls-authenticated-recovery-secret"}"#;
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
                .windows(b"mls-authenticated-recovery-secret".len())
                .any(|window| window == b"mls-authenticated-recovery-secret")
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
                    .windows(b"mls-authenticated-recovery-secret".len())
                    .any(|window| window == b"mls-authenticated-recovery-secret"),
                "{label} artifact leaked plaintext canary"
            );
        }
        SecureMeshOpenMlsProvider::delete_secret_store(secret_store.as_ref(), &secret_store_handle)
            .unwrap();
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

    #[cfg(unix)]
    #[test]
    fn secure_mesh_mls_durable_store_applies_private_file_mode() {
        let store_path = durable_store_path("private-file-mode");
        let _ = std::fs::remove_file(&store_path);

        let store = SecureMeshMlsDurableStore::open(&store_path).unwrap();
        drop(store);

        let mode = std::fs::metadata(&store_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let _ = std::fs::remove_file(&store_path);
    }

    #[test]
    fn secure_mesh_mls_old_public_state_schema_requires_authenticated_snapshot_reconciliation() {
        let store_path = durable_store_path("authenticated-schema-reconciliation");
        let _ = std::fs::remove_file(&store_path);
        let alice = SecureMeshMlsParticipant::new(b"desktop_gui:schema-alice".to_vec()).unwrap();
        let matching_group = SecureMeshMlsGroup::create(&alice, b"schema-matching-group").unwrap();
        let divergent_group =
            SecureMeshMlsGroup::create(&alice, b"schema-divergent-group").unwrap();
        let matching = matching_group
            .public_metadata("desktop_gui:schema-alice")
            .unwrap();
        let divergent = divergent_group
            .public_metadata("desktop_gui:schema-alice")
            .unwrap();

        let connection = Connection::open(&store_path).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE secure_mesh_mls_group_state (
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
                "#,
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO secure_mesh_mls_group_state (
                    group_id_hash, participant_endpoint_id, epoch, state_version,
                    member_count, own_leaf_index, active, revoked_at_epoch, updated_at
                ) VALUES (?1, ?2, ?3, 4, ?4, ?5, ?6, NULL, '2026-06-26T00:03:00Z')
                "#,
                params![
                    matching.group_id_hash,
                    matching.participant_endpoint_id,
                    matching.epoch as i64,
                    matching.member_count as i64,
                    matching.own_leaf_index as i64,
                    i64::from(matching.active),
                ],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO secure_mesh_mls_group_state (
                    group_id_hash, participant_endpoint_id, epoch, state_version,
                    member_count, own_leaf_index, active, revoked_at_epoch, updated_at
                ) VALUES (?1, ?2, ?3, 9, ?4, ?5, ?6, NULL, '2026-06-26T00:03:01Z')
                "#,
                params![
                    divergent.group_id_hash,
                    divergent.participant_endpoint_id,
                    divergent.epoch.saturating_add(1) as i64,
                    divergent.member_count as i64,
                    divergent.own_leaf_index as i64,
                    i64::from(divergent.active),
                ],
            )
            .unwrap();
        drop(connection);

        let mut store = SecureMeshMlsDurableStore::open(&store_path).unwrap();
        let pending = store
            .read(&matching.group_id_hash, &matching.participant_endpoint_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            pending.public_state_digest,
            MLS_PUBLIC_STATE_DIGEST_AUTHENTICATED_BACKFILL
        );
        let reconciled = store
            .reconcile_authenticated_snapshot(&matching, "2026-06-26T00:03:02Z")
            .unwrap();
        assert_eq!(reconciled.public_state_digest, matching.public_state_digest);
        assert_eq!(reconciled.state_version, 5);

        let error = store
            .reconcile_authenticated_snapshot(&divergent, "2026-06-26T00:03:03Z")
            .unwrap_err();
        assert!(error.to_string().contains("cannot authenticate"));
        let still_pending = store
            .read(&divergent.group_id_hash, &divergent.participant_endpoint_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            still_pending.public_state_digest,
            MLS_PUBLIC_STATE_DIGEST_AUTHENTICATED_BACKFILL
        );
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
        assert!(
            rollback_error
                .to_string()
                .contains("must strictly advance the epoch")
        );

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
