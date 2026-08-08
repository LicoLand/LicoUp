use std::{path::Path, process::Command};

use anyhow::{Result, ensure};

pub(super) fn quit_running_client(bundle_id: &str, skip: bool) -> Result<()> {
    if skip {
        return Ok(());
    }
    let script = format!(
        "if application id \"{bundle_id}\" is running then tell application id \"{bundle_id}\" to quit"
    );
    let status = Command::new("osascript").args(["-e", &script]).status()?;
    ensure!(
        status.success(),
        "client update failed to quit the running application"
    );
    Ok(())
}

pub(super) fn register_application(app_path: &Path) {
    let lsregister = Path::new(
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    );
    if lsregister.exists() {
        let _ = Command::new(lsregister)
            .args(["-f", &app_path.to_string_lossy()])
            .status();
    }
    let _ = Command::new("mdimport").arg(app_path).status();
}

pub(super) fn launch_application(app_path: &Path) -> Result<()> {
    let status = Command::new("/usr/bin/open").arg(app_path).status()?;
    ensure!(
        status.success(),
        "client update failed to restart the application"
    );
    Ok(())
}
