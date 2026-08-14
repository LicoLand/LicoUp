//! Explicitly approved installation of the released LicoUp Codex Plugin.

use crate::{domain::integration_state::IntegrationState, platform::run_bounded_command_output};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

const PLUGIN_NAME: &str = "lico-up-codex";
const PLUGIN_VERSION: &str = "0.1.0";
const MARKETPLACE_NAME: &str = "licoup-plugins";
const MARKETPLACE_SOURCE: &str = "LicoLand/LicoUp-Plugins";
const MARKETPLACE_RELEASE: &str = "v0.1.0";
const MARKETPLACE_REF: &str = "4b456c8fbf06591ee8907c6f86952d2bb49638e4";
const INSTALL_TIMEOUT: Duration = Duration::from_secs(30);
const STATUS_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_COMMAND_OUTPUT_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexPluginInstallError {
    NotCodex,
    InvalidExecutable,
    ApprovalRequired,
    ApprovalMismatch,
    ApprovalConsumed,
    ProcessUnavailable,
    InstallFailed,
}

impl CodexPluginInstallError {
    pub const fn code(self) -> &'static str {
        match self {
            Self::NotCodex => "codex_plugin_not_applicable",
            Self::InvalidExecutable => "codex_executable_invalid",
            Self::ApprovalRequired => "codex_plugin_approval_required",
            Self::ApprovalMismatch => "codex_plugin_approval_mismatch",
            Self::ApprovalConsumed => "codex_plugin_approval_consumed",
            Self::ProcessUnavailable => "codex_plugin_process_unavailable",
            Self::InstallFailed => "codex_plugin_install_failed",
        }
    }
}

#[derive(Clone, Debug)]
pub struct CodexPluginInstallPlan {
    codex_executable: std::path::PathBuf,
    digest: String,
}

impl CodexPluginInstallPlan {
    pub fn prepare(
        main_agent_id: &str,
        codex_executable: &Path,
    ) -> Result<Self, CodexPluginInstallError> {
        if main_agent_id != "codex" {
            return Err(CodexPluginInstallError::NotCodex);
        }
        let codex_executable = canonical_executable(codex_executable)?;
        Ok(Self {
            codex_executable,
            digest: release_digest(),
        })
    }

    /// Safe value for a confirmation UI. Paths and asset contents remain local.
    pub fn digest(&self) -> &str {
        &self.digest
    }

    pub const fn source() -> &'static str {
        MARKETPLACE_SOURCE
    }

    pub const fn release() -> &'static str {
        MARKETPLACE_RELEASE
    }

    pub const fn version() -> &'static str {
        PLUGIN_VERSION
    }

    pub fn approve(
        &self,
        confirmed: bool,
        expected_digest: &str,
    ) -> Result<CodexPluginInstallPermit, CodexPluginInstallError> {
        if !confirmed {
            return Err(CodexPluginInstallError::ApprovalRequired);
        }
        if expected_digest != self.digest {
            return Err(CodexPluginInstallError::ApprovalMismatch);
        }
        Ok(CodexPluginInstallPermit {
            digest: self.digest.clone(),
            consumed: false,
        })
    }
}

#[derive(Debug)]
pub struct CodexPluginInstallPermit {
    digest: String,
    consumed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodexPluginInstallReceipt {
    pub installed: bool,
    pub plugin_ready_for_new_conversations: bool,
}

/// Probes only whether the exact managed plugin is ready. Raw plugin inventory,
/// local paths, and process output never cross this boundary.
pub fn status(codex_executable: &Path) -> IntegrationState {
    let Ok(codex_executable) = canonical_executable(codex_executable) else {
        return IntegrationState::Unavailable;
    };
    let mut command = Command::new(codex_executable);
    command.args(["plugin", "list", "--json"]);
    let Ok(result) =
        run_bounded_command_output(&mut command, STATUS_TIMEOUT, MAX_COMMAND_OUTPUT_BYTES)
    else {
        return IntegrationState::Unavailable;
    };
    if result.timed_out || result.truncated || !result.status.is_some_and(|status| status.success())
    {
        return IntegrationState::Unavailable;
    }
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&result.stdout) else {
        return IntegrationState::Unavailable;
    };
    plugin_state_from_list(&value)
}

fn plugin_state_from_list(value: &serde_json::Value) -> IntegrationState {
    let entries = match value {
        serde_json::Value::Array(entries) => Some(entries.as_slice()),
        serde_json::Value::Object(object) => object
            .get("installed")
            .or_else(|| object.get("plugins"))
            .or_else(|| object.get("installedPlugins"))
            .and_then(serde_json::Value::as_array)
            .map(Vec::as_slice),
        _ => None,
    };
    let Some(entries) = entries else {
        return IntegrationState::Unavailable;
    };
    for entry in entries {
        let Some(object) = entry.as_object() else {
            continue;
        };
        let selector = format!("{PLUGIN_NAME}@{MARKETPLACE_NAME}");
        let exact_selector = ["pluginId", "id", "selector", "plugin"]
            .iter()
            .filter_map(|key| object.get(*key).and_then(serde_json::Value::as_str))
            .any(|value| value == selector);
        let exact_name = object
            .get("name")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|value| value == PLUGIN_NAME);
        let exact_marketplace = object
            .get("marketplace")
            .or_else(|| object.get("marketplaceName"))
            .and_then(serde_json::Value::as_str)
            .is_none_or(|value| value == MARKETPLACE_NAME);
        if !exact_selector && !(exact_name && exact_marketplace) {
            continue;
        }
        let explicitly_disabled = object
            .get("enabled")
            .and_then(serde_json::Value::as_bool)
            .is_some_and(|enabled| !enabled)
            || object
                .get("installed")
                .and_then(serde_json::Value::as_bool)
                .is_some_and(|installed| !installed)
            || object
                .get("status")
                .and_then(serde_json::Value::as_str)
                .is_some_and(|status| matches!(status, "disabled" | "missing" | "uninstalled"));
        return if explicitly_disabled {
            IntegrationState::Missing
        } else {
            IntegrationState::Ready
        };
    }
    IntegrationState::Missing
}

pub fn install(
    plan: &CodexPluginInstallPlan,
    permit: &mut CodexPluginInstallPermit,
) -> Result<CodexPluginInstallReceipt, CodexPluginInstallError> {
    if permit.consumed {
        return Err(CodexPluginInstallError::ApprovalConsumed);
    }
    permit.consumed = true;
    if permit.digest != plan.digest {
        return Err(CodexPluginInstallError::ApprovalMismatch);
    }
    if release_digest() != plan.digest {
        return Err(CodexPluginInstallError::ApprovalMismatch);
    }

    // Registration is additive. A non-success may mean the exact Git source
    // is already configured; the authoritative result is the version-bound
    // plugin installation receipt below.
    let _ = run_codex(
        &plan.codex_executable,
        [
            "plugin",
            "marketplace",
            "add",
            MARKETPLACE_SOURCE,
            "--ref",
            MARKETPLACE_REF,
            "--json",
        ],
    );
    let selector = format!("{PLUGIN_NAME}@{MARKETPLACE_NAME}");
    let installed = run_codex_json(
        &plan.codex_executable,
        ["plugin", "add", selector.as_str(), "--json"],
    )?;
    if !plugin_install_receipt_matches(&installed) {
        return Err(CodexPluginInstallError::InstallFailed);
    }
    Ok(CodexPluginInstallReceipt {
        installed: true,
        plugin_ready_for_new_conversations: true,
    })
}

fn run_codex<'a>(
    executable: &Path,
    args: impl IntoIterator<Item = &'a str>,
) -> Result<bool, CodexPluginInstallError> {
    let mut command = Command::new(executable);
    command.args(args);
    let result =
        run_bounded_command_output(&mut command, INSTALL_TIMEOUT, MAX_COMMAND_OUTPUT_BYTES)
            .map_err(|_| CodexPluginInstallError::ProcessUnavailable)?;
    if result.timed_out || result.truncated {
        return Err(CodexPluginInstallError::InstallFailed);
    }
    Ok(result.status.is_some_and(|status| status.success()))
}

fn run_codex_json<'a>(
    executable: &Path,
    args: impl IntoIterator<Item = &'a str>,
) -> Result<serde_json::Value, CodexPluginInstallError> {
    let mut command = Command::new(executable);
    command.args(args);
    let result =
        run_bounded_command_output(&mut command, INSTALL_TIMEOUT, MAX_COMMAND_OUTPUT_BYTES)
            .map_err(|_| CodexPluginInstallError::ProcessUnavailable)?;
    if result.timed_out || result.truncated || !result.status.is_some_and(|status| status.success())
    {
        return Err(CodexPluginInstallError::InstallFailed);
    }
    serde_json::from_slice(&result.stdout).map_err(|_| CodexPluginInstallError::InstallFailed)
}

fn plugin_install_receipt_matches(receipt: &serde_json::Value) -> bool {
    let selector = format!("{PLUGIN_NAME}@{MARKETPLACE_NAME}");
    receipt.get("pluginId").and_then(serde_json::Value::as_str) == Some(selector.as_str())
        && receipt.get("name").and_then(serde_json::Value::as_str) == Some(PLUGIN_NAME)
        && receipt
            .get("marketplaceName")
            .and_then(serde_json::Value::as_str)
            == Some(MARKETPLACE_NAME)
        && receipt.get("version").and_then(serde_json::Value::as_str) == Some(PLUGIN_VERSION)
}

fn release_digest() -> String {
    let mut digest = Sha256::new();
    digest.update(b"licoup.codex-plugin-install.v2\0");
    for value in [
        PLUGIN_NAME,
        PLUGIN_VERSION,
        MARKETPLACE_NAME,
        MARKETPLACE_SOURCE,
        MARKETPLACE_RELEASE,
        MARKETPLACE_REF,
    ] {
        digest.update(value.as_bytes());
        digest.update([0]);
    }
    format!("{:x}", digest.finalize())
}

fn regular_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file())
}

fn canonical_executable(path: &Path) -> Result<PathBuf, CodexPluginInstallError> {
    if !path.is_absolute() {
        return Err(CodexPluginInstallError::InvalidExecutable);
    }
    let canonical =
        fs::canonicalize(path).map_err(|_| CodexPluginInstallError::InvalidExecutable)?;
    if !canonical.is_absolute() || !regular_file(&canonical) {
        return Err(CodexPluginInstallError::InvalidExecutable);
    }
    Ok(canonical)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        sync::atomic::{AtomicU64, Ordering},
    };

    static FIXTURE_NONCE: AtomicU64 = AtomicU64::new(0);

    fn fixture_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "licoup-codex-plugin-fixture-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            FIXTURE_NONCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn non_codex_selection_never_prepares_installation() {
        assert_eq!(
            CodexPluginInstallPlan::prepare("claude-code", Path::new("/synthetic/codex"),)
                .unwrap_err(),
            CodexPluginInstallError::NotCodex
        );
    }

    #[test]
    fn approval_is_digest_bound_and_single_use_by_construction() {
        let plan = CodexPluginInstallPlan {
            codex_executable: std::path::PathBuf::from("/synthetic/codex"),
            digest: "digest-a".into(),
        };
        assert_eq!(
            plan.approve(true, "digest-b").unwrap_err(),
            CodexPluginInstallError::ApprovalMismatch
        );
        let permit = plan.approve(true, "digest-a").unwrap();
        assert!(!permit.consumed);
    }

    #[test]
    fn error_codes_are_stable_and_do_not_contain_local_details() {
        for error in [
            CodexPluginInstallError::InvalidExecutable,
            CodexPluginInstallError::InstallFailed,
        ] {
            let code = error.code();
            assert!(code.starts_with("codex_"));
            assert!(!code.contains('/'));
            assert!(!code.contains('\\'));
        }
    }

    #[test]
    fn approval_digest_binds_the_exact_github_release_coordinates() {
        let root = fixture_root();
        let codex = root.join(if cfg!(windows) { "codex.exe" } else { "codex" });
        fs::write(&codex, b"codex").unwrap();
        let plan = CodexPluginInstallPlan::prepare("codex", &codex).unwrap();
        assert_eq!(plan.digest(), release_digest());
        assert_eq!(CodexPluginInstallPlan::source(), "LicoLand/LicoUp-Plugins");
        assert_eq!(CodexPluginInstallPlan::release(), "v0.1.0");
        assert_eq!(CodexPluginInstallPlan::version(), "0.1.0");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn plugin_status_accepts_only_the_exact_installed_plugin() {
        assert_eq!(
            plugin_state_from_list(&serde_json::json!({
                "installed": [{"pluginId": "lico-up-codex@licoup-plugins", "enabled": true}]
            })),
            IntegrationState::Ready
        );
        assert_eq!(
            plugin_state_from_list(&serde_json::json!({
                "plugins": [{"name": "lico-up-codex", "marketplace": "other"}]
            })),
            IntegrationState::Missing
        );
        assert_eq!(
            plugin_state_from_list(&serde_json::json!({
                "plugins": [{"name": "lico-up-codex", "marketplace": "licoup-plugins", "enabled": false}]
            })),
            IntegrationState::Missing
        );
    }

    #[test]
    fn malformed_plugin_inventory_is_unavailable_not_ready() {
        assert_eq!(
            plugin_state_from_list(&serde_json::json!({"catalog": []})),
            IntegrationState::Unavailable
        );
    }

    #[test]
    fn installation_receipt_must_match_the_digest_planned_version() {
        let receipt = serde_json::json!({
            "pluginId": "lico-up-codex@licoup-plugins",
            "name": "lico-up-codex",
            "marketplaceName": "licoup-plugins",
            "version": "0.1.0"
        });
        assert!(plugin_install_receipt_matches(&receipt));
        let mut stale = receipt;
        stale["version"] = serde_json::json!("0.0.9");
        assert!(!plugin_install_receipt_matches(&stale));
    }

    #[cfg(unix)]
    #[test]
    fn absolute_executable_symlink_is_resolved_before_it_is_bound() {
        use std::os::unix::fs::symlink;

        let root = fixture_root();
        let executable = root.join("codex-real");
        let link = root.join("codex");
        fs::write(&executable, b"codex").unwrap();
        symlink(&executable, &link).unwrap();
        assert_eq!(
            canonical_executable(&link).unwrap(),
            fs::canonicalize(executable).unwrap()
        );
        fs::remove_dir_all(root).unwrap();
    }
}
