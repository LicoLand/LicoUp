use super::model::CapabilityProbe;
use std::path::Path;
use std::process::Command;

pub(in crate::platform) fn probe(executable: &Path) -> CapabilityProbe {
    if !executable.is_file() {
        return CapabilityProbe {
            available: false,
            supported: false,
            version_command_ok: false,
            help_command_ok: false,
            error_code: Some("lico_agent_executable_unavailable"),
        };
    }
    let help_ok = {
        let mut command = Command::new(executable);
        command.arg("--help");
        crate::platform::configure_untrusted_agent_command(&mut command);
        command
            .output()
            .map(|o| o.status.success() || !o.stderr.is_empty() || !o.stdout.is_empty())
            .unwrap_or(false)
    };
    CapabilityProbe {
        available: true,
        supported: true,
        version_command_ok: true,
        help_command_ok: help_ok,
        error_code: None,
    }
}
