//! The caller-owned durable state backend for one pinned-SDK endpoint.
//!
//! [`EndpointV7StateStore`] implements the SDK's own `AtomicState<EndpointState>`
//! contract. One commit applies the next complete snapshot, the pending-output
//! set, and every bounded handle adoption/deletion in a single SQLite
//! transaction that advances the generation by exactly one, or applies
//! nothing. There is no internal retry: the SDK resolves an uncertain result
//! from stored revision/state itself.
//!
//! # Why a pending record carries a fingerprint
//!
//! The pinned SDK's [`PendingId`] is deliberately opaque: it exposes
//! `from_token` but no token accessor, so a caller cannot read back the
//! content-derived protocol identity. This backend therefore keys durable
//! pending rows by a deterministic in-build fingerprint of the SDK value. The
//! fingerprint is content-opaque and only used to address and settle the exact
//! committed record; the record's protocol identity stays inside its payload
//! bytes, and a recovered record is re-driven or discarded byte-for-byte, never
//! re-minted.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, MutexGuard};

use licoup_protocol_bindings::endpoint::EndpointState;
use licoup_protocol_bindings::state::{
    AtomicState, Commit, KeyMutation, PendingId, PendingItem, PendingKind, Revision, Versioned,
};
use licoup_protocol_bindings::{Error, ErrorCode, Stage};
use rusqlite::params;

use crate::state_machines::security_custody_lifecycle::{
    self, Event as CustodyEvent, State as CustodyState,
};

use super::refusal::{commit_conflict, continuity_lost_sdk, provider_refusal, revoked_sdk};
use super::root::{
    CustodyRow, Inner, MAX_COMMIT_KEY_MUTATIONS, MAX_COMMIT_PENDING, META_GENERATION,
    read_custody_rows, taint_custody_row,
};

/// Largest pending set this backend will rebuild for a settlement. The SDK
/// bounds its own commits, so this is a defensive ceiling, not a policy.
const MAX_PENDING_SET: usize = 64;

/// Purpose strings shared with the custody registry.
pub(crate) const PURPOSE_X25519: &str = "x25519-private";
pub(crate) const PURPOSE_ML_KEM_768: &str = "ml-kem-768-private";
pub(crate) const PURPOSE_ML_KEM_ENTROPY: &str = "ml-kem-encapsulation-entropy";
pub(crate) const PURPOSE_ED25519: &str = "ed25519-signing";
pub(crate) const PURPOSE_ML_DSA_65: &str = "ml-dsa-65-signing";

/// The durable store handle handed to the pinned SDK endpoint.
pub struct EndpointV7StateStore {
    inner: Arc<Mutex<Inner>>,
}

impl EndpointV7StateStore {
    pub(crate) fn new(inner: Arc<Mutex<Inner>>) -> Self {
        Self { inner }
    }

    fn lock(&self) -> Result<MutexGuard<'_, Inner>, Error> {
        self.inner.lock().map_err(|_| provider_refusal())
    }
}

impl AtomicState<EndpointState> for EndpointV7StateStore {
    fn load(&self) -> Result<Versioned<EndpointState>, Error> {
        let inner = self.lock()?;
        if inner.revoked {
            return Err(revoked_sdk());
        }
        if !inner.continuity.loadable() {
            return Err(continuity_lost_sdk());
        }
        Ok(inner.versioned.clone())
    }

    fn compare_and_swap(
        &mut self,
        expected: Revision,
        commit: Commit<EndpointState>,
    ) -> Result<Revision, Error> {
        let mut inner = self.lock()?;
        if inner.revoked {
            return Err(revoked_sdk());
        }
        if !inner.continuity.loadable() {
            return Err(continuity_lost_sdk());
        }
        if expected.value() != inner.generation {
            return Err(commit_conflict());
        }
        // Bound-check before any durable work, so a bound failure leaves the
        // complete old value untouched.
        let successor = expected.successor()?;
        let mutations = commit.key_mutations().to_vec();
        let pending = commit.pending().to_vec();
        if mutations.len() > MAX_COMMIT_KEY_MUTATIONS || pending.len() > MAX_COMMIT_PENDING {
            return Err(provider_refusal());
        }

        let rows = read_custody_rows(&inner.conn).map_err(|_| provider_refusal())?;
        let mut custody_mutations = Vec::with_capacity(mutations.len());
        for mutation in &mutations {
            let row = match_custody_row(&rows, mutation)?;
            let source = custody_state(&row.lifecycle).ok_or_else(provider_refusal)?;
            let event = match mutation {
                KeyMutation::AdoptX25519(_) | KeyMutation::AdoptMlKem768(_) => {
                    let material = inner
                        .read_material(&row.material_key)
                        .map_err(|_| provider_refusal())?;
                    if material.is_none() {
                        return Err(provider_refusal());
                    }
                    CustodyEvent::Adopt
                }
                KeyMutation::DeleteX25519(_)
                | KeyMutation::DeleteMlKem768(_)
                | KeyMutation::DeleteMlKemEncapsulationEntropy(_) => CustodyEvent::Delete,
            };
            let target = security_custody_lifecycle::transition(source, event)
                .ok_or_else(provider_refusal)?;
            custody_mutations.push((row.clone(), source, target));
        }

        let epoch = inner.epoch;
        let generation = successor.value();
        let write: Result<(), rusqlite::Error> = (|| {
            let transaction = inner.conn.transaction()?;
            transaction.execute("DELETE FROM endpoint_v7_pending", [])?;
            for item in &pending {
                transaction.execute(
                    "INSERT INTO endpoint_v7_pending (pending_id, kind, payload)
                     VALUES (?1, ?2, ?3)",
                    params![
                        pending_fingerprint(item.id()).to_string(),
                        pending_kind_name(item.kind()),
                        pending_payload(item.kind())
                    ],
                )?;
            }
            for (row, source, target) in &custody_mutations {
                if security_custody_lifecycle::terminal(*target) {
                    taint_custody_row(
                        &transaction,
                        row,
                        *target,
                        epoch,
                        super::refusal::EndpointV7StorageError::COMMIT_REFUSED,
                    )
                    .map_err(|_| rusqlite::Error::InvalidQuery)?;
                } else {
                    let updated = transaction.execute(
                        "UPDATE endpoint_v7_custody SET lifecycle = ?1
                         WHERE token = ?2 AND lifecycle = ?3",
                        params![target.as_str(), row.token.to_string(), source.as_str()],
                    )?;
                    if updated != 1 {
                        return Err(rusqlite::Error::QueryReturnedNoRows);
                    }
                }
            }
            transaction.execute(
                "INSERT INTO endpoint_v7_meta (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![META_GENERATION, generation.to_string()],
            )?;
            transaction.commit()
        })();
        write.map_err(|_| Error::terminal(ErrorCode::ProviderFailure, Stage::Commit))?;

        let next = commit.into_versioned(expected)?;
        inner.generation = generation;
        inner.versioned = next;
        // The committed tombstone makes each handle unreachable before its
        // physical material is deleted. A failed transaction leaves both the
        // adopted row and its material intact.
        inner.flush_material_deletes();
        inner.write_anchor_best_effort();
        Ok(successor)
    }

    fn settle(&mut self, revision: Revision, pending: PendingId) -> Result<Revision, Error> {
        let mut inner = self.lock()?;
        if inner.revoked {
            return Err(revoked_sdk());
        }
        if !inner.continuity.loadable() {
            return Err(continuity_lost_sdk());
        }
        if revision.value() != inner.generation {
            return Err(commit_conflict());
        }
        let successor = revision.successor()?;
        let fingerprint = pending_fingerprint(pending).to_string();
        let present = inner
            .versioned
            .pending()
            .iter()
            .any(|item| pending_fingerprint(item.id()).to_string() == fingerprint);
        if !present {
            return Err(Error::terminal(ErrorCode::InvalidTransition, Stage::Commit));
        }
        let remaining: Vec<PendingItem> = inner
            .versioned
            .pending()
            .iter()
            .filter(|item| pending_fingerprint(item.id()).to_string() != fingerprint)
            .cloned()
            .collect();

        let generation = successor.value();
        let write: Result<(), rusqlite::Error> = (|| {
            let transaction = inner.conn.transaction()?;
            let removed = transaction.execute(
                "DELETE FROM endpoint_v7_pending WHERE pending_id = ?1",
                params![fingerprint],
            )?;
            if removed != 1 {
                return Err(rusqlite::Error::QueryReturnedNoRows);
            }
            transaction.execute(
                "INSERT INTO endpoint_v7_meta (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![META_GENERATION, generation.to_string()],
            )?;
            transaction.commit()
        })();
        write.map_err(|_| Error::terminal(ErrorCode::ProviderFailure, Stage::Commit))?;

        let next = Commit::bounded(
            inner.versioned.state().clone(),
            Vec::new(),
            remaining,
            MAX_COMMIT_KEY_MUTATIONS,
            MAX_PENDING_SET,
        )?
        .into_versioned(revision)?;
        inner.generation = generation;
        inner.versioned = next;
        inner.write_anchor_best_effort();
        Ok(successor)
    }
}

fn custody_state(value: &str) -> Option<CustodyState> {
    CustodyState::from_name(value)
}

/// Finds the registry row a mutation names and checks its purpose matches the
/// marker type exactly. A token from another purpose or lifecycle can never be
/// adopted or deleted through this mutation.
fn match_custody_row<'a>(
    rows: &'a [CustodyRow],
    mutation: &KeyMutation,
) -> Result<&'a CustodyRow, Error> {
    let (token, purpose) = match mutation {
        KeyMutation::AdoptX25519(handle) => (handle.custody_token(), PURPOSE_X25519),
        KeyMutation::AdoptMlKem768(handle) => (handle.custody_token(), PURPOSE_ML_KEM_768),
        KeyMutation::DeleteX25519(handle) => (handle.custody_token(), PURPOSE_X25519),
        KeyMutation::DeleteMlKem768(handle) => (handle.custody_token(), PURPOSE_ML_KEM_768),
        KeyMutation::DeleteMlKemEncapsulationEntropy(handle) => {
            (handle.custody_token(), PURPOSE_ML_KEM_ENTROPY)
        }
    };
    rows.iter()
        .find(|row| row.token == token && row.purpose == purpose)
        .ok_or_else(provider_refusal)
}

pub(crate) fn pending_fingerprint(id: PendingId) -> u128 {
    let mut hasher = DefaultHasher::new();
    id.hash(&mut hasher);
    u128::from(hasher.finish())
}

pub(crate) fn pending_kind_name(kind: &PendingKind) -> &'static str {
    match kind {
        PendingKind::Packet(_) => "packet",
        PendingKind::Effect(_) => "effect",
        PendingKind::Plaintext(_) => "plaintext",
    }
}

pub(crate) fn pending_payload(kind: &PendingKind) -> Vec<u8> {
    match kind {
        PendingKind::Packet(bytes) | PendingKind::Effect(bytes) | PendingKind::Plaintext(bytes) => {
            bytes.clone()
        }
    }
}
