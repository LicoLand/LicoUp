#[cfg(target_os = "macos")]
use anyhow::ensure;
use anyhow::{Result, anyhow};
use std::path::Path;
use std::process::Command;

pub(in crate::domain::collaboration_plugin::assembly) const CAPABILITY: &str =
    "platform-loopback-isolated-runtime-v1";

pub(super) fn command(
    runner: &Path,
    manifest: &Path,
    snapshot: &Path,
    runtime_data: &Path,
    port: u16,
) -> Result<Command> {
    #[cfg(target_os = "macos")]
    {
        return macos_command(runner, manifest, snapshot, runtime_data, port);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (runner, manifest, snapshot, runtime_data, port);
        Err(anyhow!(
            "collaboration_local_server_reliable_sandbox_unavailable"
        ))
    }
}

#[cfg(target_os = "macos")]
fn macos_command(
    runner: &Path,
    manifest: &Path,
    snapshot: &Path,
    runtime_data: &Path,
    port: u16,
) -> Result<Command> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";
    let metadata = std::fs::symlink_metadata(SANDBOX_EXEC)
        .map_err(|_| anyhow!("collaboration_local_server_reliable_sandbox_unavailable"))?;
    ensure!(
        metadata.is_file()
            && !metadata.file_type().is_symlink()
            && metadata.uid() == 0
            && metadata.permissions().mode() & 0o022 == 0,
        "collaboration_local_server_reliable_sandbox_unavailable"
    );
    let runner = seatbelt_literal(runner)?;
    let manifest = seatbelt_literal(manifest)?;
    let snapshot = seatbelt_literal(snapshot)?;
    let runtime_data = seatbelt_literal(runtime_data)?;
    let profile = format!(
        concat!(
            "(version 1)",
            "(deny default)",
            "(import \"system.sb\")",
            "(allow process-exec (literal \"{runner}\"))",
            "(allow signal (target self))",
            "(allow file-read* file-test-existence ",
            "(literal \"{runner}\") (literal \"{manifest}\") (literal \"{snapshot}\") ",
            "(subpath \"{runtime_data}\"))",
            "(allow file-write* (subpath \"{runtime_data}\"))",
            "(allow network-bind (local tcp \"localhost:{port}\"))",
            "(allow network-inbound (local tcp \"localhost:{port}\"))"
        ),
        runner = runner,
        manifest = manifest,
        snapshot = snapshot,
        runtime_data = runtime_data,
        port = port,
    );
    let mut command = Command::new(SANDBOX_EXEC);
    command.args(["-p", &profile]).arg(Path::new(&runner));
    Ok(command)
}

#[cfg(target_os = "macos")]
fn seatbelt_literal(path: &Path) -> Result<String> {
    ensure!(
        path.is_absolute(),
        "collaboration_local_server_sandbox_path_invalid"
    );
    let value = path
        .to_str()
        .ok_or_else(|| anyhow!("collaboration_local_server_sandbox_path_invalid"))?;
    ensure!(
        !value.chars().any(char::is_control),
        "collaboration_local_server_sandbox_path_invalid"
    );
    Ok(value.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::command;
    use std::fs;
    use uuid::Uuid;

    #[test]
    fn macos_profile_executes_only_the_declared_runner() {
        let root = std::env::temp_dir().join(format!("licoup-sandbox-test-{}", Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let manifest = root.join("manifest.json");
        let snapshot = root.join("snapshot.bin");
        let runtime_data = root.join("runtime-data");
        fs::write(&manifest, b"{}").unwrap();
        fs::write(&snapshot, b"snapshot").unwrap();
        fs::create_dir(&runtime_data).unwrap();

        let status = command(
            std::path::Path::new("/usr/bin/true"),
            &manifest,
            &snapshot,
            &runtime_data,
            32_345,
        )
        .unwrap()
        .status()
        .unwrap();
        assert!(status.success());
        let _ = fs::remove_dir_all(root);
    }
}
