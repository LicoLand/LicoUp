//! Focused regression for the public export and import verbs.
//!
//! The two acceptance criteria of the archive Task, both against synthetic roots:
//!
//! * `AC-004-1` — a synthetic root with an exportable credential reference is exported and
//!   imported through **both** containers, and the restored roots carry the same logical
//!   payload as the source and as each other, cross-checked against the owner's own
//!   coverage report.
//! * `AC-004-2` — a root whose credential store cannot travel is reported as a named
//!   limitation instead of a complete recovery, and the limitation survives the round trip.
//!
//! The refusal cases hold the same rule from the other side: a refused export publishes no
//! archive and a refused import publishes nothing into the destination, so a failure can
//! never be mistaken for a backup or for a completed restore.

use licoup_migrate::archive::{self, ExportReport, ImportReport};
use licoup_migrate::error::DATA_ROOT_MISSING;
use licoup_native::core::full_data_root_archive::RecoveryCoverage;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// Optional isolated test-root base, relative to the repository root. The Task's declared
/// test roots live under `build/review/n1-archive/<node>/fixtures`; when the variable is
/// unset the suite uses one unique directory per test in the system temporary directory.
const TEST_ROOT_ENV: &str = "LICOUP_MIGRATE_TEST_ROOT";

/// The credential domain the native owner refuses to describe as portable.
const CREDENTIAL_DOMAIN: &str = "gateway-credential-custody";

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("crate lives two levels below the repository root")
        .to_path_buf()
}

/// One disposable test root, removed when the test ends.
struct TestRoot {
    path: PathBuf,
}

impl TestRoot {
    fn new(label: &str) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let base = match std::env::var_os(TEST_ROOT_ENV) {
            Some(base) => workspace_root().join(base),
            None => std::env::temp_dir(),
        };
        // The archive owner opens every destination component without following a symlink,
        // so a root reached through one is refused before extraction starts. On macOS the
        // system temporary directory is `/var/folders/...` and `/var` is a symlink to
        // `private/var`. Resolving the base once keeps this suite runnable with no
        // environment variable and changes nothing the acceptance criteria observe.
        fs::create_dir_all(&base).expect("create the test root base");
        let base = fs::canonicalize(&base).expect("resolve the test root base");
        let path = base.join(format!(
            "licoup-migrate-archive-{}-{label}-{sequence}",
            std::process::id()
        ));
        if path.exists() {
            fs::remove_dir_all(&path).expect("clear a stale test root");
        }
        fs::create_dir_all(&path).expect("create the test root");
        Self { path }
    }

    /// The data root under test: `<test root>/source`.
    fn source(&self) -> PathBuf {
        self.path.join("source")
    }

    fn join(&self, relative: &str) -> PathBuf {
        self.path.join(relative)
    }
}

impl Drop for TestRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn write_file(root: &Path, relative: &str, bytes: &[u8]) {
    let path = root.join(relative);
    fs::create_dir_all(path.parent().expect("fixture parent")).expect("fixture directory");
    fs::write(&path, bytes).expect("fixture file");
}

/// The part of a synthetic root that always travels: text, binary, an empty file, a nested
/// tree and one directory that holds no file at all.
fn write_travelling_payload(root: &Path) {
    write_file(root, "workspaces/demo/notes.md", b"# synthetic workspace\n");
    write_file(
        root,
        "client-state/opaque-store.bin",
        &[0_u8, 1, 2, 255, 254, 0, 66],
    );
    write_file(root, "nested/deep/leaf.bin", b"\x00\x01\x02binary payload");
    write_file(root, "empty.txt", b"");
    fs::create_dir_all(root.join("client-state/cache")).expect("empty fixture directory");
}

/// A synthetic root whose credential reference can travel.
fn exportable_root(root: &Path) {
    write_travelling_payload(root);
    write_file(
        root,
        "client-state/llm-api-key-inventory.json",
        br#"{"keys":[{"provider":"synthetic","reference":"vault://synthetic/one"}]}"#,
    );
}

/// A synthetic root whose credential store is absent, so it cannot travel.
fn root_without_the_credential_store(root: &Path) {
    write_travelling_payload(root);
}

/// The logical payload of one root: every regular file's bytes and every directory, keyed
/// by relative path. Symbolic links are absent by construction — the owner does not capture
/// them and these fixtures contain none.
fn payload(root: &Path) -> BTreeMap<String, Option<Vec<u8>>> {
    let mut entries = BTreeMap::new();
    collect(root, root, &mut entries);
    entries
}

fn collect(root: &Path, directory: &Path, entries: &mut BTreeMap<String, Option<Vec<u8>>>) {
    let mut children: Vec<PathBuf> = fs::read_dir(directory)
        .expect("readable fixture directory")
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .collect();
    children.sort();
    for child in children {
        let metadata = fs::symlink_metadata(&child).expect("fixture metadata");
        let relative = child
            .strip_prefix(root)
            .expect("fixture entry inside its root")
            .to_string_lossy()
            .replace('\\', "/");
        if metadata.is_dir() {
            entries.insert(relative, None);
            collect(root, &child, entries);
        } else if metadata.is_file() {
            entries.insert(relative, Some(fs::read(&child).expect("readable fixture file")));
        }
    }
}

fn file_count(payload: &BTreeMap<String, Option<Vec<u8>>>) -> usize {
    payload.values().filter(|entry| entry.is_some()).count()
}

fn total_bytes(payload: &BTreeMap<String, Option<Vec<u8>>>) -> u64 {
    payload
        .values()
        .filter_map(|entry| entry.as_ref())
        .map(|bytes| bytes.len() as u64)
        .sum()
}

/// AC-004-1: both containers round-trip the same logical payload.
#[test]
fn both_containers_round_trip_the_same_logical_payload() {
    let root = TestRoot::new("round-trip");
    exportable_root(&root.source());
    let mut restored_payloads = Vec::new();

    for (name, container) in [("backup.zip", "zip"), ("backup.tar.gz", "tar.gz")] {
        let archive_path = root.join(&format!("archives/{name}"));
        let export = archive::export(&root.source(), &archive_path, true).expect("export runs");
        assert_eq!(export.status, "exported");
        assert_eq!(export.container, container);
        assert_eq!(
            export.coverage,
            RecoveryCoverage::Complete,
            "an exportable credential reference travels"
        );
        assert!(
            export.limitations.is_empty(),
            "nothing is reported as missing: {:?}",
            export.limitations
        );

        // The owner's own coverage report is the second half of the oracle: the payload it
        // declared must be the payload that came back.
        let source_payload = payload(&root.source());
        assert_eq!(export.file_count, file_count(&source_payload));
        assert_eq!(export.total_bytes, total_bytes(&source_payload));

        let target = root.join(&format!("restored/{container}"));
        let import = archive::import(&archive_path, &target).expect("import runs");
        assert_eq!(import.status, "imported");
        assert_eq!(import.container, container);
        assert_eq!(import.coverage, RecoveryCoverage::Complete);
        assert_eq!(import.file_count, export.file_count);
        assert_eq!(import.total_bytes, export.total_bytes);

        let restored = payload(&target);
        assert_eq!(
            restored, source_payload,
            "the {container} restore carries the source's logical payload"
        );
        restored_payloads.push((container, restored));
    }

    assert_eq!(
        restored_payloads[0].1, restored_payloads[1].1,
        "both restored roots carry the same logical payload"
    );
}

/// AC-004-2: a credential store that cannot travel is named, not hidden.
#[test]
fn a_credential_store_that_cannot_travel_is_reported_as_a_limitation() {
    let root = TestRoot::new("limited");
    root_without_the_credential_store(&root.source());
    let archive_path = root.join("archives/limited.zip");

    let export = archive::export(&root.source(), &archive_path, true).expect("export runs");
    assert_eq!(export.status, "exported");
    assert_eq!(
        export.coverage,
        RecoveryCoverage::Limited,
        "a missing credential store is never reported as complete recovery"
    );
    let domains: Vec<&str> = export
        .limitations
        .iter()
        .map(|limitation| limitation.domain.as_str())
        .collect();
    assert_eq!(domains, vec![CREDENTIAL_DOMAIN]);

    // The limitation is written into the archive, so a restore repeats it instead of
    // promising the credential back.
    let target = root.join("restored");
    let import = archive::import(&archive_path, &target).expect("import runs");
    assert_eq!(import.coverage, RecoveryCoverage::Limited);
    assert_eq!(import.limitations.len(), 1);
    assert_eq!(import.limitations[0].domain, CREDENTIAL_DOMAIN);

    // Everything that did travel still arrives intact.
    assert_eq!(payload(&target), payload(&root.source()));
}

#[test]
fn capture_leaves_the_source_payload_untouched() {
    let root = TestRoot::new("source-preserved");
    exportable_root(&root.source());
    let before = payload(&root.source());

    for name in ["backup.zip", "backup.tar.gz"] {
        archive::export(&root.source(), &root.join(&format!("archives/{name}")), true)
            .expect("export runs");
        let after = payload(&root.source());
        for (relative, bytes) in &before {
            assert_eq!(
                after.get(relative),
                Some(bytes),
                "{relative} is unchanged by capture"
            );
        }
    }
}

#[test]
fn the_container_is_inferred_from_the_archive_name() {
    let root = TestRoot::new("container");
    exportable_root(&root.source());

    let shorthand = archive::export(&root.source(), &root.join("archives/backup.tgz"), true)
        .expect("export runs");
    assert_eq!(shorthand.container, "tar.gz");

    let upper = archive::export(&root.source(), &root.join("archives/BACKUP.ZIP"), true)
        .expect("export runs");
    assert_eq!(upper.container, "zip");
}

#[test]
fn export_refuses_without_the_stopped_writer_statement_and_publishes_nothing() {
    let root = TestRoot::new("writers");
    exportable_root(&root.source());
    let archive_path = root.join("archives/unconfirmed.zip");

    let error = archive::export(&root.source(), &archive_path, false).expect_err("refused");
    assert_eq!(error.code(), "archive_writers_running");
    assert!(
        !archive_path.exists(),
        "a refused export leaves no file that could be mistaken for a backup"
    );
    assert_eq!(
        archive::ARCHIVE_WRITERS_RUNNING.code(),
        "archive_writers_running"
    );
}

#[test]
fn export_refuses_a_name_that_is_not_a_plaintext_container() {
    let root = TestRoot::new("container-refusal");
    exportable_root(&root.source());
    let archive_path = root.join("archives/backup.bin");

    let error = archive::export(&root.source(), &archive_path, true).expect_err("refused");
    assert_eq!(error.code(), archive::ARCHIVE_CONTAINER_UNSUPPORTED.code());
    assert!(!archive_path.exists());
}

#[test]
fn export_refuses_a_missing_data_root() {
    let root = TestRoot::new("missing-root");
    let archive_path = root.join("archives/absent.zip");

    let error = archive::export(&root.join("absent"), &archive_path, true).expect_err("refused");
    assert_eq!(
        error, DATA_ROOT_MISSING,
        "a missing root keeps the crate's own code"
    );
    assert!(!archive_path.exists());
}

#[test]
fn export_refuses_a_destination_inside_the_root_it_captures() {
    let root = TestRoot::new("inside-root");
    exportable_root(&root.source());
    let archive_path = root.source().join("backup.zip");

    let error = archive::export(&root.source(), &archive_path, true).expect_err("refused");
    assert_eq!(error, licoup_migrate::error::ARCHIVE_INSIDE_DATA_ROOT);
    assert!(
        !archive_path.exists(),
        "a refused capture leaves no file and no captured copy of itself"
    );
    // The root the capture declined to describe is untouched, so it can still be captured
    // to a destination outside it.
    let outside = root.join("archives/backup.zip");
    let export = archive::export(&root.source(), &outside, true).expect("export runs");
    assert_eq!(export.coverage, RecoveryCoverage::Complete);
    assert_eq!(export.file_count, file_count(&payload(&root.source())));
}

#[test]
fn import_refuses_a_destination_that_is_not_empty() {
    let root = TestRoot::new("occupied-target");
    exportable_root(&root.source());
    let archive_path = root.join("archives/backup.zip");
    archive::export(&root.source(), &archive_path, true).expect("export runs");

    let target = root.join("occupied");
    fs::create_dir_all(&target).expect("occupied destination");
    write_file(&target, "keep.txt", b"existing content");

    let error = archive::import(&archive_path, &target).expect_err("refused");
    assert_eq!(error.code(), archive::ARCHIVE_TARGET_NOT_EMPTY.code());
    assert_eq!(
        fs::read(target.join("keep.txt")).expect("existing entry survives"),
        b"existing content"
    );
    assert_eq!(
        payload(&target).len(),
        1,
        "a refused import publishes nothing into the destination"
    );
}

#[test]
fn import_refuses_bytes_that_are_not_an_archive_and_publishes_nothing() {
    let root = TestRoot::new("not-an-archive");
    let archive_path = root.join("archives/broken.zip");
    write_file(&root.path, "archives/broken.zip", b"this is not a plaintext archive");
    let target = root.join("restored");

    let error = archive::import(&archive_path, &target).expect_err("refused");
    assert_eq!(error.code(), "archive_invalid");
    assert!(
        payload(&target).is_empty(),
        "a refused import publishes nothing into the destination"
    );
}

#[test]
fn import_refuses_a_missing_archive() {
    let root = TestRoot::new("missing-archive");
    let target = root.join("restored");

    let error = archive::import(&root.join("archives/absent.zip"), &target).expect_err("refused");
    assert_eq!(error.code(), "archive_unreadable");
    assert!(payload(&target).is_empty());
}

#[test]
fn reports_serialize_as_camel_case_json_with_a_stable_status() {
    let root = TestRoot::new("json");
    exportable_root(&root.source());
    let archive_path = root.join("archives/backup.tar.gz");
    let export = archive::export(&root.source(), &archive_path, true).expect("export runs");
    let import = archive::import(&archive_path, &root.join("restored")).expect("import runs");

    let exported = serde_json::to_value(&export).expect("export report serializes");
    assert_eq!(exported["status"], "exported");
    for key in ["container", "coverage", "limitations", "fileCount", "totalBytes"] {
        assert!(exported.get(key).is_some(), "{key} is part of the report");
    }
    assert!(exported.get("file_count").is_none(), "keys are camelCase");
    assert_eq!(exported["coverage"], "complete");

    let imported = serde_json::to_value(&import).expect("import report serializes");
    assert_eq!(imported["status"], "imported");
    assert_eq!(imported["container"], "tar.gz");
    assert_eq!(imported["coverage"], "complete");

    // The two report types stay distinct so a caller cannot confuse the verbs.
    let _: ExportReport = export;
    let _: ImportReport = import;
}
