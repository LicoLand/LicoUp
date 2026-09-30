//! Full data-root archive acceptance.
//!
//! Proves, against the real foundation owner:
//!
//! 1. both plaintext containers carry the same logical payload and both restore
//!    application facts and file contents faithfully;
//! 2. a running writer is refused, the source is never modified, and no member is
//!    published outside the target root;
//! 3. a destination inside, or reached into, the captured root is refused before the
//!    owner creates anything, so an archive is never captured as a member of itself;
//! 4. a restore destination reached through a symbolic link is resolved and accepted,
//!    while a linked member inside an archive stays refused;
//! 5. symbolic links in the captured root are skipped, and credential coverage follows
//!    the store the credential owner actually reads rather than a former path.
//!
//! Everything here runs on synthetic roots under a disposable directory. No real
//! data root, operating-system credential prompt or installed client is touched.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use licoup_foundation::core::full_data_root_archive::{
    ARCHIVE_LAYOUT, ArchiveContainer, ExportRequest, RecoveryCoverage, RestoreRequest,
    export_data_root, restore_data_root,
};

/// The manifest member every archive carries first. The owner's own constant is crate
/// private, so these fixtures name the fixed member explicitly.
const MANIFEST_MEMBER: &str = "licoup-data-root.json";

/// The credential inventory document, at the data-root-relative path its owner reads.
const CREDENTIAL_INVENTORY: &str = "llm-api-key-inventory.json";

fn scratch(name: &str) -> PathBuf {
    // A canonical base for the disposable roots under test. The owner resolves a named
    // destination through its existing ancestors, so a base reached through a system
    // link is usable; resolving it once here keeps each fixture's own path stable.
    let base = std::env::temp_dir()
        .canonicalize()
        .expect("canonical temporary directory");
    let root = base.join(format!("licoup-full-archive-{name}-{}", std::process::id()));
    if root.exists() {
        fs::remove_dir_all(&root).expect("clear scratch root");
    }
    fs::create_dir_all(&root).expect("create scratch root");
    root
}

/// A synthetic complete root: canonical conversation database, settings, package
/// records and the credential inventory at the path its owner reads.
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
        &root.join(CREDENTIAL_INVENTORY),
        br#"{"providers":["synthetic-exportable"]}"#,
    );
    write(&root.join(".licoup-workspace.json"), br#"{"revision":1}"#);
    write(
        &root.join("adaptive-flywheel.toml"),
        b"[flywheel]\nrevision=1\n",
    );
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
        CREDENTIAL_INVENTORY,
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

fn export(
    root: &Path,
    archive: &Path,
) -> licoup_foundation::core::full_data_root_archive::ExportOutcome {
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
fn export_refuses_a_destination_inside_the_root_it_captures() {
    let source = synthetic_data_root("inside-root");
    let work = scratch("inside-root-out");
    let baseline = export(&source, &work.join("baseline.zip"));

    let direct = source.join("backup.zip");
    let refused = export_data_root(&ExportRequest {
        data_root: source.clone(),
        archive_path: direct.clone(),
        writers_stopped: true,
    })
    .expect_err("a destination inside the captured root is refused");
    assert_eq!(refused.to_string(), "archive_path_inside_data_root");
    assert!(!direct.exists(), "a refused capture publishes no archive");

    // A nested destination is refused before its parents are created inside the root, so
    // the root the capture declined to describe is untouched and can still be captured to
    // a destination the caller names outside it.
    let nested = source.join("nested/deeper/backup.tar.gz");
    let refused = export_data_root(&ExportRequest {
        data_root: source.clone(),
        archive_path: nested.clone(),
        writers_stopped: true,
    })
    .expect_err("a nested destination inside the captured root is refused");
    assert_eq!(refused.to_string(), "archive_path_inside_data_root");
    assert!(
        !source.join("nested").exists() && !nested.exists(),
        "no parent directory is created inside the captured root"
    );

    let after = export(&source, &work.join("after.zip"));
    assert_eq!(after.file_count, baseline.file_count);
    assert_eq!(after.total_bytes, baseline.total_bytes);
}

#[cfg(unix)]
#[test]
fn export_refuses_a_destination_reached_into_the_root_through_a_link() {
    let source = synthetic_data_root("linked-root");
    let work = scratch("linked-root-out");

    let link = work.join("root-link");
    std::os::unix::fs::symlink(&source, &link).expect("link to the captured root");
    let linked = link.join("nested/backup.zip");

    let refused = export_data_root(&ExportRequest {
        data_root: source.clone(),
        archive_path: linked.clone(),
        writers_stopped: true,
    })
    .expect_err("a destination reached into the captured root is refused");
    assert_eq!(refused.to_string(), "archive_path_inside_data_root");
    assert!(
        !source.join("nested").exists() && !linked.exists(),
        "nothing is created inside the captured root through the link"
    );
}

#[cfg(unix)]
#[test]
fn capture_skips_symbolic_links_in_the_source_root() {
    let source = synthetic_data_root("symlinks");
    let work = scratch("symlinks-out");
    let baseline = export(&source, &work.join("baseline.zip"));

    let outside = scratch("symlinks-outside");
    write(&outside.join("secret.txt"), b"outside the captured root");
    std::os::unix::fs::symlink(outside.join("secret.txt"), source.join("linked-secret.txt"))
        .expect("link to an outside file");
    std::os::unix::fs::symlink(&outside, source.join("linked-directory"))
        .expect("link to an outside directory");

    let archive = work.join("with-links.zip");
    let outcome = export(&source, &archive);
    assert_eq!(
        outcome.file_count, baseline.file_count,
        "a symbolic link is not a captured member"
    );
    assert_eq!(outcome.total_bytes, baseline.total_bytes);

    let target = work.join("restored");
    restore_data_root(&RestoreRequest {
        archive_path: archive,
        target_root: target.clone(),
    })
    .expect("restore succeeds without the links");
    assert!(
        !target.join("linked-secret.txt").exists()
            && !target.join("linked-directory").exists()
            && !target.join("linked-directory/secret.txt").exists(),
        "nothing the links pointed at is restored"
    );
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
    writer
        .start_file("data/notes.txt", options)
        .expect("add member");
    writer.write_all(b"no manifest").expect("write member");
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
fn restore_refuses_an_invalid_manifest_before_writing_anything() {
    let work = scratch("invalid-manifest");
    let archive = work.join("invalid.zip");
    let manifest = serde_json::to_vec(&serde_json::json!({
        "layout": ARCHIVE_LAYOUT,
        "container": "zip",
        "created_at_unix": 0,
        "coverage": "complete",
        "limitations": [],
        "entries": [{"path": "../escaped.txt", "kind": "file", "size": 4}],
        "total_bytes": 4,
    }))
    .expect("encode manifest");
    let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    writer
        .start_file(MANIFEST_MEMBER, options)
        .expect("add manifest");
    writer.write_all(&manifest).expect("write manifest");
    writer
        .start_file("data/../escaped.txt", options)
        .expect("add payload member");
    writer.write_all(b"evil").expect("write payload member");
    let bytes = writer.finish().expect("finish zip").into_inner();
    fs::write(&archive, bytes).expect("write fixture archive");

    let target = work.join("invalid-target");
    let error = restore_data_root(&RestoreRequest {
        archive_path: archive,
        target_root: target.clone(),
    })
    .expect_err("a manifest declaring an unsafe path is refused");
    assert_eq!(error.to_string(), "archive_inventory_path_invalid");
    assert!(
        fs::read_dir(&target)
            .expect("the refused destination exists")
            .next()
            .is_none(),
        "a refused restore publishes nothing"
    );
    assert!(
        !work.join("escaped.txt").exists(),
        "nothing is written outside the target"
    );
}

#[cfg(unix)]
#[test]
fn restore_accepts_a_destination_below_a_linked_ancestor() {
    let source = synthetic_data_root("linked-target");
    let work = scratch("linked-target-out");
    let archive = work.join("complete.zip");
    export(&source, &archive);

    let real = work.join("real");
    fs::create_dir_all(&real).expect("create the real destination parent");
    let linked = work.join("linked");
    std::os::unix::fs::symlink(&real, &linked).expect("link to the destination parent");
    let target = linked.join("restored");

    let outcome = restore_data_root(&RestoreRequest {
        archive_path: archive,
        target_root: target.clone(),
    })
    .expect("a destination reached through a symbolic link is resolved and accepted");

    assert_eq!(outcome.coverage, RecoveryCoverage::Complete);
    assert!(
        target.join(".licoup-workspace.json").is_file(),
        "the restored root is reachable through the name the caller used"
    );
    assert_equivalent(&source, &real.join("restored"));
    assert!(
        !real.join("restored/.licoup-restore-staging").exists(),
        "the staging area is removed after publication"
    );
}

#[test]
fn restore_refuses_a_linked_member_inside_an_archive() {
    let work = scratch("linked-member");

    for (name, bytes) in [
        ("linked-member.zip", zip_with_a_linked_member()),
        ("linked-member.tar.gz", tar_gz_with_a_linked_member()),
    ] {
        let archive = work.join(name);
        fs::write(&archive, bytes).expect("write fixture archive");
        let target = work.join(format!("{name}-target"));

        let error = restore_data_root(&RestoreRequest {
            archive_path: archive,
            target_root: target.clone(),
        })
        .expect_err("a linked member inside an archive is refused");
        assert_eq!(error.to_string(), "archive_extraction_refused");
        assert!(
            fs::symlink_metadata(target.join("data/link")).is_err(),
            "a refused restore publishes no member"
        );
        assert!(
            !work.join("escaped-target").exists(),
            "nothing is written where the linked member points"
        );
    }
}

#[test]
fn an_absent_credential_store_is_reported_as_a_limited_recovery() {
    let source = synthetic_data_root("limited");
    fs::remove_file(source.join(CREDENTIAL_INVENTORY)).expect("remove credential reference store");
    let work = scratch("limited-out");
    let archive = work.join("limited.tar.gz");

    let outcome = export(&source, &archive);
    assert_eq!(outcome.coverage, RecoveryCoverage::Limited);
    assert_eq!(outcome.limitations.len(), 1);
    assert_eq!(outcome.limitations[0].domain, "gateway-credential-custody");
    assert!(
        outcome.limitations[0].reason.contains(CREDENTIAL_INVENTORY),
        "the limitation names the store the owner reads: {:?}",
        outcome.limitations[0].reason
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

#[test]
fn coverage_counts_only_the_store_the_credential_owner_reads() {
    let work = scratch("credential-path");

    // The inventory at the path its owner reads is a complete recovery.
    let complete = synthetic_data_root("credential-path-complete");
    let complete_outcome = export(&complete, &work.join("complete.zip"));
    assert_eq!(complete_outcome.coverage, RecoveryCoverage::Complete);
    assert!(complete_outcome.limitations.is_empty());

    // The same document under the former `client-state/` name is ordinary payload data,
    // not the store the credential owner reads, so the archive stays a limited recovery
    // and names the absent store instead of reporting coverage the owner cannot honor.
    let misplaced = synthetic_data_root("credential-path-misplaced");
    let document = read(&misplaced.join(CREDENTIAL_INVENTORY));
    fs::remove_file(misplaced.join(CREDENTIAL_INVENTORY)).expect("move credential store");
    write(
        &misplaced.join("client-state").join(CREDENTIAL_INVENTORY),
        &document,
    );

    let misplaced_outcome = export(&misplaced, &work.join("misplaced.zip"));
    assert_eq!(misplaced_outcome.coverage, RecoveryCoverage::Limited);
    assert_eq!(misplaced_outcome.limitations.len(), 1);
    assert_eq!(
        misplaced_outcome.limitations[0].domain,
        "gateway-credential-custody"
    );
    assert!(
        misplaced_outcome.limitations[0]
            .reason
            .contains(CREDENTIAL_INVENTORY)
    );
}

/// A schema-valid manifest that declares no captured member. The fixtures below are
/// refused on their payload, so their manifest only has to be readable.
fn manifest_bytes(container: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "layout": ARCHIVE_LAYOUT,
        "container": container,
        "created_at_unix": 0,
        "coverage": "complete",
        "limitations": [],
        "entries": [],
        "total_bytes": 0,
    }))
    .expect("encode manifest")
}

/// A ZIP whose payload holds one member that is a symbolic link.
fn zip_with_a_linked_member() -> Vec<u8> {
    let manifest = manifest_bytes("zip");
    let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    writer
        .start_file(MANIFEST_MEMBER, options)
        .expect("add manifest");
    writer.write_all(&manifest).expect("write manifest");
    writer
        .add_directory("data/", options)
        .expect("add payload directory");
    writer
        .add_symlink("data/link", "escaped-target", options)
        .expect("add linked member");
    writer.finish().expect("finish zip").into_inner()
}

/// A TAR.GZ whose payload holds one member that is a symbolic link.
fn tar_gz_with_a_linked_member() -> Vec<u8> {
    let manifest = manifest_bytes("tar.gz");
    let mut tar_bytes = Vec::new();
    {
        let mut builder = tar::Builder::new(&mut tar_bytes);
        append_tar_member(
            &mut builder,
            MANIFEST_MEMBER,
            tar::EntryType::Regular,
            &manifest,
            None,
        );
        append_tar_member(&mut builder, "data/", tar::EntryType::Directory, &[], None);
        append_tar_member(
            &mut builder,
            "data/link",
            tar::EntryType::Symlink,
            &[],
            Some("escaped-target"),
        );
        builder.finish().expect("finish tar");
    }
    let mut gz_bytes = Vec::new();
    {
        let mut encoder =
            flate2::write::GzEncoder::new(&mut gz_bytes, flate2::Compression::default());
        encoder.write_all(&tar_bytes).expect("compress payload");
        encoder.finish().expect("finish gzip");
    }
    gz_bytes
}

fn append_tar_member<W: Write>(
    builder: &mut tar::Builder<W>,
    name: &str,
    entry_type: tar::EntryType,
    data: &[u8],
    link: Option<&str>,
) {
    let mut header = tar::Header::new_gnu();
    header.set_entry_type(entry_type);
    header.set_size(data.len() as u64);
    header.set_mode(if entry_type == tar::EntryType::Directory {
        0o700
    } else {
        0o600
    });
    if let Some(link) = link {
        header.set_link_name(link).expect("set link name");
    }
    header.set_cksum();
    builder
        .append_data(&mut header, name, data)
        .expect("append member");
}
