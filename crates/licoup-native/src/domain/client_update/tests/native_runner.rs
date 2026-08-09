use super::support::*;

use flate2::{Compression, write::GzEncoder};
use std::io;
use tar::Builder;

/// macOS live apply + rollback through the generated native script.
/// Runs synchronously (waitForScript) against a temporary install root so the
/// replacement and snapshot semantics are asserted end to end. The GUI PID is
/// a sleeping child that the script waits on (never killed).
#[cfg(target_os = "macos")]
#[test]
fn client_update_native_runner_applies_and_rolls_back_only_the_signed_archive_application() {
    let fixture = UpdateFixture::new();
    let archive = fixture.root.join("client-update.tar.gz");
    write_app_archive(&archive, b"staged");
    let artifact = app_bundle_artifact(&archive);
    let manifest =
        fixture.sign_manifest(fixture.unsigned_manifest(json!([release("999.0.0", artifact,)])));
    let mut params = fixture.params(manifest);
    params["sourcePath"] = json!(archive);
    download(&params).unwrap();
    let _ = verify_staged_selection(&params).unwrap();

    let install_root = fixture.root.join("Applications");
    let current_app = install_root.join("LicoUp.app");
    fs::create_dir_all(current_app.join("Contents")).unwrap();
    fs::write(current_app.join("Contents/Info.plist"), b"current").unwrap();
    // The "GUI" is a short-lived child that exits before the script's first
    // poll, so the exit-wait completes immediately.
    let mut gui_child = std::process::Command::new("/bin/sleep")
        .arg("30")
        .spawn()
        .unwrap();
    let gui_pid = gui_child.id().to_string();
    let _ = gui_child.kill();
    let _ = gui_child.wait();
    params["installRoot"] = json!(install_root);
    params["guiPid"] = json!(gui_pid);
    params["waitForScript"] = json!(true);
    params["execute"] = json!(true);

    let applied = super::super::apply::apply(&params).unwrap();
    assert_eq!(applied["phase"], "applied");
    assert_eq!(applied["scriptDispatched"], true);
    assert_eq!(
        fs::read(current_app.join("Contents/Info.plist")).unwrap(),
        b"staged"
    );
    assert_redacted(&applied, &fixture.root);

    // Snapshot must exist for the rollback path.
    let staging_root = fixture.staging.canonicalize().unwrap();
    let snapshots: Vec<_> = fs::read_dir(&staging_root)
        .unwrap()
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".rollback-")
        })
        .collect();
    assert_eq!(snapshots.len(), 1);

    let rolled_back = super::super::apply::rollback(&params).unwrap();
    assert_eq!(rolled_back["phase"], "rolledBack");
    assert_eq!(
        fs::read(current_app.join("Contents/Info.plist")).unwrap(),
        b"current"
    );
    assert_redacted(&rolled_back, &fixture.root);
}

/// Script generation is validated on every platform: the templates must use
/// only the allowlisted OS-bundled commands and never the banned tools, and
/// injected argv values are validated before they reach a script.
#[test]
fn client_update_native_runner_scripts_use_only_bundled_tools() {
    use super::super::native_runner::script::{ScriptAction, platform_script_for_test};
    for (platform, action) in [
        ("macos", ScriptAction::Apply),
        ("macos", ScriptAction::Rollback),
        ("linux", ScriptAction::Apply),
        ("linux", ScriptAction::Rollback),
    ] {
        let script = platform_script_for_test(platform, action);
        for banned in [
            "curl", "wget", "gh ", "python", "node", "unzip", "tar ", "pkill", "pgrep", "shutil",
            "rm -rf /",
        ] {
            assert!(
                !script.contains(banned),
                "{platform} script must not use banned tool '{banned}'"
            );
        }
        assert!(script.contains("#!/bin/sh"));
        assert!(script.contains("kill -0"));
        assert!(script.contains("--"));
    }
    let windows_apply = platform_script_for_test("windows", ScriptAction::Apply);
    let windows_rollback = platform_script_for_test("windows", ScriptAction::Rollback);
    for script in [windows_apply, windows_rollback] {
        for banned in [
            "curl",
            "wget",
            "Invoke-WebRequest",
            "python",
            "node",
            "Expand-Archive",
        ] {
            assert!(
                !script.contains(banned),
                "windows script must not use '{banned}'"
            );
        }
        for required in [
            "Get-Process",
            "Start-Sleep",
            "Copy-Item",
            "Remove-Item",
            "Start-Process",
        ] {
            assert!(
                script.contains(required),
                "windows script must use '{required}'"
            );
        }
    }
    assert!(windows_apply.contains("Test-Path"));
    assert!(!windows_rollback.contains("Test-Path"));
}

#[test]
fn client_update_native_runner_rejects_injected_argv_values() {
    use super::super::native_runner::script::validate_script_paths;
    for value in [
        "/tmp/evil;rm -rf /",
        "/tmp/$(id)",
        "/tmp/quote'",
        "/tmp/quote\"",
        "/tmp/backtick`",
        "/tmp/pipe|",
        "/tmp/amp&",
        "relative-path",
        "",
    ] {
        assert!(
            validate_script_paths(&[value]).is_err(),
            "argv value must be rejected: {value:?}"
        );
    }
    // Absolute paths with spaces and drive letters are accepted.
    assert!(validate_script_paths(&["/tmp/LicoUp data/App", "C:\\Users\\Lico\\App"]).is_ok());
}

#[test]
fn client_update_native_runner_target_guard_rejects_filesystem_roots() {
    use super::super::native_runner::plan::ensure_guarded_target_for_test;
    for target in [Path::new("/"), Path::new("C:\\"), Path::new("/tmp")] {
        assert!(
            ensure_guarded_target_for_test(target).is_err(),
            "target must be rejected: {target:?}"
        );
    }
    assert!(ensure_guarded_target_for_test(Path::new("/tmp/LicoUp")).is_ok());
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
        .append_data(&mut directory, "LicoUp.app/Contents", io::empty())
        .unwrap();
    let mut file = tar::Header::new_gnu();
    file.set_mode(0o644);
    file.set_size(marker.len() as u64);
    file.set_cksum();
    archive
        .append_data(&mut file, "LicoUp.app/Contents/Info.plist", marker)
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
        "applicationName": "LicoUp.app",
        "bundleId": "land.lico.licoup",
    })
}
