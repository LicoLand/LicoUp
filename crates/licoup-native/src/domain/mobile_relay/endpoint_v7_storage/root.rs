//! Durable root: exclusive writer lock, additive schema, anti-rollback
//! anchor, and the one place that owns the coupled state/custody transaction.
//!
//! # What is durable, and what cannot be
//!
//! The pinned SDK's endpoint snapshot ([`EndpointState`]) is private and has no
//! encoder or decoder: the ratchet chains, skipped-message keys, and prekey
//! handles it carries exist only inside the running process. This store does
//! not pretend otherwise. What it owns durably is everything the SDK contract
//! says the caller owns:
//!
//! * the committed generation of the current session epoch,
//! * the pending delivery records committed with that generation,
//! * the custody registry (purpose, lifecycle, class) for every handle, with
//!   the key material itself in the selected platform store,
//! * an anchor written outside the database after every durable advance.
//!
//! A process that dies therefore loses exactly one thing: the ability to
//! continue the old ratchet. It cannot lose a committed generation, a
//! committed delivery record, or a key lifecycle transition, and it cannot
//! silently resume an old session either — [`EndpointV7Storage::open`]
//! classifies the durable record and refuses to load a snapshot until an
//! explicit [`EndpointV7Storage::begin_new_session`].
//!
//! # Old-or-new
//!
//! Every durable advance is one SQLite transaction over the generation, the
//! pending set, and the custody registry, so a crash leaves the complete old
//! value or the complete new value, never a mixture. Key material lives in a
//! second medium (the platform store) that cannot join that transaction, so
//! ordering carries the guarantee:
//!
//! * an adoption becomes usable only after the registry commit already says
//!   `adopted`, so a crash before the commit leaves a staged token that
//!   [`EndpointV7Storage::open`] aborts;
//! * a deletion tombstones the token in the registry commit *before* any
//!   physical material deletion is attempted, so a crash after the commit
//!   leaves a revoked token that lookups refuse.
//!
//! Both directions fail closed, and neither can resurrect a handle that the
//! protocol already consumed.
//!
//! # Rollback
//!
//! The anchor file is written after the database commit, from the same values.
//! At open, a durable `(epoch, generation)` behind the anchor — or a database
//! missing under a live anchor — is [`EndpointV7Continuity::RolledBack`]:
//! loading stays refused and only an explicit new session moves forward. A
//! database ahead of the anchor is a crash between commit and anchor write and
//! heals in the safe direction (the database wins). Rollback of the entire
//! root, including the anchor, stays outside this claim; the pinned SDK does
//! not claim malicious-store rollback protection either.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use fs2::FileExt;
use licoup_protocol_bindings::endpoint::EndpointState;
use licoup_protocol_bindings::state::Versioned;
use rand_core::{OsRng, RngCore};
use rusqlite::{Connection, OptionalExtension, params};

use crate::state_machines::security_custody_lifecycle::{
    self, Event as CustodyEvent, State as CustodyState,
};

use crate::core::secure_mesh_secret_store::{
    SecretBytes, SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession,
    SecretStoreHandle, SecureMeshSecretStore,
};

use super::custody::EndpointV7Custody;
use super::refusal::{
    EndpointV7Continuity, EndpointV7FencedPending, EndpointV7PendingKind, EndpointV7PendingPayload,
    EndpointV7RecoveredFacts, EndpointV7StorageError, EndpointV7StorageStatus,
};
use super::store::EndpointV7StateStore;

/// Schema version this build writes.
pub const ENDPOINT_V7_STORAGE_SCHEMA_VERSION: u32 = 1;

pub(crate) const LOCK_FILE: &str = "endpoint-v7.lock";
pub(crate) const DATABASE_FILE: &str = "endpoint-v7.sqlite3";
pub(crate) const ANCHOR_FILE: &str = "endpoint-v7.anchor";
const ANCHOR_MAGIC: &str = "licoup-endpoint-v7-anchor.v1";

pub(crate) const META_SCHEMA_VERSION: &str = "schema_version";
pub(crate) const META_EPOCH: &str = "epoch";
pub(crate) const META_GENERATION: &str = "generation";
pub(crate) const META_REVOKED: &str = "revoked";
pub(crate) const META_ROOT_ID: &str = "root_id";
pub(crate) const META_TOKEN_COUNTER: &str = "token_counter";

/// Reserved identity tokens: stable for the whole life of one root.
pub(crate) const IDENTITY_ED25519_TOKEN: u128 = u128::MAX - 1;
pub(crate) const IDENTITY_ML_DSA_65_TOKEN: u128 = u128::MAX - 2;

/// How many platform-store operations one authorization session may spend
/// before the store asks the platform again.
const CUSTODY_OPERATION_BUDGET: usize = 64;

/// How many endpoint key mutations one commit may carry. Mirrors the bound the
/// pinned SDK enforces for its own commits (`MAX_ACTIVE_PREKEY_PAIRS * 2`).
pub(crate) const MAX_COMMIT_KEY_MUTATIONS: usize = 4;
/// How many pending records one commit may carry.
pub(crate) const MAX_COMMIT_PENDING: usize = 16;

const SCHEMA_DDL: &str = "
CREATE TABLE IF NOT EXISTS endpoint_v7_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS endpoint_v7_pending (
    pending_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    payload BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS endpoint_v7_fenced_pending (
    pending_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    payload BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS endpoint_v7_custody (
    token TEXT PRIMARY KEY,
    purpose TEXT NOT NULL,
    lifecycle TEXT NOT NULL,
    class TEXT NOT NULL,
    material_key TEXT NOT NULL,
    epoch INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS endpoint_v7_tombstones (
    token TEXT PRIMARY KEY,
    purpose TEXT NOT NULL,
    epoch INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS endpoint_v7_material_deletes (
    token TEXT PRIMARY KEY,
    material_key TEXT NOT NULL
);
";

/// One durable root for the v7 endpoint state and custody.
///
/// The root holds an exclusive advisory lock for its whole lifetime: a second
/// [`EndpointV7Storage::open`] — in this process or another — is refused with
/// [`EndpointV7StorageError::ROOT_LOCKED`] instead of creating a second
/// writer.
pub struct EndpointV7Storage {
    inner: Arc<Mutex<Inner>>,
}

impl core::fmt::Debug for EndpointV7Storage {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.write_str("EndpointV7Storage([REDACTED])")
    }
}

impl EndpointV7Storage {
    /// Opens one durable root.
    ///
    /// `initial_state` is the live snapshot a *new* session starts from
    /// ([`EndpointState::responder`] or [`EndpointState::initiator`]);
    /// `material` is the selected platform custody owner — this adapter never
    /// picks one by itself, so the composition root keeps that decision and
    /// tests can inject an isolated non-production store.
    pub fn open(
        root: impl AsRef<Path>,
        initial_state: EndpointState,
        material: Arc<dyn SecureMeshSecretStore>,
        namespace: &str,
    ) -> Result<Self, EndpointV7StorageError> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(&root)
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        restrict_directory(&root);

        let lock_path = root.join(LOCK_FILE);
        let lock = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        restrict_file(&lock);
        lock.try_lock_exclusive()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::ROOT_LOCKED))?;

        if !material.supported() {
            return Err(EndpointV7StorageError::new(
                EndpointV7StorageError::PLATFORM_UNSUPPORTED,
            ));
        }
        if namespace.trim().is_empty() || namespace.contains(':') {
            return Err(EndpointV7StorageError::new(EndpointV7StorageError::IO));
        }

        let mut conn = Connection::open(root.join(DATABASE_FILE))
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        configure_database(&conn)?;
        ensure_schema(&mut conn)?;

        let root_id = match meta_get(&conn, META_ROOT_ID)? {
            Some(value) if !value.is_empty() => value,
            _ => {
                let value = random_root_id();
                meta_set(&conn, META_ROOT_ID, &value)?;
                value
            }
        };
        let epoch = meta_get_u64(&conn, META_EPOCH)?.unwrap_or(0);
        let generation = meta_get_u64(&conn, META_GENERATION)?.unwrap_or(0);
        let revoked = meta_get_u64(&conn, META_REVOKED)?.is_some_and(|value| value != 0);
        let anchor = read_anchor(&root)?;

        let versioned = Versioned::initial(initial_state.clone());
        let mut inner = Inner {
            root,
            _lock: lock,
            conn,
            material,
            namespace: namespace.to_string(),
            backend: "pending",
            root_id,
            epoch,
            generation,
            revoked,
            continuity: EndpointV7Continuity::Fresh,
            initial_state,
            versioned,
            recovered: None,
            session_keys_fenced: 0,
            staged_keys_aborted: 0,
            material_session: None,
        };
        inner.backend = inner.material.backend();
        inner.reconcile_custody()?;
        inner.classify_continuity(anchor.as_ref())?;
        // A rolled-back record must not overwrite the newer anchor: doing so
        // would erase the only independent evidence that this root moved
        // backwards, and a later open would look merely "continuity lost".
        if !matches!(inner.continuity, EndpointV7Continuity::RolledBack) {
            inner.write_anchor_best_effort();
        }
        Ok(Self {
            inner: Arc::new(Mutex::new(inner)),
        })
    }

    /// A handle implementing the pinned SDK's `AtomicState<EndpointState>`.
    #[must_use]
    pub fn state_store(&self) -> EndpointV7StateStore {
        EndpointV7StateStore::new(Arc::clone(&self.inner))
    }

    /// A handle implementing the pinned SDK's `KeyCustody`.
    #[must_use]
    pub fn custody(&self) -> EndpointV7Custody {
        EndpointV7Custody::new(Arc::clone(&self.inner))
    }

    /// Stable status projection.
    pub fn status(&self) -> Result<EndpointV7StorageStatus, EndpointV7StorageError> {
        self.with_inner(|inner| {
            let pending_count = count_rows(&inner.conn, "endpoint_v7_pending")?;
            let fenced_pending_count = count_rows(&inner.conn, "endpoint_v7_fenced_pending")?;
            Ok(EndpointV7StorageStatus {
                schema_version: ENDPOINT_V7_STORAGE_SCHEMA_VERSION,
                epoch: inner.epoch,
                generation: inner.generation,
                pending_count,
                fenced_pending_count,
                custody_backend: inner.backend,
                revoked: inner.revoked,
                continuity: inner.continuity,
                root_locked: true,
                session_keys_fenced: inner.session_keys_fenced,
                staged_keys_aborted: inner.staged_keys_aborted,
            })
        })
    }

    /// The durable facts of a lost session, when open found one.
    pub fn recovered_facts(
        &self,
    ) -> Result<Option<EndpointV7RecoveredFacts>, EndpointV7StorageError> {
        self.with_inner(|inner| Ok(inner.recovered.clone()))
    }

    /// Explicitly starts a new session epoch after continuity was classified
    /// as lost or rolled back.
    ///
    /// This is the only way forward. It advances the durable epoch, leaves the
    /// previous generation in the past, and returns the fenced facts exactly
    /// once. Fenced delivery records stay durable until drained or discarded.
    pub fn begin_new_session(&self) -> Result<EndpointV7RecoveredFacts, EndpointV7StorageError> {
        self.with_inner(|inner| {
            if inner.revoked {
                return Err(EndpointV7StorageError::new(EndpointV7StorageError::REVOKED));
            }
            if inner.continuity.loadable() {
                return Err(EndpointV7StorageError::new(
                    EndpointV7StorageError::NOT_RECOVERED,
                ));
            }
            let facts = inner
                .recovered
                .clone()
                .unwrap_or_else(|| EndpointV7RecoveredFacts {
                    epoch: inner.epoch,
                    generation: inner.generation,
                    fenced_pending: Vec::new(),
                    staged_keys_aborted: inner.staged_keys_aborted,
                    session_keys_fenced: inner.session_keys_fenced,
                    rollback_suspected: matches!(
                        inner.continuity,
                        EndpointV7Continuity::RolledBack
                    ),
                });
            let transaction = inner
                .conn
                .transaction()
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            meta_set(&transaction, META_EPOCH, &(inner.epoch + 1).to_string())?;
            meta_set(&transaction, META_GENERATION, "0")?;
            transaction
                .commit()
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            inner.epoch += 1;
            inner.generation = 0;
            inner.continuity = EndpointV7Continuity::Fresh;
            inner.versioned = Versioned::initial(inner.initial_state.clone());
            inner.recovered = None;
            inner.write_anchor_best_effort();
            Ok(facts)
        })
    }

    /// Revokes the whole root: every identity and session token becomes a
    /// tombstone, every pending record is fenced, and the root is terminal.
    ///
    /// Physical material deletion is attempted after the durable tombstone;
    /// whatever the platform refuses stays logically unreachable and is
    /// retried on the next open.
    pub fn revoke(&self) -> Result<EndpointV7RecoveredFacts, EndpointV7StorageError> {
        self.with_inner(|inner| {
            if inner.revoked {
                return Err(EndpointV7StorageError::new(EndpointV7StorageError::REVOKED));
            }
            let transaction = inner
                .conn
                .transaction()
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            transaction
                .execute(
                    "INSERT OR REPLACE INTO endpoint_v7_fenced_pending (pending_id, kind, payload)
                     SELECT pending_id, kind, payload FROM endpoint_v7_pending",
                    [],
                )
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            transaction
                .execute("DELETE FROM endpoint_v7_pending", [])
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            let rows = read_custody_rows(&transaction)?;
            let mut session_keys_fenced = 0_u64;
            for row in &rows {
                if row.class == CustodyRow::SESSION {
                    session_keys_fenced += 1;
                }
                let source = custody_state(row)?;
                let target = custody_transition(source, CustodyEvent::Revoke)?;
                taint_custody_row(
                    &transaction,
                    row,
                    target,
                    inner.epoch,
                    EndpointV7StorageError::REVOKED,
                )?;
            }
            meta_set(&transaction, META_REVOKED, "1")?;
            meta_set(&transaction, META_EPOCH, &(inner.epoch + 1).to_string())?;
            meta_set(&transaction, META_GENERATION, "0")?;
            transaction
                .commit()
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;

            inner.revoked = true;
            inner.epoch += 1;
            inner.generation = 0;
            inner.continuity = EndpointV7Continuity::Revoked;
            inner.versioned = Versioned::initial(inner.initial_state.clone());
            inner.session_keys_fenced = inner
                .session_keys_fenced
                .saturating_add(session_keys_fenced);
            let facts = EndpointV7RecoveredFacts {
                epoch: inner.epoch.saturating_sub(1),
                generation: 0,
                fenced_pending: read_fenced_pending(&inner.conn)?,
                staged_keys_aborted: inner.staged_keys_aborted,
                session_keys_fenced,
                rollback_suspected: false,
            };
            inner.recovered = Some(facts.clone());
            inner.flush_material_deletes();
            inner.write_anchor_best_effort();
            Ok(facts)
        })
    }

    /// Drains the fenced delivery payloads of a lost session exactly once.
    ///
    /// These records were already committed by the pinned SDK. The caller must
    /// either re-drive the exact item (packets and effects are replay-safe by
    /// the protocol's own identities) or discard it; it must never mint a new
    /// identity for the same work.
    pub fn take_recovered_pending_payloads(
        &self,
    ) -> Result<Vec<(u128, EndpointV7PendingPayload)>, EndpointV7StorageError> {
        self.with_inner(|inner| {
            let rows = read_fenced_pending_records(&inner.conn)?;
            let transaction = inner
                .conn
                .transaction()
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            transaction
                .execute("DELETE FROM endpoint_v7_fenced_pending", [])
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            transaction
                .commit()
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            Ok(rows)
        })
    }

    /// Discards the fenced delivery records without delivering them.
    pub fn discard_recovered_pending(&self) -> Result<u32, EndpointV7StorageError> {
        self.with_inner(|inner| {
            let transaction = inner
                .conn
                .transaction()
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            let removed = transaction
                .execute("DELETE FROM endpoint_v7_fenced_pending", [])
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            transaction
                .commit()
                .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
            Ok(u32::try_from(removed).unwrap_or(u32::MAX))
        })
    }

    pub(crate) fn with_inner<T>(
        &self,
        operation: impl FnOnce(&mut Inner) -> Result<T, EndpointV7StorageError>,
    ) -> Result<T, EndpointV7StorageError> {
        let mut inner = self.lock()?;
        operation(&mut inner)
    }

    pub(crate) fn lock(&self) -> Result<MutexGuard<'_, Inner>, EndpointV7StorageError> {
        self.inner
            .lock()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))
    }
}

/// One custody registry row.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CustodyRow {
    pub(crate) token: u128,
    pub(crate) purpose: String,
    pub(crate) lifecycle: String,
    pub(crate) class: String,
    pub(crate) material_key: String,
}

impl CustodyRow {
    pub(crate) const STAGED: &'static str = CustodyState::Staged.as_str();
    pub(crate) const ADOPTED: &'static str = CustodyState::Adopted.as_str();
    pub(crate) const SESSION: &'static str = "session";
    pub(crate) const IDENTITY: &'static str = "identity";
}

fn custody_state(row: &CustodyRow) -> Result<CustodyState, EndpointV7StorageError> {
    CustodyState::from_name(&row.lifecycle)
        .ok_or_else(|| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))
}

fn custody_transition(
    source: CustodyState,
    event: CustodyEvent,
) -> Result<CustodyState, EndpointV7StorageError> {
    security_custody_lifecycle::transition(source, event)
        .ok_or_else(|| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))
}

struct Anchor {
    epoch: u64,
    generation: u64,
}

/// Shared durable state behind one root lock.
pub(crate) struct Inner {
    pub(crate) root: PathBuf,
    _lock: File,
    pub(crate) conn: Connection,
    pub(crate) material: Arc<dyn SecureMeshSecretStore>,
    pub(crate) namespace: String,
    pub(crate) backend: &'static str,
    pub(crate) root_id: String,
    pub(crate) epoch: u64,
    pub(crate) generation: u64,
    pub(crate) revoked: bool,
    pub(crate) continuity: EndpointV7Continuity,
    pub(crate) initial_state: EndpointState,
    pub(crate) versioned: Versioned<EndpointState>,
    pub(crate) recovered: Option<EndpointV7RecoveredFacts>,
    pub(crate) session_keys_fenced: u64,
    pub(crate) staged_keys_aborted: u64,
    material_session: Option<SecretStoreAuthorizationSession>,
}

impl Inner {
    // -- custody medium ---------------------------------------------------

    fn material_handle(
        &self,
        material_key: &str,
    ) -> Result<SecretStoreHandle, EndpointV7StorageError> {
        SecretStoreHandle::new(self.namespace.clone(), material_key)
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::MATERIAL_UNAVAILABLE))
    }

    pub(crate) fn authorize_material(
        &mut self,
        operations: usize,
    ) -> Result<SecretStoreAuthorizationSession, EndpointV7StorageError> {
        let needed = operations.max(1);
        if let Some(session) = &self.material_session
            && session.remaining_operation_count() >= needed
        {
            return Ok(session.clone());
        }
        let request = SecretStoreAuthorizationRequest::new(
            "LicoUp endpoint v7 protocol state and custody",
            CUSTODY_OPERATION_BUDGET,
        );
        let session = self
            .material
            .begin_authorized_session(&request)
            .map_err(|_| {
                EndpointV7StorageError::new(EndpointV7StorageError::PLATFORM_UNSUPPORTED)
            })?;
        self.material_session = Some(session.clone());
        Ok(session)
    }

    pub(crate) fn read_material(
        &mut self,
        material_key: &str,
    ) -> Result<Option<SecretBytes>, EndpointV7StorageError> {
        let handle = self.material_handle(material_key)?;
        let session = self.authorize_material(1)?;
        self.material
            .get_secret_with_session(&session, &handle)
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::MATERIAL_UNAVAILABLE))
    }

    pub(crate) fn write_material(
        &mut self,
        material_key: &str,
        material: SecretBytes,
    ) -> Result<(), EndpointV7StorageError> {
        let handle = self.material_handle(material_key)?;
        let session = self.authorize_material(1)?;
        self.material
            .set_secret_with_session(&session, &handle, material)
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::MATERIAL_UNAVAILABLE))
    }

    /// Attempts one physical material deletion. `false` means the platform
    /// refused; the logical tombstone already stands.
    pub(crate) fn delete_material(&mut self, material_key: &str) -> bool {
        let Ok(handle) = self.material_handle(material_key) else {
            return false;
        };
        let Ok(session) = self.authorize_material(1) else {
            return false;
        };
        self.material
            .delete_secret_with_session(&session, &handle)
            .is_ok()
    }

    /// Retries every material deletion the platform refused earlier.
    pub(crate) fn flush_material_deletes(&mut self) {
        let Ok(rows) = read_material_delete_rows(&self.conn) else {
            return;
        };
        for (token, material_key) in rows {
            if !self.delete_material(&material_key) {
                continue;
            }
            let _ = self.conn.execute(
                "DELETE FROM endpoint_v7_material_deletes WHERE token = ?1",
                params![token.to_string()],
            );
        }
    }

    // -- durable classification ------------------------------------------

    /// Aborts every tentative token, fences every adopted session token, and
    /// keeps the device identity. Runs before continuity is decided so the
    /// registry never offers a handle from a previous process.
    fn reconcile_custody(&mut self) -> Result<(), EndpointV7StorageError> {
        let rows = read_custody_rows(&self.conn)?;
        let transaction = self
            .conn
            .transaction()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
        let mut staged = 0_u64;
        let mut fenced = 0_u64;
        for row in &rows {
            let source = custody_state(row)?;
            match (source, row.class.as_str()) {
                (CustodyState::Staged, _) => {
                    let target = custody_transition(source, CustodyEvent::Abort)?;
                    taint_custody_row(
                        &transaction,
                        row,
                        target,
                        self.epoch,
                        EndpointV7StorageError::COMMIT_REFUSED,
                    )?;
                    staged += 1;
                }
                (CustodyState::Adopted, CustodyRow::SESSION) => {
                    let target = custody_transition(source, CustodyEvent::Fence)?;
                    let updated = transaction
                        .execute(
                            "UPDATE endpoint_v7_custody SET lifecycle = ?1
                             WHERE token = ?2 AND lifecycle = ?3",
                            params![target.as_str(), row.token.to_string(), source.as_str()],
                        )
                        .map_err(|_| {
                            EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED)
                        })?;
                    if updated != 1 {
                        return Err(EndpointV7StorageError::new(
                            EndpointV7StorageError::COMMIT_REFUSED,
                        ));
                    }
                    fenced += 1;
                }
                (CustodyState::Fenced, CustodyRow::SESSION) => fenced += 1,
                (CustodyState::Adopted, CustodyRow::IDENTITY) => {}
                _ => {
                    return Err(EndpointV7StorageError::new(
                        EndpointV7StorageError::COMMIT_REFUSED,
                    ));
                }
            }
        }
        transaction
            .commit()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
        self.staged_keys_aborted = staged;
        self.session_keys_fenced = fenced;
        // Aborted staged rows were tombstoned and queued in the same durable
        // transaction. Physical deletion starts only after that commit and is
        // retried on future opens when the platform refuses it.
        self.flush_material_deletes();
        Ok(())
    }

    fn classify_continuity(
        &mut self,
        anchor: Option<&Anchor>,
    ) -> Result<(), EndpointV7StorageError> {
        let rollback_suspected = match anchor {
            Some(anchor) => (self.epoch, self.generation) < (anchor.epoch, anchor.generation),
            None => self.generation > 0 || self.revoked,
        };
        self.continuity = if rollback_suspected {
            EndpointV7Continuity::RolledBack
        } else if self.revoked {
            EndpointV7Continuity::Revoked
        } else if self.generation > 0 {
            EndpointV7Continuity::ContinuityLost
        } else {
            EndpointV7Continuity::Fresh
        };
        if self.generation > 0 {
            self.fence_committed_pending()?;
        }
        if !self.continuity.loadable() {
            let fenced_pending = read_fenced_pending(&self.conn)?;
            self.recovered = Some(EndpointV7RecoveredFacts {
                epoch: self.epoch,
                generation: self.generation,
                fenced_pending,
                staged_keys_aborted: self.staged_keys_aborted,
                session_keys_fenced: self.session_keys_fenced,
                rollback_suspected,
            });
        }
        self.versioned = Versioned::initial(self.initial_state.clone());
        Ok(())
    }

    /// Moves every committed delivery record of the lost session into the
    /// fenced table in one transaction.
    fn fence_committed_pending(&mut self) -> Result<(), EndpointV7StorageError> {
        let transaction = self
            .conn
            .transaction()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
        transaction
            .execute(
                "INSERT OR REPLACE INTO endpoint_v7_fenced_pending (pending_id, kind, payload)
                 SELECT pending_id, kind, payload FROM endpoint_v7_pending",
                [],
            )
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
        transaction
            .execute("DELETE FROM endpoint_v7_pending", [])
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))?;
        transaction
            .commit()
            .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))
    }

    pub(crate) fn write_anchor_best_effort(&self) {
        let anchor = Anchor {
            epoch: self.epoch,
            generation: self.generation,
        };
        let _ = write_anchor(&self.root, &anchor);
    }
}

// ---------------------------------------------------------------------------
// Schema, metadata, and anchor helpers
// ---------------------------------------------------------------------------

fn configure_database(conn: &Connection) -> Result<(), EndpointV7StorageError> {
    let io = || EndpointV7StorageError::new(EndpointV7StorageError::IO);
    conn.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))
        .map_err(|_| io())?;
    conn.execute_batch("PRAGMA synchronous=FULL;")
        .map_err(|_| io())?;
    conn.busy_timeout(std::time::Duration::from_secs(5))
        .map_err(|_| io())?;
    Ok(())
}

fn ensure_schema(conn: &mut Connection) -> Result<(), EndpointV7StorageError> {
    let existing = schema_version(conn)?;
    if let Some(version) = existing
        && version > ENDPOINT_V7_STORAGE_SCHEMA_VERSION
    {
        return Err(EndpointV7StorageError::new(
            EndpointV7StorageError::SCHEMA_UNSUPPORTED,
        ));
    }
    // Additive, idempotent DDL applied in one transaction: a crash during an
    // interrupted upgrade leaves the old or the new schema, never both halves.
    let transaction = conn
        .transaction()
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    transaction
        .execute_batch(SCHEMA_DDL)
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    meta_set(
        &transaction,
        META_SCHEMA_VERSION,
        &ENDPOINT_V7_STORAGE_SCHEMA_VERSION.to_string(),
    )
    .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    transaction
        .commit()
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    Ok(())
}

fn schema_version(conn: &Connection) -> Result<Option<u32>, EndpointV7StorageError> {
    let present: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'endpoint_v7_meta'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map(|count| count > 0)
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    if !present {
        return Ok(None);
    }
    Ok(meta_get_u64(conn, META_SCHEMA_VERSION)?.map(|value| value as u32))
}

pub(crate) fn meta_get(
    conn: &Connection,
    key: &str,
) -> Result<Option<String>, EndpointV7StorageError> {
    conn.query_row(
        "SELECT value FROM endpoint_v7_meta WHERE key = ?1",
        params![key],
        |row| row.get::<_, String>(0),
    )
    .optional()
    .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))
}

pub(crate) fn meta_get_u64(
    conn: &Connection,
    key: &str,
) -> Result<Option<u64>, EndpointV7StorageError> {
    Ok(meta_get(conn, key)?.and_then(|value| value.parse().ok()))
}

pub(crate) fn meta_set(
    conn: &Connection,
    key: &str,
    value: &str,
) -> Result<(), EndpointV7StorageError> {
    conn.execute(
        "INSERT INTO endpoint_v7_meta (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )
    .map(|_| ())
    .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::COMMIT_REFUSED))
}

pub(crate) fn count_rows(conn: &Connection, table: &str) -> Result<u32, EndpointV7StorageError> {
    conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
        row.get::<_, i64>(0)
    })
    .map(|count| u32::try_from(count).unwrap_or(u32::MAX))
    .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))
}

pub(crate) fn read_custody_rows(
    conn: &Connection,
) -> Result<Vec<CustodyRow>, EndpointV7StorageError> {
    let mut statement = conn
        .prepare(
            "SELECT token, purpose, lifecycle, class, material_key
             FROM endpoint_v7_custody ORDER BY token",
        )
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    let mut result = Vec::new();
    for row in rows {
        let (token, purpose, lifecycle, class, material_key) =
            row.map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        let Some(token) = token.parse::<u128>().ok() else {
            continue;
        };
        result.push(CustodyRow {
            token,
            purpose,
            lifecycle,
            class,
            material_key,
        });
    }
    Ok(result)
}

fn read_material_delete_rows(
    conn: &Connection,
) -> Result<Vec<(u128, String)>, EndpointV7StorageError> {
    let mut statement = conn
        .prepare("SELECT token, material_key FROM endpoint_v7_material_deletes ORDER BY token")
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    let mut result = Vec::new();
    for row in rows {
        let (token, material_key) =
            row.map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        if let Ok(token) = token.parse::<u128>() {
            result.push((token, material_key));
        }
    }
    Ok(result)
}

fn read_fenced_pending(
    conn: &Connection,
) -> Result<Vec<EndpointV7FencedPending>, EndpointV7StorageError> {
    Ok(read_fenced_pending_records(conn)?
        .into_iter()
        .map(|(id, payload)| EndpointV7FencedPending {
            id,
            kind: match payload {
                EndpointV7PendingPayload::Packet(_) => EndpointV7PendingKind::Packet,
                EndpointV7PendingPayload::Effect(_) => EndpointV7PendingKind::Effect,
                EndpointV7PendingPayload::Plaintext(_) => EndpointV7PendingKind::Plaintext,
            },
        })
        .collect())
}

fn read_fenced_pending_records(
    conn: &Connection,
) -> Result<Vec<(u128, EndpointV7PendingPayload)>, EndpointV7StorageError> {
    let mut statement = conn
        .prepare(
            "SELECT pending_id, kind, payload FROM endpoint_v7_fenced_pending ORDER BY pending_id",
        )
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Vec<u8>>(2)?,
            ))
        })
        .map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
    let mut result = Vec::new();
    for row in rows {
        let (id, kind, payload) =
            row.map_err(|_| EndpointV7StorageError::new(EndpointV7StorageError::IO))?;
        let Ok(id) = id.parse::<u128>() else {
            continue;
        };
        let Some(kind) = EndpointV7PendingKind::from_str(&kind) else {
            continue;
        };
        let payload = match kind {
            EndpointV7PendingKind::Packet => EndpointV7PendingPayload::Packet(payload),
            EndpointV7PendingKind::Effect => EndpointV7PendingPayload::Effect(payload),
            EndpointV7PendingKind::Plaintext => EndpointV7PendingPayload::Plaintext(payload),
        };
        result.push((id, payload));
    }
    Ok(result)
}

/// Turns one registry row into a tombstone plus a queued material deletion.
///
/// A tombstone is the durable representation of a terminal lifecycle target;
/// the queued physical deletion is retried whenever the platform refused it.
pub(crate) fn taint_custody_row(
    conn: &Connection,
    row: &CustodyRow,
    target: CustodyState,
    epoch: u64,
    code: &'static str,
) -> Result<(), EndpointV7StorageError> {
    if !security_custody_lifecycle::terminal(target) {
        return Err(EndpointV7StorageError::new(code));
    }
    conn.execute(
        "INSERT OR REPLACE INTO endpoint_v7_tombstones (token, purpose, epoch) VALUES (?1, ?2, ?3)",
        params![row.token.to_string(), row.purpose, epoch as i64],
    )
    .map_err(|_| EndpointV7StorageError::new(code))?;
    conn.execute(
        "INSERT OR REPLACE INTO endpoint_v7_material_deletes (token, material_key) VALUES (?1, ?2)",
        params![row.token.to_string(), row.material_key],
    )
    .map_err(|_| EndpointV7StorageError::new(code))?;
    let removed = conn
        .execute(
            "DELETE FROM endpoint_v7_custody WHERE token = ?1",
            params![row.token.to_string()],
        )
        .map_err(|_| EndpointV7StorageError::new(code))?;
    if removed != 1 {
        return Err(EndpointV7StorageError::new(code));
    }
    Ok(())
}

pub(crate) fn issue_token(conn: &Connection) -> Result<u128, EndpointV7StorageError> {
    let counter = meta_get_u64(conn, META_TOKEN_COUNTER)?
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| {
            EndpointV7StorageError::with_sdk(
                EndpointV7StorageError::COMMIT_REFUSED,
                super::refusal::bound_exceeded(),
            )
        })?;
    meta_set(conn, META_TOKEN_COUNTER, &counter.to_string())?;
    Ok(u128::from(counter))
}

// ---------------------------------------------------------------------------
// Anchor and file hygiene
// ---------------------------------------------------------------------------

fn read_anchor(root: &Path) -> Result<Option<Anchor>, EndpointV7StorageError> {
    let path = root.join(ANCHOR_FILE);
    let Ok(body) = fs::read_to_string(&path) else {
        return Ok(None);
    };
    let mut lines = body.lines();
    if lines.next() != Some(ANCHOR_MAGIC) {
        return Ok(None);
    }
    let (Some(_version), Some(epoch), Some(generation)) =
        (lines.next(), lines.next(), lines.next())
    else {
        return Ok(None);
    };
    let (Ok(epoch), Ok(generation)) = (epoch.parse::<u64>(), generation.parse::<u64>()) else {
        return Ok(None);
    };
    Ok(Some(Anchor { epoch, generation }))
}

fn write_anchor(root: &Path, anchor: &Anchor) -> Result<(), EndpointV7StorageError> {
    let io = || EndpointV7StorageError::new(EndpointV7StorageError::IO);
    let temporary = root.join(format!("{ANCHOR_FILE}.tmp"));
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&temporary)
        .map_err(|_| io())?;
    restrict_file(&file);
    let body = format!(
        "{ANCHOR_MAGIC}\n{}\n{}\n{}\n",
        ENDPOINT_V7_STORAGE_SCHEMA_VERSION, anchor.epoch, anchor.generation
    );
    file.write_all(body.as_bytes()).map_err(|_| io())?;
    file.sync_all().map_err(|_| io())?;
    drop(file);
    fs::rename(&temporary, root.join(ANCHOR_FILE)).map_err(|_| io())?;
    sync_directory(root);
    Ok(())
}

fn random_root_id() -> String {
    let mut bytes = [0_u8; 8];
    OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn restrict_file(file: &File) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = file.set_permissions(fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = file;
}

fn restrict_directory(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
    }
    #[cfg(not(unix))]
    let _ = path;
}

fn sync_directory(path: &Path) {
    #[cfg(unix)]
    {
        if let Ok(directory) = File::open(path) {
            let _ = directory.sync_all();
        }
    }
    #[cfg(not(unix))]
    let _ = path;
}
