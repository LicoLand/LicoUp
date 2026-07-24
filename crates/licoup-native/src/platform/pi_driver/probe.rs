use super::super::process_supervisor::SupervisedChild;
use super::model::CapabilityProbe;
use std::process::{Command, Stdio};
use std::time::Duration;

pub(in crate::platform) fn probe(
    executable: &str,
    timeout_ms: u64,
    _max_output: usize,
) -> CapabilityProbe {
    let version_ok = run_probe_command(executable, "--version", timeout_ms) == Some(true);
    let help_ok = run_probe_command(executable, "--help", timeout_ms) == Some(true);
    if !version_ok && !help_ok {
        CapabilityProbe::unavailable()
    } else {
        CapabilityProbe::installed(version_ok, help_ok)
    }
}

fn run_probe_command(executable: &str, argument: &str, timeout_ms: u64) -> Option<bool> {
    let mut command = Command::new(executable);
    command
        .arg(argument)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = SupervisedChild::spawn(&mut command).ok()?;
    let status = child
        .finish_or_terminate_tree(Duration::from_millis(timeout_ms))
        .ok()?;
    Some(status.map(|value| value.success()).unwrap_or(false))
}
