use super::support::*;

use flate2::{Compression, write::GzEncoder};
use std::io;
use tar::Builder;

#[test]
fn client_update_macos_runner_applies_and_rolls_back_only_the_signed_archive_application() {
    let fixture = UpdateFixture::new();
    let archive = fixture.root.join("client-update.tar.gz");
    write_app_archive(&archive, b"staged");
    let artifact = app_bundle_artifact(&archive);
    let manifest =
        fixture.sign_manifest(fixture.unsigned_manifest(json!([release("999.0.0", artifact,)])));
    let mut params = fixture.params(manifest);
    params["sourcePath"] = json!(archive);
    download(&params).unwrap();
    let (selection, staged_path) = verify_staged_selection(&params).unwrap();

    let install_root = fixture.root.join("Applications");
    let current_app = install_root.join("Lico Arc.app");
    fs::create_dir_all(current_app.join("Contents")).unwrap();
    fs::write(current_app.join("Contents/Info.plist"), b"current").unwrap();
    let applied =
        super::super::macos_runner::apply_for_test(&selection, &staged_path, &install_root)
            .unwrap();
    assert_eq!(applied["phase"], "applied");
    assert_eq!(
        fs::read(current_app.join("Contents/Info.plist")).unwrap(),
        b"staged"
    );
    assert_redacted(&applied, &fixture.root);

    let rolled_back = super::super::macos_runner::rollback_for_test(
        &selection,
        &install_root,
        staged_path.parent().unwrap(),
    )
    .unwrap();
    assert_eq!(rolled_back["phase"], "rolledBack");
    assert_eq!(
        fs::read(current_app.join("Contents/Info.plist")).unwrap(),
        b"current"
    );
    assert_redacted(&rolled_back, &fixture.root);
}

#[test]
fn client_update_macos_archive_paths_reject_parent_absolute_and_current_components() {
    for path in [
        Path::new("../escape"),
        Path::new("/absolute"),
        Path::new("./current"),
    ] {
        assert!(
            super::super::macos_runner::validate_archive_path_for_test(path)
                .unwrap_err()
                .to_string()
                .contains("relative and normalized")
        );
    }
}

fn write_app_archive(path: &Path, marker: &[u8]) {
    let encoder = GzEncoder::new(fs::File::create(path).unwrap(), Compression::default());
    let mut archive = Builder::new(encoder);
    let mut directory = tar::Header::new_gnu();
    directory.set_entry_type(tar::EntryType::Directory);
    directory.set_mode(0o755);
    directory.set_size(0);
    directory.set_cksum();
    archive
        .append_data(&mut directory, "Lico Arc.app/Contents", io::empty())
        .unwrap();
    let mut file = tar::Header::new_gnu();
    file.set_mode(0o644);
    file.set_size(marker.len() as u64);
    file.set_cksum();
    archive
        .append_data(&mut file, "Lico Arc.app/Contents/Info.plist", marker)
        .unwrap();
    archive.into_inner().unwrap().finish().unwrap();
}

fn app_bundle_artifact(path: &Path) -> Value {
    json!({
        "targetId": TARGET_ID,
        "platform": "macos",
        "osFamily": "darwin",
        "arch": "arm64",
        "installerStrategy": "app-bundle-replacement",
        "url": url::Url::from_file_path(path).unwrap().to_string(),
        "fileName": "client-update.tar.gz",
        "size": fs::metadata(path).unwrap().len(),
        "sha256": sha256_hex(&fs::read(path).unwrap()),
        "applicationName": "Lico Arc.app",
        "bundleId": "com.liko.arc",
    })
}
