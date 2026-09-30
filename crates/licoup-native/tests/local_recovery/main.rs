//! Local recovery oracle for a converted data root.
//!
//! One oracle joins the delivered native owners end to end: a synthetic root arranged
//! at the shape the last published release left is converted by the client's own
//! admission owner, exported to both plaintext containers, imported into disposable
//! destinations, and reopened through the real store and credential owners.
//!
//! What is real here: `client_state_migration::admit`,
//! `full_data_root_archive::{export_data_root, restore_data_root}`,
//! `ConversationStore`, `StrategyStore`, `ClientStateStore`,
//! `PlatformLlmApiKeyVault`, the SQLite engine, the file lock and the private-file
//! hardening. Every fixture below is a file of a published shape, and every assertion
//! is read back either from a root on disk or from the owner that owns it.
//!
//! # The released shape
//!
//! The fixture states the published shape once, from the release record the repository
//! holds — the published **nightly**, product version `0.3.0` (build 3), whose data
//! frontier is `licoup-state-0.2.1`. The repository publishes two artifacts and their
//! frontiers differ: the stable `v0.2.1` tag carries `licoup-state-0.1.1`, the nightly
//! carries `licoup-state-0.2.1`, and this working tree carries `licoup-state-0.3.0`.
//! The fixed source endpoint of this milestone is the nightly, so the conversion proved
//! here is `licoup-state-0.2.1` → `licoup-state-0.3.0`:
//!
//! * every domain the published frontier declares at schema version 1 — including
//!   `gateway-credential-custody`, which that frontier already declares — with the
//!   ledger recording the frontier the root was admitted through;
//! * the published strategy store, `strategy_meta.version = '2'`, whose published column
//!   lists are `strategy-store-2` in the migration owner's publication history: the
//!   format domain version 1 answers to;
//! * the published canonical Conversation store, `schema_meta.version = '15'`, the inner
//!   schema the published nightly wrote, with the published `migration-v5.complete`
//!   marker;
//! * published JSON documents at the stamps the published probe accepts;
//! * credential metadata at the data root, where the credential inventory owner reads
//!   it (`PlatformLlmApiKeyVault::at_state_root`/`production`), in the shape and with
//!   the permissions that owner accepts;
//! * the protected credential step in either form that release leaves: the domain marker
//!   together with the credential metadata it produces, or — while the protected
//!   migration is still owed — neither.
//!
//! The released root is read only. Every disposable working root is created by this
//! file, and removed when its case succeeds, so a failed stage can never be confused
//! with a converted or a restored one.
//!
//! # Known divergence this file does not paper over
//!
//! The archive owner's credential coverage rule names `client-state/llm-api-key-inventory.json`
//! as the credential reference store, while the credential inventory owner reads
//! `<data root>/llm-api-key-inventory.json` — the path the released client wrote and the
//! path production still constructs that owner at. A faithful released root therefore
//! reports `coverage: limited` for `gateway-credential-custody` even though the credential
//! metadata is captured and stays readable by its owner. That divergence belongs to the
//! two owners, not to this oracle, so this file asserts the facts that matter — the
//! credential member is in the archive's own declared inventory and its owner lists it
//! after the round trip — instead of asserting the divergent coverage report as correct.
//!
//! # Oracle
//!
//! Each stage is compared against an independently arranged expectation, and the roots
//! are read from disk rather than trusted: the released root's fingerprint must be
//! unchanged after conversion, export and import; the converted root's fingerprint must
//! be unchanged by export, import and a repeated conversion; and the reopened owners
//! must report the arranged content. A version marker alone never satisfies this file:
//! `local_recovery_a_version_marker_alone_does_not_satisfy_the_oracle` runs the same
//! comparison against a root that carries nothing but target-version markers and
//! requires it to fail.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use licoup_foundation::core::full_data_root_archive::{
    ArchiveContainer, ArchiveManifest, ExportOutcome, ExportRequest, RecoveryCoverage,
    RestoreRequest, export_data_root, restore_data_root,
};
use licoup_native::domain::client_conversation::ConversationStore;
use licoup_native::domain::client_state_migration::{
    AdmissionResult, DomainStateProjection, admit, domain_state_projection,
    frontier_projection_struct, gateway_credential_migration_pending, running_product_version,
};
use licoup_native::domain::workflow_store::StrategyStore;
use licoup_native::platform::client_state::ClientStateStore;
use licoup_native::platform::file_security::{
    atomic_write_private_text, ensure_private_dir, harden_private_tree,
};
use licoup_native::platform::llm_api_key_vault::PlatformLlmApiKeyVault;
use rusqlite::{Connection, OptionalExtension};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

// ---------------------------------------------------------------------------
// The released record
// ---------------------------------------------------------------------------

/// The frontier identity of the published nightly: the fixed source endpoint this
/// milestone converts from. The stable `v0.2.1` tag carries `licoup-state-0.1.1`.
const RELEASED_FRONTIER_ID: &str = "licoup-state-0.2.1";
/// Every domain the published frontier declared sat at schema version 1.
const RELEASED_DOMAIN_SCHEMA_VERSION: u32 = 1;
/// The published strategy store's `strategy_meta.version`.
const RELEASED_STRATEGY_META_VERSION: &str = "2";
/// The published canonical Conversation inner schema, the value the published nightly
/// wrote and validated.
const RELEASED_CONVERSATION_SCHEMA_VERSION: &str = "15";
/// The product version this working tree's release record names, read at run time from
/// `tools/client-version.json` rather than restated here.
const PRODUCT_VERSION_MANIFEST: &str = "tools/client-version.json";
/// The development product version `client_state_migration` falls back to when the
/// packaging pipeline did not inject one. A root may only record a version the binary
/// that admits it does not predate, so a development build records its own identity.
const DEVELOPMENT_PRODUCT_FALLBACK: &str = "0.0.1-alpha";
/// The published Conversation cutover marker, byte for byte.
const PUBLISHED_CONVERSATION_COMPLETION: &str = "schema=v5\nstatus=complete\n";
/// The current Conversation inner schema, written by the store's own upgrade.
const CURRENT_CONVERSATION_SCHEMA_VERSION: &str = "18";
/// The current strategy store's `strategy_meta.version`.
const CURRENT_STRATEGY_META_VERSION: &str = "3";
/// The credential custody domain the published frontier declares and the archive owner
/// names as the domain whose credential reference store must travel for a complete
/// recovery.
const CREDENTIAL_DOMAIN_ID: &str = "gateway-credential-custody";

/// Migration bookkeeping identity strings. The owner's constants are crate private, so
/// the fixture names the fixed schema identities explicitly, exactly as the sibling
/// archive acceptance test names the fixed manifest member. The released and the current
/// values are identical for both.
const LEDGER_SCHEMA: &str = "v0.0.1:client-state-migration-ledger-1";
const DOMAIN_MARKER_SCHEMA: &str = "v0.0.1:client-state-domain-marker-1";
const COLLECTION_STATE_SCHEMA: &str = "v0.0.1:schema:definition-1";

/// The workflow document schema the strategy store reads back.
const WORKFLOW_SCHEMA: &str = "licoup.adaptive-flywheel.workflow.v1";

/// Root-relative paths of the state this oracle arranges and compares.
const STRATEGY_STORE: &str = "client-state/adaptive-flywheel/strategies.sqlite3";
const CONVERSATION_STORE: &str = "client-state/conversations/conversations.sqlite3";
const CONVERSATION_COMPLETION: &str = "client-state/conversations/migration-v5.complete";
const CREDENTIAL_INVENTORY: &str = "llm-api-key-inventory.json";
const SETTINGS_COLLECTION: &str = "client-state/settings.json";
const APPEARANCE_DOCUMENT: &str = "client-state/appearance-preferences.json";
const TAB_ORDER_DOCUMENT: &str = "client-state/agent-tab-order.json";
const WORKSPACE_MANIFEST: &str = ".licoup-workspace.json";

// The arranged expectation. These are the values the fixture writes once; every stage
// compares what the owners report against them.
const ARRANGED_CONVERSATION_ID: &str = "conversation-released-1";
const ARRANGED_CONVERSATION_TITLE: &str = "Released conversation";
const ARRANGED_DEFINITION_ID: &str = "released-definition";
const ARRANGED_REVISION_DIGEST: &str = "released-revision-1";
const ARRANGED_DEFINITION_NAME: &str = "Released strategy";
const ARRANGED_DEFINITION_VERSION: &str = "1";
const ARRANGED_SLOT_ID: &str = "worker";
const ARRANGED_BINDING_VALUE_ID: &str = "agent:released-value";
const ARRANGED_BINDING_REVISION: u64 = 3;
const ARRANGED_SETTINGS_THEME: &str = "orbital-dark";
const ARRANGED_APPEARANCE_PRESET: &str = "orbital-dark";
const ARRANGED_APPEARANCE_LOCALE: &str = "en";
const ARRANGED_TAB_ORDER: [&str; 2] = ["agent-alpha", "agent-beta"];
const ARRANGED_WORKSPACE_NAME: &str = "released-workspace";
const ARRANGED_CREDENTIAL_ID: &str = "6f1d2c3a-4b5e-4f70-8a91-0b1c2d3e4f50";
const ARRANGED_CREDENTIAL_LABEL: &str = "Released model key";
const ARRANGED_CREDENTIAL_PROVIDER: &str = "kimi";
const ARRANGED_CREDENTIAL_LEASE_DAYS: u16 = 30;
const ARRANGED_CREDENTIAL_CREATED_AT: u64 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Disposable roots
// ---------------------------------------------------------------------------

/// The repository root, resolved from this test file's own crate directory.
fn repository_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("the crate lives two levels below the repository root")
        .to_path_buf()
}

/// A disposable root for one case, below this Task's declared artifact directory.
///
/// Each case owns its own directory and clears it before use, so a leftover root from a
/// failed earlier run is never read as the result of this one.
fn case_root(node: &str, case: &str) -> PathBuf {
    let root = repository_root()
        .join("build/review/n4-oracle")
        .join(node)
        .join("fixtures")
        .join(case);
    if root.exists() {
        fs::remove_dir_all(&root).expect("clear the disposable case root");
    }
    fs::create_dir_all(&root).expect("create the disposable case root");
    root
}

fn remove_case_root(root: &Path) {
    if root.exists() {
        fs::remove_dir_all(root).expect("remove the disposable case root");
    }
}

fn write_document(path: &Path, bytes: &[u8]) {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent).expect("private document directory");
    }
    atomic_write_private_text(path, &String::from_utf8_lossy(bytes))
        .expect("private document write");
}

fn read_document(path: &Path) -> Vec<u8> {
    fs::read(path).expect("read fixture document")
}

/// A document read that stays usable when a root does not carry the document at all.
///
/// A reopened root is compared against the arranged expectation whatever it holds, so an
/// absent document reports no value instead of failing the comparison for the wrong
/// reason.
fn read_json_or_null(path: &Path) -> Value {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        Err(_) => Value::Null,
    }
}

/// The product version this working tree's release record names. Read from the version
/// manifest, so the released value is never restated in this file.
fn recorded_product_version_from_manifest() -> String {
    read_json_or_null(&repository_root().join(PRODUCT_VERSION_MANIFEST))
        .get("productVersion")
        .and_then(Value::as_str)
        .expect("the release record names a product version")
        .to_owned()
}

/// The frontier a root's own ledger declares, which is the endpoint that root was
/// admitted through. Absent when the root carries no ledger.
fn ledger_frontier_id(root: &Path) -> Option<String> {
    read_json_or_null(&root.join("client-state/migrations/ledger.json"))
        .get("frontierId")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// Copy one private root to a disposable working root, preserving the shape and the
/// permissions of every entry. The released root itself is never modified.
fn copy_root(source: &Path, destination: &Path) {
    ensure_private_dir(destination).expect("converted root directory");
    let mut entries = fs::read_dir(source)
        .expect("read the released root")
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    entries.sort();
    for entry in entries {
        let relative = entry
            .strip_prefix(source)
            .expect("entry below the released root");
        let target = destination.join(relative);
        let metadata = fs::symlink_metadata(&entry).expect("released entry metadata");
        if metadata.is_dir() {
            copy_root(&entry, &target);
        } else {
            fs::copy(&entry, &target).expect("copy released entry");
            fs::set_permissions(&target, metadata.permissions()).expect("copy entry permissions");
        }
    }
}

// ---------------------------------------------------------------------------
// Fingerprints
// ---------------------------------------------------------------------------

/// One root entry: presence, kind, private mode and content digest.
///
/// The comparison is over what each stage left on disk. Mode is part of it because every
/// root here is arranged through the client's own private-file hardening, and the archive
/// extractor publishes 0600 files below 0700 directories, so a stage that changes a
/// permission is a change worth catching.
#[derive(Clone, Debug, Eq, PartialEq)]
struct RootEntry {
    path: String,
    kind: &'static str,
    mode: u32,
    bytes: usize,
    digest: String,
}

type RootFingerprint = Vec<RootEntry>;

fn fingerprint_root(root: &Path) -> RootFingerprint {
    let mut entries = Vec::new();
    collect_fingerprint(root, root, &mut entries);
    entries.sort_by(|left, right| left.path.cmp(&right.path));
    entries
}

fn collect_fingerprint(root: &Path, directory: &Path, entries: &mut Vec<RootEntry>) {
    let mut children = fs::read_dir(directory)
        .expect("readable root directory")
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    children.sort();
    for child in children {
        let relative = child
            .strip_prefix(root)
            .expect("entry below the root")
            .to_string_lossy()
            .replace('\\', "/");
        let metadata = fs::symlink_metadata(&child).expect("root entry metadata");
        assert!(
            !metadata.file_type().is_symlink(),
            "a disposable root must not contain a symbolic link: {relative}"
        );
        if metadata.is_dir() {
            entries.push(RootEntry {
                path: format!("{relative}/"),
                kind: "directory",
                mode: mode_of(&metadata),
                bytes: 0,
                digest: String::new(),
            });
            collect_fingerprint(root, &child, entries);
        } else {
            let bytes = fs::read(&child).expect("read root entry");
            entries.push(RootEntry {
                path: relative,
                kind: "file",
                mode: mode_of(&metadata),
                bytes: bytes.len(),
                digest: hex(&Sha256::digest(&bytes)),
            });
        }
    }
}

#[cfg(unix)]
fn mode_of(metadata: &fs::Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o777
}

#[cfg(not(unix))]
fn mode_of(_metadata: &fs::Metadata) -> u32 {
    0
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(DIGITS[(byte >> 4) as usize] as char);
        text.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    text
}

// ---------------------------------------------------------------------------
// The released-shape fixture
// ---------------------------------------------------------------------------

/// The two forms the published nightly leaves for its protected credential step.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReleasedProtectedCustody {
    /// The protected migration completed: the domain marker reached version 1 and the
    /// credential metadata it produced is in the root.
    Completed,
    /// The protected migration is still owed: neither the domain marker nor the
    /// credential metadata exists, which is exactly the state a user who did not answer
    /// the native prompt leaves behind.
    Deferred,
}

/// Arrange one synthetic root at the shape the published nightly left.
///
/// The domain set is read from the embedded frontier, so this fixture never restates a
/// domain list: it states the *published* fact once — every declared domain at version 1
/// — and the one domain whose protected step has its own two forms.
fn arrange_released_root(root: &Path, custody: ReleasedProtectedCustody) {
    ensure_private_dir(root).expect("released root directory");
    let frontier = frontier_projection_struct().expect("the embedded migration frontier");

    let migrations = root.join("client-state/migrations");
    let marker_root = migrations.join("domain-state");
    ensure_private_dir(&marker_root).expect("released migration directories");
    atomic_write_private_text(&migrations.join("admission.lock"), "")
        .expect("released admission lock file");

    // The published ledger and the published domain markers. The high-water mark is the
    // admitting binary's own product version: the published nightly records `0.3.0` there
    // (the version its release record names), and a development build records the identity
    // it declares, because the owner refuses a root whose record is newer than the binary
    // that opens it.
    let recorded_product_version =
        running_product_version().expect("the binary declares a product version");
    assert!(
        recorded_product_version == recorded_product_version_from_manifest()
            || recorded_product_version == DEVELOPMENT_PRODUCT_FALLBACK,
        "the recorded product version is either the release record's or the development fallback"
    );
    let mut ledger_domains = serde_json::Map::new();
    for domain in &frontier.domains {
        if domain.domain_id == CREDENTIAL_DOMAIN_ID && custody == ReleasedProtectedCustody::Deferred
        {
            continue;
        }
        let completed = domain
            .steps
            .iter()
            .filter(|step| step.to_schema_version <= RELEASED_DOMAIN_SCHEMA_VERSION)
            .map(|step| Value::String(step.step_id.clone()))
            .collect::<Vec<_>>();
        assert!(
            !completed.is_empty(),
            "every published domain reached version 1 through at least one published step"
        );
        ledger_domains.insert(
            domain.domain_id.clone(),
            json!({
                "schemaVersion": RELEASED_DOMAIN_SCHEMA_VERSION,
                "completedStepIds": completed,
            }),
        );
        write_marker(
            &marker_root,
            &domain.domain_id,
            RELEASED_DOMAIN_SCHEMA_VERSION,
        );
    }
    atomic_write_private_text(
        &migrations.join("ledger.json"),
        &json!({
            "schemaVersion": LEDGER_SCHEMA,
            "highestAdmittedProductVersion": recorded_product_version,
            "frontierId": RELEASED_FRONTIER_ID,
            "domains": ledger_domains,
        })
        .to_string(),
    )
    .expect("published ledger");

    write_released_strategy_store(root);
    write_released_conversation_store(root);
    write_released_documents(root);
    if custody == ReleasedProtectedCustody::Completed {
        write_released_credential_inventory(root);
    }

    harden_private_tree(root).expect("harden the released root");
}

fn write_marker(marker_root: &Path, domain_id: &str, version: u32) {
    atomic_write_private_text(
        &marker_root.join(format!("{domain_id}.json")),
        &json!({
            "schemaVersion": DOMAIN_MARKER_SCHEMA,
            "domainId": domain_id,
            "authoritativeSchemaVersion": version,
        })
        .to_string(),
    )
    .expect("released domain marker");
}

/// The released strategy store: `strategy-store-2` in the migration owner's publication
/// history, whose published column lists are `strategy_meta(key, value)` and ordinal
/// `strategy_bindings`, with the published `strategy_definitions` row shape. The three
/// tables below state the published definition once; the conversion itself is performed
/// by the owners under test, never here.
fn write_released_strategy_store(root: &Path) {
    let path = root.join(STRATEGY_STORE);
    ensure_private_dir(path.parent().expect("strategy store directory"))
        .expect("strategy store directory");
    let connection = Connection::open(&path).expect("released strategy store");
    connection
        .execute_batch(&format!(
            "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO strategy_meta(key, value) VALUES ('version', '{RELEASED_STRATEGY_META_VERSION}');
             CREATE TABLE strategy_definitions(
               definition_id TEXT NOT NULL,
               revision_digest TEXT PRIMARY KEY,
               semantics_digest TEXT NOT NULL,
               name TEXT NOT NULL,
               version TEXT NOT NULL,
               workflow_json TEXT NOT NULL,
               asset_count INTEGER NOT NULL,
               imported_at INTEGER NOT NULL
             );
             INSERT INTO strategy_definitions VALUES
               ('{ARRANGED_DEFINITION_ID}', '{ARRANGED_REVISION_DIGEST}', 'released-semantics-1',
                '{ARRANGED_DEFINITION_NAME}', '{ARRANGED_DEFINITION_VERSION}',
                '{workflow}', 0, 11);
             CREATE TABLE strategy_bindings(
               revision_digest TEXT NOT NULL,
               slot_id TEXT NOT NULL,
               ordinal INTEGER NOT NULL DEFAULT 0,
               value_id TEXT NOT NULL,
               model TEXT NOT NULL DEFAULT '',
               reasoning_effort TEXT NOT NULL DEFAULT '',
               revision INTEGER NOT NULL,
               PRIMARY KEY(revision_digest, slot_id, ordinal)
             );
             INSERT INTO strategy_bindings VALUES
               ('{ARRANGED_REVISION_DIGEST}', '{ARRANGED_SLOT_ID}', 0,
                '{ARRANGED_BINDING_VALUE_ID}', '', '', {ARRANGED_BINDING_REVISION});",
            workflow = released_workflow_document(),
        ))
        .expect("released strategy store schema");
    connection
        .close()
        .expect("close the released strategy store");
}

/// A minimal workflow document the strategy store reads back through its own owner.
fn released_workflow_document() -> String {
    json!({
        "schema": WORKFLOW_SCHEMA,
        "metadata": {
            "id": ARRANGED_DEFINITION_ID,
            "name": ARRANGED_DEFINITION_NAME,
            "version": ARRANGED_DEFINITION_VERSION,
        },
        "initial": "start",
        "states": [{"id": "start", "kind": "succeed", "label": "Start"}],
        "transitions": [],
    })
    .to_string()
    .replace('\'', "''")
}

/// The published canonical Conversation store: the published `conversations` identity
/// columns at the inner schema `15` the published nightly wrote, with the published
/// completion marker. The store's own ladder owns the move from there to the current
/// schema; this fixture only states the published shape once.
fn write_released_conversation_store(root: &Path) {
    let path = root.join(CONVERSATION_STORE);
    ensure_private_dir(path.parent().expect("conversation store directory"))
        .expect("conversation store directory");
    let connection = Connection::open(&path).expect("released conversation store");
    connection
        .execute_batch(&format!(
            "CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta(key, value) VALUES ('version', '{RELEASED_CONVERSATION_SCHEMA_VERSION}');
             CREATE TABLE conversations(
               id TEXT PRIMARY KEY, title TEXT NOT NULL,
               archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
               pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
               is_group INTEGER NOT NULL DEFAULT 0 CHECK(is_group IN (0,1)),
               strategy_revision TEXT, assistant_membership_id TEXT,
               revision INTEGER NOT NULL DEFAULT 0,
               created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
             );
             INSERT INTO conversations(
               id, title, archived, pinned, is_group, strategy_revision,
               assistant_membership_id, revision, created_at, updated_at
             ) VALUES ('{ARRANGED_CONVERSATION_ID}', '{ARRANGED_CONVERSATION_TITLE}',
                       0, 0, 0, NULL, NULL, 0, 21, 22);"
        ))
        .expect("released conversation store schema");
    connection
        .close()
        .expect("close the released conversation store");
    write_document(
        &root.join(CONVERSATION_COMPLETION),
        PUBLISHED_CONVERSATION_COMPLETION.as_bytes(),
    );
}

/// The published JSON documents: collections and preferences as the published nightly
/// left them, at the stamps its own probe accepts.
fn write_released_documents(root: &Path) {
    write_document(
        &root.join(SETTINGS_COLLECTION),
        json!({
            "schemaVersion": COLLECTION_STATE_SCHEMA,
            "collection": "settings",
            "theme": ARRANGED_SETTINGS_THEME,
        })
        .to_string()
        .as_bytes(),
    );
    write_document(
        &root.join(APPEARANCE_DOCUMENT),
        json!({
            "schemaVersion": 1,
            "appearancePresetId": ARRANGED_APPEARANCE_PRESET,
            "localePreference": ARRANGED_APPEARANCE_LOCALE,
        })
        .to_string()
        .as_bytes(),
    );
    write_document(
        &root.join(TAB_ORDER_DOCUMENT),
        json!({"schemaVersion": 1, "order": ARRANGED_TAB_ORDER})
            .to_string()
            .as_bytes(),
    );
    write_document(
        &root.join(WORKSPACE_MANIFEST),
        json!({"schemaVersion": 1, "name": ARRANGED_WORKSPACE_NAME, "revision": 4})
            .to_string()
            .as_bytes(),
    );
}

/// The published credential metadata, at the path its owner reads and in the shape and
/// permissions that owner accepts. Only non-secret inventory metadata is ever arranged.
fn write_released_credential_inventory(root: &Path) {
    write_document(
        &root.join(CREDENTIAL_INVENTORY),
        json!({
            "schemaVersion": "licoup.llm-api-key-inventory.v1",
            "leaseDays": ARRANGED_CREDENTIAL_LEASE_DAYS,
            "entries": [{
                "credentialId": ARRANGED_CREDENTIAL_ID,
                "provider": ARRANGED_CREDENTIAL_PROVIDER,
                "label": ARRANGED_CREDENTIAL_LABEL,
                "createdAtEpochSeconds": ARRANGED_CREDENTIAL_CREATED_AT,
            }],
        })
        .to_string()
        .as_bytes(),
    );
}

// ---------------------------------------------------------------------------
// Reading the roots
// ---------------------------------------------------------------------------

fn sqlite_text(path: &Path, sql: &str) -> Option<String> {
    let connection = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .expect("open a store read-only");
    connection
        .query_row(sql, [], |row| row.get(0))
        .optional()
        .expect("store query")
}

fn sqlite_has_table(path: &Path, table: &str) -> bool {
    let connection = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .expect("open a store read-only");
    let present: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
            [table],
            |row| row.get(0),
        )
        .expect("schema query");
    present > 0
}

/// The facts the arranged stores must carry, read from a root rather than from a report.
#[derive(Clone, Debug, Eq, PartialEq)]
struct StoreFacts {
    strategy_meta_version: String,
    notice_outbox_present: bool,
    conversation_schema_version: String,
    conversation_completion: String,
}

fn store_facts(root: &Path) -> StoreFacts {
    let strategy = root.join(STRATEGY_STORE);
    let conversation = root.join(CONVERSATION_STORE);
    StoreFacts {
        strategy_meta_version: sqlite_text(
            &strategy,
            "SELECT value FROM strategy_meta WHERE key='version'",
        )
        .expect("the strategy store records its format"),
        notice_outbox_present: sqlite_has_table(&strategy, "workflow_notice_intents")
            && sqlite_has_table(&strategy, "workflow_notice_acceptances"),
        conversation_schema_version: sqlite_text(
            &conversation,
            "SELECT value FROM schema_meta WHERE key='version'",
        )
        .expect("the conversation store records its schema"),
        conversation_completion: String::from_utf8(read_document(
            &root.join(CONVERSATION_COMPLETION),
        ))
        .expect("the completion marker is UTF-8"),
    }
}

fn released_store_facts() -> StoreFacts {
    StoreFacts {
        strategy_meta_version: RELEASED_STRATEGY_META_VERSION.to_owned(),
        notice_outbox_present: false,
        conversation_schema_version: RELEASED_CONVERSATION_SCHEMA_VERSION.to_owned(),
        conversation_completion: PUBLISHED_CONVERSATION_COMPLETION.to_owned(),
    }
}

fn converted_store_facts() -> StoreFacts {
    StoreFacts {
        strategy_meta_version: CURRENT_STRATEGY_META_VERSION.to_owned(),
        notice_outbox_present: true,
        conversation_schema_version: CURRENT_CONVERSATION_SCHEMA_VERSION.to_owned(),
        conversation_completion: PUBLISHED_CONVERSATION_COMPLETION.to_owned(),
    }
}

// ---------------------------------------------------------------------------
// Reopening a root through its owners
// ---------------------------------------------------------------------------

/// What the real owners report for one root. Every field is produced by an owner read,
/// never by reading the expectation back out of a fixture.
#[derive(Clone, Debug, Eq, PartialEq)]
struct ReopenedFacts {
    conversations: Vec<(String, String)>,
    definitions: Vec<(String, String, String, String)>,
    bindings: Vec<(String, u8, String, u64)>,
    settings_theme: String,
    credentials: Vec<(String, String, u16)>,
    appearance_preset: String,
    appearance_locale: String,
    tab_order: Vec<String>,
    workspace_name: String,
}

/// Reopen one restored or converted root through the client's own owners.
///
/// The credential inventory owner is constructed the way the client constructs it in
/// production, at the data root, which is also where the released client wrote the
/// metadata. The client-state collection owner is constructed at the state root the
/// collection owner itself names (`<data root>/client-state`).
fn reopen_owners(root: &Path) -> ReopenedFacts {
    let conversations = ConversationStore::open(root)
        .expect("the conversation owner opens the root")
        .list(false)
        .expect("the conversation owner lists its store")
        .into_iter()
        .map(|summary| (summary.id, summary.title))
        .collect();

    let strategy = StrategyStore::open(root).expect("the strategy owner opens the root");
    let definitions = strategy
        .list_definitions()
        .expect("the strategy owner lists its definitions")
        .into_iter()
        .map(|summary| {
            (
                summary.definition_id,
                summary.revision_digest,
                summary.name,
                summary.version,
            )
        })
        .collect();
    let definition = strategy.latest_definition(ARRANGED_DEFINITION_ID).ok();
    let bindings = definition
        .iter()
        .flat_map(|definition| definition.bindings.iter())
        .map(|binding| {
            (
                binding.slot_id.clone(),
                binding.ordinal,
                binding.value_id.clone(),
                binding.revision,
            )
        })
        .collect();

    let settings = ClientStateStore::new(root.join("client-state"))
        .expect("the client-state owner opens the state root")
        .read_collection("settings")
        .expect("the client-state owner reads the arranged collection");

    let appearance = read_json_or_null(&root.join(APPEARANCE_DOCUMENT));
    let tab_order = read_json_or_null(&root.join(TAB_ORDER_DOCUMENT));
    let workspace = read_json_or_null(&root.join(WORKSPACE_MANIFEST));

    ReopenedFacts {
        conversations,
        definitions,
        bindings,
        settings_theme: settings
            .get("theme")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        credentials: read_credentials(root),
        appearance_preset: appearance
            .get("appearancePresetId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        appearance_locale: appearance
            .get("localePreference")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        tab_order: tab_order
            .get("order")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default(),
        workspace_name: workspace
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
    }
}

/// The credential inventory owner's listing, read once and shaped for comparison.
fn read_credentials(root: &Path) -> Vec<(String, String, u16)> {
    let inventory = PlatformLlmApiKeyVault::at_state_root(root)
        .expect("the credential inventory owner opens the data root")
        .list()
        .expect("the credential inventory owner lists its metadata");
    inventory
        .entries
        .into_iter()
        .map(|entry| (entry.credential_id, entry.label, inventory.lease_days))
        .collect()
}

/// The independently arranged expectation: what every reopened root must report.
fn arranged_expectation() -> ReopenedFacts {
    ReopenedFacts {
        conversations: vec![(
            ARRANGED_CONVERSATION_ID.to_owned(),
            ARRANGED_CONVERSATION_TITLE.to_owned(),
        )],
        definitions: vec![(
            ARRANGED_DEFINITION_ID.to_owned(),
            ARRANGED_REVISION_DIGEST.to_owned(),
            ARRANGED_DEFINITION_NAME.to_owned(),
            ARRANGED_DEFINITION_VERSION.to_owned(),
        )],
        bindings: vec![(
            ARRANGED_SLOT_ID.to_owned(),
            0,
            ARRANGED_BINDING_VALUE_ID.to_owned(),
            ARRANGED_BINDING_REVISION,
        )],
        settings_theme: ARRANGED_SETTINGS_THEME.to_owned(),
        credentials: vec![(
            ARRANGED_CREDENTIAL_ID.to_owned(),
            ARRANGED_CREDENTIAL_LABEL.to_owned(),
            ARRANGED_CREDENTIAL_LEASE_DAYS,
        )],
        appearance_preset: ARRANGED_APPEARANCE_PRESET.to_owned(),
        appearance_locale: ARRANGED_APPEARANCE_LOCALE.to_owned(),
        tab_order: ARRANGED_TAB_ORDER
            .iter()
            .map(|id| (*id).to_owned())
            .collect(),
        workspace_name: ARRANGED_WORKSPACE_NAME.to_owned(),
    }
}

// ---------------------------------------------------------------------------
// Archive helpers
// ---------------------------------------------------------------------------

fn export(root: &Path, archive: &Path) -> ExportOutcome {
    export_data_root(&ExportRequest {
        data_root: root.to_path_buf(),
        archive_path: archive.to_path_buf(),
        writers_stopped: true,
    })
    .expect("export succeeds")
}

fn restore(
    archive: &Path,
    target: &Path,
) -> licoup_foundation::core::full_data_root_archive::RestoreOutcome {
    restore_data_root(&RestoreRequest {
        archive_path: archive.to_path_buf(),
        target_root: target.to_path_buf(),
    })
    .expect("restore succeeds")
}

/// The archive's own declared inventory, read from the container rather than trusted
/// from an outcome value.
fn archive_manifest(archive: &Path) -> ArchiveManifest {
    let bytes = fs::read(archive).expect("read the archive");
    let mut zip =
        zip::ZipArchive::new(std::io::Cursor::new(bytes)).expect("the archive is a ZIP container");
    let mut member = zip
        .by_name("licoup-data-root.json")
        .expect("the archive carries its manifest first");
    let mut manifest = Vec::new();
    std::io::Read::read_to_end(&mut member, &mut manifest).expect("read the manifest");
    serde_json::from_slice(&manifest).expect("the manifest is a manifest")
}

fn assert_projection_is_at_target(root: &Path, admission: &AdmissionResult) {
    let frontier = frontier_projection_struct().expect("the embedded migration frontier");
    let projection = domain_state_projection(root).expect("the domain state projection");
    assert_eq!(
        projection.len(),
        frontier.domains.len(),
        "every declared domain is projected"
    );
    let projected = projection
        .iter()
        .map(|state| (state.domain_id.clone(), state))
        .collect::<BTreeMap<_, _>>();
    for domain in &frontier.domains {
        let state = projected
            .get(&domain.domain_id)
            .expect("every frontier domain is projected");
        if admission
            .pending_authorization_domain_ids
            .contains(&domain.domain_id)
        {
            assert!(
                state.effective_version < domain.target_schema_version,
                "{} owes platform authorization and must not read as recovered: {state:?}",
                domain.domain_id
            );
            continue;
        }
        // Every domain the admission did not leave pending records the target. Which
        // store each domain owns is the owner's business, so this file does not restate
        // a per-domain store expectation; the store-backed domains are compared through
        // their owners and through the store facts above.
        assert_eq!(
            state.marker_schema_version,
            Some(domain.target_schema_version),
            "{} was admitted, so its marker records the target",
            domain.domain_id
        );
    }
}

fn domain_state<'a>(
    projection: &'a [DomainStateProjection],
    domain_id: &str,
) -> &'a DomainStateProjection {
    projection
        .iter()
        .find(|state| state.domain_id == domain_id)
        .unwrap_or_else(|| panic!("{domain_id} is a declared domain"))
}

/// One comparable projection value per domain, so "before" and "after" are a value
/// comparison rather than a comparison of whatever the projection type happens to derive.
type ProjectionFacts = Vec<(String, u32, Option<u32>, u32, u32)>;

fn projection_facts(root: &Path) -> ProjectionFacts {
    domain_state_projection(root)
        .expect("the domain state projection")
        .into_iter()
        .map(|state| {
            (
                state.domain_id,
                state.store_version,
                state.marker_schema_version,
                state.effective_version,
                state.target_schema_version,
            )
        })
        .collect()
}

// ---------------------------------------------------------------------------
// AC-001: convert, round-trip both containers, reopen through the real owners
// ---------------------------------------------------------------------------

#[test]
fn local_recovery_converted_root_round_trips_through_both_containers() {
    let released = case_root("NODE-001", "released-root");
    arrange_released_root(&released, ReleasedProtectedCustody::Completed);

    // The fixture is the published nightly's shape, and the endpoints differ: the source
    // declares the published frontier, the binary declares its own. Without a domain
    // below the target the conversion claim would be vacuous.
    assert_eq!(store_facts(&released), released_store_facts());
    assert_eq!(
        ledger_frontier_id(&released).as_deref(),
        Some(RELEASED_FRONTIER_ID),
        "the released root declares the published source endpoint"
    );
    let frontier = frontier_projection_struct().expect("frontier");
    assert_ne!(
        frontier.frontier_id, RELEASED_FRONTIER_ID,
        "the binary's own target endpoint must differ from the published source"
    );
    println!(
        "recorded product version: manifest={} binary={} (development fallback {})",
        recorded_product_version_from_manifest(),
        running_product_version().expect("the binary declares a product version"),
        DEVELOPMENT_PRODUCT_FALLBACK
    );
    let released_projection = domain_state_projection(&released).expect("projection");
    let mut owed = Vec::new();
    for domain in &frontier.domains {
        let state = domain_state(&released_projection, &domain.domain_id);
        assert_eq!(
            state.marker_schema_version,
            Some(RELEASED_DOMAIN_SCHEMA_VERSION),
            "{} was published at version 1: {state:?}",
            domain.domain_id
        );
        if domain.target_schema_version > RELEASED_DOMAIN_SCHEMA_VERSION {
            owed.push(domain.domain_id.clone());
            assert!(
                state.effective_version < domain.target_schema_version,
                "{} is owed by the source endpoint: {state:?}",
                domain.domain_id
            );
        } else {
            assert_eq!(
                state.effective_version, domain.target_schema_version,
                "{} is already at the target the published frontier names",
                domain.domain_id
            );
        }
    }
    assert!(
        !owed.is_empty(),
        "the source endpoint must owe at least one domain for this oracle to prove a conversion"
    );
    println!("source endpoints: frontier={RELEASED_FRONTIER_ID} owes={owed:?}");
    let released_fingerprint = fingerprint_root(&released);

    // Conversion runs on a disposable copy; the released root stays read only.
    let converted = case_root("NODE-001", "converted-root");
    copy_root(&released, &converted);
    let admission = match admit(&converted) {
        Ok(admission) => admission,
        Err(error) => {
            // `admit` reports one stable code by design, so a refusal is reported with the
            // published shape it was reading and with the cause the store owner gives.
            let published_schema = store_facts(&converted).conversation_schema_version;
            let cause = ConversationStore::open_for_migration(&converted)
                .err()
                .map(|cause| cause.to_string())
                .unwrap_or_else(|| "the conversation owner opened the published store".to_owned());
            panic!(
                "the client's own admission refused the published nightly root ({error}); the \
                 conversation store records published inner schema {published_schema} and the \
                 conversation owner reports: {cause}"
            );
        }
    };
    assert_eq!(admission.status, "ready");
    assert!(
        admission
            .applied_domain_ids
            .iter()
            .any(|domain| owed.contains(domain)),
        "a domain the source endpoint owed must be reported as converted: {admission:?}"
    );
    assert_eq!(
        admission.frontier_id, frontier.frontier_id,
        "the admission names the binary's own target endpoint"
    );
    assert_eq!(
        ledger_frontier_id(&converted).as_deref(),
        Some(frontier.frontier_id.as_str()),
        "the converted root declares the target endpoint instead of the published one"
    );
    assert_projection_is_at_target(&converted, &admission);
    // The published nightly already declares the protected credential domain at version 1,
    // and a root that completed that step carries its marker, so no domain is left owed on
    // either platform. The deferred form is covered by the incomplete-recovery case.
    assert!(
        admission.pending_authorization_domain_ids.is_empty(),
        "a root whose protected step completed owes no platform authorization: {admission:?}"
    );
    assert!(
        !gateway_credential_migration_pending(&converted).expect("pending projection"),
        "no domain is left owing the protected credential migration"
    );
    assert_eq!(
        store_facts(&converted),
        converted_store_facts(),
        "the converted root carries the current store formats"
    );
    println!(
        "converted: applied={:?} skipped={:?} pending={:?}",
        admission.applied_domain_ids,
        admission.skipped_domain_ids,
        admission.pending_authorization_domain_ids
    );

    // Every converted root reopens through the real owners with the arranged content.
    assert_eq!(reopen_owners(&converted), arranged_expectation());
    let converted_fingerprint = fingerprint_root(&converted);

    // Export the converted root to both plaintext containers.
    let work = case_root("NODE-002", "containers");
    let zip_archive = work.join("converted.zip");
    let tar_archive = work.join("converted.tar.gz");
    let zip_outcome = export(&converted, &zip_archive);
    let tar_outcome = export(&converted, &tar_archive);
    assert_eq!(zip_outcome.container, ArchiveContainer::Zip);
    assert_eq!(tar_outcome.container, ArchiveContainer::TarGz);
    assert_eq!(
        zip_outcome.file_count, tar_outcome.file_count,
        "both containers carry the same logical payload"
    );
    assert_eq!(zip_outcome.total_bytes, tar_outcome.total_bytes);
    println!(
        "export: coverage={:?} limitations={:?} files={} bytes={}",
        zip_outcome.coverage,
        zip_outcome.limitations,
        zip_outcome.file_count,
        zip_outcome.total_bytes
    );

    // The credential member is in the archive's own declared inventory, and its owner
    // reads it back from both restored roots. The archive owner's credential coverage
    // rule names a different path than the credential owner writes; that divergence is
    // reported to the maintainer rather than asserted as this oracle's contract, so the
    // oracle states the fact that matters: the member travelled and stayed usable.
    let manifest = archive_manifest(&zip_archive);
    let credential_entry = manifest
        .entries
        .iter()
        .find(|entry| entry.path == CREDENTIAL_INVENTORY)
        .expect("the archive declares the credential metadata member");
    assert_eq!(
        credential_entry.size as usize,
        read_document(&released.join(CREDENTIAL_INVENTORY)).len(),
        "the declared member is the member the released root holds"
    );

    for (archive, label) in [(&zip_archive, "zip"), (&tar_archive, "tar.gz")] {
        let restored = work.join(format!("restored-{label}"));
        let outcome = restore(archive, &restored);
        assert_eq!(outcome.coverage, zip_outcome.coverage);
        assert_eq!(outcome.file_count, zip_outcome.file_count);
        assert_eq!(
            outcome.limitations, zip_outcome.limitations,
            "the limitation travels with the archive"
        );
        assert_eq!(
            reopen_owners(&restored),
            arranged_expectation(),
            "the {label} restored root reports the arranged facts through the real owners"
        );
        assert_eq!(store_facts(&restored), converted_store_facts());
    }

    // Export and import change neither the converted root nor the released source.
    assert_eq!(
        fingerprint_root(&converted),
        converted_fingerprint,
        "the converted root is unchanged by export and import"
    );
    assert_eq!(
        fingerprint_root(&released),
        released_fingerprint,
        "the released source root is unchanged by conversion, export and import"
    );

    remove_case_root(&work);
    remove_case_root(&converted);
    remove_case_root(&released);
}

// ---------------------------------------------------------------------------
// AC-002: a repeated conversion changes nothing
// ---------------------------------------------------------------------------

#[test]
fn local_recovery_repeated_conversion_changes_nothing() {
    let released = case_root("NODE-004", "released-root");
    arrange_released_root(&released, ReleasedProtectedCustody::Completed);
    let released_fingerprint = fingerprint_root(&released);

    let converted = case_root("NODE-004", "converted-root");
    copy_root(&released, &converted);
    let first = admit(&converted).expect("the first admission converts the root");
    assert!(
        !first.applied_domain_ids.is_empty(),
        "the published shape owes work: {first:?}"
    );

    let projection_before = projection_facts(&converted);
    let stores_before = fingerprint_root(&converted);

    let second = admit(&converted).expect("the second admission is admitted");
    assert_eq!(second.status, "ready");
    assert!(
        second.applied_domain_ids.is_empty(),
        "a second run must name no newly converted domain: {second:?}"
    );
    assert_eq!(
        second.skipped_domain_ids.len() + second.pending_authorization_domain_ids.len(),
        domain_state_projection(&converted)
            .expect("projection")
            .len(),
        "every declared domain is already at its target or explicitly owed: {second:?}"
    );
    assert_eq!(
        projection_facts(&converted),
        projection_before,
        "the domain state projection is unchanged by the second run"
    );
    assert_eq!(
        fingerprint_root(&converted),
        stores_before,
        "every store is byte identical after the second run"
    );
    assert_eq!(
        reopen_owners(&converted),
        arranged_expectation(),
        "the repeated run keeps the arranged facts"
    );
    assert_eq!(
        fingerprint_root(&released),
        released_fingerprint,
        "the released source root is unchanged by the repeated conversion"
    );

    remove_case_root(&converted);
    remove_case_root(&released);
}

// ---------------------------------------------------------------------------
// AC-003: refusals and incomplete recovery stay visible
// ---------------------------------------------------------------------------

#[test]
fn local_recovery_incomplete_cases_stay_visible() {
    // The published nightly leaves this form when the protected credential migration is
    // still owed: no custody domain marker and no credential metadata, because the step
    // that produces both has not run. It is the root whose credential reference store
    // cannot travel *and* the root whose conversion still owes platform authorization.
    let released = case_root("NODE-003", "released-root");
    arrange_released_root(&released, ReleasedProtectedCustody::Deferred);
    assert!(
        !released.join(CREDENTIAL_INVENTORY).exists(),
        "a root that still owes the protected step carries no credential metadata"
    );

    let without_credentials = case_root("NODE-003", "converted-without-credentials");
    copy_root(&released, &without_credentials);
    let admission = admit(&without_credentials).expect("admission");
    assert_eq!(admission.status, "ready");
    let work = case_root("NODE-003", "archives");
    let archive = work.join("without-credentials.tar.gz");
    let zip_archive = work.join("without-credentials.zip");
    let outcome = export(&without_credentials, &archive);
    let zip_outcome = export(&without_credentials, &zip_archive);
    assert_eq!(
        outcome.coverage,
        RecoveryCoverage::Limited,
        "a root whose credential store cannot travel is not a complete recovery"
    );
    assert_eq!(outcome.limitations.len(), 1);
    assert_eq!(outcome.limitations[0].domain, CREDENTIAL_DOMAIN_ID);
    assert_eq!(zip_outcome.limitations, outcome.limitations);
    // The archive's own declared inventory corroborates the limitation: no credential
    // member is in the payload, so the named limitation is not a cosmetic one.
    let manifest = archive_manifest(&zip_archive);
    assert!(
        !manifest
            .entries
            .iter()
            .any(|entry| entry.path == CREDENTIAL_INVENTORY),
        "an absent credential store leaves no credential member in the archive"
    );
    let mut credential_documents = Vec::new();
    for entry in fs::read_dir(&without_credentials).expect("read the converted root") {
        let entry = entry.expect("converted root entry");
        if entry
            .file_name()
            .to_string_lossy()
            .contains("llm-api-key-inventory")
        {
            credential_documents.push(entry.file_name().to_string_lossy().into_owned());
        }
    }
    assert!(credential_documents.is_empty(), "{credential_documents:?}");
    assert!(reopen_owners(&without_credentials).credentials.is_empty());

    let restored = work.join("restored-without-credentials");
    let restored_outcome = restore(&archive, &restored);
    assert_eq!(restored_outcome.coverage, RecoveryCoverage::Limited);
    assert_eq!(restored_outcome.limitations, outcome.limitations);
    assert!(
        reopen_owners(&restored).credentials.is_empty(),
        "the limitation is truthful: the credential metadata did not travel"
    );

    // The converted root still owes the protected credential step, and the platform's own
    // contract decides how that reads: macOS cannot prove the account holds no legacy
    // Keychain items from a data root alone, so it names the domain as pending; another
    // platform completes the step. Either way the root is never reported as fully
    // recovered while a domain is owed.
    let pending = admit(&without_credentials).expect("admission is repeatable");
    let frontier = frontier_projection_struct().expect("frontier");
    let custody = frontier
        .domains
        .iter()
        .find(|domain| domain.domain_id == CREDENTIAL_DOMAIN_ID)
        .expect("the credential custody domain is declared");
    if cfg!(target_os = "macos") {
        assert!(
            pending
                .pending_authorization_domain_ids
                .contains(&CREDENTIAL_DOMAIN_ID.to_owned()),
            "a data root alone cannot prove the account holds no legacy items: {pending:?}"
        );
        assert!(
            gateway_credential_migration_pending(&without_credentials).expect("pending projection"),
            "the pending authorization stays visible instead of reading as recovered"
        );
        let projection = domain_state_projection(&without_credentials).expect("projection");
        let state = domain_state(&projection, CREDENTIAL_DOMAIN_ID);
        assert!(state.effective_version < custody.target_schema_version);
        assert_eq!(
            ledger_frontier_id(&without_credentials).as_deref(),
            Some(frontier.frontier_id.as_str()),
            "the admitted root declares the target endpoint even while a domain is owed"
        );
    } else {
        assert!(pending.pending_authorization_domain_ids.is_empty());
        assert!(
            !gateway_credential_migration_pending(&without_credentials)
                .expect("pending projection")
        );
    }
    assert_projection_is_at_target(&without_credentials, &pending);

    // An export that must be refused publishes no archive and changes nothing.
    let refused_archive = work.join("refused.zip");
    let before = fingerprint_root(&without_credentials);
    let refusal = export_data_root(&ExportRequest {
        data_root: without_credentials.clone(),
        archive_path: refused_archive.clone(),
        writers_stopped: false,
    })
    .expect_err("a capture without the operator's writer statement is refused");
    assert_eq!(refusal.to_string(), "archive_writers_running");
    assert!(
        !refused_archive.exists(),
        "a refused export publishes nothing"
    );
    assert_eq!(
        fingerprint_root(&without_credentials),
        before,
        "a refused export writes nothing"
    );

    // An import that must be refused publishes no member into the destination.
    let occupied = work.join("occupied");
    write_document(&occupied.join("keep.txt"), b"existing");
    let refused_target = occupied.clone();
    let archive_bytes = read_document(&archive);
    let import_refusal = restore_data_root(&RestoreRequest {
        archive_path: archive.clone(),
        target_root: refused_target.clone(),
    })
    .expect_err("a non-empty destination is refused");
    assert_eq!(import_refusal.to_string(), "archive_target_not_empty");
    assert_eq!(
        read_document(&occupied.join("keep.txt")),
        b"existing",
        "a refused import disturbs no existing destination member"
    );
    let mut members = fs::read_dir(&occupied)
        .expect("read the refused destination")
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    members.sort();
    assert_eq!(
        members,
        vec!["keep.txt".to_owned()],
        "a refused import publishes no destination member"
    );
    assert_eq!(
        read_document(&archive),
        archive_bytes,
        "a refused import leaves the archive unchanged"
    );

    remove_case_root(&work);
    remove_case_root(&without_credentials);
    remove_case_root(&released);
}

// ---------------------------------------------------------------------------
// AC-004: a version marker alone never satisfies the oracle
// ---------------------------------------------------------------------------

#[test]
fn local_recovery_a_version_marker_alone_does_not_satisfy_the_oracle() {
    // A root that carries nothing but target-version markers: admission on an empty root
    // writes the domain markers the projection reads, and the released stores never
    // existed. This is the shape a marker-only "recovery" claim would rest on.
    let marker_only = case_root("NODE-004", "marker-only-root");
    ensure_private_dir(&marker_only).expect("marker-only root");
    let admission = admit(&marker_only).expect("admission on an empty root");
    let projection = domain_state_projection(&marker_only).expect("projection");
    let frontier = frontier_projection_struct().expect("frontier");
    for domain in &frontier.domains {
        if admission
            .pending_authorization_domain_ids
            .contains(&domain.domain_id)
        {
            continue;
        }
        assert_eq!(
            domain_state(&projection, &domain.domain_id).marker_schema_version,
            Some(domain.target_schema_version),
            "the marker-only root satisfies every version marker"
        );
    }

    // The same comparison the end-to-end oracle uses rejects it, because no owner
    // reports the arranged content.
    let observed = reopen_owners(&marker_only);
    assert_ne!(
        observed,
        arranged_expectation(),
        "a version marker alone must never satisfy the recovery oracle"
    );
    assert!(
        observed.conversations.is_empty(),
        "a marker-only root holds no arranged conversation: {observed:?}"
    );
    assert!(
        observed.credentials.is_empty(),
        "a marker-only root holds no arranged credential: {observed:?}"
    );
    assert!(
        observed.definitions.is_empty(),
        "a marker-only root holds no arranged strategy definition: {observed:?}"
    );
    assert_eq!(
        observed.settings_theme, "",
        "a marker-only root holds no arranged collection value: {observed:?}"
    );

    remove_case_root(&marker_only);
}
