//! A28 contract cases for endpoint storage and custody.
//!
//! These cases do not need the gated authority artifact: they drive the
//! caller-owned half directly — durable old-or-new commits, lifecycle and
//! purpose checks, the exclusive root lock, rollback classification,
//! interrupted-schema repair, revocation, and permission counterexamples.

use std::fs;
use std::path::Path;
use std::sync::Arc;

use licoup_native::core::secure_mesh_secret_store::SecureMeshSecretStore;
use licoup_protocol_bindings::ErrorCode;
use licoup_protocol_bindings::endpoint::EndpointState;
use licoup_protocol_bindings::state::{
    AtomicState, Commit, CustodyRef, KeyCustody, KeyMutation, PendingId, PendingItem, Revision,
};

use licoup_native::domain::mobile_relay::endpoint_storage::{
    EndpointV7Continuity, EndpointV7PendingKind, EndpointV7PendingPayload, EndpointV7Storage,
    EndpointV7StorageError,
};

use crate::support::{
    FIXTURE_NAMESPACE, FixtureVault, TempDir, fixture_material_count, synthetic_ml_kem_seed,
    synthetic_seed,
};

fn open(
    root: &Path,
    vault: &Arc<FixtureVault>,
) -> Result<EndpointV7Storage, EndpointV7StorageError> {
    EndpointV7Storage::open(
        root,
        EndpointState::responder(),
        Arc::clone(vault) as Arc<dyn SecureMeshSecretStore>,
        FIXTURE_NAMESPACE,
    )
}

fn adopt_commit(
    state: &EndpointState,
    mutation: KeyMutation,
) -> Result<Commit<EndpointState>, licoup_protocol_bindings::Error> {
    Commit::bounded(state.clone(), vec![mutation], Vec::new(), 4, 16)
}

fn custody_row_count(root: &Path) -> i64 {
    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .query_row("SELECT COUNT(*) FROM endpoint_v7_custody", [], |row| {
            row.get::<_, i64>(0)
        })
        .expect("custody table exists")
}

fn meta_value(root: &Path, key: &str) -> Option<String> {
    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .query_row(
            "SELECT value FROM endpoint_v7_meta WHERE key = ?1",
            rusqlite::params![key],
            |row| row.get::<_, String>(0),
        )
        .ok()
}

fn custody_lifecycle(root: &Path, token: u128) -> Option<String> {
    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .query_row(
            "SELECT lifecycle FROM endpoint_v7_custody WHERE token = ?1",
            rusqlite::params![token.to_string()],
            |row| row.get::<_, String>(0),
        )
        .ok()
}

#[test]
fn staged_tokens_are_aborted_by_the_next_open() {
    let temp = TempDir::new("stage-abort");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");

    let staged_x25519 = {
        let storage = open(&root, &vault).expect("a fresh root opens");
        let staged_x25519 = storage
            .custody()
            .stage_x25519(synthetic_seed(0x11))
            .expect("staging a tentative X25519 key");
        let _staged_ml_kem = storage
            .custody()
            .stage_ml_kem_768(synthetic_ml_kem_seed(0x12))
            .expect("staging a tentative ML-KEM key");
        assert_eq!(fixture_material_count(&vault), 2);
        staged_x25519
    };

    // Reopen: the tentative tokens were never adopted, so they are aborted
    // before any caller can see them.
    let storage = open(&root, &vault).expect("reopen after staged keys");
    let status = storage.status().expect("status");
    assert_eq!(status.continuity, EndpointV7Continuity::Fresh);
    assert_eq!(status.staged_keys_aborted, 2);
    assert_eq!(fixture_material_count(&vault), 0);
    assert!(
        storage
            .custody()
            .x25519_public(CustodyRef::Staged(&staged_x25519))
            .is_err(),
        "an aborted tentative token is unusable"
    );
}

#[test]
fn failed_abort_reconciliation_preserves_the_staged_registry_and_material() {
    let temp = TempDir::new("abort-rollback");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    let token = {
        let storage = open(&root, &vault).expect("a fresh root opens");
        storage
            .custody()
            .stage_x25519(synthetic_seed(0x19))
            .expect("staging")
            .custody_token()
    };

    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .execute_batch(
            "CREATE TRIGGER fail_staged_abort
             BEFORE DELETE ON endpoint_v7_custody
             WHEN OLD.lifecycle = 'staged'
             BEGIN
                 SELECT RAISE(FAIL, 'synthetic staged abort failure');
             END;",
        )
        .expect("failure trigger installs");
    drop(connection);

    let refused = open(&root, &vault).expect_err("failed abort transaction refuses open");
    assert_eq!(refused.code(), EndpointV7StorageError::COMMIT_REFUSED);
    assert_eq!(custody_lifecycle(&root, token).as_deref(), Some("staged"));
    assert_eq!(fixture_material_count(&vault), 1);

    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .execute_batch("DROP TRIGGER fail_staged_abort;")
        .expect("failure trigger is removable");
    drop(connection);
    let storage = open(&root, &vault).expect("abort succeeds after failure is removed");
    assert_eq!(storage.status().expect("status").staged_keys_aborted, 1);
    assert_eq!(fixture_material_count(&vault), 0);
}

#[test]
fn failed_explicit_abort_preserves_the_staged_registry_and_material() {
    let temp = TempDir::new("explicit-abort-rollback");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    let storage = open(&root, &vault).expect("a fresh root opens");
    let staged = storage
        .custody()
        .stage_x25519(synthetic_seed(0x1a))
        .expect("staging");
    let token = staged.custody_token();

    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .execute_batch(
            "CREATE TRIGGER fail_explicit_abort
             BEFORE DELETE ON endpoint_v7_custody
             WHEN OLD.lifecycle = 'staged'
             BEGIN
                 SELECT RAISE(FAIL, 'synthetic explicit abort failure');
             END;",
        )
        .expect("failure trigger installs");
    drop(connection);

    let mut custody = storage.custody();
    custody.abort_x25519(&staged);
    assert_eq!(custody_lifecycle(&root, token).as_deref(), Some("staged"));
    assert_eq!(fixture_material_count(&vault), 1);

    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .execute_batch("DROP TRIGGER fail_explicit_abort;")
        .expect("failure trigger is removable");
    drop(connection);
    custody.abort_x25519(&staged);
    assert_eq!(custody_lifecycle(&root, token), None);
    assert_eq!(fixture_material_count(&vault), 0);
}

#[test]
fn adopted_session_tokens_are_fenced_by_the_next_open() {
    let temp = TempDir::new("adopt-fence");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");

    let adopted = {
        let storage = open(&root, &vault).expect("a fresh root opens");
        let staged = storage
            .custody()
            .stage_x25519(synthetic_seed(0x21))
            .expect("staging");
        let mut store = storage.state_store();
        let current = store.load().expect("initial load");
        store
            .compare_and_swap(
                current.revision(),
                adopt_commit(current.state(), KeyMutation::AdoptX25519(staged.clone()))
                    .expect("bounded commit"),
            )
            .expect("the adoption commits");
        assert!(storage.status().expect("status").continuity.loadable());
        staged.adopted_handle()
    };

    // A committed session does not survive the process. Its ratchet material
    // is fenced, not reused: the pinned SDK cannot reconstruct the snapshot.
    let storage = open(&root, &vault).expect("reopen after a committed session");
    let status = storage.status().expect("status");
    assert_eq!(status.continuity, EndpointV7Continuity::ContinuityLost);
    assert_eq!(status.session_keys_fenced, 1);
    assert_eq!(status.generation, 1);
    assert_eq!(
        custody_lifecycle(&root, adopted.custody_token()).as_deref(),
        Some("fenced"),
        "the generated fence target is the durable registry state"
    );
    let facts = storage
        .recovered_facts()
        .expect("facts query")
        .expect("a lost session is reported");
    assert_eq!(facts.generation, 1);
    assert_eq!(facts.session_keys_fenced, 1);
    assert!(
        storage
            .custody()
            .x25519_public(CustodyRef::Adopted(&adopted))
            .is_err(),
        "a fenced session token is never usable again"
    );
    let refused = storage
        .state_store()
        .load()
        .expect_err("loading a lost session is refused");
    assert_eq!(refused.code, ErrorCode::StateRollback);
    // The explicit new session is the only way forward, and it advances the
    // epoch while preserving the fenced facts.
    let facts = storage.begin_new_session().expect("explicit new session");
    assert_eq!(facts.generation, 1);
    assert_eq!(facts.session_keys_fenced, 1);
    let status = storage.status().expect("status");
    assert_eq!(status.continuity, EndpointV7Continuity::Fresh);
    assert_eq!(status.generation, 0);
    assert_eq!(status.epoch, 1);
    assert!(storage.state_store().load().is_ok());
}

#[test]
fn failed_fence_reconciliation_preserves_the_adopted_registry_and_material() {
    let temp = TempDir::new("fence-rollback");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    let token = {
        let storage = open(&root, &vault).expect("a fresh root opens");
        let staged = storage
            .custody()
            .stage_x25519(synthetic_seed(0x29))
            .expect("staging");
        let token = staged.custody_token();
        let mut store = storage.state_store();
        let current = store.load().expect("initial load");
        store
            .compare_and_swap(
                current.revision(),
                adopt_commit(current.state(), KeyMutation::AdoptX25519(staged))
                    .expect("bounded commit"),
            )
            .expect("the adoption commits");
        token
    };

    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .execute_batch(
            "CREATE TRIGGER fail_session_fence
             BEFORE UPDATE OF lifecycle ON endpoint_v7_custody
             WHEN OLD.lifecycle = 'adopted' AND NEW.lifecycle = 'fenced'
             BEGIN
                 SELECT RAISE(FAIL, 'synthetic session fence failure');
             END;",
        )
        .expect("failure trigger installs");
    drop(connection);

    let refused = open(&root, &vault).expect_err("failed fence transaction refuses open");
    assert_eq!(refused.code(), EndpointV7StorageError::COMMIT_REFUSED);
    assert_eq!(custody_lifecycle(&root, token).as_deref(), Some("adopted"));
    assert_eq!(fixture_material_count(&vault), 1);
}

#[test]
fn commits_refuse_staged_mismatched_unknown_and_wrong_purpose_tokens() {
    let temp = TempDir::new("mutation-checks");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");

    let storage = open(&root, &vault).expect("a fresh root opens");
    let staged_x25519 = storage
        .custody()
        .stage_x25519(synthetic_seed(0x31))
        .expect("staging X25519");
    let staged_ml_kem = storage
        .custody()
        .stage_ml_kem_768(synthetic_ml_kem_seed(0x32))
        .expect("staging ML-KEM");
    let mut store = storage.state_store();
    let current = store.load().expect("initial load");

    // An unknown token, a mismatched purpose, and a forged identity token are
    // all refused before anything is written.
    for mutation in [
        KeyMutation::AdoptX25519(
            licoup_protocol_bindings::state::StagedSecretHandle::from_custody_token(999_999),
        ),
        KeyMutation::AdoptMlKem768(
            licoup_protocol_bindings::state::StagedSecretHandle::from_custody_token(
                staged_x25519.custody_token(),
            ),
        ),
        KeyMutation::DeleteX25519(staged_x25519.adopted_handle()),
        KeyMutation::DeleteMlKemEncapsulationEntropy(
            licoup_protocol_bindings::state::SecretHandle::from_custody_token(1),
        ),
    ] {
        let refused = store.compare_and_swap(
            current.revision(),
            adopt_commit(current.state(), mutation).expect("bounded commit"),
        );
        assert!(
            refused.is_err(),
            "a mutation that does not name its own committed token is refused"
        );
        assert_eq!(
            store.load().expect("load after refusal").revision(),
            current.revision(),
            "a refused commit applies nothing"
        );
    }

    // The exact staged tokens still adopt, and a second adoption of the same
    // token is refused.
    let first = store
        .compare_and_swap(
            current.revision(),
            adopt_commit(
                current.state(),
                KeyMutation::AdoptX25519(staged_x25519.clone()),
            )
            .expect("bounded commit"),
        )
        .expect("the exact staged token adopts");
    let after_first = store.load().expect("load after adoption");
    assert_eq!(after_first.revision(), first);
    assert!(
        store
            .compare_and_swap(
                first,
                adopt_commit(
                    after_first.state(),
                    KeyMutation::AdoptMlKem768(staged_ml_kem.clone()),
                )
                .expect("bounded commit"),
            )
            .is_ok()
    );
    let after_second = store.load().expect("load after second adoption");
    assert!(
        store
            .compare_and_swap(
                after_second.revision(),
                adopt_commit(
                    after_second.state(),
                    KeyMutation::AdoptX25519(staged_x25519)
                )
                .expect("bounded commit"),
            )
            .is_err(),
        "an adopted token is not staged again"
    );
}

#[test]
fn custody_refuses_unknown_cross_purpose_and_retired_tokens() {
    let temp = TempDir::new("custody-refusals");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    let storage = open(&root, &vault).expect("a fresh root opens");
    let staged = storage
        .custody()
        .stage_x25519(synthetic_seed(0x41))
        .expect("staging X25519");

    // Unknown token, staged token used as an adopted one, and a token of a
    // different purpose all refuse.
    assert!(
        storage
            .custody()
            .x25519_public(CustodyRef::Adopted(
                &licoup_protocol_bindings::state::SecretHandle::from_custody_token(4242)
            ))
            .is_err()
    );
    assert!(
        storage
            .custody()
            .x25519_public(CustodyRef::Adopted(&staged.adopted_handle()))
            .is_err()
    );
    assert!(
        storage
            .custody()
            .ml_dsa_65_public(
                &licoup_protocol_bindings::state::SecretHandle::from_custody_token(
                    staged.custody_token()
                )
            )
            .is_err()
    );

    // Retire the token through a real delete mutation, then prove it is gone.
    let adopted = staged.adopted_handle();
    let mut store = storage.state_store();
    let current = store.load().expect("initial load");
    let adopted_state = {
        let next = store
            .compare_and_swap(
                current.revision(),
                adopt_commit(current.state(), KeyMutation::AdoptX25519(staged.clone()))
                    .expect("bounded commit"),
            )
            .expect("adoption commits");
        assert_eq!(next, Revision::initial().successor().expect("successor"));
        store.load().expect("load after adoption")
    };
    let retired = store
        .compare_and_swap(
            adopted_state.revision(),
            adopt_commit(
                adopted_state.state(),
                KeyMutation::DeleteX25519(adopted.clone()),
            )
            .expect("bounded commit"),
        )
        .expect("deletion commits");
    assert_eq!(retired.value(), 2);
    assert!(
        storage
            .custody()
            .x25519_public(CustodyRef::Adopted(&adopted))
            .is_err(),
        "a deleted token is never usable again"
    );
    assert_eq!(
        fixture_material_count(&vault),
        0,
        "the platform deletion was applied"
    );
}

#[test]
fn failed_delete_commit_preserves_the_adopted_handle_and_material() {
    let temp = TempDir::new("delete-rollback");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    let storage = open(&root, &vault).expect("a fresh root opens");
    let staged = storage
        .custody()
        .stage_x25519(synthetic_seed(0x42))
        .expect("staging X25519");
    let adopted = staged.adopted_handle();
    let mut store = storage.state_store();
    let initial = store.load().expect("initial load");
    let adopted_revision = store
        .compare_and_swap(
            initial.revision(),
            adopt_commit(initial.state(), KeyMutation::AdoptX25519(staged))
                .expect("bounded adoption"),
        )
        .expect("adoption commits");
    let adopted_state = store.load().expect("load after adoption");
    let public_before = storage
        .custody()
        .x25519_public(CustodyRef::Adopted(&adopted))
        .expect("adopted material is usable");

    let connection =
        rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database is readable");
    connection
        .execute_batch(
            "CREATE TRIGGER fail_generation_update
             BEFORE UPDATE ON endpoint_v7_meta
             WHEN NEW.key = 'generation'
             BEGIN
                 SELECT RAISE(FAIL, 'synthetic generation update failure');
             END;",
        )
        .expect("failure trigger installs");
    drop(connection);

    let refused = store.compare_and_swap(
        adopted_revision,
        adopt_commit(
            adopted_state.state(),
            KeyMutation::DeleteX25519(adopted.clone()),
        )
        .expect("bounded deletion"),
    );
    assert!(refused.is_err(), "injected transaction failure is refused");
    assert_eq!(
        store.load().expect("load after refusal").revision(),
        adopted_revision,
        "the failed transaction does not advance the snapshot"
    );
    assert_eq!(
        storage
            .custody()
            .x25519_public(CustodyRef::Adopted(&adopted))
            .expect("adopted material remains usable"),
        public_before
    );
    assert_eq!(fixture_material_count(&vault), 1);
}

#[test]
fn the_root_lock_refuses_a_second_writer() {
    let temp = TempDir::new("root-lock");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");

    let first = open(&root, &vault).expect("first writer opens");
    let refused = open(&root, &vault).expect_err("a second writer is refused");
    assert_eq!(refused.code(), EndpointV7StorageError::ROOT_LOCKED);
    drop(first);
    let _second = open(&root, &vault).expect("the lock is released with the handle");
}

#[test]
fn a_future_schema_is_refused_without_migrating() {
    let temp = TempDir::new("future-schema");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    fs::create_dir_all(&root).expect("root");
    {
        let connection =
            rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database");
        connection
            .execute_batch(
                "CREATE TABLE endpoint_v7_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO endpoint_v7_meta (key, value) VALUES ('schema_version', '99');",
            )
            .expect("future schema fixture");
    }
    let refused = open(&root, &vault).expect_err("a newer schema is refused");
    assert_eq!(
        refused.code(),
        EndpointV7StorageError::SCHEMA_UNSUPPORTED,
        "a schema this build does not know is never migrated"
    );
    assert_eq!(
        meta_value(&root, "schema_version").as_deref(),
        Some("99"),
        "the refused database is left exactly as it was"
    );
}

#[test]
fn an_interrupted_schema_upgrade_is_completed_without_losing_state() {
    let temp = TempDir::new("interrupted-upgrade");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");

    {
        let storage = open(&root, &vault).expect("fresh root");
        let mut store = storage.state_store();
        let current = store.load().expect("initial load");
        let pending = PendingItem::packet(PendingId::from_token(7), b"opaque-committed".to_vec())
            .expect("bounded pending item");
        store
            .compare_and_swap(
                current.revision(),
                Commit::bounded(current.state().clone(), Vec::new(), vec![pending], 4, 16)
                    .expect("bounded commit"),
            )
            .expect("commit with one pending record");
    }

    // The version marker is written in the same transaction as the additive
    // DDL; a crash before that commit leaves exactly this window.
    {
        let connection =
            rusqlite::Connection::open(root.join("endpoint-v7.sqlite3")).expect("database");
        connection
            .execute(
                "DELETE FROM endpoint_v7_meta WHERE key = 'schema_version'",
                [],
            )
            .expect("simulate the interrupted upgrade window");
    }

    let storage = open(&root, &vault).expect("the schema upgrade completes");
    assert_eq!(
        meta_value(&root, "schema_version").as_deref(),
        Some("1"),
        "the version marker is restored"
    );
    let status = storage.status().expect("status");
    assert_eq!(status.continuity, EndpointV7Continuity::ContinuityLost);
    assert_eq!(status.generation, 1);
    assert_eq!(
        status.fenced_pending_count, 1,
        "committed work is preserved"
    );
    let facts = storage
        .recovered_facts()
        .expect("facts")
        .expect("a lost session is reported");
    assert_eq!(facts.fenced_pending.len(), 1);
    assert_eq!(facts.fenced_pending[0].kind, EndpointV7PendingKind::Packet);
    let drained = storage
        .take_recovered_pending_payloads()
        .expect("draining fenced payloads");
    assert_eq!(drained.len(), 1);
    assert_eq!(
        drained[0].1,
        EndpointV7PendingPayload::Packet(b"opaque-committed".to_vec()),
        "the committed bytes are recovered byte-for-byte"
    );
    assert_eq!(storage.status().expect("status").fenced_pending_count, 0);
}

#[test]
fn a_rolled_back_database_is_refused_until_an_explicit_new_session() {
    let temp = TempDir::new("rollback");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    let backup = temp.path().join("endpoint-v7.sqlite3.backup");

    {
        let storage = open(&root, &vault).expect("fresh root");
        let mut store = storage.state_store();
        let mut revision = store.load().expect("initial load").revision();
        for _ in 0..2 {
            let current = store.load().expect("load");
            revision = store
                .compare_and_swap(
                    revision,
                    Commit::bounded(current.state().clone(), Vec::new(), Vec::new(), 4, 16)
                        .expect("bounded commit"),
                )
                .expect("commit");
        }
    }
    fs::copy(root.join("endpoint-v7.sqlite3"), &backup).expect("backup of generation 2");

    {
        let storage = open(&root, &vault).expect("reopen");
        let mut store = storage.state_store();
        // The reopened root lost its snapshot, so the durable generation is
        // ahead: this reopen is the lost-session path, and it refuses to load
        // until an explicit new epoch.
        assert!(!storage.status().expect("status").continuity.loadable());
        let facts = storage.begin_new_session().expect("new session");
        assert_eq!(facts.generation, 2);
        let current = store.load().expect("fresh snapshot");
        let next = store
            .compare_and_swap(
                current.revision(),
                Commit::bounded(current.state().clone(), Vec::new(), Vec::new(), 4, 16)
                    .expect("bounded commit"),
            )
            .expect("commit after new session");
        assert_eq!(next.value(), 1);
    }

    // An older database file (with a live, newer anchor) is a rollback: the
    // store refuses to load and never reuses the old sequence.
    remove_database_siblings(&root);
    fs::copy(&backup, root.join("endpoint-v7.sqlite3")).expect("restore the older database");
    let storage = open(&root, &vault).expect("the root still opens");
    assert_eq!(
        storage.status().expect("status").continuity,
        EndpointV7Continuity::RolledBack
    );
    assert_eq!(
        storage
            .state_store()
            .load()
            .expect_err("a rolled-back generation is never presented")
            .code,
        ErrorCode::StateRollback
    );
    // Reopening without an explicit new session must still report the
    // rollback: classification never overwrites the newer anchor.
    drop(storage);
    let storage = open(&root, &vault).expect("the rolled-back root reopens");
    assert_eq!(
        storage.status().expect("status").continuity,
        EndpointV7Continuity::RolledBack
    );
    let facts = storage.begin_new_session().expect("explicit new session");
    assert!(facts.rollback_suspected);
    let mut store = storage.state_store();
    assert_eq!(
        store.load().expect("fresh snapshot").revision(),
        Revision::initial()
    );
    let current = store.load().expect("fresh snapshot");
    assert!(
        store
            .compare_and_swap(
                current.revision(),
                Commit::bounded(current.state().clone(), Vec::new(), Vec::new(), 4, 16)
                    .expect("bounded commit"),
            )
            .is_ok(),
        "the explicit new epoch can commit again"
    );
}

#[test]
fn a_revoked_root_is_terminal_and_its_material_is_deleted() {
    let temp = TempDir::new("revoke");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");

    {
        let storage = open(&root, &vault).expect("fresh root");
        storage
            .custody()
            .install_device_identity(synthetic_seed(0x61), synthetic_seed(0x62))
            .expect("device identity installs");
        let staged = storage
            .custody()
            .stage_x25519(synthetic_seed(0x63))
            .expect("staging");
        let mut store = storage.state_store();
        let current = store.load().expect("initial load");
        store
            .compare_and_swap(
                current.revision(),
                adopt_commit(current.state(), KeyMutation::AdoptX25519(staged))
                    .expect("bounded commit"),
            )
            .expect("adoption commits");
        assert!(fixture_material_count(&vault) >= 3);
        let facts = storage.revoke().expect("revocation commits");
        assert_eq!(facts.session_keys_fenced, 1);
        assert_eq!(
            storage
                .state_store()
                .load()
                .expect_err("a revoked root never loads")
                .code,
            ErrorCode::Deleted
        );
        assert_eq!(
            storage
                .revoke()
                .expect_err("revocation is not repeatable")
                .code(),
            EndpointV7StorageError::REVOKED
        );
        assert_eq!(fixture_material_count(&vault), 0);
    }

    let storage = open(&root, &vault).expect("a revoked root still opens for status");
    assert_eq!(
        storage.status().expect("status").continuity,
        EndpointV7Continuity::Revoked
    );
    assert_eq!(
        storage
            .state_store()
            .load()
            .expect_err("a revoked root never loads")
            .code,
        ErrorCode::Deleted
    );
    assert_eq!(
        storage
            .begin_new_session()
            .expect_err("revocation is terminal")
            .code(),
        EndpointV7StorageError::REVOKED
    );
    assert!(
        storage
            .custody()
            .install_device_identity(synthetic_seed(0x61), synthetic_seed(0x62))
            .is_err(),
        "a revoked root cannot install an identity"
    );
}

#[test]
fn a_read_only_root_refuses_open_without_losing_committed_state() {
    let temp = TempDir::new("read-only");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");

    {
        let storage = open(&root, &vault).expect("fresh root");
        let mut store = storage.state_store();
        let current = store.load().expect("initial load");
        store
            .compare_and_swap(
                current.revision(),
                Commit::bounded(current.state().clone(), Vec::new(), Vec::new(), 4, 16)
                    .expect("bounded commit"),
            )
            .expect("commit");
    }

    let database = root.join("endpoint-v7.sqlite3");
    remove_database_siblings(&root);
    let database_mode = fs::metadata(&database)
        .expect("database metadata")
        .permissions();
    set_mode(&database, 0o400);
    let refused = open(&root, &vault).expect_err("an unwritable database is refused");
    assert_eq!(refused.code(), EndpointV7StorageError::IO);
    remove_database_siblings(&root);
    set_mode(&database, database_mode.mode());
    let storage = open(&root, &vault).expect("the restored root opens");
    assert_eq!(storage.status().expect("status").generation, 1);
}

#[test]
fn an_unwritable_custody_platform_leaves_no_dangling_registry_row() {
    let temp = TempDir::new("custody-permission");
    let vault = Arc::new(FixtureVault::new(temp.path().join("vault")));
    let root = temp.path().join("endpoint");
    let storage = open(&root, &vault).expect("fresh root");
    assert_eq!(custody_row_count(&root), 0);

    set_mode(vault.path(), 0o500);
    let refused = storage
        .custody()
        .stage_x25519(synthetic_seed(0x71))
        .expect_err("an unwritable platform refuses the write");
    assert_eq!(refused.code(), EndpointV7StorageError::MATERIAL_UNAVAILABLE);
    assert_eq!(
        custody_row_count(&root),
        0,
        "a failed material write never leaves a registry row behind"
    );
    set_mode(vault.path(), 0o700);
    assert!(
        storage.custody().stage_x25519(synthetic_seed(0x72)).is_ok(),
        "the platform recovers with its permissions"
    );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).expect("permissions are settable");
}

#[cfg(not(unix))]
fn set_mode(path: &Path, _mode: u32) {
    let _ = path;
}

#[cfg(unix)]
trait ModeExt {
    fn mode(&self) -> u32;
}

#[cfg(unix)]
impl ModeExt for fs::Permissions {
    fn mode(&self) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        PermissionsExt::mode(self)
    }
}

#[cfg(not(unix))]
trait ModeExt {
    fn mode(&self) -> u32;
}

#[cfg(not(unix))]
impl ModeExt for fs::Permissions {
    fn mode(&self) -> u32 {
        0
    }
}

fn remove_database_siblings(root: &Path) {
    for suffix in ["-wal", "-shm", "-journal"] {
        let candidate = Path::new(&format!(
            "{}{suffix}",
            root.join("endpoint-v7.sqlite3").display()
        ))
        .to_path_buf();
        let _ = fs::remove_file(candidate);
    }
}
