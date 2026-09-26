//! Full data-root archive acceptance.
//!
//! Proves, against the real native owner:
//!
//! 1. both plaintext containers carry the same logical payload and both restore
//!    application facts and file contents faithfully (AC-001);
//! 2. a running writer is refused, the source is never modified, and no member is
//!    published outside the target root (AC-002).
//!
//! Everything here runs on synthetic roots under a disposable directory. No real
//! data root, operating-system credential prompt or installed client is touched.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use licoup_native::core::full_data_root_archive::{
    export_data_root, restore_data_root, ArchiveContainer, ExportRequest, RecoveryCoverage,
    RestoreRequest,
};

fn scratch(name: &str) -> PathBuf {
    // A canonical temporary root: /tmp is a symlink on macOS and the no-follow
    // extraction root correctly refuses a destination below one.
    let base = std::env::temp_dir()
        .canonicalize()
        .expect("canonical temporary directory");
    let root = base.join(format!(
        "licoup-full-archive-{name}-{}",
        std::process::id()
    ));
    if root.exists() {
        fs::remove_dir_all(&root).expect("clear scratch root");
    }
    fs::create_dir_all(&root).expect("create scratch root");
    root
}

/// A synthetic complete root: canonical conversation database, settings, package
/// records and an exportable key-reference store.
fn synthetic_data_root(name: &str) -> PathBuf {
    let root = scratch(name);
    write(
        &root.join("client-state/conversations/conversations.sqlite3"),
        b"SQLite format 3\0synthetic canonical store",
    );
    write(
        &root.join("client-state/conversations/migration-v5.complete"),
        b"v5",
    );
    write(
        &root.join("client-state/appearance-preferences.json"),
        br#"{"theme":"dark"}"#,
    );
    write(
        &root.join("client-state/agent-tool-allowlists.json"),
        br#"{"allow":[]}"#,
    );
    write(
        &root.join("client-state/llm-api-key-inventory.json"),
        br#"{"providers":["synthetic-exportable"]}"#,
    );
    write(&root.join(".licoup-workspace.json"), br#"{"revision":1}"#);
    write(&root.join("adaptive-flywheel.toml"), b"[flywheel]\nrevision=1\n");
    write(
        &root.join("group-conversations/group-1.json"),
        br#"{"id":"group-1"}"#,
    );
    root
}

fn write(path: &Path, bytes: &[u8]) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent");
    }
    fs::write(path, bytes).expect("write fixture");
}

fn read(path: &Path) -> Vec<u8> {
    fs::read(path).expect("read fixture")
}

fn assert_equivalent(original: &Path, restored: &Path) {
    for relative in [
        ".licoup-workspace.json",
        "adaptive-flywheel.toml",
        "client-state/conversations/conversations.sqlite3",
        "client-state/conversations/migration-v5.complete",
        "client-state/appearance-preferences.json",
        "client-state/agent-tool-allowlists.json",
        "client-state/llm-api-key-inventory.json",
        "group-conversations/group-1.json",
    ] {
        let expected = read(&original.join(relative));
        let actual = read(&restored.join(relative));
        assert_eq!(
            expected, actual,
            "restored member {relative} must equal the captured member"
        );
    }
}

fn export(root: &Path, archive: &Path) -> licoup_native::core::full_data_root_archive::ExportOutcome {
    export_data_root(&ExportRequest {
        data_root: root.to_path_buf(),
        archive_path: archive.to_path_buf(),
        writers_stopped: true,
    })
    .expect("export succeeds")
}

#[test]
fn both_containers_restore_equivalent_application_facts() {
    let source = synthetic_data_root("roundtrip");
    let work = scratch("roundtrip-out");

    let zip_archive = work.join("complete.zip");
    let tar_archive = work.join("complete.tar.gz");

    let zip_outcome = export(&source, &zip_archive);
    let tar_outcome = export(&source, &tar_archive);

    assert_eq!(zip_outcome.container, ArchiveContainer::Zip);
    assert_eq!(tar_outcome.container, ArchiveContainer::TarGz);
    assert_eq!(zip_outcome.coverage, RecoveryCoverage::Complete);
    assert_eq!(tar_outcome.coverage, RecoveryCoverage::Complete);
    assert!(zip_outcome.limitations.is_empty());
    assert_eq!(zip_outcome.file_count, tar_outcome.file_count);
    assert_eq!(zip_outcome.total_bytes, tar_outcome.total_bytes);

    let zip_target = work.join("restored-zip");
    let tar_target = work.join("restored-tar");
    let zip_restore = restore_data_root(&RestoreRequest {
        archive_path: zip_archive.clone(),
        target_root: zip_target.clone(),
    })
    .expect("zip restore succeeds");
    let tar_restore = restore_data_root(&RestoreRequest {
        archive_path: tar_archive.clone(),
        target_root: tar_target.clone(),
    })
    .expect("tar.gz restore succeeds");

    assert_eq!(zip_restore.file_count, tar_restore.file_count);
    assert_eq!(zip_restore.coverage, RecoveryCoverage::Complete);

    assert_equivalent(&source, &zip_target);
    assert_equivalent(&source, &tar_target);

    // The source is untouched by either export or restore.
    assert_equivalent(&source, &source);
}

#[test]
fn running_writer_is_refused_without_modifying_the_source() {
    let source = synthetic_data_root("writer");
    let work = scratch("writer-out");
    let archive = work.join("refused.zip");

    // A writer holds the application's own admission lock.
    let lock_path = source.join("client-state/migrations/admission.lock");
    fs::create_dir_all(lock_path.parent().expect("lock parent")).expect("lock dir");
    let held = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .expect("open lock");
    fs2::FileExt::lock_exclusive(&held).expect("hold admission lock");

    let before = read(&source.join("client-state/appearance-preferences.json"));
    let error = export_data_root(&ExportRequest {
        data_root: source.clone(),
        archive_path: archive.clone(),
        writers_stopped: true,
    })
    .expect_err("a running writer is refused");
    assert_eq!(error.to_string(), "archive_writers_running");

    assert!(
        !archive.exists(),
        "a refused capture must not leave an archive behind"
    );
    assert_eq!(
        before,
        read(&source.join("client-state/appearance-preferences.json")),
        "a refused capture must not modify the source"
    );

    fs2::FileExt::unlock(&held).expect("release lock");

    // With the writer stopped the same request succeeds.
    let outcome = export(&source, &archive);
    assert_eq!(outcome.coverage, RecoveryCoverage::Complete);
}

#[test]
fn capture_requires_the_writer_statement_and_an_existing_root() {
    let source = synthetic_data_root("preconditions");
    let work = scratch("preconditions-out");

    let no_statement = export_data_root(&ExportRequest {
        data_root: source.clone(),
        archive_path: work.join("no-statement.zip"),
        writers_stopped: false,
    })
    .expect_err("capture without the writer statement is refused");
    assert_eq!(no_statement.to_string(), "archive_writers_running");

    let missing_root = export_data_root(&ExportRequest {
        data_root: work.join("absent"),
        archive_path: work.join("absent.zip"),
        writers_stopped: true,
    })
    .expect_err("a missing root is refused");
    assert_eq!(missing_root.to_string(), "data_root_missing");

    let unsupported = export_data_root(&ExportRequest {
        data_root: source,
        archive_path: work.join("complete.rar"),
        writers_stopped: true,
    })
    .expect_err("an unsupported container is refused");
    assert_eq!(unsupported.to_string(), "archive_container_unsupported");
}

#[test]
fn restore_refuses_a_non_empty_target_and_a_missing_payload() {
    let source = synthetic_data_root("target");
    let work = scratch("target-out");
    let archive = work.join("complete.zip");
    export(&source, &archive);

    let occupied = work.join("occupied");
    write(&occupied.join("keep.txt"), b"existing");
    let error = restore_data_root(&RestoreRequest {
        archive_path: archive.clone(),
        target_root: occupied.clone(),
    })
    .expect_err("a non-empty target is refused");
    assert_eq!(error.to_string(), "archive_target_not_empty");
    assert_eq!(
        read(&occupied.join("keep.txt")),
        b"existing",
        "a refused restore must not disturb the target"
    );

    let decoy = work.join("decoy.zip");
    let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    writer.start_file("data/notes.txt", options).expect("add member");
    writer
        .write_all(b"no manifest")
        .expect("write member");
    let bytes = writer.finish().expect("finish zip").into_inner();
    fs::write(&decoy, bytes).expect("write decoy");

    let missing = restore_data_root(&RestoreRequest {
        archive_path: decoy,
        target_root: work.join("decoy-target"),
    })
    .expect_err("an archive without a manifest is refused");
    assert_eq!(missing.to_string(), "archive_manifest_missing");
}

#[test]
fn an_absent_credential_store_is_reported_as_a_limited_recovery() {
    let source = synthetic_data_root("limited");
    fs::remove_file(source.join("client-state/llm-api-key-inventory.json"))
        .expect("remove credential reference store");
    let work = scratch("limited-out");
    let archive = work.join("limited.tar.gz");

    let outcome = export(&source, &archive);
    assert_eq!(outcome.coverage, RecoveryCoverage::Limited);
    assert_eq!(outcome.limitations.len(), 1);
    assert_eq!(
        outcome.limitations[0].domain,
        "gateway-credential-custody"
    );

    let target = work.join("restored");
    let restored = restore_data_root(&RestoreRequest {
        archive_path: archive,
        target_root: target.clone(),
    })
    .expect("limited restore still succeeds");
    assert_eq!(
        restored.coverage,
        RecoveryCoverage::Limited,
        "the limitation travels with the archive"
    );
    assert!(target.join(".licoup-workspace.json").is_file());
}
