//! Digest-bound mutation of one namespaced, LicoUp-owned user MCP entry.

use super::{file_security, paths};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

pub(crate) const SERVER_KEY: &str = "land.lico.licoup.subagents";
const ENTRY_SCHEMA: &str = "licoup.subagent-mcp-registration.v2";
const MANAGED_BY: &str = "LicoUp";
const MAX_CONFIG_BYTES: u64 = 1024 * 1024;
const SKILL_SOURCE: &str = include_str!("../../resources/subagent-mesh/SKILL.md");

fn cursor_context_environment() -> Value {
    json!({
        "LICOUP_PORTABLE_DIR": "${env:LICOUP_PORTABLE_DIR}",
        "LICOUP_MCP_CONVERSATION_ID": "${env:LICOUP_MCP_CONVERSATION_ID}",
        "LICOUP_MCP_MEMBERSHIP_ID": "${env:LICOUP_MCP_MEMBERSHIP_ID}",
        "LICOUP_MCP_PARENT_DISPATCH_ID": "${env:LICOUP_MCP_PARENT_DISPATCH_ID}",
    })
}

/// Gemini/Antigravity expand `$VAR` / `${VAR}` in the MCP `env` block and
/// redact undeclared variables. An absent `env` leaves the thin connector
/// without a portable root, so it exits before `initialize` and the IDE
/// reports EOF. Cursor `${env:VAR}` must not be used here: Antigravity would
/// pass that spelling through as a literal path.
fn antigravity_context_environment() -> Value {
    json!({
        "LICOUP_PORTABLE_DIR": "${LICOUP_PORTABLE_DIR}",
        "LICOUP_MCP_CONVERSATION_ID": "${LICOUP_MCP_CONVERSATION_ID}",
        "LICOUP_MCP_MEMBERSHIP_ID": "${LICOUP_MCP_MEMBERSHIP_ID}",
        "LICOUP_MCP_PARENT_DISPATCH_ID": "${LICOUP_MCP_PARENT_DISPATCH_ID}",
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProviderConfigKind {
    Cursor,
    Antigravity,
}

impl ProviderConfigKind {
    pub const fn provider_id(self) -> &'static str {
        match self {
            Self::Cursor => "cursor",
            Self::Antigravity => "antigravity",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RegistrationError {
    InvalidConnector,
    ConfigUnavailable,
    ConfigAmbiguous,
    ConfigPathUnsupported,
    OwnedEntryAmbiguous,
    ApprovalRequired,
    ApprovalMismatch,
    ApprovalConsumed,
    ConfigChanged,
    WriteFailed,
}

#[derive(Clone, Debug)]
pub struct RegistrationPlan {
    kind: ProviderConfigKind,
    connector: PathBuf,
    config_path: PathBuf,
    config_digest: String,
    skill_path: PathBuf,
    skill_digest: String,
    skill_was_absent: bool,
    digest: String,
}

impl RegistrationPlan {
    pub fn prepare(kind: ProviderConfigKind, connector: &Path) -> Result<Self, RegistrationError> {
        let connector = canonical_connector(connector)?;
        let config_path = resolve_config_path(kind)?;
        Self::prepare_at(kind, connector, config_path)
    }

    /// Prepare against one explicitly discovered config path. The path must
    /// canonicalize to a reviewed candidate for this provider; the selected
    /// canonical path and the current config bytes are bound into the approval
    /// digest. Without this route the default both-present resolution stays
    /// fail-closed.
    pub fn prepare_with_config_path(
        kind: ProviderConfigKind,
        connector: &Path,
        config_path: &Path,
    ) -> Result<Self, RegistrationError> {
        let connector = canonical_connector(connector)?;
        let config_path = admit_explicit_config_path(kind, config_path)?;
        Self::prepare_at(kind, connector, config_path)
    }

    fn prepare_at(
        kind: ProviderConfigKind,
        connector: PathBuf,
        config_path: PathBuf,
    ) -> Result<Self, RegistrationError> {
        let skill_path = resolve_skill_path(kind)?;
        let raw = read_optional_config(&config_path)?;
        let config = parse_config(raw.as_deref())?;
        ensure_owned_entry_unambiguous(&config, kind)?;
        let config_digest = digest_bytes(raw.as_deref().unwrap_or(b"<absent>"));
        let skill = read_optional_skill(&skill_path)?;
        if skill
            .as_deref()
            .is_some_and(|current| current != SKILL_SOURCE.as_bytes())
        {
            return Err(RegistrationError::OwnedEntryAmbiguous);
        }
        let skill_digest = digest_bytes(skill.as_deref().unwrap_or(b"<absent>"));
        let digest = plan_digest(
            kind,
            &connector,
            &config_path,
            &config_digest,
            &skill_digest,
        )?;
        Ok(Self {
            kind,
            connector,
            config_path,
            config_digest,
            skill_path,
            skill_digest,
            skill_was_absent: skill.is_none(),
            digest,
        })
    }

    pub fn digest(&self) -> &str {
        &self.digest
    }

    pub fn approve(
        &self,
        confirmed: bool,
        digest: &str,
    ) -> Result<RegistrationPermit, RegistrationError> {
        if !confirmed {
            return Err(RegistrationError::ApprovalRequired);
        }
        if digest != self.digest {
            return Err(RegistrationError::ApprovalMismatch);
        }
        Ok(RegistrationPermit {
            digest: digest.to_owned(),
            consumed: false,
        })
    }
}

pub struct RegistrationPermit {
    digest: String,
    consumed: bool,
}

pub fn status(kind: ProviderConfigKind, connector: &Path) -> Result<bool, RegistrationError> {
    let connector = canonical_connector(connector)?;
    let path = resolve_config_path(kind)?;
    status_at(kind, &connector, &path)
}

/// Read-only readiness probe against one explicitly discovered config path,
/// admitted through the same reviewed-candidate rule as the mutating route.
pub fn status_with_config_path(
    kind: ProviderConfigKind,
    connector: &Path,
    config_path: &Path,
) -> Result<bool, RegistrationError> {
    let connector = canonical_connector(connector)?;
    let path = admit_explicit_config_path(kind, config_path)?;
    status_at(kind, &connector, &path)
}

fn status_at(
    kind: ProviderConfigKind,
    connector: &Path,
    path: &Path,
) -> Result<bool, RegistrationError> {
    let raw = read_optional_config(path)?;
    let config = parse_config(raw.as_deref())?;
    ensure_owned_entry_unambiguous(&config, kind)?;
    let skill_path = resolve_skill_path(kind)?;
    let skill_ready =
        read_optional_skill(&skill_path)?.is_some_and(|skill| skill == SKILL_SOURCE.as_bytes());
    Ok(skill_ready && entry(&config).is_some_and(|entry| entry_is_exact(entry, kind, connector)))
}

pub fn install(
    plan: &RegistrationPlan,
    permit: &mut RegistrationPermit,
) -> Result<(), RegistrationError> {
    claim(plan, permit)?;
    let raw = read_optional_config(&plan.config_path)?;
    if digest_bytes(raw.as_deref().unwrap_or(b"<absent>")) != plan.config_digest {
        return Err(RegistrationError::ConfigChanged);
    }
    if digest_bytes(
        read_optional_skill(&plan.skill_path)?
            .as_deref()
            .unwrap_or(b"<absent>"),
    ) != plan.skill_digest
    {
        return Err(RegistrationError::ConfigChanged);
    }
    let mut config = parse_config(raw.as_deref())?;
    ensure_owned_entry_unambiguous(&config, plan.kind)?;
    let mut owned_entry = json!({
        "command": plan.connector.to_string_lossy(),
        "args": ["--caller", plan.kind.provider_id()],
        "disabled": false,
        "managedBy": MANAGED_BY,
        "schemaVersion": ENTRY_SCHEMA,
        "provider": plan.kind.provider_id(),
    });
    owned_entry["env"] = match plan.kind {
        ProviderConfigKind::Cursor => cursor_context_environment(),
        ProviderConfigKind::Antigravity => antigravity_context_environment(),
    };
    servers_mut(&mut config)?.insert(SERVER_KEY.to_owned(), owned_entry);
    write_skill(&plan.skill_path)?;
    if let Err(error) = write_config(&plan.config_path, &config) {
        if plan.skill_was_absent {
            let _ = fs::remove_file(&plan.skill_path);
        }
        return Err(error);
    }
    if !entry(&config).is_some_and(|entry| entry_is_exact(entry, plan.kind, &plan.connector)) {
        return Err(RegistrationError::WriteFailed);
    }
    Ok(())
}

pub fn remove(
    plan: &RegistrationPlan,
    permit: &mut RegistrationPermit,
) -> Result<(), RegistrationError> {
    claim(plan, permit)?;
    let raw = read_optional_config(&plan.config_path)?;
    if digest_bytes(raw.as_deref().unwrap_or(b"<absent>")) != plan.config_digest {
        return Err(RegistrationError::ConfigChanged);
    }
    if digest_bytes(
        read_optional_skill(&plan.skill_path)?
            .as_deref()
            .unwrap_or(b"<absent>"),
    ) != plan.skill_digest
    {
        return Err(RegistrationError::ConfigChanged);
    }
    let mut config = parse_config(raw.as_deref())?;
    ensure_owned_entry_unambiguous(&config, plan.kind)?;
    if entry(&config).is_none() {
        return Ok(());
    }
    servers_mut(&mut config)?.remove(SERVER_KEY);
    write_config(&plan.config_path, &config)?;
    if read_optional_skill(&plan.skill_path)?.is_some_and(|skill| skill == SKILL_SOURCE.as_bytes())
    {
        fs::remove_file(&plan.skill_path).map_err(|_| RegistrationError::WriteFailed)?;
    }
    Ok(())
}

fn claim(
    plan: &RegistrationPlan,
    permit: &mut RegistrationPermit,
) -> Result<(), RegistrationError> {
    if permit.consumed {
        return Err(RegistrationError::ApprovalConsumed);
    }
    permit.consumed = true;
    if permit.digest != plan.digest
        || plan_digest(
            plan.kind,
            &plan.connector,
            &plan.config_path,
            &plan.config_digest,
            &plan.skill_digest,
        )? != plan.digest
    {
        return Err(RegistrationError::ApprovalMismatch);
    }
    Ok(())
}

/// Reviewed config candidates for one provider, in preference order. Every
/// approved mutation targets exactly one of these locations and nothing else.
fn reviewed_config_candidates(kind: ProviderConfigKind) -> Result<Vec<PathBuf>, RegistrationError> {
    let home = paths::user_home_from_env().ok_or(RegistrationError::ConfigUnavailable)?;
    Ok(match kind {
        ProviderConfigKind::Cursor => vec![home.join(".cursor").join("mcp.json")],
        ProviderConfigKind::Antigravity => vec![
            home.join(".gemini").join("config").join("mcp_config.json"),
            home.join(".gemini")
                .join("antigravity")
                .join("mcp_config.json"),
        ],
    })
}

/// Admit an explicitly discovered config path only when its canonical form is
/// exactly one reviewed candidate for the provider. The path must already
/// exist as a regular file: this route selects the active vendor location the
/// target scan observed; it never creates a new vendor config location.
fn admit_explicit_config_path(
    kind: ProviderConfigKind,
    explicit: &Path,
) -> Result<PathBuf, RegistrationError> {
    if !explicit.is_absolute() {
        return Err(RegistrationError::ConfigPathUnsupported);
    }
    let canonical =
        fs::canonicalize(explicit).map_err(|_| RegistrationError::ConfigPathUnsupported)?;
    let metadata =
        fs::symlink_metadata(&canonical).map_err(|_| RegistrationError::ConfigPathUnsupported)?;
    if !metadata.file_type().is_file() {
        return Err(RegistrationError::ConfigPathUnsupported);
    }
    let candidates = reviewed_config_candidates(kind)?;
    if path_matches_reviewed_candidate(&canonical, &candidates) {
        Ok(canonical)
    } else {
        Err(RegistrationError::ConfigPathUnsupported)
    }
}

fn path_matches_reviewed_candidate(canonical: &Path, candidates: &[PathBuf]) -> bool {
    candidates.iter().any(|candidate| {
        candidate == canonical
            || fs::canonicalize(candidate)
                .ok()
                .is_some_and(|resolved| resolved == canonical)
    })
}

fn resolve_skill_path(kind: ProviderConfigKind) -> Result<PathBuf, RegistrationError> {
    let home = paths::user_home_from_env().ok_or(RegistrationError::ConfigUnavailable)?;
    let root = match kind {
        ProviderConfigKind::Cursor => home.join(".cursor").join("skills"),
        ProviderConfigKind::Antigravity => home.join(".gemini").join("config").join("skills"),
    };
    Ok(root.join("lico-up-subagents").join("SKILL.md"))
}

fn resolve_config_path(kind: ProviderConfigKind) -> Result<PathBuf, RegistrationError> {
    let candidates = reviewed_config_candidates(kind)?;
    match kind {
        ProviderConfigKind::Cursor => Ok(candidates[0].clone()),
        ProviderConfigKind::Antigravity => {
            let official = &candidates[0];
            let legacy = &candidates[1];
            if official.exists() && legacy.exists() {
                return Err(RegistrationError::ConfigAmbiguous);
            }
            if legacy.exists() {
                Ok(legacy.clone())
            } else {
                Ok(official.clone())
            }
        }
    }
}

fn canonical_connector(path: &Path) -> Result<PathBuf, RegistrationError> {
    if !path.is_absolute() {
        return Err(RegistrationError::InvalidConnector);
    }
    let path = fs::canonicalize(path).map_err(|_| RegistrationError::InvalidConnector)?;
    let metadata = fs::symlink_metadata(&path).map_err(|_| RegistrationError::InvalidConnector)?;
    if !metadata.file_type().is_file() {
        return Err(RegistrationError::InvalidConnector);
    }
    Ok(path)
}

fn read_optional_config(path: &Path) -> Result<Option<Vec<u8>>, RegistrationError> {
    if !path.exists() {
        return Ok(None);
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| RegistrationError::ConfigUnavailable)?;
    if !metadata.file_type().is_file() || metadata.len() > MAX_CONFIG_BYTES {
        return Err(RegistrationError::ConfigUnavailable);
    }
    // A zero-byte vendor file is an absent config, not a corrupt one: the
    // approval digest binds the same "<absent>" marker and the install writes
    // a fresh object. Non-empty invalid JSON stays fail-closed in parse_config.
    let raw = fs::read(path).map_err(|_| RegistrationError::ConfigUnavailable)?;
    if raw.is_empty() {
        return Ok(None);
    }
    Ok(Some(raw))
}

fn read_optional_skill(path: &Path) -> Result<Option<Vec<u8>>, RegistrationError> {
    read_optional_config(path)
}

fn parse_config(raw: Option<&[u8]>) -> Result<Value, RegistrationError> {
    let mut config = match raw {
        Some(raw) => {
            serde_json::from_slice(raw).map_err(|_| RegistrationError::ConfigUnavailable)?
        }
        None => json!({"mcpServers": {}}),
    };
    let object = config
        .as_object_mut()
        .ok_or(RegistrationError::ConfigUnavailable)?;
    match object.get("mcpServers") {
        None => {
            object.insert("mcpServers".to_owned(), json!({}));
        }
        Some(Value::Object(_)) => {}
        Some(_) => return Err(RegistrationError::ConfigUnavailable),
    }
    Ok(config)
}

fn servers_mut(config: &mut Value) -> Result<&mut Map<String, Value>, RegistrationError> {
    config
        .get_mut("mcpServers")
        .and_then(Value::as_object_mut)
        .ok_or(RegistrationError::ConfigUnavailable)
}

fn entry(config: &Value) -> Option<&Map<String, Value>> {
    config
        .get("mcpServers")?
        .as_object()?
        .get(SERVER_KEY)?
        .as_object()
}

fn ensure_owned_entry_unambiguous(
    config: &Value,
    kind: ProviderConfigKind,
) -> Result<(), RegistrationError> {
    let Some(entry) = entry(config) else {
        return Ok(());
    };
    let owned = entry.get("managedBy").and_then(Value::as_str) == Some(MANAGED_BY)
        && entry.get("schemaVersion").and_then(Value::as_str) == Some(ENTRY_SCHEMA)
        && entry.get("provider").and_then(Value::as_str) == Some(kind.provider_id());
    if owned {
        Ok(())
    } else {
        Err(RegistrationError::OwnedEntryAmbiguous)
    }
}

fn entry_is_exact(entry: &Map<String, Value>, kind: ProviderConfigKind, connector: &Path) -> bool {
    let args_exact = entry
        .get("args")
        .and_then(Value::as_array)
        .is_some_and(|args| args.as_slice() == [json!("--caller"), json!(kind.provider_id())]);
    let environment_exact = match kind {
        ProviderConfigKind::Cursor => entry.get("env") == Some(&cursor_context_environment()),
        ProviderConfigKind::Antigravity => {
            entry.get("env") == Some(&antigravity_context_environment())
        }
    };
    if entry.get("managedBy").and_then(Value::as_str) != Some(MANAGED_BY)
        || entry.get("schemaVersion").and_then(Value::as_str) != Some(ENTRY_SCHEMA)
        || entry.get("provider").and_then(Value::as_str) != Some(kind.provider_id())
        || entry.get("disabled").and_then(Value::as_bool) != Some(false)
        || !args_exact
        || !environment_exact
    {
        return false;
    }
    entry
        .get("command")
        .and_then(Value::as_str)
        .map(Path::new)
        .and_then(|path| fs::canonicalize(path).ok())
        .is_some_and(|path| path == connector)
}

fn write_config(path: &Path, config: &Value) -> Result<(), RegistrationError> {
    let parent = path.parent().ok_or(RegistrationError::WriteFailed)?;
    file_security::ensure_private_dir(parent).map_err(|_| RegistrationError::WriteFailed)?;
    if path.exists() {
        file_security::harden_private_path(path).map_err(|_| RegistrationError::WriteFailed)?;
    }
    let text = serde_json::to_string_pretty(config).map_err(|_| RegistrationError::WriteFailed)?;
    file_security::atomic_write_private_text_bounded(path, &text, MAX_CONFIG_BYTES as usize)
        .map_err(|_| RegistrationError::WriteFailed)
}

fn write_skill(path: &Path) -> Result<(), RegistrationError> {
    let parent = path.parent().ok_or(RegistrationError::WriteFailed)?;
    file_security::ensure_private_dir(parent).map_err(|_| RegistrationError::WriteFailed)?;
    if path.exists() {
        file_security::harden_private_path(path).map_err(|_| RegistrationError::WriteFailed)?;
    }
    file_security::atomic_write_private_text_bounded(path, SKILL_SOURCE, 64 * 1024)
        .map_err(|_| RegistrationError::WriteFailed)
}

fn plan_digest(
    kind: ProviderConfigKind,
    connector: &Path,
    config_path: &Path,
    config_digest: &str,
    skill_digest: &str,
) -> Result<String, RegistrationError> {
    let binary = fs::read(connector).map_err(|_| RegistrationError::InvalidConnector)?;
    let mut digest = Sha256::new();
    for value in [
        ENTRY_SCHEMA.as_bytes(),
        kind.provider_id().as_bytes(),
        SERVER_KEY.as_bytes(),
        config_path.to_string_lossy().as_bytes(),
        config_digest.as_bytes(),
        skill_digest.as_bytes(),
        SKILL_SOURCE.as_bytes(),
        &binary,
    ] {
        digest.update(value);
        digest.update([0]);
    }
    Ok(format!("sha256:{:x}", digest.finalize()))
}

fn digest_bytes(value: &[u8]) -> String {
    format!("sha256:{:x}", Sha256::digest(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foreign_namespaced_entry_fails_closed() {
        let config = json!({"mcpServers": {
            SERVER_KEY: {"command": "foreign"}
        }});
        assert_eq!(
            ensure_owned_entry_unambiguous(&config, ProviderConfigKind::Cursor),
            Err(RegistrationError::OwnedEntryAmbiguous)
        );
    }

    #[test]
    fn exact_owned_entry_is_recognized_without_touching_siblings() {
        let root =
            std::env::temp_dir().join(format!("licoup-provider-mcp-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let connector = root.join("lico-subagent-mcp");
        fs::write(&connector, b"synthetic connector").unwrap();
        let connector = fs::canonicalize(connector).unwrap();
        let config = json!({"mcpServers": {
            "other": {"command": "other"},
            SERVER_KEY: {
                "command": connector.to_string_lossy(),
                "args": ["--caller", "cursor"],
                "env": {
                    "LICOUP_PORTABLE_DIR": "${env:LICOUP_PORTABLE_DIR}",
                    "LICOUP_MCP_CONVERSATION_ID": "${env:LICOUP_MCP_CONVERSATION_ID}",
                    "LICOUP_MCP_MEMBERSHIP_ID": "${env:LICOUP_MCP_MEMBERSHIP_ID}",
                    "LICOUP_MCP_PARENT_DISPATCH_ID": "${env:LICOUP_MCP_PARENT_DISPATCH_ID}"
                },
                "disabled": false,
                "managedBy": MANAGED_BY,
                "schemaVersion": ENTRY_SCHEMA,
                "provider": "cursor"
            }
        }});
        assert!(entry(&config).is_some_and(|entry| {
            entry_is_exact(entry, ProviderConfigKind::Cursor, &connector)
        }));
        assert!(config["mcpServers"].get("other").is_some());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn antigravity_owned_entry_requires_gemini_env_interpolation() {
        let root =
            std::env::temp_dir().join(format!("licoup-provider-agy-env-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let connector = root.join("lico-subagent-mcp");
        fs::write(&connector, b"synthetic connector").unwrap();
        let connector = fs::canonicalize(connector).unwrap();
        let mut entry = json!({
            "command": connector.to_string_lossy(),
            "args": ["--caller", "antigravity"],
            "disabled": false,
            "managedBy": MANAGED_BY,
            "schemaVersion": ENTRY_SCHEMA,
            "provider": "antigravity"
        })
        .as_object()
        .cloned()
        .unwrap();
        assert!(!entry_is_exact(
            &entry,
            ProviderConfigKind::Antigravity,
            &connector
        ));
        entry.insert("env".to_owned(), cursor_context_environment());
        assert!(!entry_is_exact(
            &entry,
            ProviderConfigKind::Antigravity,
            &connector
        ));
        entry.insert("env".to_owned(), antigravity_context_environment());
        assert!(entry_is_exact(
            &entry,
            ProviderConfigKind::Antigravity,
            &connector
        ));
        assert_eq!(
            antigravity_context_environment()["LICOUP_PORTABLE_DIR"],
            "${LICOUP_PORTABLE_DIR}"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn approval_is_single_use_and_bound_to_unchanged_config_bytes() {
        let root =
            std::env::temp_dir().join(format!("licoup-provider-approval-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let connector = root.join("lico-subagent-mcp");
        fs::write(&connector, b"synthetic connector").unwrap();
        let config_path = root.join("mcp.json");
        let config_digest = digest_bytes(b"<absent>");
        let skill_path = root.join("skills/lico-up-subagents/SKILL.md");
        let skill_digest = digest_bytes(b"<absent>");
        let digest = plan_digest(
            ProviderConfigKind::Cursor,
            &connector,
            &config_path,
            &config_digest,
            &skill_digest,
        )
        .unwrap();
        let plan = RegistrationPlan {
            kind: ProviderConfigKind::Cursor,
            connector,
            config_path: config_path.clone(),
            config_digest,
            skill_path,
            skill_digest,
            skill_was_absent: true,
            digest,
        };
        let mut permit = plan.approve(true, plan.digest()).unwrap();
        fs::write(&config_path, b"{\"mcpServers\":{}}").unwrap();
        assert_eq!(
            install(&plan, &mut permit),
            Err(RegistrationError::ConfigChanged)
        );
        assert_eq!(
            install(&plan, &mut permit),
            Err(RegistrationError::ApprovalConsumed)
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn one_approval_delivers_owned_entry_and_skill_without_touching_sibling() {
        let root =
            std::env::temp_dir().join(format!("licoup-provider-delivery-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let connector = root.join("lico-subagent-mcp");
        fs::write(&connector, b"synthetic connector").unwrap();
        let connector = fs::canonicalize(connector).unwrap();
        let config_path = root.join("mcp.json");
        let config_source = br#"{"mcpServers":{"other":{"command":"other"}}}"#;
        fs::write(&config_path, config_source).unwrap();
        let config_digest = digest_bytes(config_source);
        let skill_path = root.join("skills/lico-up-subagents/SKILL.md");
        let skill_digest = digest_bytes(b"<absent>");
        let digest = plan_digest(
            ProviderConfigKind::Cursor,
            &connector,
            &config_path,
            &config_digest,
            &skill_digest,
        )
        .unwrap();
        let plan = RegistrationPlan {
            kind: ProviderConfigKind::Cursor,
            connector,
            config_path: config_path.clone(),
            config_digest,
            skill_path: skill_path.clone(),
            skill_digest,
            skill_was_absent: true,
            digest,
        };
        let mut permit = plan.approve(true, plan.digest()).unwrap();
        install(&plan, &mut permit).unwrap();
        let config: Value = serde_json::from_slice(&fs::read(config_path).unwrap()).unwrap();
        assert!(config["mcpServers"].get("other").is_some());
        assert!(config["mcpServers"].get(SERVER_KEY).is_some());
        assert_eq!(
            config["mcpServers"][SERVER_KEY]["env"],
            cursor_context_environment()
        );
        assert_eq!(fs::read_to_string(skill_path).unwrap(), SKILL_SOURCE);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn explicit_config_path_must_canonicalize_to_a_reviewed_candidate() {
        let root =
            std::env::temp_dir().join(format!("licoup-provider-explicit-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let connector = root.join("lico-subagent-mcp");
        fs::write(&connector, b"synthetic connector").unwrap();
        let home = paths::user_home_from_env().unwrap();
        let foreign = root.join("foreign.json");
        fs::write(&foreign, b"{\"mcpServers\":{}}").unwrap();
        assert_eq!(
            RegistrationPlan::prepare_with_config_path(
                ProviderConfigKind::Antigravity,
                &connector,
                &foreign,
            )
            .unwrap_err(),
            RegistrationError::ConfigPathUnsupported
        );
        let relative = Path::new("mcp_config.json");
        assert_eq!(
            RegistrationPlan::prepare_with_config_path(
                ProviderConfigKind::Antigravity,
                &connector,
                relative,
            )
            .unwrap_err(),
            RegistrationError::ConfigPathUnsupported
        );
        let missing = home
            .join(".gemini")
            .join("config")
            .join("definitely-absent-mcp_config.json");
        assert_eq!(
            RegistrationPlan::prepare_with_config_path(
                ProviderConfigKind::Antigravity,
                &connector,
                &missing,
            )
            .unwrap_err(),
            RegistrationError::ConfigPathUnsupported
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn explicit_antigravity_candidates_both_admitted_with_path_bound_digest() {
        let home = paths::user_home_from_env().unwrap();
        let official = home.join(".gemini").join("config").join("mcp_config.json");
        let legacy = home
            .join(".gemini")
            .join("antigravity")
            .join("mcp_config.json");
        if !official.exists() || !legacy.exists() {
            // The both-present environment is exercised by the installed
            // contract run; without it this unit stays a pure admission check.
            return;
        }
        let root =
            std::env::temp_dir().join(format!("licoup-provider-agy-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let connector = root.join("lico-subagent-mcp");
        fs::write(&connector, b"synthetic connector").unwrap();
        let connector = fs::canonicalize(connector).unwrap();
        // Default resolution stays fail-closed while both candidates exist.
        assert_eq!(
            RegistrationPlan::prepare(ProviderConfigKind::Antigravity, &connector).unwrap_err(),
            RegistrationError::ConfigAmbiguous
        );
        let official_plan = RegistrationPlan::prepare_with_config_path(
            ProviderConfigKind::Antigravity,
            &connector,
            &official,
        )
        .unwrap();
        let legacy_plan = RegistrationPlan::prepare_with_config_path(
            ProviderConfigKind::Antigravity,
            &connector,
            &legacy,
        )
        .unwrap();
        assert_ne!(official_plan.digest(), legacy_plan.digest());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn reviewed_candidate_matching_is_exact_and_canonical() {
        let root =
            std::env::temp_dir().join(format!("licoup-provider-match-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let candidate = root.join("mcp_config.json");
        fs::write(&candidate, b"{}").unwrap();
        let canonical = fs::canonicalize(&candidate).unwrap();
        let candidates = vec![candidate.clone()];
        assert!(path_matches_reviewed_candidate(&canonical, &candidates));
        assert!(path_matches_reviewed_candidate(&candidate, &candidates));
        let sibling = root.join("other.json");
        fs::write(&sibling, b"{}").unwrap();
        let sibling = fs::canonicalize(sibling).unwrap();
        assert!(!path_matches_reviewed_candidate(&sibling, &candidates));
        let _ = fs::remove_dir_all(root);
    }
}
