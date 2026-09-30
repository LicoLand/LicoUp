use std::fs;
use std::io::Write;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use super::support::temp_path;

#[test]
fn dropping_an_uncommitted_private_file_leaves_no_output() {
    let root = temp_path("atomic-private-drop");
    fs::create_dir_all(&root).unwrap();
    let destination = root.join("archive.bin");
    {
        let mut writer = super::super::AtomicPrivateFile::create(&destination).unwrap();
        writer.file_mut().write_all(b"partial").unwrap();
    }
    assert!(!destination.exists());
    assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn committing_a_private_file_replaces_the_destination_privately() {
    let root = temp_path("atomic-private-commit");
    fs::create_dir_all(&root).unwrap();
    let destination = root.join("archive.bin");
    let mut writer = super::super::AtomicPrivateFile::create(&destination).unwrap();
    writer.file_mut().write_all(b"archive").unwrap();
    writer.commit().unwrap();

    assert_eq!(fs::read(&destination).unwrap(), b"archive");
    #[cfg(unix)]
    assert_eq!(
        fs::symlink_metadata(&destination)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn a_destination_symlink_is_refused_and_its_referent_is_preserved() {
    use std::os::unix::fs::symlink;

    let root = temp_path("atomic-private-link");
    fs::create_dir_all(&root).unwrap();
    let referent = root.join("referent");
    let destination = root.join("destination");
    fs::write(&referent, b"preserve").unwrap();
    symlink(&referent, &destination).unwrap();

    let result = super::super::AtomicPrivateFile::create(&destination);
    assert!(result.is_err());
    assert_eq!(fs::read(&referent).unwrap(), b"preserve");
    assert!(fs::symlink_metadata(&destination).unwrap().is_symlink());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn replacing_a_hard_link_alias_preserves_the_other_name() {
    let root = temp_path("atomic-private-hardlink");
    fs::create_dir_all(&root).unwrap();
    let referent = root.join("referent");
    let destination = root.join("alias");
    fs::write(&referent, b"original").unwrap();
    fs::hard_link(&referent, &destination).unwrap();

    let mut writer = super::super::AtomicPrivateFile::create(&destination).unwrap();
    writer.file_mut().write_all(b"archive").unwrap();
    writer.commit().unwrap();

    assert_eq!(fs::read(&referent).unwrap(), b"original");
    assert_eq!(fs::read(&destination).unwrap(), b"archive");
    fs::remove_dir_all(root).unwrap();
}
