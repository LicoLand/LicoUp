use anyhow::{Result, anyhow};
use uuid::Uuid;

use crate::core::secure_mesh_secret_store::{
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession, SecretStoreHandle,
    SecureMeshSecretStore,
};

pub struct SecretClassPersistenceProof {
    pub backend: &'static str,
    pub secret_classes: Vec<String>,
    pub requested_class_count: usize,
    pub persisted_class_count: usize,
    pub deleted_class_count: usize,
    pub all_classes_persisted: bool,
    pub all_classes_deleted: bool,
    pub raw_secret_material_included: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct PlatformSecretStore {
    pub(super) service: &'static str,
    pub(super) account_prefix: &'static str,
}

impl PlatformSecretStore {
    pub const fn new(service: &'static str, account_prefix: &'static str) -> Self {
        Self {
            service,
            account_prefix,
        }
    }

    pub fn handle_for_namespace(
        &self,
        namespace: impl Into<String>,
        key: impl Into<String>,
    ) -> Result<SecretStoreHandle> {
        SecretStoreHandle::new(format!("{}:{}", self.account_prefix, namespace.into()), key)
    }

    pub fn verify_secret_class_persistence(
        &self,
        namespace: impl Into<String>,
        secret_classes: &[&str],
    ) -> Result<SecretClassPersistenceProof> {
        if !self.supported() {
            return Err(anyhow!(
                "secure mesh native secret store unsupported for shared secret class proof"
            ));
        }
        let namespace = namespace.into();
        let session = self.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
            "Secure Mesh shared secret class persistence proof",
            secret_classes.len().saturating_mul(4),
        ))?;
        self.verify_secret_class_persistence_with_session(&session, namespace, secret_classes)
    }

    pub fn verify_secret_class_persistence_with_session(
        &self,
        session: &SecretStoreAuthorizationSession,
        namespace: impl Into<String>,
        secret_classes: &[&str],
    ) -> Result<SecretClassPersistenceProof> {
        let namespace = namespace.into();
        let mut persisted_class_count = 0usize;
        let mut deleted_class_count = 0usize;
        let mut handles = Vec::new();
        for secret_class in secret_classes {
            let handle = self.handle_for_namespace(&namespace, *secret_class)?;
            let proof_secret = format!(
                "secure-mesh-secret-store-proof:{}:{}",
                secret_class,
                Uuid::new_v4()
            );
            self.set_secret_with_session(session, &handle, &proof_secret)?;
            if self.get_secret_with_session(session, &handle)?.as_deref()
                == Some(proof_secret.as_str())
            {
                persisted_class_count += 1;
            }
            handles.push(handle);
        }
        for handle in &handles {
            self.delete_secret_with_session(session, handle)?;
            if self.get_secret_with_session(session, handle)?.is_none() {
                deleted_class_count += 1;
            }
        }
        Ok(SecretClassPersistenceProof {
            backend: self.backend(),
            secret_classes: secret_classes
                .iter()
                .map(|secret_class| (*secret_class).to_string())
                .collect(),
            requested_class_count: secret_classes.len(),
            persisted_class_count,
            deleted_class_count,
            all_classes_persisted: persisted_class_count == secret_classes.len(),
            all_classes_deleted: deleted_class_count == secret_classes.len(),
            raw_secret_material_included: false,
        })
    }
}
