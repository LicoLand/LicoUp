use anyhow::{Result, anyhow, ensure};
use openmls::prelude::{BasicCredential, CredentialWithKey, Extensions, KeyPackage};
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::OpenMlsProvider;
use zeroize::Zeroize;

use crate::core::secure_mesh_secret_store::{
    SecretStoreAuthorizationSession, SecretStoreHandle, SecureMeshSecretStore,
};

use super::capability_extension::secure_mesh_mls_leaf_capabilities;
use super::config::secure_mesh_mls_ciphersuite;
use super::constants::MLS_EPOCH_SECRET_STORE_CLASS;
#[cfg(test)]
use super::constants::MLS_RECOVERY_SECRET_STORE_CLASS;
use super::key_package::SecureMeshMlsKeyPackage;
use super::provider::SecureMeshOpenMlsProvider;

pub struct SecureMeshMlsParticipant {
    pub(super) provider: SecureMeshOpenMlsProvider,
    pub(super) credential_with_key: CredentialWithKey,
    pub(super) signer: SignatureKeyPair,
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
    pub(super) fn save_recovery_secret_store_with_session(
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
