//! OS login autostart for the loopback LLM Gateway sidecar.
//!
//! Installs a per-user launch item that runs
//! `licoup-cli llm-gateway service start` at login. The Gateway starts
//! disconnected (no Keychain handoff) until the user authorizes in the app.
//! Credentials are never stored in the launch item.

use crate::platform::file_security::{
    atomic_write_private_text, ensure_private_dir, read_private_text_bounded,
};
use crate::platform::paths;
use anyhow::{Result, anyhow, bail, ensure};
use directories::UserDirs;
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const AUTOSTART_SCHEMA: &str = "licoup.llm-gateway-autostart.v1";
const LABEL: &str = "land.lico.licoup.llm-gateway";
const MAX_MARKER_BYTES: usize = 4 * 1024;

#[derive(Clone, Debug)]
struct AutostartMarker {
    enabled: bool,
    port: u16,
    program: String,
}

impl AutostartMarker {
    fn to_json(&self) -> Value {
        json!({
            "schemaVersion": AUTOSTART_SCHEMA,
            "enabled": self.enabled,
            "port": self.port,
            "program": self.program,
        })
    }

    fn from_json(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        if object.get("schemaVersion").and_then(Value::as_str) != Some(AUTOSTART_SCHEMA) {
            return None;
        }
        Some(Self {
            enabled: object.get("enabled").and_then(Value::as_bool)?,
            port: object.get("port").and_then(Value::as_u64).and_then(|value| {
                u16::try_from(value).ok().filter(|port| *port != 0)
            })?,
            program: object
                .get("program")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
        })
    }
}

fn state_dir() -> Result<PathBuf> {
    let root = paths::portable_data_dir()?.join("llm-gateway");
    ensure_private_dir(&root)?;
    Ok(root)
}

fn marker_path() -> Result<PathBuf> {
    Ok(state_dir()?.join("autostart.json"))
}

fn cli_program_path() -> Result<PathBuf> {
    let current = std::env::current_exe().map_err(|_| anyhow!("llm_gateway_autostart_cli_missing"))?;
    let metadata =
        fs::symlink_metadata(&current).map_err(|_| anyhow!("llm_gateway_autostart_cli_missing"))?;
    ensure!(
        metadata.file_type().is_file(),
        "llm_gateway_autostart_cli_missing"
    );
    fs::canonicalize(&current).map_err(|_| anyhow!("llm_gateway_autostart_cli_missing"))
}

fn read_marker() -> Result<Option<AutostartMarker>> {
    let path = marker_path()?;
    let Some(text) = read_private_text_bounded(&path, MAX_MARKER_BYTES)? else {
        return Ok(None);
    };
    let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    Ok(AutostartMarker::from_json(&value))
}

fn write_marker(marker: &AutostartMarker) -> Result<()> {
    let path = marker_path()?;
    atomic_write_private_text(&path, &serde_json::to_string_pretty(&marker.to_json())?)?;
    Ok(())
}

fn clear_marker() -> Result<()> {
    let path = marker_path()?;
    if path.is_file() {
        fs::remove_file(&path).map_err(|_| anyhow!("llm_gateway_autostart_clear_failed"))?;
    }
    Ok(())
}

/// Report whether login autostart is installed for the current user.
pub fn autostart_status() -> Result<Value> {
    let marker = read_marker()?;
    let installed = platform_installed()?;
    let enabled = marker.as_ref().is_some_and(|value| value.enabled) && installed;
    Ok(json!({
        "ok": true,
        "schemaVersion": AUTOSTART_SCHEMA,
        "supported": platform_supported(),
        "enabled": enabled,
        "installed": installed,
        "port": marker.as_ref().map(|value| value.port),
        "program": marker.as_ref().map(|value| value.program.clone()).unwrap_or_default(),
        "label": LABEL,
    }))
}

/// Install and load the per-user login item that starts the Gateway alone.
pub fn autostart_enable(port: u16) -> Result<Value> {
    ensure!(port != 0, "llm_gateway_port_invalid");
    if !platform_supported() {
        bail!("llm_gateway_autostart_unsupported");
    }
    let program = cli_program_path()?;
    platform_install(&program, port)?;
    write_marker(&AutostartMarker {
        enabled: true,
        port,
        program: program.to_string_lossy().into_owned(),
    })?;
    autostart_status()
}

/// Unload and remove the per-user login item.
pub fn autostart_disable() -> Result<Value> {
    if !platform_supported() {
        bail!("llm_gateway_autostart_unsupported");
    }
    platform_uninstall()?;
    clear_marker()?;
    autostart_status()
}

fn platform_supported() -> bool {
    cfg!(target_os = "macos") || cfg!(target_os = "linux")
}

fn user_home() -> Result<PathBuf> {
    UserDirs::new()
        .map(|dirs| dirs.home_dir().to_path_buf())
        .ok_or_else(|| anyhow!("llm_gateway_autostart_home_missing"))
}

#[cfg(target_os = "macos")]
fn launch_agents_dir() -> Result<PathBuf> {
    let directory = user_home()?.join("Library/LaunchAgents");
    fs::create_dir_all(&directory).map_err(|_| anyhow!("llm_gateway_autostart_install_failed"))?;
    Ok(directory)
}

#[cfg(target_os = "macos")]
fn plist_path() -> Result<PathBuf> {
    Ok(launch_agents_dir()?.join(format!("{LABEL}.plist")))
}

#[cfg(target_os = "macos")]
fn platform_installed() -> Result<bool> {
    Ok(plist_path()?.is_file())
}

#[cfg(target_os = "macos")]
fn platform_install(program: &Path, port: u16) -> Result<()> {
    let log_path = state_dir()?.join("autostart.log");
    let portable = paths::portable_data_dir()?;
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{}</string>
    <string>llm-gateway</string>
    <string>service</string>
    <string>start</string>
    <string>--port</string>
    <string>{port}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LICOUP_PORTABLE_DIR</key>
    <string>{}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>{}</string>
  <key>StandardErrorPath</key>
  <string>{}</string>
</dict>
</plist>
"#,
        xml_escape(&program.to_string_lossy()),
        xml_escape(&portable.to_string_lossy()),
        xml_escape(&log_path.to_string_lossy()),
        xml_escape(&log_path.to_string_lossy()),
    );
    let path = plist_path()?;
    atomic_write_private_text(&path, &plist)?;
    // Replace any previous registration, then bootstrap the new definition.
    let _ = launchctl_bootout();
    let status = Command::new("/bin/launchctl")
        .args(["bootstrap", &gui_domain()?, path.to_str().unwrap_or_default()])
        .status()
        .map_err(|_| anyhow!("llm_gateway_autostart_install_failed"))?;
    ensure!(status.success(), "llm_gateway_autostart_install_failed");
    Ok(())
}

#[cfg(target_os = "macos")]
fn platform_uninstall() -> Result<()> {
    let _ = launchctl_bootout();
    let path = plist_path()?;
    if path.is_file() {
        fs::remove_file(&path).map_err(|_| anyhow!("llm_gateway_autostart_clear_failed"))?;
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn launchctl_bootout() -> Result<()> {
    let _ = Command::new("/bin/launchctl")
        .args(["bootout", &format!("{}/{}", gui_domain()?, LABEL)])
        .status();
    Ok(())
}

#[cfg(target_os = "macos")]
fn gui_domain() -> Result<String> {
    let uid = unsafe { libc::getuid() };
    Ok(format!("gui/{uid}"))
}

#[cfg(target_os = "linux")]
fn systemd_unit_path() -> Result<PathBuf> {
    let directory = user_home()?.join(".config/systemd/user");
    fs::create_dir_all(&directory).map_err(|_| anyhow!("llm_gateway_autostart_install_failed"))?;
    Ok(directory.join("lico-llm-gateway.service"))
}

#[cfg(target_os = "linux")]
fn platform_installed() -> Result<bool> {
    Ok(systemd_unit_path()?.is_file())
}

#[cfg(target_os = "linux")]
fn platform_install(program: &Path, port: u16) -> Result<()> {
    let portable = paths::portable_data_dir()?;
    let unit = format!(
        "[Unit]\nDescription=LicoUp LLM Gateway\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nEnvironment=LICOUP_PORTABLE_DIR={}\nExecStart={} llm-gateway service start --port {port}\nExecStop={} llm-gateway service stop --port {port}\n\n[Install]\nWantedBy=default.target\n",
        shell_escape(&portable.to_string_lossy()),
        shell_escape(&program.to_string_lossy()),
        shell_escape(&program.to_string_lossy()),
    );
    let path = systemd_unit_path()?;
    atomic_write_private_text(&path, &unit)?;
    let reload = Command::new("systemctl")
        .args(["--user", "daemon-reload"])
        .status()
        .map_err(|_| anyhow!("llm_gateway_autostart_install_failed"))?;
    ensure!(reload.success(), "llm_gateway_autostart_install_failed");
    let enable = Command::new("systemctl")
        .args(["--user", "enable", "lico-llm-gateway.service"])
        .status()
        .map_err(|_| anyhow!("llm_gateway_autostart_install_failed"))?;
    ensure!(enable.success(), "llm_gateway_autostart_install_failed");
    Ok(())
}

#[cfg(target_os = "linux")]
fn platform_uninstall() -> Result<()> {
    let _ = Command::new("systemctl")
        .args(["--user", "disable", "--now", "lico-llm-gateway.service"])
        .status();
    let path = systemd_unit_path()?;
    if path.is_file() {
        fs::remove_file(&path).map_err(|_| anyhow!("llm_gateway_autostart_clear_failed"))?;
    }
    let _ = Command::new("systemctl")
        .args(["--user", "daemon-reload"])
        .status();
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_installed() -> Result<bool> {
    Ok(false)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_install(_program: &Path, _port: u16) -> Result<()> {
    bail!("llm_gateway_autostart_unsupported")
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_uninstall() -> Result<()> {
    bail!("llm_gateway_autostart_unsupported")
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(target_os = "linux")]
fn shell_escape(value: &str) -> String {
    if value.is_empty() {
        return "''".into();
    }
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':'))
    {
        return value.to_owned();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marker_round_trips() {
        let marker = AutostartMarker {
            enabled: true,
            port: 15722,
            program: "/Applications/LicoUp.app/Contents/MacOS/licoup-cli".into(),
        };
        let restored = AutostartMarker::from_json(&marker.to_json()).unwrap();
        assert!(restored.enabled);
        assert_eq!(restored.port, 15722);
        assert!(restored.program.contains("licoup-cli"));
    }
}
