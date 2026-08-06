//! Per-user login autostart for the desktop client and local MCP prepare.
//!
//! LLM Gateway login autostart stays in [`super::llm_gateway_autostart`]; this
//! module reports and drives the desktop + MCP toggles and aggregates status.

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

pub const SCHEMA: &str = "licoup.client-autostart.v1";
const DESKTOP_LABEL: &str = "land.lico.licoup.desktop";
const MCP_LABEL: &str = "land.lico.licoup.mcp-prepare";
const MAX_MARKER_BYTES: usize = 8 * 1024;

#[derive(Clone, Debug, Default)]
struct DesktopMarker {
    enabled: bool,
    silent: bool,
    program: String,
}

#[derive(Clone, Debug, Default)]
struct McpMarker {
    enabled: bool,
    program: String,
}

fn state_dir() -> Result<PathBuf> {
    let root = paths::portable_data_dir()?.join("client-autostart");
    ensure_private_dir(&root)?;
    Ok(root)
}

fn desktop_marker_path() -> Result<PathBuf> {
    Ok(state_dir()?.join("desktop.json"))
}

fn mcp_marker_path() -> Result<PathBuf> {
    Ok(state_dir()?.join("mcp.json"))
}

fn user_home() -> Result<PathBuf> {
    UserDirs::new()
        .map(|dirs| dirs.home_dir().to_path_buf())
        .ok_or_else(|| anyhow!("client_autostart_home_missing"))
}

fn cli_program_path() -> Result<PathBuf> {
    let current = std::env::current_exe().map_err(|_| anyhow!("client_autostart_cli_missing"))?;
    let metadata =
        fs::symlink_metadata(&current).map_err(|_| anyhow!("client_autostart_cli_missing"))?;
    ensure!(
        metadata.file_type().is_file(),
        "client_autostart_cli_missing"
    );
    fs::canonicalize(&current).map_err(|_| anyhow!("client_autostart_cli_missing"))
}

fn app_bundle_path() -> Result<PathBuf> {
    let cli = cli_program_path()?;
    // …/LicoUp.app/Contents/MacOS/licoup-cli → …/LicoUp.app
    let bundle = cli
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or_else(|| anyhow!("client_autostart_app_missing"))?;
    ensure!(
        bundle.extension().and_then(|value| value.to_str()) == Some("app")
            || bundle.join("Contents").is_dir(),
        "client_autostart_app_missing"
    );
    Ok(bundle.to_path_buf())
}

fn read_json_file(path: &Path) -> Result<Option<Value>> {
    let Some(text) = read_private_text_bounded(path, MAX_MARKER_BYTES)? else {
        return Ok(None);
    };
    Ok(serde_json::from_str(&text).ok())
}

fn write_json_file(path: &Path, value: &Value) -> Result<()> {
    atomic_write_private_text(path, &serde_json::to_string_pretty(value)?)?;
    Ok(())
}

fn read_desktop_marker() -> Result<DesktopMarker> {
    let Some(value) = read_json_file(&desktop_marker_path()?)? else {
        return Ok(DesktopMarker::default());
    };
    Ok(DesktopMarker {
        enabled: value.get("enabled").and_then(Value::as_bool).unwrap_or(false),
        silent: value.get("silent").and_then(Value::as_bool).unwrap_or(false),
        program: value
            .get("program")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
    })
}

fn read_mcp_marker() -> Result<McpMarker> {
    let Some(value) = read_json_file(&mcp_marker_path()?)? else {
        return Ok(McpMarker::default());
    };
    Ok(McpMarker {
        enabled: value.get("enabled").and_then(Value::as_bool).unwrap_or(false),
        program: value
            .get("program")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
    })
}

/// Aggregate status for the Settings “开启自启动” card.
pub fn status() -> Result<Value> {
    let desktop = read_desktop_marker()?;
    let mcp = read_mcp_marker()?;
    let gateway = crate::platform::llm_gateway_autostart::autostart_status()?;
    let desktop_installed = platform_desktop_installed()?;
    let mcp_installed = platform_mcp_installed()?;
    Ok(json!({
        "ok": true,
        "schemaVersion": SCHEMA,
        "supported": platform_supported(),
        "desktop": {
            "enabled": desktop.enabled && desktop_installed,
            "silent": desktop.silent,
            "installed": desktop_installed,
            "program": desktop.program,
            "label": DESKTOP_LABEL,
        },
        "gateway": gateway,
        "mcp": {
            "enabled": mcp.enabled && mcp_installed,
            "installed": mcp_installed,
            "program": mcp.program,
            "label": MCP_LABEL,
            "binariesPresent": mcp_binaries_present()?,
        },
    }))
}

pub fn set_desktop(enabled: bool, silent: bool) -> Result<Value> {
    if !platform_supported() {
        bail!("client_autostart_unsupported");
    }
    if enabled {
        let app = app_bundle_path()?;
        platform_desktop_install(&app, silent)?;
        write_json_file(
            &desktop_marker_path()?,
            &json!({
                "schemaVersion": SCHEMA,
                "enabled": true,
                "silent": silent,
                "program": app.to_string_lossy(),
            }),
        )?;
    } else {
        platform_desktop_uninstall()?;
        let _ = fs::remove_file(desktop_marker_path()?);
    }
    status()
}

pub fn set_mcp(enabled: bool) -> Result<Value> {
    if !platform_supported() {
        bail!("client_autostart_unsupported");
    }
    if enabled {
        let cli = cli_program_path()?;
        platform_mcp_install(&cli)?;
        write_json_file(
            &mcp_marker_path()?,
            &json!({
                "schemaVersion": SCHEMA,
                "enabled": true,
                "program": cli.to_string_lossy(),
            }),
        )?;
    } else {
        platform_mcp_uninstall()?;
        let _ = fs::remove_file(mcp_marker_path()?);
    }
    status()
}

pub fn set_gateway(enabled: bool, port: u16) -> Result<Value> {
    if enabled {
        crate::platform::llm_gateway_autostart::autostart_enable(port)?;
    } else {
        crate::platform::llm_gateway_autostart::autostart_disable()?;
    }
    status()
}

/// Login oneshot for the MCP prepare LaunchAgent. Never silently installs
/// agent MCP plugins (digest confirmation required). Verifies packaged
/// binaries and writes a readiness stamp.
pub fn prepare_mcp() -> Result<Value> {
    let present = mcp_binaries_present()?;
    let stamp = state_dir()?.join("mcp-prepare-last.json");
    write_json_file(
        &stamp,
        &json!({
            "ok": true,
            "schemaVersion": SCHEMA,
            "preparedAtUnixMs": unix_ms(),
            "binariesPresent": present,
        }),
    )?;
    Ok(json!({
        "ok": true,
        "schemaVersion": SCHEMA,
        "binariesPresent": present,
    }))
}

fn mcp_binaries_present() -> Result<bool> {
    let cli = match cli_program_path() {
        Ok(path) => path,
        Err(_) => return Ok(false),
    };
    let dir = match cli.parent() {
        Some(path) => path,
        None => return Ok(false),
    };
    let subagent = dir.join(format!("lico-subagent-mcp{}", std::env::consts::EXE_SUFFIX));
    let conversation = dir.join(format!(
        "lico-conversation-mcp{}",
        std::env::consts::EXE_SUFFIX
    ));
    Ok(subagent.is_file() && conversation.is_file())
}

fn platform_supported() -> bool {
    cfg!(target_os = "macos") || cfg!(target_os = "linux")
}

fn unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as i64)
        .unwrap_or(0)
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(target_os = "macos")]
fn launch_agents_dir() -> Result<PathBuf> {
    let directory = user_home()?.join("Library/LaunchAgents");
    fs::create_dir_all(&directory).map_err(|_| anyhow!("client_autostart_install_failed"))?;
    Ok(directory)
}

#[cfg(target_os = "macos")]
fn gui_domain() -> Result<String> {
    Ok(format!("gui/{}", unsafe { libc::getuid() }))
}

#[cfg(target_os = "macos")]
fn launchctl_bootout(label: &str) -> Result<()> {
    let _ = Command::new("/bin/launchctl")
        .args(["bootout", &format!("{}/{}", gui_domain()?, label)])
        .status();
    Ok(())
}

#[cfg(target_os = "macos")]
fn launchctl_bootstrap(plist: &Path) -> Result<()> {
    let status = Command::new("/bin/launchctl")
        .args([
            "bootstrap",
            &gui_domain()?,
            plist.to_str().ok_or_else(|| anyhow!("client_autostart_install_failed"))?,
        ])
        .status()
        .map_err(|_| anyhow!("client_autostart_install_failed"))?;
    ensure!(status.success(), "client_autostart_install_failed");
    Ok(())
}

#[cfg(target_os = "macos")]
fn write_plist(label: &str, body: &str) -> Result<PathBuf> {
    let path = launch_agents_dir()?.join(format!("{label}.plist"));
    atomic_write_private_text(&path, body)?;
    let _ = launchctl_bootout(label);
    launchctl_bootstrap(&path)?;
    Ok(path)
}

#[cfg(target_os = "macos")]
fn platform_desktop_installed() -> Result<bool> {
    Ok(launch_agents_dir()?.join(format!("{DESKTOP_LABEL}.plist")).is_file())
}

#[cfg(target_os = "macos")]
fn platform_mcp_installed() -> Result<bool> {
    Ok(launch_agents_dir()?.join(format!("{MCP_LABEL}.plist")).is_file())
}

#[cfg(target_os = "macos")]
fn platform_desktop_install(app: &Path, silent: bool) -> Result<()> {
    let log = state_dir()?.join("desktop-autostart.log");
    let args = if silent {
        format!(
            r#"    <string>/usr/bin/open</string>
    <string>-na</string>
    <string>{}</string>
    <string>--args</string>
    <string>--silent-start</string>"#,
            xml_escape(&app.to_string_lossy())
        )
    } else {
        format!(
            r#"    <string>/usr/bin/open</string>
    <string>-na</string>
    <string>{}</string>"#,
            xml_escape(&app.to_string_lossy())
        )
    };
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{DESKTOP_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
{args}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>{}</string>
  <key>StandardErrorPath</key>
  <string>{}</string>
</dict>
</plist>
"#,
        xml_escape(&log.to_string_lossy()),
        xml_escape(&log.to_string_lossy()),
    );
    write_plist(DESKTOP_LABEL, &plist)?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn platform_desktop_uninstall() -> Result<()> {
    let _ = launchctl_bootout(DESKTOP_LABEL);
    let path = launch_agents_dir()?.join(format!("{DESKTOP_LABEL}.plist"));
    if path.is_file() {
        fs::remove_file(&path).map_err(|_| anyhow!("client_autostart_clear_failed"))?;
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn platform_mcp_install(cli: &Path) -> Result<()> {
    let log = state_dir()?.join("mcp-autostart.log");
    let portable = paths::portable_data_dir()?;
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{MCP_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{}</string>
    <string>autostart</string>
    <string>prepare-mcp</string>
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
        xml_escape(&cli.to_string_lossy()),
        xml_escape(&portable.to_string_lossy()),
        xml_escape(&log.to_string_lossy()),
        xml_escape(&log.to_string_lossy()),
    );
    write_plist(MCP_LABEL, &plist)?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn platform_mcp_uninstall() -> Result<()> {
    let _ = launchctl_bootout(MCP_LABEL);
    let path = launch_agents_dir()?.join(format!("{MCP_LABEL}.plist"));
    if path.is_file() {
        fs::remove_file(&path).map_err(|_| anyhow!("client_autostart_clear_failed"))?;
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn systemd_unit(name: &str) -> Result<PathBuf> {
    let directory = user_home()?.join(".config/systemd/user");
    fs::create_dir_all(&directory).map_err(|_| anyhow!("client_autostart_install_failed"))?;
    Ok(directory.join(name))
}

#[cfg(target_os = "linux")]
fn platform_desktop_installed() -> Result<bool> {
    Ok(systemd_unit("lico-desktop.service")?.is_file())
}

#[cfg(target_os = "linux")]
fn platform_mcp_installed() -> Result<bool> {
    Ok(systemd_unit("lico-mcp-prepare.service")?.is_file())
}

#[cfg(target_os = "linux")]
fn systemctl_user(args: &[&str]) -> Result<()> {
    let status = Command::new("systemctl")
        .arg("--user")
        .args(args)
        .status()
        .map_err(|_| anyhow!("client_autostart_install_failed"))?;
    ensure!(status.success(), "client_autostart_install_failed");
    Ok(())
}

#[cfg(target_os = "linux")]
fn platform_desktop_install(app: &Path, silent: bool) -> Result<()> {
    let exec = if silent {
        format!(
            "/usr/bin/env {} --silent-start",
            app.join("lico-up").display()
        )
    } else {
        // Desktop Linux bundle exposes the Flutter binary; prefer `open`-like start via the app path.
        format!("{}", app.display())
    };
    let unit = format!(
        "[Unit]\nDescription=LicoUp Desktop\n\n[Service]\nType=simple\nExecStart={exec}\nRestart=no\n\n[Install]\nWantedBy=default.target\n"
    );
    atomic_write_private_text(&systemd_unit("lico-desktop.service")?, &unit)?;
    systemctl_user(&["daemon-reload"])?;
    systemctl_user(&["enable", "lico-desktop.service"])?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn platform_desktop_uninstall() -> Result<()> {
    let _ = Command::new("systemctl")
        .args(["--user", "disable", "--now", "lico-desktop.service"])
        .status();
    let path = systemd_unit("lico-desktop.service")?;
    if path.is_file() {
        fs::remove_file(&path).map_err(|_| anyhow!("client_autostart_clear_failed"))?;
    }
    let _ = Command::new("systemctl")
        .args(["--user", "daemon-reload"])
        .status();
    Ok(())
}

#[cfg(target_os = "linux")]
fn platform_mcp_install(cli: &Path) -> Result<()> {
    let portable = paths::portable_data_dir()?;
    let unit = format!(
        "[Unit]\nDescription=LicoUp MCP prepare\n\n[Service]\nType=oneshot\nEnvironment=LICOUP_PORTABLE_DIR={}\nExecStart={} autostart prepare-mcp\n\n[Install]\nWantedBy=default.target\n",
        portable.display(),
        cli.display(),
    );
    atomic_write_private_text(&systemd_unit("lico-mcp-prepare.service")?, &unit)?;
    systemctl_user(&["daemon-reload"])?;
    systemctl_user(&["enable", "lico-mcp-prepare.service"])?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn platform_mcp_uninstall() -> Result<()> {
    let _ = Command::new("systemctl")
        .args(["--user", "disable", "--now", "lico-mcp-prepare.service"])
        .status();
    let path = systemd_unit("lico-mcp-prepare.service")?;
    if path.is_file() {
        fs::remove_file(&path).map_err(|_| anyhow!("client_autostart_clear_failed"))?;
    }
    let _ = Command::new("systemctl")
        .args(["--user", "daemon-reload"])
        .status();
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_desktop_installed() -> Result<bool> {
    Ok(false)
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_mcp_installed() -> Result<bool> {
    Ok(false)
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_desktop_install(_app: &Path, _silent: bool) -> Result<()> {
    bail!("client_autostart_unsupported")
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_desktop_uninstall() -> Result<()> {
    bail!("client_autostart_unsupported")
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_mcp_install(_cli: &Path) -> Result<()> {
    bail!("client_autostart_unsupported")
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform_mcp_uninstall() -> Result<()> {
    bail!("client_autostart_unsupported")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_constant_is_stable() {
        assert_eq!(SCHEMA, "licoup.client-autostart.v1");
        assert_eq!(DESKTOP_LABEL, "land.lico.licoup.desktop");
        assert_eq!(MCP_LABEL, "land.lico.licoup.mcp-prepare");
    }
}
