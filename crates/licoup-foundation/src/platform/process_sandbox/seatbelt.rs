#[cfg(target_os = "macos")]
use anyhow::ensure;
use anyhow::{Result, anyhow};
use std::path::Path;
use std::process::Command;

pub const CAPABILITY_COLLABORATION_LOOPBACK: &str = "platform-loopback-isolated-runtime-v1";
pub const CAPABILITY_LICO_AGENT_PLAN: &str = "platform-lico-agent-plan-isolated-v1";

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum SandboxError {
    Unavailable,
    PathInvalid,
}

impl SandboxError {
    fn collaboration_code(self) -> &'static str {
        match self {
            Self::Unavailable => "collaboration_local_server_reliable_sandbox_unavailable",
            Self::PathInvalid => "collaboration_local_server_sandbox_path_invalid",
        }
    }

    fn plan_code(self) -> &'static str {
        match self {
            Self::Unavailable => "lico_agent_plan_reliable_sandbox_unavailable",
            Self::PathInvalid => "lico_agent_plan_sandbox_path_invalid",
        }
    }
}

/// Escape an absolute path for inclusion in a seatbelt profile literal.
pub fn seatbelt_literal(path: &Path) -> Result<String, SandboxError> {
    if !path.is_absolute() {
        return Err(SandboxError::PathInvalid);
    }
    let value = path.to_str().ok_or(SandboxError::PathInvalid)?;
    if value.chars().any(char::is_control) {
        return Err(SandboxError::PathInvalid);
    }
    Ok(value.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(target_os = "macos")]
fn verify_sandbox_exec() -> Result<(), SandboxError> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";
    let metadata =
        std::fs::symlink_metadata(SANDBOX_EXEC).map_err(|_| SandboxError::Unavailable)?;
    if !(metadata.is_file()
        && !metadata.file_type().is_symlink()
        && metadata.uid() == 0
        && metadata.permissions().mode() & 0o022 == 0)
    {
        return Err(SandboxError::Unavailable);
    }
    Ok(())
}

/// Collaboration local-server profile: write under `runtime_data`, bind/inbound on port.
pub fn collaboration_loopback_command(
    runner: &Path,
    manifest: &Path,
    snapshot: &Path,
    runtime_data: &Path,
    port: u16,
) -> Result<Command> {
    #[cfg(target_os = "macos")]
    {
        verify_sandbox_exec().map_err(|e| anyhow!(e.collaboration_code()))?;
        let runner_l = seatbelt_literal(runner).map_err(|e| anyhow!(e.collaboration_code()))?;
        let manifest_l = seatbelt_literal(manifest).map_err(|e| anyhow!(e.collaboration_code()))?;
        let snapshot_l = seatbelt_literal(snapshot).map_err(|e| anyhow!(e.collaboration_code()))?;
        let runtime_l =
            seatbelt_literal(runtime_data).map_err(|e| anyhow!(e.collaboration_code()))?;
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
            runner = runner_l,
            manifest = manifest_l,
            snapshot = snapshot_l,
            runtime_data = runtime_l,
            port = port,
        );
        let mut command = Command::new("/usr/bin/sandbox-exec");
        command.args(["-p", &profile]).arg(runner);
        return Ok(command);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (runner, manifest, snapshot, runtime_data, port);
        Err(anyhow!(SandboxError::Unavailable.collaboration_code()))
    }
}

/// Plan-mode Lico Agent profile: write one literal plan file; outbound Gateway only.
pub fn lico_agent_plan_command(
    runner: &Path,
    plan_file: &Path,
    workspace: &Path,
    gateway_port: u16,
    extra_args: &[String],
) -> Result<Command> {
    #[cfg(target_os = "macos")]
    {
        verify_sandbox_exec().map_err(|e| anyhow!(e.plan_code()))?;
        let runner_l = seatbelt_literal(runner).map_err(|e| anyhow!(e.plan_code()))?;
        let plan_l = seatbelt_literal(plan_file).map_err(|e| anyhow!(e.plan_code()))?;
        let workspace_l = seatbelt_literal(workspace).map_err(|e| anyhow!(e.plan_code()))?;
        ensure!(
            plan_file.is_absolute() && workspace.is_absolute(),
            SandboxError::PathInvalid.plan_code()
        );
        let profile = format!(
            concat!(
                "(version 1)",
                "(deny default)",
                "(import \"system.sb\")",
                "(allow process-exec (literal \"{runner}\"))",
                "(allow signal (target self))",
                "(allow file-read* file-test-existence ",
                "(literal \"{runner}\") (literal \"{plan}\") (subpath \"{workspace}\"))",
                "(allow file-write* (literal \"{plan}\"))",
                "(allow network-outbound (remote tcp \"localhost:{port}\"))"
            ),
            runner = runner_l,
            plan = plan_l,
            workspace = workspace_l,
            port = gateway_port,
        );
        let mut command = Command::new("/usr/bin/sandbox-exec");
        command.args(["-p", &profile]).arg(runner);
        command.args(extra_args);
        return Ok(command);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (runner, plan_file, workspace, gateway_port, extra_args);
        Err(anyhow!(SandboxError::Unavailable.plan_code()))
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::fs;
    use uuid::Uuid;

    fn sandbox_exec_can_apply() -> bool {
        // Outer CI/dev sandboxes can allow sandbox-exec while still denying
        // nested writes under /var/folders. Probe a literal write before
        // asserting Plan profile allow/deny behavior.
        let probe_root = std::env::temp_dir().join(format!("licoup-sb-probe-{}", Uuid::new_v4()));
        let _ = fs::create_dir_all(&probe_root);
        let probe_file = probe_root.join("probe.txt");
        let _ = fs::write(&probe_file, b"");
        let Ok(literal) = seatbelt_literal(&probe_file) else {
            let _ = fs::remove_dir_all(&probe_root);
            return false;
        };
        let profile = format!(
            "(version 1)(deny default)(import \"system.sb\")(allow process-exec (literal \"/usr/bin/tee\"))(allow file-read* file-test-existence (literal \"/usr/bin/tee\") (literal \"{literal}\"))(allow file-write* (literal \"{literal}\"))"
        );
        let mut command = std::process::Command::new("/usr/bin/sandbox-exec");
        command
            .args(["-p", &profile, "/usr/bin/tee"])
            .arg(&probe_file)
            .stdin(std::process::Stdio::piped());
        let ok = command
            .spawn()
            .ok()
            .and_then(|mut child| {
                use std::io::Write;
                child.stdin.as_mut()?.write_all(b"ok").ok()?;
                child.wait().ok()
            })
            .map(|status| {
                status.success() && fs::read_to_string(&probe_file).ok().as_deref() == Some("ok")
            })
            .unwrap_or(false);
        let _ = fs::remove_dir_all(probe_root);
        ok
    }

    #[test]
    fn collaboration_profile_runs_declared_runner() {
        if !sandbox_exec_can_apply() {
            return;
        }
        let root = std::env::temp_dir().join(format!("licoup-sb-collab-{}", Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let manifest = root.join("manifest.json");
        let snapshot = root.join("snapshot.bin");
        let runtime_data = root.join("runtime-data");
        fs::write(&manifest, b"{}").unwrap();
        fs::write(&snapshot, b"snapshot").unwrap();
        fs::create_dir(&runtime_data).unwrap();
        let status = collaboration_loopback_command(
            Path::new("/usr/bin/true"),
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

    #[test]
    fn plan_profile_allows_literal_plan_write() {
        if !sandbox_exec_can_apply() {
            return;
        }
        let root = std::env::temp_dir().join(format!("licoup-sb-plan-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let plan = root.join("active-plan.md");
        fs::write(&plan, b"").unwrap();
        let workspace = root.join("workspace");
        fs::create_dir(&workspace).unwrap();
        // Prefer a single literal binary over /bin/sh: seatbelt process-exec of
        // /bin/sh can fail when the host needs to resolve shell variants.
        let mut command = lico_agent_plan_command(
            Path::new("/usr/bin/tee"),
            &plan,
            &workspace,
            15_722,
            &[plan.display().to_string()],
        )
        .unwrap();
        command.stdin(std::process::Stdio::piped());
        let mut child = command.spawn().unwrap();
        use std::io::Write;
        child.stdin.as_mut().unwrap().write_all(b"ok").unwrap();
        let status = child.wait().unwrap();
        assert!(status.success());
        assert_eq!(fs::read_to_string(&plan).unwrap(), "ok");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn plan_profile_denies_sibling_write() {
        if !sandbox_exec_can_apply() {
            return;
        }
        let root = std::env::temp_dir().join(format!("licoup-sb-deny-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let plan = root.join("active-plan.md");
        fs::write(&plan, b"").unwrap();
        let sibling = root.join("other.md");
        let workspace = root.join("workspace");
        fs::create_dir(&workspace).unwrap();
        let mut command = lico_agent_plan_command(
            Path::new("/usr/bin/tee"),
            &plan,
            &workspace,
            15_722,
            &[sibling.display().to_string()],
        )
        .unwrap();
        command.stdin(std::process::Stdio::piped());
        let mut child = command.spawn().unwrap();
        use std::io::Write;
        let _ = child.stdin.as_mut().unwrap().write_all(b"x");
        let status = child.wait().unwrap();
        assert!(!status.success());
        assert!(!sibling.exists() || fs::read_to_string(&sibling).unwrap_or_default() != "x");
        let _ = fs::remove_dir_all(root);
    }
}
