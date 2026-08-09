//! Fixed native script templates executed by the OS-bundled interpreter.
//!
//! Values are passed strictly as positional argv (`$1..$n` in /bin/sh,
//! `$args[n]` in PowerShell) and are never interpolated into script text.
//! Every value is validated against a conservative printable-ASCII charset
//! that excludes shell metacharacters, and paths must be absolute with a
//! guarded replacement target.

use anyhow::{Result, ensure};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::domain::client_update) enum ScriptAction {
    Apply,
    Rollback,
}

pub(super) fn script_extension() -> &'static str {
    if cfg!(windows) { "ps1" } else { "sh" }
}

pub(super) fn apply_script(action: ScriptAction) -> &'static str {
    match (std::env::consts::OS, action) {
        ("macos", ScriptAction::Apply) => MACOS_APPLY_SH,
        ("macos", ScriptAction::Rollback) => MACOS_ROLLBACK_SH,
        ("linux", ScriptAction::Apply) => LINUX_APPLY_SH,
        ("linux", ScriptAction::Rollback) => LINUX_ROLLBACK_SH,
        ("windows", ScriptAction::Apply) => WINDOWS_APPLY_PS1,
        ("windows", ScriptAction::Rollback) => WINDOWS_ROLLBACK_PS1,
        _ => unreachable!("platform gating happens in the apply plan"),
    }
}

/// Validates every positional argv value that will reach a script.
pub(in crate::domain::client_update) fn validate_script_args(args: &[&str]) -> Result<()> {
    for (index, value) in args.iter().enumerate() {
        validate_arg(value, index)?;
    }
    Ok(())
}

/// Validates path argv values: printable safe charset plus absolute paths
/// (`/...`, `\\...` or a drive-letter prefix).
pub(in crate::domain::client_update) fn validate_script_paths(paths: &[&str]) -> Result<()> {
    for (index, value) in paths.iter().enumerate() {
        validate_arg(value, index)?;
        let absolute = value.starts_with('/')
            || value.starts_with("\\\\")
            || value.as_bytes().get(1) == Some(&b':');
        ensure!(
            absolute,
            "client update script path argument {index} must be absolute"
        );
    }
    Ok(())
}

fn validate_arg(value: &str, index: usize) -> Result<()> {
    ensure!(
        !value.is_empty() && value.len() <= 512,
        "client update script argument {index} is invalid"
    );
    ensure!(
        value.bytes().all(|byte| (0x20..=0x7e).contains(&byte)),
        "client update script argument {index} contains unsupported characters"
    );
    for forbidden in [
        '"', '\'', '$', '`', ';', '&', '|', '>', '<', '(', ')', '*', '?', '[', ']', '{', '}', '#',
        '~', '!',
    ] {
        ensure!(
            !value.contains(forbidden),
            "client update script argument {index} contains forbidden characters"
        );
    }
    Ok(())
}

pub(super) fn validate_bundle_id_arg(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 255
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_')),
        "client update bundleId is invalid"
    );
    Ok(())
}

/// macOS apply: quit via osascript (best effort), wait for the GUI to exit,
/// snapshot the current app, atomically replace it, re-register LaunchServices
/// and relaunch through LaunchServices. The signed archive nests the .app
/// inside the extraction root, so the staged app is `EXPANDED/APP_DIR`; the
/// relaunch is best effort because a failed `open` must not fail the update.
const MACOS_APPLY_SH: &str = r#"#!/bin/sh
set -eu
APP_DIR="$1"
INSTALL_ROOT="$2"
EXPANDED="$3"
SNAPSHOT="$4"
GUI_PID="$5"
BUNDLE_ID="$6"
TARGET="$INSTALL_ROOT/$APP_DIR"
STAGED_APP="$EXPANDED/$APP_DIR"
/usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
i=0
while /bin/kill -0 "$GUI_PID" 2>/dev/null; do
  i=$((i+1))
  if [ "$i" -gt 300 ]; then echo "client exit wait timed out" >&2; exit 3; fi
  /bin/sleep 1
done
if [ -d "$TARGET" ]; then /usr/bin/ditto "$TARGET" "$SNAPSHOT" >/dev/null 2>&1 || true; fi
/bin/rm -rf -- "$TARGET"
/usr/bin/ditto "$STAGED_APP" "$TARGET"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1 || true
/usr/bin/mdimport "$TARGET" >/dev/null 2>&1 || true
/usr/bin/open "$TARGET" >/dev/null 2>&1 || true
exit 0
"#;

/// macOS rollback: restore the snapshot and relaunch. The snapshot is a flat
/// copy of the target app (ditto creates the destination as a copy of the
/// source), so the restored app is the snapshot directory itself.
const MACOS_ROLLBACK_SH: &str = r#"#!/bin/sh
set -eu
APP_DIR="$1"
INSTALL_ROOT="$2"
SNAPSHOT="$3"
GUI_PID="$4"
BUNDLE_ID="$5"
TARGET="$INSTALL_ROOT/$APP_DIR"
/usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
i=0
while /bin/kill -0 "$GUI_PID" 2>/dev/null; do
  i=$((i+1))
  if [ "$i" -gt 300 ]; then echo "client exit wait timed out" >&2; exit 3; fi
  /bin/sleep 1
done
if [ -d "$TARGET" ]; then /bin/rm -rf -- "$TARGET"; fi
/usr/bin/ditto "$SNAPSHOT" "$TARGET"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1 || true
/usr/bin/mdimport "$TARGET" >/dev/null 2>&1 || true
/usr/bin/open "$TARGET" >/dev/null 2>&1 || true
exit 0
"#;

/// Linux apply: wait for the GUI to exit, snapshot, atomically replace the
/// bundle directory and relaunch detached. Only coreutils and /bin/sh
/// builtins are used; no tar/unzip/pkill/pgrep.
const LINUX_APPLY_SH: &str = r#"#!/bin/sh
set -eu
INSTALL_ROOT="$1"
EXPANDED="$2"
SNAPSHOT="$3"
GUI_PID="$4"
APP_NAME="licoup"
i=0
while /bin/kill -0 "$GUI_PID" 2>/dev/null; do
  i=$((i+1))
  if [ "$i" -gt 300 ]; then echo "client exit wait timed out" >&2; exit 3; fi
  /bin/sleep 1
done
if [ -d "$INSTALL_ROOT" ]; then /bin/cp -R "$INSTALL_ROOT" "$SNAPSHOT" >/dev/null 2>&1 || true; fi
/bin/rm -rf -- "$INSTALL_ROOT"
/bin/cp -R "$EXPANDED" "$INSTALL_ROOT"
/usr/bin/nohup "$INSTALL_ROOT/$APP_NAME" >/dev/null 2>&1 &
exit 0
"#;

/// Linux rollback: restore the snapshot and relaunch.
const LINUX_ROLLBACK_SH: &str = r#"#!/bin/sh
set -eu
INSTALL_ROOT="$1"
SNAPSHOT="$2"
GUI_PID="$3"
APP_NAME="licoup"
i=0
while /bin/kill -0 "$GUI_PID" 2>/dev/null; do
  i=$((i+1))
  if [ "$i" -gt 300 ]; then echo "client exit wait timed out" >&2; exit 3; fi
  /bin/sleep 1
done
if [ -d "$INSTALL_ROOT" ]; then /bin/rm -rf -- "$INSTALL_ROOT"; fi
/bin/cp -R "$SNAPSHOT" "$INSTALL_ROOT"
/usr/bin/nohup "$INSTALL_ROOT/$APP_NAME" >/dev/null 2>&1 &
exit 0
"#;

/// Windows apply: PowerShell cmdlets only; the Remove-Item retry loop covers
/// the window where the CLI process is still unlinking from inside the
/// install directory.
const WINDOWS_APPLY_PS1: &str = r#"$ErrorActionPreference = 'Stop'
$installRoot = $args[0]
$expanded = $args[1]
$snapshot = $args[2]
$guiPid = [int]$args[3]
$appName = 'licoup.exe'
$deadline = (Get-Date).AddMinutes(5)
while ($null -ne (Get-Process -Id $guiPid -ErrorAction SilentlyContinue)) {
  if ((Get-Date) -gt $deadline) { Write-Error 'client exit wait timed out'; exit 3 }
  Start-Sleep -Seconds 1
}
if (Test-Path -LiteralPath $installRoot) {
  Copy-Item -LiteralPath $installRoot -Destination $snapshot -Recurse -Force
}
for ($attempt = 0; $attempt -lt 10; $attempt++) {
  try { Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop; break }
  catch { Start-Sleep -Seconds 1 }
}
Copy-Item -LiteralPath $expanded -Destination $installRoot -Recurse -Force
Start-Process -FilePath (Join-Path $installRoot $appName) -WorkingDirectory $installRoot
"#;

/// Windows rollback: restore the snapshot and relaunch.
const WINDOWS_ROLLBACK_PS1: &str = r#"$ErrorActionPreference = 'Stop'
$installRoot = $args[0]
$snapshot = $args[1]
$guiPid = [int]$args[2]
$appName = 'licoup.exe'
$deadline = (Get-Date).AddMinutes(5)
while ($null -ne (Get-Process -Id $guiPid -ErrorAction SilentlyContinue)) {
  if ((Get-Date) -gt $deadline) { Write-Error 'client exit wait timed out'; exit 3 }
  Start-Sleep -Seconds 1
}
for ($attempt = 0; $attempt -lt 10; $attempt++) {
  try { Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop; break }
  catch { Start-Sleep -Seconds 1 }
}
Copy-Item -LiteralPath $snapshot -Destination $installRoot -Recurse -Force
Start-Process -FilePath (Join-Path $installRoot $appName) -WorkingDirectory $installRoot
"#;

/// Platform-independent template access for tests so the windows scripts can
/// be asserted from any build machine.
#[cfg(test)]
pub(in crate::domain::client_update) fn platform_script_for_test(
    platform: &str,
    action: ScriptAction,
) -> &'static str {
    match (platform, action) {
        ("macos", ScriptAction::Apply) => MACOS_APPLY_SH,
        ("macos", ScriptAction::Rollback) => MACOS_ROLLBACK_SH,
        ("linux", ScriptAction::Apply) => LINUX_APPLY_SH,
        ("linux", ScriptAction::Rollback) => LINUX_ROLLBACK_SH,
        ("windows", ScriptAction::Apply) => WINDOWS_APPLY_PS1,
        ("windows", ScriptAction::Rollback) => WINDOWS_ROLLBACK_PS1,
        _ => unreachable!("unknown platform in test"),
    }
}
