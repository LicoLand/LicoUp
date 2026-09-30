//! Focused regression for the rehearsal entry.
//!
//! The two acceptance criteria of the rehearsal Task, both driven through the shipped
//! binary so the verb, its arguments and its report are exercised together:
//!
//! * `AC-004` — a synthetic source root at the released format is converted, exported to
//!   both plaintext containers and restored, and the report names every stage as observed
//!   while the roots those stages produced are on disk and the source fingerprint is not.
//! * `AC-005` — a source that is not at the released format and a missing source are refused
//!   with a typed code before anything is written.
//!
//! The oracle is deliberately the disk: every stage the report claims is compared with the
//! root that stage names, so a report that claims a stage it did not run fails here.

use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

/// Optional isolated test-root base, relative to the repository root. This Task's declared
/// test roots live under `build/review/n4-verb/NODE-008/fixtures`; when the variable is
/// unset the suite uses one unique directory per test in the system temporary directory.
const TEST_ROOT_ENV: &str = "LICOUP_MIGRATE_TEST_ROOT";

/// The stage list the report must carry on every run.
const STAGES: &[&str] = &[
    "source-observed",
    "copied",
    "converted",
    "archive-zip",
    "restore-zip",
    "reopen-zip",
    "archive-tar-gz",
    "restore-tar-gz",
    "reopen-tar-gz",
];

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("crate lives two levels below the repository root")
        .to_path_buf()
}

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_licoup-migrate"))
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
            "licoup-migrate-rehearse-{}-{label}-{sequence}",
            std::process::id()
        ));
        if path.exists() {
            fs::remove_dir_all(&path).expect("clear a stale test root");
        }
        fs::create_dir_all(&path).expect("create the test root");
        Self { path }
    }

    /// The synthetic released root the rehearsal only ever reads.
    fn source(&self) -> PathBuf {
        self.path.join("source")
    }

    fn work(&self) -> PathBuf {
        self.path.join("work")
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

/// Arrange a synthetic root at the shape the last published release left: every domain at
/// the schema version that release declared, and the published strategy store format that
/// answers to domain version 1, which the current target still has to move.
///
/// The fixture builder is deliberately the only place this suite states the released shape;
/// the domain list itself is read from the client's own frontier projection.
fn released_root(root: &Path) {
    let marker_root = root.join("client-state/migrations/domain-state");
    fs::create_dir_all(&marker_root).expect("marker root");
    let frontier = licoup_native::domain::client_state_migration::frontier_projection_struct()
        .expect("the client's own frontier projection");
    for domain in &frontier.domains {
        // The released record declares every domain at version 1. `adaptive-flywheel` is the
        // one domain whose current target is still ahead of it, which is why the rehearsal
        // observes a conversion at all.
        let version = if domain.domain_id == "adaptive-flywheel" {
            1
        } else {
            domain.target_schema_version
        };
        write_file(
            root,
            &format!(
                "client-state/migrations/domain-state/{}.json",
                domain.domain_id
            ),
            format!(
                "{{\"schemaVersion\":\"v0.0.1:client-state-domain-marker-1\",\"domainId\":\"{}\",\"authoritativeSchemaVersion\":{version}}}",
                domain.domain_id
            )
            .as_bytes(),
        );
    }
    // The published strategy store: `strategy-store-2` carries `strategy_meta.version` 2 and
    // the ordinal bindings shape, which is the format domain version 1 answers to.
    let database = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
    fs::create_dir_all(database.parent().expect("strategy store parent"))
        .expect("strategy store directory");
    let connection = rusqlite::Connection::open(&database).expect("open the strategy store");
    connection
        .execute_batch(
            "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO strategy_meta(key,value) VALUES ('version','2');
             CREATE TABLE strategy_bindings(
               ordinal INTEGER NOT NULL,
               value_id TEXT NOT NULL,
               model TEXT,
               reasoning_effort TEXT
             );",
        )
        .expect("published strategy shape");
    drop(connection);
    // The credential reference store the native owner requires before it will describe a
    // capture as complete coverage.
    write_file(
        root,
        "client-state/llm-api-key-inventory.json",
        br#"{"keys":[{"provider":"synthetic","reference":"vault://synthetic/one"}]}"#,
    );
    write_file(root, "workspaces/demo/notes.md", b"# synthetic workspace\n");
    write_file(root, "empty.txt", b"");
}

/// The logical payload of one root: every regular file's bytes and every directory, keyed by
/// relative path. Two roots with the same payload hold the same content.
fn payload(root: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut entries = BTreeMap::new();
    collect(root, root, &mut entries);
    entries
}

fn collect(root: &Path, directory: &Path, entries: &mut BTreeMap<String, Vec<u8>>) {
    let Ok(read) = fs::read_dir(directory) else {
        return;
    };
    let mut children: Vec<PathBuf> = read
        .filter_map(Result::ok)
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
            entries.insert(format!("{relative}/"), Vec::new());
            collect(root, &child, entries);
        } else if metadata.is_file() {
            entries.insert(relative, fs::read(&child).expect("readable fixture file"));
        }
    }
}

fn run(arguments: &[&str]) -> (i32, Value) {
    let output = Command::new(binary())
        .args(arguments)
        .output()
        .expect("run the tool");
    let stdout = String::from_utf8(output.stdout).expect("utf-8 report");
    let report: Value =
        serde_json::from_str(stdout.trim()).expect("one JSON report per invocation");
    (output.status.code().unwrap_or(-1), report)
}

fn rehearse_arguments<'a>(source: &'a str, work: &'a str, extra: &[&'a str]) -> Vec<&'a str> {
    let mut arguments = vec![
        "rehearse",
        "--data-root",
        source,
        "--work-root",
        work,
        "--writers-stopped",
    ];
    arguments.extend_from_slice(extra);
    arguments
}

/// AC-004: the rehearsal reports every stage as observed, leaves the roots on disk and
/// leaves the source alone. The disk, not the report, is the oracle.
#[test]
fn the_rehearsal_converts_and_round_trips_both_containers() {
    let root = TestRoot::new("complete");
    released_root(&root.source());
    let source_before = payload(&root.source());

    let (code, report) = run(&rehearse_arguments(
        root.source().to_str().expect("utf-8 source"),
        root.work().to_str().expect("utf-8 work"),
        &["--keep-work-root"],
    ));

    assert_eq!(code, 0, "a complete rehearsal exits zero: {report}");
    assert_eq!(report["status"], "complete");
    assert_eq!(report["recoveryComplete"], true);
    assert!(
        report["notRun"].as_array().expect("notRun").is_empty(),
        "nothing is left unrun: {report}"
    );
    assert!(
        report["stillOwed"]
            .as_array()
            .expect("stillOwed")
            .is_empty(),
        "the owner accounted for every declared domain: {report}"
    );
    assert!(
        report["converted"]
            .as_array()
            .expect("converted")
            .iter()
            .any(|domain| domain == "adaptive-flywheel"),
        "the released strategy store was moved to the current format: {report}"
    );

    // Every stage is named exactly once, in the declared order.
    let stages: Vec<&str> = report["stages"]
        .as_array()
        .expect("stages")
        .iter()
        .map(|stage| stage["stage"].as_str().expect("stage name"))
        .collect();
    assert_eq!(stages, STAGES);

    // Each claimed stage names a root that is on disk, and the fingerprint it reports is the
    // fingerprint of that root as this suite computes it. A stage whose root is later
    // rewritten by the stage that follows it — the disposable copy the conversion owns —
    // reports the fingerprint it observed at its own boundary, so it is compared against the
    // tree it copied rather than against the converted tree. This is the oracle the
    // acceptance criterion states: a report claiming a stage whose root is absent, or
    // describing a root that is not the one on disk, fails here.
    let source_fingerprint = &report["sourceFingerprint"];
    assert_eq!(
        source_fingerprint["digest"].as_str(),
        Some(root_digest(&root.source()).as_str()),
        "the report states the source's own fingerprint"
    );
    for stage in report["stages"].as_array().expect("stages") {
        let name = stage["stage"].as_str().expect("stage name");
        assert_eq!(stage["outcome"], "observed", "{name} ran: {stage}");
        let named = stage["root"].as_str().unwrap_or_else(|| {
            panic!("{name} names the root it produced");
        });
        let path = Path::new(named);
        assert!(
            path.exists(),
            "{name} claims a root that is absent: {named}"
        );
        let fingerprint = &stage["rootFingerprint"];
        assert!(
            fingerprint["digest"]
                .as_str()
                .is_some_and(|value| value.len() == 16),
            "{name} reports a fingerprint for its root: {stage}"
        );
        if name == "copied" {
            let source_shape = fingerprint_of(&root.source());
            assert_eq!(
                fingerprint["entries"].as_u64(),
                Some(source_shape.entries),
                "the copy holds the released root's entry count"
            );
            assert_eq!(
                fingerprint["digest"].as_str(),
                Some(source_shape.digest.as_str()),
                "the copy is the released root byte for byte"
            );
            continue;
        }
        if path.is_file() {
            // An archive stage's product is the archive file itself.
            continue;
        }
        let on_disk = fingerprint_of(path);
        assert_eq!(
            fingerprint["entries"].as_u64(),
            Some(on_disk.entries),
            "{name} counts the entries of the root it names"
        );
        assert_eq!(
            fingerprint["digest"].as_str(),
            Some(on_disk.digest.as_str()),
            "{name} describes the root it left on disk"
        );
    }

    // The two containers each left the converted root and a restored copy, and the archive
    // stage names the container the owner actually wrote.
    let observed: BTreeMap<&str, &str> = report["stages"]
        .as_array()
        .expect("stages")
        .iter()
        .map(|stage| {
            (
                stage["stage"].as_str().expect("stage name"),
                stage["observed"].as_str().expect("observed"),
            )
        })
        .collect();
    assert!(observed["archive-zip"].contains("zip container"));
    assert!(observed["archive-tar-gz"].contains("tar.gz container"));
    assert!(observed["reopen-zip"].contains("converted nothing"));
    assert!(observed["reopen-tar-gz"].contains("converted nothing"));

    // The converted root the caller keeps is a real converted root: the payload the source
    // carried travelled into it untouched, and both restores carry it back. The conversion's
    // own records — the ledger, the domain markers and a store it owns — are expected to be
    // rewritten, so they are compared as readable facts rather than as bytes.
    let converted = body_listing(&root.work().join("converted"));
    let restored_zip = body_listing(&root.work().join("restored/zip"));
    let restored_tar = body_listing(&root.work().join("restored/tar.gz"));
    let source_after = payload(&root.source());
    for (relative, bytes) in &source_before {
        assert_eq!(
            source_after.get(relative),
            Some(bytes),
            "{relative} is untouched by the rehearsal"
        );
    }
    for relative in [
        "workspaces/demo/notes.md",
        "empty.txt",
        "client-state/llm-api-key-inventory.json",
    ] {
        let body = body(&source_before, relative);
        assert_eq!(
            converted.get(relative),
            Some(&body),
            "{relative} travelled into the converted root"
        );
        assert_eq!(
            restored_zip.get(relative),
            Some(&body),
            "{relative} came back from the zip restore"
        );
        assert_eq!(
            restored_tar.get(relative),
            Some(&body),
            "{relative} came back from the tar.gz restore"
        );
    }
    assert_eq!(
        converted.keys().collect::<Vec<_>>(),
        restored_zip.keys().collect::<Vec<_>>(),
        "the restores carry every path the converted root holds"
    );
    assert_eq!(
        restored_zip, restored_tar,
        "both containers carry the same logical payload"
    );

    // The converted store in each restored root is a database the client's own owner can
    // read, not a file that merely exists.
    for container in ["zip", "tar.gz"] {
        let database = root
            .work()
            .join("restored")
            .join(container)
            .join("client-state/adaptive-flywheel/strategies.sqlite3");
        let connection = rusqlite::Connection::open_with_flags(
            &database,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .expect("the restored strategy store opens read-only");
        let version: String = connection
            .query_row(
                "SELECT value FROM strategy_meta WHERE key='version'",
                [],
                |row| row.get(0),
            )
            .expect("the restored store carries its format version");
        assert_eq!(
            version, "3",
            "the {container} restore carries the converted strategy format"
        );
    }
}

/// One file body, described the same way [`body_listing`] describes every entry.
fn body(listing: &BTreeMap<String, Vec<u8>>, relative: &str) -> String {
    let bytes = listing.get(relative).expect("a listed fixture entry");
    format!("{}:{:016x}", bytes.len(), fold(bytes))
}

/// One root's fingerprint, computed the way the rehearsal reports it. The suite recomputes
/// it independently so a report cannot describe a root that is not on disk.
struct ObservedFingerprint {
    entries: u64,
    digest: String,
}

fn fingerprint_of(root: &Path) -> ObservedFingerprint {
    let mut entries: Vec<(String, char, u64)> = Vec::new();
    collect_fingerprint(root, root, &mut entries);
    entries.sort();
    let mut digest = 0xcbf2_9ce4_8422_2325_u64;
    for (relative, kind, size) in &entries {
        for byte in relative.as_bytes() {
            digest = (digest ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3);
        }
        digest = (digest ^ u64::from(*kind as u8)).wrapping_mul(0x0000_0100_0000_01b3);
        for byte in size.to_le_bytes() {
            digest = (digest ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    ObservedFingerprint {
        entries: entries.len() as u64,
        digest: format!("{digest:016x}"),
    }
}

fn root_digest(root: &Path) -> String {
    fingerprint_of(root).digest
}

fn collect_fingerprint(root: &Path, directory: &Path, entries: &mut Vec<(String, char, u64)>) {
    let Ok(read) = fs::read_dir(directory) else {
        return;
    };
    for entry in read.filter_map(Result::ok) {
        let path = entry.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        let relative = path
            .strip_prefix(root)
            .expect("entry below the root")
            .to_string_lossy()
            .replace('\\', "/");
        if metadata.is_dir() {
            entries.push((relative, 'd', 0));
            collect_fingerprint(root, &path, entries);
        } else if metadata.is_file() {
            entries.push((relative, 'f', metadata.len()));
        }
    }
}

/// The logical body of one root: the size and content hash of every regular file, keyed by
/// relative path. Two roots with the same listing hold the same bytes except where a store
/// was rewritten, which is what [`body_listing`] is compared for.
fn body_listing(root: &Path) -> BTreeMap<String, String> {
    payload(root)
        .into_iter()
        .map(|(relative, bytes)| {
            let described = format!("{}:{:016x}", bytes.len(), fold(&bytes));
            (relative, described)
        })
        .collect()
}

/// A stable fold over one file body, so a comparison can name a difference without printing
/// a store's contents.
fn fold(bytes: &[u8]) -> u64 {
    let mut digest = 0xcbf2_9ce4_8422_2325_u64;
    for byte in bytes {
        digest = (digest ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    digest
}

/// AC-004: the source root is not the subject, so a rehearsal that keeps its working root
/// still leaves the named source byte-identical, and one that does not keep it removes only
/// its own working root.
#[test]
fn the_named_source_is_read_only_and_the_working_root_is_disposable() {
    let root = TestRoot::new("disposable");
    released_root(&root.source());
    let before = payload(&root.source());

    // Without `--keep-work-root` the tool removes the directory it created and says so.
    let (code, report) = run(&rehearse_arguments(
        root.source().to_str().expect("utf-8 source"),
        root.work().to_str().expect("utf-8 work"),
        &[],
    ));
    assert_eq!(code, 0, "{report}");
    assert_eq!(report["workRootRetained"], false);
    assert!(
        !root.work().exists(),
        "the disposable working root is removed when the caller does not keep it"
    );
    assert_eq!(before, payload(&root.source()), "the source is unchanged");

    // The report names the working root it used, so a caller can reach the roots it kept.
    assert_eq!(
        report["workRoot"].as_str(),
        Some(root.work().to_str().expect("utf-8 work path"))
    );
}

/// AC-005: a source that already declares this binary's own target frontier is refused by
/// code, with nothing written outside the disposable working directory.
#[test]
fn a_source_that_is_not_at_the_released_format_is_refused_before_anything_is_written() {
    let root = TestRoot::new("wrong-shape");
    released_root(&root.source());
    // Bring the source to this binary's own target through the client's own owner: that is
    // the format this binary writes, not the format the last published release left.
    licoup_native::domain::client_state_migration::admit(&root.source()).expect("admission");
    let before = payload(&root.source());

    let (code, report) = run(&rehearse_arguments(
        root.source().to_str().expect("utf-8 source"),
        root.work().to_str().expect("utf-8 work"),
        &["--keep-work-root"],
    ));

    assert_eq!(code, 1, "a refused rehearsal exits non-zero: {report}");
    assert_eq!(report["status"], "refused");
    assert_eq!(report["error"], "source_root_already_at_target");
    // The refusal names the shape it observed, so the reader learns what the source is
    // instead of only that it was declined.
    let shape = &report["observedShape"];
    assert_eq!(shape["present"], true);
    assert_eq!(shape["directory"], true);
    assert_eq!(
        shape["frontierId"], shape["targetFrontierId"],
        "the source already declares this binary's own target: {report}"
    );
    assert!(shape["entries"].as_u64().is_some_and(|entries| entries > 0));
    assert!(
        !root.work().exists(),
        "a refusal writes nothing outside its own working directory: it writes none at all"
    );
    assert_eq!(before, payload(&root.source()), "the source is unchanged");
}

/// AC-005: a missing source is refused by code and nothing is created.
#[test]
fn a_missing_source_is_refused_and_creates_nothing() {
    let root = TestRoot::new("missing");
    let absent = root.source();

    let (code, report) = run(&rehearse_arguments(
        absent.to_str().expect("utf-8 source"),
        root.work().to_str().expect("utf-8 work"),
        &["--keep-work-root"],
    ));

    assert_eq!(code, 1);
    assert_eq!(report["status"], "refused");
    assert_eq!(report["error"], "source_root_missing");
    let shape = &report["observedShape"];
    assert_eq!(shape["present"], false, "the observed shape is the absence");
    assert_eq!(shape["entries"], 0);
    assert!(
        shape.get("frontierId").is_none(),
        "no root declares no frontier"
    );
    assert!(!absent.exists(), "the refused root is not created");
    assert!(!root.work().exists(), "no working root is created");
}

/// AC-005: a directory that carries no released shape at all is refused rather than
/// rehearsed into a root no release ever produced.
#[test]
fn a_source_without_a_released_shape_is_refused() {
    let root = TestRoot::new("empty-source");
    fs::create_dir_all(root.source()).expect("empty source");

    let (code, report) = run(&rehearse_arguments(
        root.source().to_str().expect("utf-8 source"),
        root.work().to_str().expect("utf-8 work"),
        &["--keep-work-root"],
    ));

    assert_eq!(code, 1);
    assert_eq!(report["status"], "refused");
    assert_eq!(report["error"], "source_root_shape_absent");
    let shape = &report["observedShape"];
    assert_eq!(shape["present"], true);
    assert_eq!(shape["directory"], true);
    assert_eq!(
        shape["entries"], 0,
        "an empty directory carries no released shape: {report}"
    );
    assert!(!root.work().exists());
}

/// The parser refuses a rehearsal that omits the working root or the stopping statement
/// before the tool reads anything at all.
#[test]
fn the_rehearsal_verb_requires_its_working_root_and_the_stopping_statement() {
    let root = TestRoot::new("usage");
    released_root(&root.source());
    let source = root.source().to_str().expect("utf-8 source").to_string();
    let work = root.work().to_str().expect("utf-8 work").to_string();

    let (code, report) = run(&["rehearse", "--data-root", &source, "--writers-stopped"]);
    assert_eq!(
        code, 2,
        "a missing working root is a usage refusal: {report}"
    );
    assert_eq!(report["error"], "work_root_required");

    let (code, report) = run(&["rehearse", "--data-root", &source, "--work-root", &work]);
    assert_eq!(code, 2, "a missing statement is a usage refusal: {report}");
    assert_eq!(report["error"], "maintenance_confirmation_required");
    assert!(!root.work().exists(), "nothing ran");
}

/// The help text names the verb and the two arguments a rehearsal cannot be run without.
#[test]
fn the_help_text_names_the_rehearsal_and_its_inputs() {
    let output = Command::new(binary())
        .arg("--help")
        .output()
        .expect("run the tool");
    let help = String::from_utf8(output.stdout).expect("utf-8 help");
    assert!(output.status.success());
    for token in [
        "rehearse --data-root <path> --work-root <directory> --writers-stopped",
        "--work-root <path>",
        "--keep-work-root",
    ] {
        assert!(help.contains(token), "the help text names {token}: {help}");
    }
}
