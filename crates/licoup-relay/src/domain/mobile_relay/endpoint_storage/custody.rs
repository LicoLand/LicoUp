//! Purpose-checked key custody over the selected platform secret store.
//!
//! [`EndpointV7Custody`] implements the pinned SDK's own `KeyCustody` contract.
//! Every operation looks a token up in the durable registry and checks purpose,
//! lifecycle, and class before touching material; the marker type on a handle
//! is never taken as proof that the token is authorised. Material bytes only
//! exist inside this module for the duration of one provider call and are
//! zeroized afterwards; nothing here exports private material.
//!
//! The cryptographic operations themselves are the pinned SDK provider's
//! (`licoup_protocol_bindings::provider::RustCryptoProvider`). This module adds
//! no cryptography of its own.
//!
//! # Lifecycles
//!
//! * `staged` — issued by this module, still tentative. A staged token can be
//!   read for public-key derivation and encapsulated against, but cannot sign
//!   and cannot be used as a ratchet handle.
//! * `adopted` — committed by an SDK `KeyMutation::Adopt*`, so it is usable.
//! * `fenced` — an adopted session token whose session did not survive a
//!   process restart. It can never be used again, by any session.
//! * deleted — the registry row is gone and a tombstone prevents the token from
//!   ever being reissued.
//!
//! Device identity tokens are the exception: they are root-stable, adopted for
//! the life of the root, and are only removed by an explicit root revocation.

use std::sync::{Arc, Mutex, MutexGuard};

use licoup_protocol_bindings::Error;
use licoup_protocol_bindings::endpoint::IdentitySigningHandles;
use licoup_protocol_bindings::provider::{
    AgreementProvider, RustCryptoProvider, SignatureProvider,
};
use licoup_protocol_bindings::state::{
    CustodyRef, Ed25519Signing, KeyCustody, MlDsa65Signing, MlKem768Private,
    MlKemEncapsulationEntropy, SecretHandle, StagedSecretHandle, X25519Private,
};
use rusqlite::params;
use zeroize::Zeroize;

// The platform secret store is secure-mesh custody and lives in
// `licoup-secure-mesh`; this crate reaches it at that crate's path.
use licoup_secure_mesh::core::secure_mesh_secret_store::SecretBytes;
use crate::state_machines::security_custody_lifecycle::{
    self, Event as CustodyEvent, State as CustodyState,
};

use super::refusal::{EndpointV7StorageError, continuity_lost_sdk, provider_refusal, revoked_sdk};
use super::root::{
    CustodyRow, IDENTITY_ED25519_TOKEN, IDENTITY_ML_DSA_65_TOKEN, Inner, issue_token,
    read_custody_rows, taint_custody_row,
};
use super::store::{
    PURPOSE_ED25519, PURPOSE_ML_DSA_65, PURPOSE_ML_KEM_768, PURPOSE_ML_KEM_ENTROPY, PURPOSE_X25519,
};

/// The public halves of the installed device identity: the Ed25519 public key
/// and the ML-DSA-65 public key.
pub type EndpointV7IdentityPublicKeys = ([u8; 32], Vec<u8>);

/// The custody handle handed to the pinned SDK endpoint.
pub struct EndpointV7Custody {
    inner: Arc<Mutex<Inner>>,
}

impl EndpointV7Custody {
    pub(crate) fn new(inner: Arc<Mutex<Inner>>) -> Self {
        Self { inner }
    }

    /// Installs the device identity seeds once per root.
    ///
    /// Idempotent for the same material; a different material is refused until
    /// the root is revoked, so a replaced identity cannot silently continue an
    /// existing root.
    pub fn install_device_identity(
        &self,
        ed25519_seed: [u8; 32],
        ml_dsa_65_seed: [u8; 32],
    ) -> Result<IdentitySigningHandles, EndpointV7StorageError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        if inner.revoked {
            return Err(EndpointV7StorageError::new(EndpointV7StorageError::REVOKED));
        }
        let ed_key = identity_material_key(&inner.root_id, "ed25519");
        let ml_key = identity_material_key(&inner.root_id, "ml-dsa-65");
        let existing_ed = inner.read_material(&ed_key).map_err(|_| {
            EndpointV7StorageError::new(EndpointV7StorageError::MATERIAL_UNAVAILABLE)
        })?;
        let existing_ml = inner.read_material(&ml_key).map_err(|_| {
            EndpointV7StorageError::new(EndpointV7StorageError::MATERIAL_UNAVAILABLE)
        })?;
        match (existing_ed, existing_ml) {
            (Some(ed), Some(ml)) => {
                if ed.expose_bytes() == ed25519_seed && ml.expose_bytes() == ml_dsa_65_seed {
                    return Ok(identity_handles());
                }
                return Err(EndpointV7StorageError::new(
                    EndpointV7StorageError::CUSTODY_REFUSED,
                ));
            }
            (None, None) => {}
            _ => {
                // A half-installed identity from an interrupted install is
                // never completed implicitly.
                return Err(EndpointV7StorageError::new(
                    EndpointV7StorageError::CUSTODY_REFUSED,
                ));
            }
        }
        inner
            .write_material(&ed_key, bytes_of(&ed25519_seed))
            .map_err(|_| {
                EndpointV7StorageError::new(EndpointV7StorageError::MATERIAL_UNAVAILABLE)
            })?;
        if inner
            .write_material(&ml_key, bytes_of(&ml_dsa_65_seed))
            .is_err()
        {
            inner.delete_material(&ed_key);
            return Err(EndpointV7StorageError::new(
                EndpointV7StorageError::MATERIAL_UNAVAILABLE,
            ));
        }
        let write: Result<(), rusqlite::Error> = (|| {
            let epoch = inner.epoch;
            let root_id = inner.root_id.clone();
            let adopted = security_custody_lifecycle::transition(
                security_custody_lifecycle::INITIAL,
                CustodyEvent::Adopt,
            )
            .ok_or(rusqlite::Error::InvalidQuery)?;
            let transaction = inner.conn.transaction()?;
            for (token, purpose, label) in [
                (IDENTITY_ED25519_TOKEN, PURPOSE_ED25519, "ed25519"),
                (IDENTITY_ML_DSA_65_TOKEN, PURPOSE_ML_DSA_65, "ml-dsa-65"),
            ] {
                transaction.execute(
                    "INSERT OR REPLACE INTO endpoint_v7_custody
                     (token, purpose, lifecycle, class, material_key, epoch)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        token.to_string(),
                        purpose,
                        adopted.as_str(),
                        CustodyRow::IDENTITY,
                        identity_material_key(&root_id, label),
                        epoch as i64
                    ],
                )?;
            }
            transaction.commit()
        })();
        if write.is_err() {
            inner.delete_material(&ed_key);
            inner.delete_material(&ml_key);
            return Err(EndpointV7StorageError::new(
                EndpointV7StorageError::COMMIT_REFUSED,
            ));
        }
        Ok(identity_handles())
    }

    /// The installed device identity handles, when present.
    pub fn device_identity_handles(
        &self,
    ) -> Result<Option<IdentitySigningHandles>, EndpointV7StorageError> {
        let inner = self
            .inner
            .lock()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        if inner.revoked {
            return Err(EndpointV7StorageError::new(EndpointV7StorageError::REVOKED));
        }
        Ok(identity_row_present(&inner, IDENTITY_ED25519_TOKEN)?.then(identity_handles))
    }

    /// The public halves of the installed device identity, so the caller can
    /// bind its own identity labels to them.
    pub fn device_identity_public_keys(
        &self,
    ) -> Result<Option<EndpointV7IdentityPublicKeys>, EndpointV7StorageError> {
        let provider = RustCryptoProvider;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        if !identity_row_present(&inner, IDENTITY_ED25519_TOKEN)? {
            return Ok(None);
        }
        let mut ed = seed_32(&mut inner, IDENTITY_ED25519_TOKEN, PURPOSE_ED25519)?;
        let mut ml = seed_32(&mut inner, IDENTITY_ML_DSA_65_TOKEN, PURPOSE_ML_DSA_65)?;
        let public = (provider.ed25519_public(&ed), provider.ml_dsa_65_public(&ml));
        ed.zeroize();
        ml.zeroize();
        Ok(Some(public))
    }

    /// Issues one tentative X25519 private handle.
    ///
    /// The token is durable before the material is written; a crash between the
    /// two leaves a staged row without material, which open aborts and which
    /// can never be adopted.
    pub fn stage_x25519(
        &self,
        private: [u8; 32],
    ) -> Result<StagedSecretHandle<X25519Private>, EndpointV7StorageError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        let token = stage_row(&mut inner, PURPOSE_X25519)?;
        let material_key = session_material_key(&inner.root_id, token);
        if inner
            .write_material(&material_key, bytes_of(&private))
            .is_err()
        {
            forget_row(&mut inner, token);
            return Err(EndpointV7StorageError::new(
                EndpointV7StorageError::MATERIAL_UNAVAILABLE,
            ));
        }
        Ok(StagedSecretHandle::from_custody_token(token))
    }

    /// Issues one tentative ML-KEM-768 private handle.
    pub fn stage_ml_kem_768(
        &self,
        seed: [u8; 64],
    ) -> Result<StagedSecretHandle<MlKem768Private>, EndpointV7StorageError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        let token = stage_row(&mut inner, PURPOSE_ML_KEM_768)?;
        let material_key = session_material_key(&inner.root_id, token);
        if inner
            .write_material(&material_key, bytes_of(&seed))
            .is_err()
        {
            forget_row(&mut inner, token);
            return Err(EndpointV7StorageError::new(
                EndpointV7StorageError::MATERIAL_UNAVAILABLE,
            ));
        }
        Ok(StagedSecretHandle::from_custody_token(token))
    }

    /// Issues one adopted encapsulation-entropy handle.
    ///
    /// The pinned SDK consumes this object immediately for one encapsulation
    /// and deletes it through a key mutation, so it is adopted on issue.
    pub fn adopted_encapsulation_entropy(
        &self,
        entropy: [u8; 32],
    ) -> Result<SecretHandle<MlKemEncapsulationEntropy>, EndpointV7StorageError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        let token = adopted_row(&mut inner, PURPOSE_ML_KEM_ENTROPY)?;
        let material_key = session_material_key(&inner.root_id, token);
        if inner
            .write_material(&material_key, bytes_of(&entropy))
            .is_err()
        {
            forget_row(&mut inner, token);
            return Err(EndpointV7StorageError::new(
                EndpointV7StorageError::MATERIAL_UNAVAILABLE,
            ));
        }
        Ok(SecretHandle::from_custody_token(token))
    }
}

impl KeyCustody for EndpointV7Custody {
    fn ed25519_public(&self, handle: &SecretHandle<Ed25519Signing>) -> Result<[u8; 32], Error> {
        let mut seed = self.adopted_seed_32(handle.custody_token(), PURPOSE_ED25519)?;
        let public = RustCryptoProvider.ed25519_public(&seed);
        seed.zeroize();
        Ok(public)
    }

    fn ed25519_sign(
        &self,
        handle: &SecretHandle<Ed25519Signing>,
        message: &[u8],
    ) -> Result<[u8; 64], Error> {
        let mut seed = self.adopted_seed_32(handle.custody_token(), PURPOSE_ED25519)?;
        let signature = RustCryptoProvider.ed25519_sign(&seed, message);
        seed.zeroize();
        Ok(signature)
    }

    fn ml_dsa_65_public(&self, handle: &SecretHandle<MlDsa65Signing>) -> Result<Vec<u8>, Error> {
        let mut seed = self.adopted_seed_32(handle.custody_token(), PURPOSE_ML_DSA_65)?;
        let public = RustCryptoProvider.ml_dsa_65_public(&seed);
        seed.zeroize();
        Ok(public)
    }

    fn ml_dsa_65_sign(
        &self,
        handle: &SecretHandle<MlDsa65Signing>,
        message: &[u8],
    ) -> Result<Vec<u8>, Error> {
        let mut seed = self.adopted_seed_32(handle.custody_token(), PURPOSE_ML_DSA_65)?;
        let signature = RustCryptoProvider.ml_dsa_65_sign(&seed, message);
        seed.zeroize();
        Ok(signature)
    }

    fn x25519_public(&self, handle: CustodyRef<'_, X25519Private>) -> Result<[u8; 32], Error> {
        let mut private = self.x25519_private(handle)?;
        let public = RustCryptoProvider.x25519_public(&private);
        private.zeroize();
        Ok(public)
    }

    fn x25519(
        &self,
        handle: CustodyRef<'_, X25519Private>,
        public: &[u8; 32],
    ) -> Result<[u8; 32], Error> {
        let mut private = self.x25519_private(handle)?;
        let shared = RustCryptoProvider.x25519(&private, public);
        private.zeroize();
        shared
    }

    fn ml_kem_768_public(&self, handle: CustodyRef<'_, MlKem768Private>) -> Result<Vec<u8>, Error> {
        let mut seed = self.ml_kem_768_seed(handle)?;
        let public = RustCryptoProvider.ml_kem_768_public(&seed);
        seed.zeroize();
        Ok(public)
    }

    fn ml_kem_768_encapsulate(
        &self,
        public: &[u8],
        entropy: &SecretHandle<MlKemEncapsulationEntropy>,
    ) -> Result<(Vec<u8>, [u8; 32]), Error> {
        let mut inner = self.lock()?;
        let mut seed = seed_32(&mut inner, entropy.custody_token(), PURPOSE_ML_KEM_ENTROPY)?;
        let result = RustCryptoProvider.ml_kem_768_encapsulate(public, &seed);
        seed.zeroize();
        result
    }

    fn ml_kem_768_decapsulate(
        &self,
        handle: &SecretHandle<MlKem768Private>,
        ciphertext: &[u8],
    ) -> Result<[u8; 32], Error> {
        let mut inner = self.lock()?;
        let mut seed = seed_64(&mut inner, handle.custody_token(), PURPOSE_ML_KEM_768)?;
        let shared = RustCryptoProvider.ml_kem_768_decapsulate(&seed, ciphertext);
        seed.zeroize();
        shared
    }

    fn abort_x25519(&mut self, staged: &StagedSecretHandle<X25519Private>) {
        let _ = self
            .inner
            .lock()
            .map(|mut inner| abort_row(&mut inner, staged.custody_token(), PURPOSE_X25519));
    }

    fn abort_ml_kem_768(&mut self, staged: &StagedSecretHandle<MlKem768Private>) {
        let _ = self
            .inner
            .lock()
            .map(|mut inner| abort_row(&mut inner, staged.custody_token(), PURPOSE_ML_KEM_768));
    }
}

impl EndpointV7Custody {
    fn lock(&self) -> Result<MutexGuard<'_, Inner>, Error> {
        self.inner.lock().map_err(|_| provider_refusal())
    }

    fn adopted_seed_32(&self, token: u128, purpose: &str) -> Result<[u8; 32], Error> {
        let mut inner = self.lock()?;
        seed_32(&mut inner, token, purpose)
    }

    fn x25519_private(&self, handle: CustodyRef<'_, X25519Private>) -> Result<[u8; 32], Error> {
        let (token, lifecycle) = match handle {
            CustodyRef::Adopted(handle) => (handle.custody_token(), CustodyRow::ADOPTED),
            CustodyRef::Staged(handle) => (handle.custody_token(), CustodyRow::STAGED),
        };
        let mut inner = self.lock()?;
        let material = material_of(&mut inner, token, PURPOSE_X25519, lifecycle)?;
        let mut private = [0_u8; 32];
        private.copy_from_slice(material.expose_bytes());
        Ok(private)
    }

    fn ml_kem_768_seed(&self, handle: CustodyRef<'_, MlKem768Private>) -> Result<[u8; 64], Error> {
        let (token, lifecycle) = match handle {
            CustodyRef::Adopted(handle) => (handle.custody_token(), CustodyRow::ADOPTED),
            CustodyRef::Staged(handle) => (handle.custody_token(), CustodyRow::STAGED),
        };
        let mut inner = self.lock()?;
        let material = material_of(&mut inner, token, PURPOSE_ML_KEM_768, lifecycle)?;
        let mut seed = [0_u8; 64];
        seed.copy_from_slice(material.expose_bytes());
        Ok(seed)
    }
}

/// Looks one token up by purpose and lifecycle and returns its material.
fn material_of(
    inner: &mut Inner,
    token: u128,
    purpose: &str,
    lifecycle: &str,
) -> Result<SecretBytes, Error> {
    if inner.revoked {
        return Err(revoked_sdk());
    }
    if !inner.continuity.loadable() {
        return Err(continuity_lost_sdk());
    }
    let rows = read_custody_rows(&inner.conn).map_err(|_| provider_refusal())?;
    let row = rows
        .iter()
        .find(|row| row.token == token && row.purpose == purpose && row.lifecycle == lifecycle)
        .ok_or_else(provider_refusal)?;
    inner
        .read_material(&row.material_key)
        .map_err(|_| provider_refusal())?
        .ok_or_else(provider_refusal)
}

fn seed_32(inner: &mut Inner, token: u128, purpose: &str) -> Result<[u8; 32], Error> {
    let material = material_of(inner, token, purpose, CustodyRow::ADOPTED)?;
    let mut seed = [0_u8; 32];
    seed.copy_from_slice(material.expose_bytes());
    Ok(seed)
}

fn seed_64(inner: &mut Inner, token: u128, purpose: &str) -> Result<[u8; 64], Error> {
    let material = material_of(inner, token, purpose, CustodyRow::ADOPTED)?;
    let mut seed = [0_u8; 64];
    seed.copy_from_slice(material.expose_bytes());
    Ok(seed)
}

fn stage_row(inner: &mut Inner, purpose: &str) -> Result<u128, EndpointV7StorageError> {
    insert_row(
        inner,
        purpose,
        security_custody_lifecycle::INITIAL,
        CustodyRow::SESSION,
    )
}

fn adopted_row(inner: &mut Inner, purpose: &str) -> Result<u128, EndpointV7StorageError> {
    let adopted = security_custody_lifecycle::transition(
        security_custody_lifecycle::INITIAL,
        CustodyEvent::Adopt,
    )
    .ok_or_else(|| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
    insert_row(inner, purpose, adopted, CustodyRow::SESSION)
}

fn insert_row(
    inner: &mut Inner,
    purpose: &str,
    lifecycle: CustodyState,
    class: &str,
) -> Result<u128, EndpointV7StorageError> {
    if inner.revoked {
        return Err(EndpointV7StorageError::new(EndpointV7StorageError::REVOKED));
    }
    if !inner.continuity.loadable() {
        return Err(EndpointV7StorageError::new(
            EndpointV7StorageError::CONTINUITY_LOST,
        ));
    }
    let write: Result<u128, rusqlite::Error> = (|| {
        let epoch = inner.epoch;
        let root_id = inner.root_id.clone();
        let transaction = inner.conn.transaction()?;
        let token = issue_token(&transaction).map_err(|_| rusqlite::Error::InvalidQuery)?;
        transaction.execute(
            "INSERT INTO endpoint_v7_custody (token, purpose, lifecycle, class, material_key, epoch)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                token.to_string(),
                purpose,
                lifecycle.as_str(),
                class,
                session_material_key(&root_id, token),
                epoch as i64
            ],
        )?;
        transaction.commit()?;
        Ok(token)
    })();
    write.map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))
}

fn forget_row(inner: &mut Inner, token: u128) {
    let Ok(rows) = read_custody_rows(&inner.conn) else {
        return;
    };
    let Some(row) = rows.iter().find(|row| row.token == token) else {
        return;
    };
    let Some(source) = CustodyState::from_name(&row.lifecycle) else {
        return;
    };
    let Some(target) = security_custody_lifecycle::transition(source, CustodyEvent::Abort) else {
        return;
    };
    let row = row.clone();
    let epoch = inner.epoch;
    let write = (|| {
        let transaction = inner
            .conn
            .transaction()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
        taint_custody_row(
            &transaction,
            &row,
            target,
            epoch,
            EndpointV7StorageError::COMMIT_REFUSED,
        )?;
        transaction
            .commit()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))
    })();
    if write.is_ok() {
        inner.flush_material_deletes();
    }
}

/// Aborts one staged token: the durable row is tombstoned and removed, then the
/// physical deletion is attempted and retried by the next open.
fn abort_row(inner: &mut Inner, token: u128, purpose: &str) {
    let Ok(rows) = read_custody_rows(&inner.conn) else {
        return;
    };
    let Some(row) = rows
        .iter()
        .find(|row| row.token == token && row.purpose == purpose)
    else {
        // An adopted object is never abortable; matching the SDK contract, a
        // mismatched token is a no-op.
        return;
    };
    let Some(source) = CustodyState::from_name(&row.lifecycle) else {
        return;
    };
    let Some(target) = security_custody_lifecycle::transition(source, CustodyEvent::Abort) else {
        return;
    };
    let epoch = inner.epoch;
    let row = row.clone();
    let write = (|| {
        let transaction = inner
            .conn
            .transaction()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
        taint_custody_row(
            &transaction,
            &row,
            target,
            epoch,
            EndpointV7StorageError::COMMIT_REFUSED,
        )?;
        transaction
            .commit()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))
    })();
    if write.is_ok() {
        inner.flush_material_deletes();
    }
}

fn identity_row_present(inner: &Inner, token: u128) -> Result<bool, EndpointV7StorageError> {
    let rows = read_custody_rows(&inner.conn)?;
    Ok(rows.iter().any(|row| {
        row.token == token
            && row.class == CustodyRow::IDENTITY
            && row.lifecycle == CustodyRow::ADOPTED
    }))
}

fn identity_handles() -> IdentitySigningHandles {
    IdentitySigningHandles {
        ed25519: SecretHandle::from_custody_token(IDENTITY_ED25519_TOKEN),
        ml_dsa_65: SecretHandle::from_custody_token(IDENTITY_ML_DSA_65_TOKEN),
    }
}

fn session_material_key(root_id: &str, token: u128) -> String {
    format!("{root_id}/session/{token}")
}

fn identity_material_key(root_id: &str, purpose: &str) -> String {
    format!("{root_id}/identity/{purpose}")
}

fn bytes_of(seed: &[u8]) -> SecretBytes {
    SecretBytes::try_from_bytes(seed.to_vec()).expect("fixed-size key material is always bounded")
}
