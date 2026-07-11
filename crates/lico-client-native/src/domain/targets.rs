use crate::domain::mcp_trust;
use crate::platform::client_state::ClientStateStore;
use crate::platform::file_security::atomic_write_private_text;
use crate::platform::runtime_adapters;
use anyhow::{Result, anyhow};
use directories::UserDirs;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
struct TargetDef {
    id: &'static str,
    label: &'static str,
    kind: &'static str,
    config_hint: &'static str,
    binary_names: &'static [&'static str],
    process_names: &'static [&'static str],
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdapterCapabilities {
    pub detection: String,
    pub config_read: String,
    pub config_plan: String,
    pub config_apply: String,
    pub rollback: String,
    pub official_cli: String,
    pub conversation_driver: String,
    pub conversation_protocol: String,
    pub conversation_readiness: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation_blocker: Option<String>,
    pub conversation_probe: Value,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub conversation_capability_matrix: Value,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub conversation_summary_codes: Vec<String>,
    #[serde(default, skip_serializing_if = "is_zero_usize")]
    pub conversation_consecutive_passes: usize,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub conversation_evidence_age: String,
}

fn is_zero_usize(value: &usize) -> bool {
    *value == 0
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetCandidate {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub target: String,
    pub label: String,
    pub kind: String,
    pub status: String,
    pub configured: bool,
    pub confidence: f64,
    pub detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binary_path: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub history_roots: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub remote_history_roots: Vec<String>,
    pub manual: bool,
    pub adapter_status: String,
    pub adapter_capabilities: AdapterCapabilities,
    pub supported_actions: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scan_source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub environment: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub option_overrides: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_catalog: Option<Value>,
}

#[derive(Clone, Debug)]
struct ModelCatalogEntry {
    name: String,
    display_name: String,
    provider: Option<String>,
    provider_id: Option<String>,
    provider_inferred: bool,
    sources: BTreeSet<String>,
    reasoning_efforts: BTreeSet<String>,
}

#[derive(Clone, Debug)]
struct ManualTarget {
    target: String,
    label: String,
    kind: String,
    config_path: Option<PathBuf>,
    binary_path: Option<PathBuf>,
    history_roots: Vec<PathBuf>,
}

#[derive(Debug)]
struct ScanContext {
    running_processes: Option<BTreeSet<String>>,
    running_processes_injected: bool,
}

impl ScanContext {
    fn from_params(params: &Value) -> Self {
        if let Some(running_processes) = running_process_names_from_params(params) {
            return Self {
                running_processes: Some(running_processes),
                running_processes_injected: true,
            };
        }
        Self {
            running_processes: None,
            running_processes_injected: false,
        }
    }

    fn running_processes(&mut self) -> &BTreeSet<String> {
        self.running_processes
            .get_or_insert_with(current_running_process_names)
    }
}

fn adapter_supports_action(target: &str, action: &str) -> bool {
    let caps = adapter_capabilities_for(target);
    match action {
        "mcp.config.plan" => caps.config_plan == "implemented" || caps.config_plan == "partial",
        "mcp.config.apply" | "mcp.plugin.update" => caps.config_apply == "implemented",
        "mcp.config.rollback" | "mcp.plugin.rollback" => caps.rollback == "implemented",
        "mcp.plugin.status" => true,
        "skill.install" => target_supports_skill_install(target),
        // Runtime sending is candidate-bound. A target id without the exact
        // accepted executable fingerprint must never advertise it.
        "runtime.message.send" => false,
        _ => false,
    }
}

fn target_supports_skill_install(target: &str) -> bool {
    matches!(target, "codex" | "claude-code")
}

fn candidate_runtime_is_ready(
    capabilities: &mut AdapterCapabilities,
    target: &str,
    executable: Option<&Path>,
) -> bool {
    let Some(profile) = runtime_adapters::runtime_driver_profile(target) else {
        return false;
    };
    if profile.readiness != "ready" {
        return false;
    }
    if executable.is_some_and(|path| runtime_adapters::runtime_evidence_matches(target, path)) {
        capabilities.conversation_readiness = "ready".to_string();
        capabilities.conversation_blocker = None;
        return true;
    }
    capabilities.conversation_readiness = "unverified".to_string();
    capabilities.conversation_blocker = Some("runtime_evidence_binding_mismatch".to_string());
    false
}

fn adapter_capabilities_for(target: &str) -> AdapterCapabilities {
    let apply_targets: &[&str] = &["openclaw", "antigravity", "opencode", "cursor"];
    let plan_only_targets: &[&str] = &[
        "codex",
        "kilo-code",
        "claude-code",
        "copilot",
        "hermes",
        "kimi",
        "kimi-code",
    ];

    let mut capabilities = if apply_targets.contains(&target) {
        AdapterCapabilities {
            detection: "implemented".to_string(),
            config_read: "implemented".to_string(),
            config_plan: "implemented".to_string(),
            config_apply: "implemented".to_string(),
            rollback: "implemented".to_string(),
            official_cli: "unknown".to_string(),
            conversation_driver: "unsupported".to_string(),
            conversation_protocol: String::new(),
            conversation_readiness: "history-only".to_string(),
            conversation_blocker: None,
            conversation_probe: json!({}),
            conversation_capability_matrix: Value::Null,
            conversation_summary_codes: Vec::new(),
            conversation_consecutive_passes: 0,
            conversation_evidence_age: String::new(),
        }
    } else if plan_only_targets.contains(&target) {
        AdapterCapabilities {
            detection: "implemented".to_string(),
            config_read: "partial".to_string(),
            config_plan: "partial".to_string(),
            config_apply: "unsupported".to_string(),
            rollback: "unsupported".to_string(),
            official_cli: "unknown".to_string(),
            conversation_driver: "unsupported".to_string(),
            conversation_protocol: String::new(),
            conversation_readiness: "history-only".to_string(),
            conversation_blocker: None,
            conversation_probe: json!({}),
            conversation_capability_matrix: Value::Null,
            conversation_summary_codes: Vec::new(),
            conversation_consecutive_passes: 0,
            conversation_evidence_age: String::new(),
        }
    } else {
        AdapterCapabilities {
            detection: "implemented".to_string(),
            config_read: "unsupported".to_string(),
            config_plan: "unsupported".to_string(),
            config_apply: "unsupported".to_string(),
            rollback: "unsupported".to_string(),
            official_cli: "unknown".to_string(),
            conversation_driver: "unsupported".to_string(),
            conversation_protocol: String::new(),
            conversation_readiness: "history-only".to_string(),
            conversation_blocker: None,
            conversation_probe: json!({}),
            conversation_capability_matrix: Value::Null,
            conversation_summary_codes: Vec::new(),
            conversation_consecutive_passes: 0,
            conversation_evidence_age: String::new(),
        }
    };
    if let Some(profile) = runtime_adapters::runtime_driver_profile(target) {
        capabilities.conversation_driver = profile.driver_status;
        capabilities.conversation_protocol = profile.protocol;
        capabilities.conversation_readiness = profile.readiness;
        capabilities.conversation_blocker = profile.blocker;
        capabilities.conversation_capability_matrix =
            profile.capability_matrix.unwrap_or(Value::Null);
        capabilities.conversation_summary_codes = profile.summary_codes;
        capabilities.conversation_consecutive_passes = profile.consecutive_passes;
        capabilities.conversation_evidence_age = profile.evidence_age_class;
    }
    capabilities
}

fn target_defs() -> Vec<TargetDef> {
    vec![
        TargetDef {
            id: "openclaw",
            label: "OpenClaw - CLI",
            kind: "vm-cli",
            config_hint: "OpenClaw VM MCP configuration",
            binary_names: &["openclaw"],
            process_names: &["openclaw.exe", "openclaw"],
        },
        TargetDef {
            id: "claude-code",
            label: "Claude Code - CLI",
            kind: "cli",
            config_hint: "Claude Code MCP CLI configuration",
            binary_names: &["claude"],
            process_names: &["claude.exe", "claude"],
        },
        TargetDef {
            id: "codex",
            label: "ChatGPT Codex - CLI",
            kind: "cli",
            config_hint: "Codex MCP configuration",
            binary_names: &["codex"],
            process_names: &["codex.exe", "codex"],
        },
        TargetDef {
            id: "code",
            label: "Visual Studio Code - IDE",
            kind: "desktop-agent",
            config_hint: "VS Code workspace and global storage",
            binary_names: &["code", "code-insiders"],
            process_names: &["code.exe", "code", "code-insiders.exe", "code-insiders"],
        },
        TargetDef {
            id: "antigravity",
            label: "Antigravity - CLI",
            kind: "cli",
            config_hint: "Antigravity MCP configuration",
            binary_names: &["agy", "antigravity"],
            process_names: &["agy.exe", "agy", "antigravity.exe", "antigravity"],
        },
        TargetDef {
            id: "opencode",
            label: "OpenCode - CLI",
            kind: "cli",
            config_hint: "OpenCode remote MCP configuration",
            binary_names: &["opencode"],
            process_names: &["opencode.exe", "opencode"],
        },
        TargetDef {
            id: "copilot",
            label: "GitHub Copilot - CLI",
            kind: "cli",
            config_hint: "Copilot MCP CLI configuration",
            binary_names: &["copilot"],
            process_names: &["copilot.exe", "copilot"],
        },
        TargetDef {
            id: "kilo-code",
            label: "Kilo Code - CLI",
            kind: "cli",
            config_hint: "Kilo Code MCP configuration",
            binary_names: &["kilo", "kilocode"],
            process_names: &[
                "kilo.exe",
                "kilo",
                "kilo code.exe",
                "kilo code",
                "kilocode.exe",
                "kilocode",
            ],
        },
        TargetDef {
            id: "cursor",
            label: "Cursor - IDE",
            kind: "desktop-agent",
            config_hint: "Cursor MCP configuration and desktop history",
            binary_names: &["cursor-agent", "cursor"],
            process_names: &["cursor-agent.exe", "cursor-agent", "cursor.exe", "cursor"],
        },
        TargetDef {
            id: "hermes",
            label: "Hermes Agent - CLI",
            kind: "vm-cli",
            config_hint: "Hermes Agent MCP configuration",
            binary_names: &["hermes"],
            process_names: &["hermes.exe", "hermes"],
        },
        TargetDef {
            id: "kimi",
            label: "Kimi - Desktop",
            kind: "desktop-agent",
            config_hint: "Kimi desktop application data",
            binary_names: &[],
            process_names: &["Kimi", "kimi", "Kimi.exe", "kimi.exe", "com.moonshot.kimi"],
        },
        TargetDef {
            id: "kimi-code",
            label: "Kimi Code - CLI",
            kind: "cli",
            config_hint: "Kimi Code CLI configuration and sessions",
            binary_names: &["kimi"],
            process_names: &["kimi.exe", "kimi", "kimi-code.exe", "kimi-code"],
        },
    ]
}

pub fn scan_targets() -> Result<Value> {
    scan_targets_with_params(&json!({}))
}

pub fn scan_targets_with_params(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let manual_targets = manual_targets(&store)?;
    let mut scan_context = ScanContext::from_params(params);
    let mut candidates = Vec::<TargetCandidate>::new();
    for def in target_defs() {
        let manual = manual_targets.iter().find(|item| item.target == def.id);
        candidates.push(scan_target_with_manual(
            &def,
            manual,
            &mut scan_context,
            params,
        )?);
    }
    let mut scan_scopes = vec!["host-adapter-defaults".to_string()];
    let mut diagnostics = Vec::<Value>::new();
    if param_bool(params, "includeAccessibleEnvironments").unwrap_or(true) {
        match installer_scan_candidates(params) {
            Ok(mut external_candidates) => {
                if !external_candidates.is_empty() {
                    scan_scopes.push("installer-accessible-environments".to_string());
                    merge_installer_candidates(&mut candidates, external_candidates.drain(..));
                }
            }
            Err(error) => diagnostics.push(json!({
                "stage": "targets.scan",
                "scope": "installer-accessible-environments",
                "status": "failed",
                "message": error.to_string()
            })),
        }
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": 1,
        "source": "target-adapters",
        "scanScopes": scan_scopes,
        "diagnostics": diagnostics,
        "candidates": candidates,
    }))
}

/// Resolve the single local executable that is both advertised by target
/// discovery and bound to the canonical CL-06 evidence. Callers must still
/// revalidate immediately before launch; this prevents a remote command from
/// choosing a PATH entry or supplying a local execution path.
pub(crate) fn ready_runtime_executable(target: &str) -> Option<PathBuf> {
    if !runtime_adapters::runtime_driver_profile(target)
        .is_some_and(|profile| profile.readiness == "ready")
    {
        return None;
    }
    let scan = scan_targets_with_params(&json!({})).ok()?;
    let candidates = scan.get("candidates")?.as_array()?;
    let mut matched = BTreeSet::<PathBuf>::new();
    for candidate in candidates {
        if candidate.get("target").and_then(Value::as_str) != Some(target)
            || candidate.get("location").and_then(Value::as_str) != Some("local")
            || candidate.get("status").and_then(Value::as_str) == Some("not-detected")
            || !candidate
                .get("supportedActions")
                .and_then(Value::as_array)
                .is_some_and(|actions| {
                    actions
                        .iter()
                        .any(|action| action.as_str() == Some("runtime.message.send"))
                })
        {
            continue;
        }
        let Some(binary_path) = candidate
            .get("binaryPath")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
        else {
            continue;
        };
        if !binary_path.is_absolute() {
            continue;
        }
        let Some(canonical) = fs::canonicalize(binary_path).ok() else {
            continue;
        };
        matched.insert(canonical);
    }
    if matched.len() != 1 {
        return None;
    }
    let executable = matched.into_iter().next()?;
    runtime_adapters::runtime_evidence_matches(target, &executable).then_some(executable)
}

pub fn add_target(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let def = target_def(&target)?;
    let store = client_state_store(params)?;
    let saved = upsert_manual_target(&store, &def, params)?;
    let activity = store.activity_log().append(
        "target.manual.saved",
        json!({
            "target": def.id,
            "configPath": saved.get("configPath").cloned().unwrap_or_else(|| json!("")),
            "binaryPath": saved.get("binaryPath").cloned().unwrap_or_else(|| json!(""))
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": "accepted",
        "target": def.id,
        "label": def.label,
        "manual": true,
        "record": saved,
        "activity": activity,
        "nextAction": "mcp.config.plan",
    }))
}

pub fn inspect_target(target: &str) -> Result<Value> {
    inspect_target_with_params(&json!({ "target": target }))
}

pub fn inspect_target_with_params(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let def = target_def(&target)?;
    let store = client_state_store(params)?;
    let manual_targets = manual_targets(&store)?;
    let manual = manual_targets.iter().find(|item| item.target == def.id);
    let mut scan_context = ScanContext::from_params(params);
    let candidate = scan_target_with_manual(&def, manual, &mut scan_context, params)?;
    Ok(json!({
        "ok": true,
        "target": candidate,
        "fields": target_fields(def.id),
        "writePolicy": {
            "snapshotRequired": true,
            "structuredPatchRequired": true,
            "atomicWriteRequired": true,
            "preserveUnrelatedConfig": true
        }
    }))
}

pub fn mcp_config_plan(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let def = target_def(&target)?;
    let config_path = resolve_config_path(&def, params).ok();

    let verification = mcp_trust::resolve_and_verify_endpoint(params)?;
    let caps = adapter_capabilities_for(def.id);
    let adapter_supports_apply = adapter_supports_action(def.id, "mcp.config.apply");

    let endpoint_verified = verification.status == mcp_trust::VerificationStatus::Verified;
    let has_config_path = config_path.is_some();
    let apply_allowed = endpoint_verified && adapter_supports_apply && has_config_path;

    let apply_blocked_reason = if !adapter_supports_apply {
        "adapter_unsupported"
    } else if !endpoint_verified {
        "verification_required"
    } else if !has_config_path {
        "missing_config_path"
    } else {
        "none"
    };

    let required_action = if adapter_supports_apply {
        if !endpoint_verified {
            "verify_endpoint"
        } else {
            "none"
        }
    } else if caps.config_plan == "partial" {
        "manual_config"
    } else {
        "unsupported_adapter"
    };

    let base_url = verification.endpoint;
    let token_ref = token_ref(params);

    let format_loss_risk = config_path
        .as_ref()
        .map(|p| config_has_jsonc_comments(p))
        .unwrap_or(false);

    Ok(json!({
        "ok": true,
        "status": "planned",
        "target": def.id,
        "label": def.label,
        "endpointSource": verification.source,
        "verificationStatus": verification.status.as_str(),
        "adapterCapabilities": caps,
        "adapterApplyStatus": caps.config_apply,
        "applyAllowed": apply_allowed,
        "applyBlockedReason": apply_blocked_reason,
        "formatLossRisk": format_loss_risk,
        "requiredAction": required_action,
        "plan": {
            "operation": "mcp.config.apply",
            "configPath": config_path.map(display_path),
            "baseUrl": base_url.clone(),
            "tokenRef": token_ref.clone(),
            "fields": target_fields_with_values(def.id, &base_url, &token_ref),
            "requiresSnapshot": true,
            "requiresStructuredPatch": true,
            "requiresAtomicWrite": true,
            "rollbackCommand": "lico-client mcp config rollback --target <target> --snapshot-id <snapshotId>"
        }
    }))
}

pub fn mcp_config_apply(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let def = target_def(&target)?;

    if !adapter_supports_action(def.id, "mcp.config.apply") {
        return Ok(json!({
            "ok": false,
            "status": "unsupported_adapter_action",
            "target": target,
            "action": "mcp.config.apply",
            "message": format!("Target '{}' does not support mcp.config.apply", target)
        }));
    }

    let config_path = match resolve_config_path(&def, params) {
        Ok(path) => path,
        Err(err) => {
            let msg = err.to_string();
            if msg.contains("missing_config_path") {
                let label = msg
                    .strip_prefix("missing_config_path: ")
                    .unwrap_or("target");
                return Ok(json!({
                    "ok": false,
                    "status": "missing_config_path",
                    "target": target,
                    "message": format!("{} requires --config-path for config writes", label)
                }));
            }
            return Err(err);
        }
    };

    let verification = mcp_trust::resolve_and_verify_endpoint(params)?;
    let status = verification.status;
    if status != mcp_trust::VerificationStatus::Verified {
        return Ok(json!({
            "ok": false,
            "status": status.as_str(),
            "target": target,
            "endpoint": verification.endpoint,
            "message": "MCP endpoint must be verified before applying target config."
        }));
    }

    let base_url = verification.endpoint;
    let token_ref = token_ref(params);
    let current = fs::read_to_string(&config_path).unwrap_or_default();
    let before_hash = hash_text(&current);

    if let Some(expected_hash) = params.get("expectedHash").and_then(Value::as_str) {
        if expected_hash != before_hash {
            return Ok(json!({
                "ok": false,
                "status": "field_conflict",
                "target": def.id,
                "configPath": display_path(config_path.clone()),
                "expectedHash": expected_hash,
                "actualHash": before_hash,
                "message": "Target config changed after plan; refusing to overwrite without a new plan."
            }));
        }
    }

    let explicit_format_rewrite = params
        .get("explicitFormatRewrite")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if config_has_jsonc_comments(&config_path) && !explicit_format_rewrite {
        return Ok(json!({
            "ok": false,
            "status": "format_loss_confirmation_required",
            "target": def.id,
            "configPath": display_path(config_path.clone()),
            "message": "Target config contains comments that would be lost. Set explicitFormatRewrite: true to proceed."
        }));
    }

    let fields = target_fields_with_values(def.id, &base_url, &token_ref);
    let new_content = match apply_structured_patch(def.id, &current, &base_url, &token_ref) {
        Ok(content) => content,
        Err(err) => {
            let msg = err.to_string();
            if msg.contains("field_conflict") {
                return Ok(build_field_conflict_error(
                    def.id,
                    &config_path,
                    &msg,
                    &current,
                ));
            }
            return Err(err);
        }
    };
    let store = client_state_store(params)?;
    let snapshot = store.snapshot_store().capture(
        def.id,
        &config_path,
        json!({
            "operation": "mcp.config.apply",
            "configPath": display_path(config_path.clone()),
            "beforeHash": before_hash.clone(),
            "fields": fields.clone()
        }),
    )?;
    atomic_write(&config_path, &new_content)?;
    let after_hash = hash_text(&new_content);
    let format_loss_risk = config_has_jsonc_comments(&config_path);
    let activity = store.activity_log().append(
        "mcp.config.applied",
        json!({
            "target": def.id,
            "configPath": display_path(config_path.clone()),
            "snapshotId": snapshot.snapshot_id.clone(),
            "snapshotPath": display_path(snapshot.snapshot_path.clone()),
            "beforeHash": before_hash.clone(),
            "afterHash": after_hash.clone()
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": "applied",
        "target": def.id,
        "configPath": display_path(config_path),
        "snapshotId": snapshot.snapshot_id,
        "snapshotPath": display_path(snapshot.snapshot_path),
        "beforeHash": before_hash,
        "afterHash": after_hash,
        "formatLossRisk": format_loss_risk,
        "activity": activity,
        "patch": {
            "type": "structured",
            "fields": fields
        }
    }))
}

pub fn mcp_config_rollback(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let def = target_def(&target)?;
    let store = client_state_store(params)?;
    let Some(snapshot_path) = params.get("snapshotPath").and_then(Value::as_str) else {
        let snapshot_id = snapshot_id_from_params(params)?;
        let restore = store.snapshot_store().restore(&snapshot_id)?;
        let activity = store.activity_log().append(
            "mcp.config.rolled_back",
            json!({
                "target": def.id,
                "snapshotId": snapshot_id.clone(),
                "snapshotPath": restore.get("snapshotPath").cloned().unwrap_or_else(|| json!("")),
                "configPath": restore.get("sourcePath").cloned().unwrap_or_else(|| json!(""))
            }),
        )?;
        return Ok(json!({
            "ok": true,
            "status": "rolled_back",
            "target": def.id,
            "configPath": restore.get("sourcePath").cloned().unwrap_or_else(|| json!("")),
            "restoredSnapshotId": snapshot_id,
            "restoredSnapshotPath": restore.get("snapshotPath").cloned().unwrap_or_else(|| json!("")),
            "preRollbackSnapshotId": restore.get("preRestoreSnapshotId").cloned().unwrap_or_else(|| json!("")),
            "preRollbackSnapshotPath": restore.get("preRestoreSnapshotPath").cloned().unwrap_or_else(|| json!("")),
            "redactionApplied": restore.get("redactionApplied").cloned().unwrap_or_else(|| json!(false)),
            "activity": activity
        }));
    };
    let snapshot_path = PathBuf::from(snapshot_path);
    let raw = fs::read_to_string(&snapshot_path)?;
    let snapshot: Value = serde_json::from_str(&raw)?;
    let config_path = snapshot
        .get("sourcePath")
        .or_else(|| snapshot.get("configPath"))
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("Snapshot is missing sourcePath"))?;
    let existed = snapshot
        .get("existed")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let original_content = snapshot
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let redaction_applied = snapshot
        .get("redaction")
        .and_then(|item| item.get("applied"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let rollback_snapshot = store.snapshot_store().capture(
        def.id,
        &config_path,
        json!({
            "operation": "mcp.config.rollback",
            "restoringSnapshotPath": display_path(snapshot_path.clone())
        }),
    )?;
    if existed {
        atomic_write(&config_path, original_content)?;
    } else if config_path.exists() {
        fs::remove_file(&config_path)?;
    }
    let snapshot_id = snapshot
        .get("snapshotId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let activity = store.activity_log().append(
        "mcp.config.rolled_back",
        json!({
            "target": def.id,
            "configPath": display_path(config_path.clone()),
            "snapshotId": snapshot_id.clone(),
            "snapshotPath": display_path(snapshot_path.clone()),
            "preRollbackSnapshotId": rollback_snapshot.snapshot_id.clone(),
            "preRollbackSnapshotPath": display_path(rollback_snapshot.snapshot_path.clone())
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": "rolled_back",
        "target": def.id,
        "configPath": display_path(config_path),
        "restoredSnapshotId": snapshot_id,
        "restoredSnapshotPath": display_path(snapshot_path),
        "preRollbackSnapshotId": rollback_snapshot.snapshot_id,
        "preRollbackSnapshotPath": display_path(rollback_snapshot.snapshot_path),
        "redactionApplied": redaction_applied,
        "activity": activity
    }))
}

fn scan_target_with_manual(
    def: &TargetDef,
    manual: Option<&ManualTarget>,
    scan_context: &mut ScanContext,
    params: &Value,
) -> Result<TargetCandidate> {
    let config_path = manual
        .and_then(|item| item.config_path.clone())
        .or_else(|| default_config_path_with_params(def.id, params));
    let manual_binary = manual.and_then(|item| item.binary_path.clone());
    let binary_path = manual_binary
        .filter(|path| def.id != "cursor" || cursor_binary_supports_acp(path, params))
        .or_else(|| find_target_binary(def, params));
    let detection_path = default_detection_path_with_params(def.id, params);
    let history_roots = manual
        .map(|item| item.history_roots.clone())
        .unwrap_or_default();
    let configured = config_path
        .as_ref()
        .map(|path| config_has_lico(path))
        .unwrap_or(false);
    let config_exists = config_path
        .as_ref()
        .map(|path| path.exists())
        .unwrap_or(false);
    let detection_exists = detection_path
        .as_ref()
        .map(|path| path.exists())
        .unwrap_or(false);
    let detected_without_process = config_exists || binary_path.is_some() || detection_exists;
    let should_check_process = scan_context.running_processes_injected
        || (!detected_without_process && target_uses_running_process_detection(def.id));
    let running_process = if should_check_process {
        running_process_for(def, scan_context)
    } else {
        None
    };
    let detected =
        config_exists || binary_path.is_some() || detection_exists || running_process.is_some();
    let manual_entry = manual.is_some();
    let status = if configured {
        "configured"
    } else if detected {
        "detected"
    } else if manual_entry {
        "manual"
    } else {
        "not-detected"
    };
    let confidence = if configured {
        1.0
    } else if detected {
        0.72
    } else {
        0.15
    };
    let mut detail_parts = Vec::<String>::new();
    detail_parts.push(match (&config_path, &binary_path) {
        (Some(config), Some(binary)) => {
            format!(
                "{}: {}; binary: {}",
                def.config_hint,
                config.display(),
                binary.display()
            )
        }
        (Some(config), None) => format!("{}: {}", def.config_hint, config.display()),
        (None, Some(binary)) => format!("binary: {}", binary.display()),
        (None, None) => def.config_hint.to_string(),
    });
    if let Some(path) = detection_path
        .as_ref()
        .filter(|path| config_path.as_ref() != Some(path))
    {
        detail_parts.push(format!("evidence: {}", path.display()));
    }
    if let Some(process) = running_process {
        detail_parts.push(format!("process: {} running", process));
    }
    let base_detail = detail_parts.join("; ");
    let detail = if manual_entry {
        format!("Manual entry: {}", base_detail)
    } else {
        base_detail
    };
    let mut capabilities = adapter_capabilities_for(def.id);
    if let Some(binary) = binary_path.as_deref()
        && param_bool(params, "probeConversationRuntime") == Some(true)
    {
        let probe_cwd = param_string(params, "workingDirectory")
            .or_else(|| param_string(params, "cwd"))
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .or_else(|| env::current_dir().ok());
        if let Some(probe_cwd) = probe_cwd.as_deref() {
            capabilities.conversation_probe =
                runtime_adapters::probe_runtime_driver(def.id, binary, probe_cwd);
        }
    } else if binary_path.is_some() {
        capabilities.conversation_probe = json!({
            "available": true,
            "supported": false,
            "errorCode": "probe_not_run"
        });
    } else {
        capabilities.conversation_probe = json!({
            "available": false,
            "supported": false,
            "errorCode": "runtime_not_detected"
        });
    }

    let runtime_send_ready =
        candidate_runtime_is_ready(&mut capabilities, def.id, binary_path.as_deref());
    let adapter_status = if capabilities.config_apply == "implemented" {
        "implemented"
    } else if capabilities.config_apply == "partial" || capabilities.config_read == "partial" {
        "partial"
    } else {
        "unsupported"
    };
    let model_catalog = if detected || manual_entry {
        model_catalog_for_target(def.id, config_path.as_deref(), None, None, params)
    } else {
        empty_model_catalog("unavailable", "not-detected")
    };

    let mut supported_actions = Vec::new();
    supported_actions.push("mcp.plugin.status".to_string());
    if capabilities.config_plan == "implemented" || capabilities.config_plan == "partial" {
        supported_actions.push("mcp.config.plan".to_string());
    }
    if capabilities.config_apply == "implemented" {
        supported_actions.push("mcp.config.apply".to_string());
        supported_actions.push("mcp.plugin.update".to_string());
    }
    if capabilities.rollback == "implemented" {
        supported_actions.push("mcp.config.rollback".to_string());
        supported_actions.push("mcp.plugin.rollback".to_string());
    }
    if target_supports_skill_install(def.id) {
        supported_actions.push("skill.install".to_string());
    }
    if runtime_send_ready {
        supported_actions.push("runtime.message.send".to_string());
    }

    Ok(TargetCandidate {
        id: Some(def.id.to_string()),
        target: def.id.to_string(),
        label: manual
            .map(|item| item.label.clone())
            .unwrap_or_else(|| def.label.to_string()),
        kind: manual
            .map(|item| item.kind.clone())
            .unwrap_or_else(|| def.kind.to_string()),
        status: status.to_string(),
        configured,
        confidence,
        detail,
        config_path: config_path.map(display_path),
        binary_path: binary_path.map(display_path),
        history_roots: history_roots.into_iter().map(display_path).collect(),
        remote_history_roots: Vec::new(),
        manual: manual_entry,
        adapter_status: adapter_status.to_string(),
        adapter_capabilities: capabilities,
        supported_actions,
        scan_source: Some("host-adapter-defaults".to_string()),
        location: Some("local".to_string()),
        environment: None,
        option_overrides: None,
        model_catalog: Some(model_catalog),
    })
}

fn merge_installer_candidates(
    candidates: &mut Vec<TargetCandidate>,
    installer_candidates: impl Iterator<Item = TargetCandidate>,
) {
    for candidate in installer_candidates {
        if candidate.location.as_deref() == Some("local") {
            if let Some(existing) = candidates.iter_mut().find(|item| {
                item.target == candidate.target && item.location.as_deref() == Some("local")
            }) {
                merge_local_installer_candidate(existing, candidate);
                continue;
            }
        }
        candidates.push(candidate);
    }
}

fn merge_local_installer_candidate(existing: &mut TargetCandidate, installer: TargetCandidate) {
    let installer_detected = matches!(installer.status.as_str(), "configured" | "detected");
    if !existing.configured && !existing.manual && installer_detected {
        existing.status = installer.status;
        existing.confidence = existing.confidence.max(installer.confidence);
    }
    if existing.binary_path.is_none() {
        existing.binary_path = installer.binary_path;
    }
    if let Some(detail) = installer.detail.as_str().strip_prefix("Manual entry: ") {
        existing.detail = format!("{}; installer scan: {}", existing.detail, detail);
    } else if !installer.detail.trim().is_empty() {
        existing.detail = format!("{}; installer scan: {}", existing.detail, installer.detail);
    }
    existing.scan_source =
        Some("host-adapter-defaults+installer-accessible-environments".to_string());
    existing.option_overrides = installer.option_overrides;
    if let Some(model_catalog) = installer.model_catalog {
        existing.model_catalog = Some(merge_model_catalog_values(
            existing.model_catalog.take(),
            Some(model_catalog),
        ));
    }
    existing
        .supported_actions
        .retain(|action| action != "runtime.message.send");
    let runtime_target = existing.target.clone();
    let runtime_binary = existing.binary_path.clone();
    if candidate_runtime_is_ready(
        &mut existing.adapter_capabilities,
        &runtime_target,
        runtime_binary.as_deref().map(Path::new),
    ) {
        existing
            .supported_actions
            .push("runtime.message.send".to_string());
    }
}

fn installer_scan_candidates(params: &Value) -> Result<Vec<TargetCandidate>> {
    let Some(command) = installer_scan_command(params) else {
        return Ok(Vec::new());
    };
    let output = run_installer_scan_command(&command).map_err(|error| {
        anyhow!(
            "unable to run installer target scan via {}: {}",
            command.display(),
            error
        )
    })?;
    if !output.status.success() {
        return Err(anyhow!(
            "installer target scan failed via {}: {}",
            command.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let stdout = String::from_utf8(output.stdout)
        .map_err(|error| anyhow!("installer target scan returned non-UTF8 output: {}", error))?;
    let payload: Value = serde_json::from_str(&stdout)
        .map_err(|error| anyhow!("installer target scan returned invalid JSON: {}", error))?;
    let mut candidates = Vec::<TargetCandidate>::new();
    let mut seen = std::collections::BTreeSet::<String>::new();
    for item in payload
        .get("candidates")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
    {
        let Some(candidate) = installer_candidate_from_value(item, params) else {
            continue;
        };
        let key = candidate
            .id
            .clone()
            .unwrap_or_else(|| format!("{}:{}", candidate.target, candidate.detail));
        if seen.insert(key) {
            candidates.push(candidate);
        }
    }
    Ok(candidates)
}

fn run_installer_scan_command(
    command: &InstallerScanCommand,
) -> std::io::Result<std::process::Output> {
    let extension = Path::new(&command.program)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if matches!(extension.as_str(), "mjs" | "js") {
        return Command::new("node")
            .arg(&command.program)
            .args(&command.args)
            .output();
    }
    #[cfg(windows)]
    {
        if matches!(extension.as_str(), "cmd" | "bat") {
            return Command::new("cmd.exe")
                .args(["/d", "/s", "/c"])
                .arg(windows_cmd_call(command))
                .output();
        }
        if extension == "ps1" {
            return Command::new("powershell.exe")
                .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
                .arg(&command.program)
                .args(&command.args)
                .output();
        }
    }
    Command::new(&command.program).args(&command.args).output()
}

#[cfg(windows)]
fn windows_cmd_call(command: &InstallerScanCommand) -> String {
    std::iter::once("call".to_string())
        .chain(std::iter::once(windows_quote_cmd_arg(&command.program)))
        .chain(command.args.iter().map(|arg| windows_quote_cmd_arg(arg)))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(windows)]
fn windows_quote_cmd_arg(value: &str) -> String {
    if value.is_empty() {
        return "\"\"".to_string();
    }
    if !value
        .chars()
        .any(|ch| ch.is_whitespace() || matches!(ch, '"' | '&' | '(' | ')' | '^' | '|' | '<' | '>'))
    {
        return value.to_string();
    }
    format!("\"{}\"", value.replace('"', "\"\""))
}

#[derive(Clone, Debug)]
struct InstallerScanCommand {
    program: String,
    args: Vec<String>,
}

impl InstallerScanCommand {
    fn display(&self) -> String {
        std::iter::once(self.program.as_str())
            .chain(self.args.iter().map(String::as_str))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

fn installer_scan_command(params: &Value) -> Option<InstallerScanCommand> {
    if let Some(program) = param_string(params, "installerScanCommand")
        .or_else(|| env::var("LICO_MCP_SCAN_COMMAND").ok())
        .or_else(|| env::var("LICO_MCP_BIN").ok())
    {
        let mut args = installer_scan_args(params);
        if args.is_empty() {
            args = vec!["scan".to_string(), "--json".to_string()];
        }
        return Some(InstallerScanCommand { program, args });
    }

    #[cfg(not(test))]
    {
        if let Some(path) = find_binary(&["lico-mcp"]) {
            return Some(InstallerScanCommand {
                program: display_path(path),
                args: vec!["scan".to_string(), "--json".to_string()],
            });
        }
    }

    #[cfg(not(test))]
    {
        let source_script = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("apps")
            .join("mcp-gateway-installer")
            .join("bin")
            .join("lico-mcp.mjs");
        if source_script.is_file() {
            return Some(InstallerScanCommand {
                program: display_path(source_script),
                args: vec!["scan".to_string(), "--json".to_string()],
            });
        }
    }

    None
}

fn installer_scan_args(params: &Value) -> Vec<String> {
    match params.get("installerScanArgs") {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .collect(),
        Some(Value::String(value)) => value
            .split_whitespace()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .collect(),
        _ => Vec::new(),
    }
}

fn installer_candidate_from_value(item: Value, params: &Value) -> Option<TargetCandidate> {
    let target = item
        .get("target")
        .and_then(Value::as_str)
        .map(normalize_target)
        .filter(|value| target_def(value).is_ok())?;
    let location = installer_candidate_location(&item);
    let def = target_def(&target).ok()?;
    let status = item
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("detected")
        .to_string();
    let detected = status == "configured" || status == "detected";
    let configured = item
        .get("installed")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let option_overrides = item.get("optionOverrides").cloned();
    let binary_path = installer_candidate_binary_path(def.id, option_overrides.as_ref());
    let mut capabilities = adapter_capabilities_for(def.id);
    let runtime_send_ready = if location == "local" {
        candidate_runtime_is_ready(
            &mut capabilities,
            def.id,
            binary_path.as_deref().map(Path::new),
        )
    } else {
        if capabilities.conversation_readiness == "ready" {
            capabilities.conversation_readiness = "unverified".to_string();
            capabilities.conversation_blocker =
                Some("remote_runtime_transport_unavailable".to_string());
        }
        false
    };
    let adapter_status = if capabilities.config_apply == "implemented" {
        "implemented"
    } else if capabilities.config_apply == "partial" || capabilities.config_read == "partial" {
        "partial"
    } else {
        "unsupported"
    };
    let mut supported_actions = vec!["mcp.plugin.status".to_string()];
    if capabilities.config_plan == "implemented" || capabilities.config_plan == "partial" {
        supported_actions.push("mcp.config.plan".to_string());
    }
    if capabilities.config_apply == "implemented" {
        supported_actions.push("mcp.config.apply".to_string());
        supported_actions.push("mcp.plugin.update".to_string());
    }
    if capabilities.rollback == "implemented" {
        supported_actions.push("mcp.config.rollback".to_string());
        supported_actions.push("mcp.plugin.rollback".to_string());
    }
    if target_supports_skill_install(def.id) {
        supported_actions.push("skill.install".to_string());
    }
    if runtime_send_ready {
        supported_actions.push("runtime.message.send".to_string());
    }
    let environment = installer_candidate_environment(&location, option_overrides.as_ref());
    let remote_history_roots = remote_history_roots_for(def.id, option_overrides.as_ref());
    let model_catalog = model_catalog_for_target(
        def.id,
        None,
        option_overrides.as_ref(),
        environment.as_ref(),
        params,
    );
    Some(TargetCandidate {
        id: item
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string)
            .or_else(|| Some(format!("{}:{}", target, location))),
        target,
        label: item
            .get("label")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(def.label)
            .to_string(),
        kind: format!("{}-agent", location),
        status,
        configured,
        confidence: if configured {
            1.0
        } else if detected {
            0.82
        } else {
            0.2
        },
        detail: item
            .get("detail")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| format!("{} detected in {}", def.label, location)),
        config_path: None,
        binary_path,
        history_roots: Vec::new(),
        remote_history_roots,
        manual: false,
        adapter_status: adapter_status.to_string(),
        adapter_capabilities: capabilities,
        supported_actions,
        scan_source: Some("installer-accessible-environments".to_string()),
        location: Some(location),
        environment,
        option_overrides,
        model_catalog: Some(model_catalog),
    })
}

fn installer_candidate_location(item: &Value) -> String {
    item.pointer("/optionOverrides/execution-location")
        .or_else(|| item.pointer("/optionOverrides/remote-kind"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("local")
        .to_string()
}

fn installer_candidate_environment(location: &str, overrides: Option<&Value>) -> Option<Value> {
    let object = overrides.and_then(Value::as_object)?;
    let id = object
        .get("remote-id")
        .or_else(|| object.get("orb-vm"))
        .or_else(|| object.get("openclaw-vm"))
        .or_else(|| object.get("hermes-vm"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let name = object
        .get("remote-name")
        .or_else(|| object.get("orb-vm"))
        .or_else(|| object.get("openclaw-vm"))
        .or_else(|| object.get("hermes-vm"))
        .and_then(Value::as_str)
        .unwrap_or(id);
    if id.is_empty() && name.is_empty() {
        return Some(json!({ "kind": location }));
    }
    Some(json!({
        "kind": location,
        "id": id,
        "name": name,
        "user": object
            .get("orb-user")
            .or_else(|| object.get("openclaw-user"))
            .or_else(|| object.get("hermes-user"))
            .cloned()
            .unwrap_or_else(|| json!(""))
    }))
}

fn installer_candidate_binary_path(target: &str, overrides: Option<&Value>) -> Option<String> {
    let key = match target {
        "codex" => "codex-bin",
        "claude-code" => "claude-bin",
        "kilo-code" => "kilo-bin",
        "copilot" => "copilot-bin",
        "opencode" => "opencode-bin",
        "openclaw" => "openclaw-bin",
        "hermes" => "hermes-bin",
        "kimi-code" => "kimi-bin",
        _ => return None,
    };
    overrides
        .and_then(|value| value.get(key))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
}

fn model_catalog_for_target(
    target: &str,
    config_path: Option<&Path>,
    option_overrides: Option<&Value>,
    environment: Option<&Value>,
    params: &Value,
) -> Value {
    let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
    let mut global_efforts = BTreeSet::<String>::new();
    let mut sources = BTreeSet::<String>::new();
    let mut diagnostics = Vec::<Value>::new();
    let may_read_local_sources = environment
        .and_then(|value| value.get("kind"))
        .and_then(Value::as_str)
        .map(|kind| kind == "local")
        .unwrap_or(true);

    if let Some(fixture) = model_catalog_fixture_for_target(target, params) {
        merge_model_catalog_value_into(
            &fixture,
            "fixture",
            &mut entries,
            &mut sources,
            &mut diagnostics,
        );
    }

    if let Some(value) = option_overrides {
        sources.insert("option-overrides".to_string());
        collect_model_catalog_from_value(
            value,
            "option-overrides",
            &mut entries,
            &mut global_efforts,
        );
    }

    if let Some(value) = environment {
        sources.insert("environment".to_string());
        collect_model_catalog_from_value(value, "environment", &mut entries, &mut global_efforts);
    }

    if let Some(path) = config_path {
        sources.insert("config".to_string());
        collect_model_catalog_from_config_path(
            path,
            "config",
            &mut entries,
            &mut global_efforts,
            &mut diagnostics,
        );
    }
    if may_read_local_sources {
        for path in extra_model_config_paths(target, params) {
            sources.insert("local-settings".to_string());
            collect_model_catalog_from_config_path(
                &path,
                "local-settings",
                &mut entries,
                &mut global_efforts,
                &mut diagnostics,
            );
        }
        for path in extra_model_collection_paths(target, params) {
            sources.insert("model-cache".to_string());
            collect_model_catalog_from_model_collection_path(
                &path,
                "model-cache",
                &mut entries,
                &mut diagnostics,
            );
        }
    }
    if may_read_local_sources && target == "kilo-code" {
        sources.insert("kilo-state".to_string());
        collect_kilo_code_model_catalog(params, &mut entries, &mut diagnostics);
    }

    if may_read_local_sources && target == "antigravity" {
        sources.insert("antigravity-cli".to_string());
        collect_antigravity_cli_model_catalog(params, &mut entries, &mut diagnostics);
        sources.insert("antigravity-runtime".to_string());
        let catalog = crate::domain::agent_usage::antigravity_model_catalog(params);
        merge_model_catalog_value_into(
            &catalog,
            "antigravity-runtime",
            &mut entries,
            &mut sources,
            &mut diagnostics,
        );
    }

    if may_read_local_sources && param_bool(params, "includeHistoryModelCatalog").unwrap_or(true) {
        sources.insert("history".to_string());
        collect_model_catalog_from_history(target, params, &mut entries, &mut diagnostics);
    }

    if !global_efforts.is_empty() {
        for entry in entries.values_mut() {
            entry
                .reasoning_efforts
                .extend(global_efforts.iter().cloned());
        }
    }

    build_model_catalog(entries, sources, diagnostics)
}

fn empty_model_catalog(status: &str, source: &str) -> Value {
    json!({
        "schemaVersion": 1,
        "status": status,
        "sources": [source],
        "models": [],
        "diagnostics": [],
    })
}

fn collect_antigravity_cli_model_catalog(
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let source = "antigravity-cli:models";
    if param_bool(params, "disableAgentCliModelLookup").unwrap_or(false)
        || param_bool(params, "disableAntigravityCliModelLookup").unwrap_or(false)
    {
        diagnostics.push(json!({
            "source": source,
            "status": "disabled",
        }));
        return;
    }
    if cfg!(test) && !param_bool(params, "enableAgentCliModelLookup").unwrap_or(false) {
        diagnostics.push(json!({
            "source": source,
            "status": "disabled-in-tests",
        }));
        return;
    }

    let program = param_string(params, "antigravityCliPath")
        .or_else(|| param_string(params, "agyPath"))
        .or_else(|| param_string(params, "agyBin"))
        .map(PathBuf::from)
        .or_else(|| find_binary(&["agy", "antigravity"]));
    let Some(program) = program else {
        diagnostics.push(json!({
            "source": source,
            "status": "binary-unavailable",
        }));
        return;
    };
    let output = Command::new(program).arg("models").output();
    let Ok(output) = output else {
        diagnostics.push(json!({
            "source": source,
            "status": "command-failed",
        }));
        return;
    };
    if !output.status.success() {
        diagnostics.push(json!({
            "source": source,
            "status": "command-exited",
            "code": output.status.code(),
        }));
        return;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let added = collect_model_catalog_from_cli_lines(&stdout, source, entries);
    if added == 0 {
        diagnostics.push(json!({
            "source": source,
            "status": "empty",
        }));
    }
}

fn collect_model_catalog_from_cli_lines(
    raw: &str,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) -> usize {
    let before = entries.len();
    for line in raw.lines() {
        let trimmed = line
            .trim()
            .trim_start_matches(|ch| matches!(ch, '-' | '*') || ch == '\u{2022}')
            .trim();
        if trimmed.is_empty()
            || trimmed.starts_with("Usage")
            || trimmed.starts_with("Available")
            || trimmed.starts_with("Model")
        {
            continue;
        }
        add_model_catalog_entry(entries, trimmed, source, BTreeSet::new());
    }
    entries.len().saturating_sub(before)
}

fn model_catalog_fixture_for_target(target: &str, params: &Value) -> Option<Value> {
    params
        .get("modelCatalogFixture")
        .and_then(|value| value.get(target))
        .cloned()
        .or_else(|| {
            let requested = params.get("target").and_then(Value::as_str)?;
            if requested == target {
                params.get("modelCatalog").cloned()
            } else {
                None
            }
        })
}

fn extra_model_config_paths(target: &str, params: &Value) -> Vec<PathBuf> {
    let Some(home) = home_dir_for_model_catalog(params) else {
        return Vec::new();
    };
    let paths = match target {
        "antigravity" => vec![
            home.join(".gemini").join("settings.json"),
            home.join(".gemini")
                .join("antigravity-ide")
                .join("settings.json"),
            home.join(".gemini")
                .join("antigravity-cli")
                .join("settings.json"),
        ],
        "claude-code" => vec![
            home.join(".claude").join("settings.json"),
            home.join(".claude").join("settings.local.json"),
            home.join(".claude.json"),
        ],
        _ => Vec::new(),
    };
    paths.into_iter().filter(|path| path.exists()).collect()
}

fn extra_model_collection_paths(target: &str, params: &Value) -> Vec<PathBuf> {
    let Some(home) = home_dir_for_model_catalog(params) else {
        return Vec::new();
    };
    let mut paths = Vec::<PathBuf>::new();
    if target == "codex" {
        collect_json_model_catalog_files(&home.join(".codex").join("model-catalogs"), &mut paths);
    }
    if target == "copilot" {
        collect_named_model_cache_files(
            &home
                .join("Library")
                .join("Application Support")
                .join("Code")
                .join("User")
                .join("workspaceStorage"),
            "GitHub.copilot-chat",
            &mut paths,
            0,
        );
    }
    paths.sort_by(|left, right| {
        file_modified_at(right)
            .cmp(&file_modified_at(left))
            .then_with(|| left.cmp(right))
    });
    paths.truncate(8);
    paths
}

fn collect_json_model_catalog_files(root: &Path, paths: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_file() {
            continue;
        }
        if path.extension().and_then(|value| value.to_str()) == Some("json") {
            paths.push(path);
        }
    }
}

fn home_dir_for_model_catalog(params: &Value) -> Option<PathBuf> {
    param_string(params, "homeDir")
        .map(PathBuf::from)
        .or_else(|| UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf()))
}

fn collect_named_model_cache_files(
    root: &Path,
    required_component: &str,
    paths: &mut Vec<PathBuf>,
    depth: usize,
) {
    if depth > 5 || paths.len() >= 32 {
        return;
    }
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            collect_named_model_cache_files(&path, required_component, paths, depth + 1);
            continue;
        }
        if !file_type.is_file() {
            continue;
        }
        if path.file_name().and_then(|value| value.to_str()) != Some("models.json") {
            continue;
        }
        if path
            .components()
            .any(|component| component.as_os_str() == required_component)
        {
            paths.push(path);
        }
    }
}

fn file_modified_at(path: &Path) -> SystemTime {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .unwrap_or(UNIX_EPOCH)
}

fn merge_model_catalog_values(left: Option<Value>, right: Option<Value>) -> Value {
    let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
    let mut sources = BTreeSet::<String>::new();
    let mut diagnostics = Vec::<Value>::new();
    for value in [left, right].into_iter().flatten() {
        merge_model_catalog_value_into(
            &value,
            "merged",
            &mut entries,
            &mut sources,
            &mut diagnostics,
        );
    }
    build_model_catalog(entries, sources, diagnostics)
}

fn merge_model_catalog_value_into(
    value: &Value,
    fallback_source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    sources: &mut BTreeSet<String>,
    diagnostics: &mut Vec<Value>,
) {
    let source = value
        .get("source")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(fallback_source);
    sources.insert(source.to_string());
    if let Some(extra_sources) = value.get("sources").and_then(Value::as_array) {
        for item in extra_sources {
            if let Some(source) = item.as_str().filter(|value| !value.trim().is_empty()) {
                sources.insert(source.to_string());
            }
        }
    }
    if let Some(items) = value.get("diagnostics").and_then(Value::as_array) {
        diagnostics.extend(items.iter().cloned());
    }
    let Some(models) = value.get("models").and_then(Value::as_array) else {
        return;
    };
    for model in models {
        let name = model_name_from_value(model);
        if name.trim().is_empty() {
            continue;
        }
        let efforts = reasoning_efforts_from_value(model);
        let display_name = model_display_name_from_value(model, &name);
        add_model_catalog_entry_with_provider(
            entries,
            &name,
            display_name.as_deref(),
            provider_id_from_model_value(model).as_deref(),
            provider_name_from_model_value(model).as_deref(),
            source,
            efforts,
        );
    }
}

fn collect_model_catalog_from_config_path(
    path: &Path,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    global_efforts: &mut BTreeSet<String>,
    diagnostics: &mut Vec<Value>,
) {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => {
            diagnostics.push(json!({
                "source": source,
                "status": "not-readable",
            }));
            return;
        }
    };
    let parsed = parse_model_config_document(path, &raw);
    let Some(value) = parsed else {
        diagnostics.push(json!({
            "source": source,
            "status": "not-parseable",
        }));
        return;
    };
    collect_model_catalog_from_value(&value, source, entries, global_efforts);
}

fn collect_model_catalog_from_model_collection_path(
    path: &Path,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => {
            diagnostics.push(json!({
                "source": source,
                "status": "not-readable",
            }));
            return;
        }
    };
    let Some(value) = parse_model_config_document(path, &raw) else {
        diagnostics.push(json!({
            "source": source,
            "status": "not-parseable",
        }));
        return;
    };
    collect_model_catalog_entries_from_collection_value(&value, source, entries);
}

fn collect_kilo_code_model_catalog(
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let Some(home) = home_dir_for_model_catalog(params) else {
        diagnostics.push(json!({
            "source": "kilo-state",
            "status": "home-unavailable",
        }));
        return;
    };

    let vscode_state_paths = {
        let explicit = param_paths(params, &["kiloVsCodeStateDbPath", "kiloVscodeStateDbPath"]);
        if explicit.is_empty() {
            kilo_vscode_state_db_paths(&home)
        } else {
            explicit
        }
    };
    for path in vscode_state_paths {
        collect_kilo_models_from_vscode_state_db(&path, entries, diagnostics);
    }

    let kilo_db_paths = {
        let explicit = param_paths(params, &["kiloDbPath", "kiloDatabasePath"]);
        if explicit.is_empty() {
            vec![
                home.join(".local")
                    .join("share")
                    .join("kilo")
                    .join("kilo.db"),
            ]
        } else {
            explicit
        }
    };
    for path in kilo_db_paths {
        collect_kilo_models_from_local_db(&path, entries, diagnostics);
    }
}

fn kilo_vscode_state_db_paths(home: &Path) -> Vec<PathBuf> {
    let roots = match std::env::consts::OS {
        "windows" => {
            let app_data = default_app_data_dir(home);
            vec![
                app_data.join("Code"),
                app_data.join("Code - Insiders"),
                app_data.join("Cursor"),
                app_data.join("VSCodium"),
            ]
        }
        "macos" => {
            let app_support = home.join("Library").join("Application Support");
            vec![
                app_support.join("Code"),
                app_support.join("Code - Insiders"),
                app_support.join("Cursor"),
                app_support.join("VSCodium"),
            ]
        }
        _ => vec![
            home.join(".config").join("Code"),
            home.join(".config").join("Code - Insiders"),
            home.join(".config").join("Cursor"),
            home.join(".config").join("VSCodium"),
        ],
    };
    roots
        .into_iter()
        .map(|root| root.join("User").join("globalStorage").join("state.vscdb"))
        .filter(|path| path.exists())
        .collect()
}

fn collect_kilo_models_from_vscode_state_db(
    path: &Path,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let Some(connection) = open_sqlite_readonly(path) else {
        if path.exists() {
            diagnostics.push(json!({
                "source": "kilo-vscode-state",
                "status": "not-readable",
            }));
        }
        return;
    };
    let mut statement = match connection.prepare("SELECT value FROM ItemTable WHERE key=?1") {
        Ok(statement) => statement,
        Err(_) => {
            diagnostics.push(json!({
                "source": "kilo-vscode-state",
                "status": "schema-mismatch",
            }));
            return;
        }
    };
    let value = statement
        .query_row(["kilocode.kilo-code"], |row| row.get::<_, String>(0))
        .ok();
    let Some(value) = value else {
        return;
    };
    let Ok(parsed) = serde_json::from_str::<Value>(&value) else {
        diagnostics.push(json!({
            "source": "kilo-vscode-state",
            "status": "not-parseable",
        }));
        return;
    };
    collect_kilo_models_from_state_value(&parsed, "kilo-vscode-state", entries);
}

fn collect_kilo_models_from_state_value(
    value: &Value,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) {
    let Some(object) = value.as_object() else {
        return;
    };
    for key in ["recentModels", "favoriteModels"] {
        if let Some(items) = object.get(key).and_then(Value::as_array) {
            for item in items {
                collect_kilo_model_ref(item, source, entries);
            }
        }
    }
    if let Some(selections) = object.get("variantSelections").and_then(Value::as_object) {
        for (raw_key, variant) in selections {
            let Some((provider_id, model_id)) =
                kilo_provider_and_model_id_from_selection_key(raw_key)
            else {
                continue;
            };
            let efforts = variant
                .as_str()
                .and_then(sanitize_option_name)
                .into_iter()
                .collect::<BTreeSet<_>>();
            add_model_catalog_entry_with_provider(
                entries,
                &model_id,
                None,
                provider_id.as_deref(),
                None,
                source,
                efforts,
            );
        }
    }
}

fn collect_kilo_model_ref(
    value: &Value,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) {
    let Some(object) = value.as_object() else {
        return;
    };
    let Some(model_id) = object
        .get("modelID")
        .or_else(|| object.get("modelId"))
        .or_else(|| object.get("id"))
        .or_else(|| object.get("model"))
        .and_then(Value::as_str)
        .and_then(sanitize_model_name)
    else {
        return;
    };
    let efforts = object
        .get("variant")
        .or_else(|| object.get("reasoningEffort"))
        .or_else(|| object.get("thinking"))
        .and_then(Value::as_str)
        .and_then(sanitize_option_name)
        .into_iter()
        .collect::<BTreeSet<_>>();
    let provider_id = object
        .get("providerID")
        .or_else(|| object.get("providerId"))
        .or_else(|| object.get("provider_id"))
        .and_then(Value::as_str)
        .and_then(sanitize_option_name);
    let provider_name = object
        .get("providerName")
        .or_else(|| object.get("providerLabel"))
        .or_else(|| object.get("provider"))
        .and_then(Value::as_str)
        .and_then(sanitize_option_name);
    add_model_catalog_entry_with_provider(
        entries,
        &model_id,
        model_display_name_from_object(object, &model_id).as_deref(),
        provider_id.as_deref(),
        provider_name.as_deref(),
        source,
        efforts,
    );
}

fn kilo_provider_and_model_id_from_selection_key(value: &str) -> Option<(Option<String>, String)> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parts = trimmed.split('/').collect::<Vec<_>>();
    let (provider_id, model_id) = if parts.len() >= 4 && parts[0] == "agent" {
        (sanitize_option_name(parts[2]), parts[3..].join("/"))
    } else if parts.len() >= 2 && parts[0] == "kilo" {
        (sanitize_option_name(parts[0]), parts[1..].join("/"))
    } else {
        (None, trimmed.to_string())
    };
    sanitize_model_name(&model_id).map(|model_id| (provider_id, model_id))
}

fn collect_kilo_models_from_local_db(
    path: &Path,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let Some(connection) = open_sqlite_readonly(path) else {
        if path.exists() {
            diagnostics.push(json!({
                "source": "kilo-local-db",
                "status": "not-readable",
            }));
        }
        return;
    };
    if sqlite_table_exists(&connection, "session_message") {
        collect_kilo_models_from_session_messages(&connection, entries, diagnostics);
    }
    if sqlite_table_exists(&connection, "session") {
        collect_kilo_models_from_session_rows(&connection, entries);
    }
}

fn collect_kilo_models_from_session_messages(
    connection: &Connection,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let mut statement = match connection.prepare(
        "SELECT data FROM session_message WHERE type='model-switched' ORDER BY time_created DESC LIMIT 200",
    ) {
        Ok(statement) => statement,
        Err(_) => return,
    };
    let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(0)) else {
        diagnostics.push(json!({
            "source": "kilo-local-db",
            "status": "query-failed",
        }));
        return;
    };
    for row in rows.flatten() {
        let Ok(value) = serde_json::from_str::<Value>(&row) else {
            continue;
        };
        if let Some(model) = value.get("model") {
            collect_kilo_model_ref(model, "kilo-local-db", entries);
        }
    }
}

fn collect_kilo_models_from_session_rows(
    connection: &Connection,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) {
    let mut statement = match connection.prepare(
        "SELECT model FROM session WHERE model IS NOT NULL AND trim(model) <> '' ORDER BY time_updated DESC LIMIT 200",
    ) {
        Ok(statement) => statement,
        Err(_) => return,
    };
    let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(0)) else {
        return;
    };
    for row in rows.flatten() {
        if let Some(name) = sanitize_model_name(&row) {
            add_model_catalog_entry(entries, &name, "kilo-local-db", BTreeSet::new());
        }
    }
}

fn open_sqlite_readonly(path: &Path) -> Option<Connection> {
    if !path.exists() {
        return None;
    }
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()
}

fn sqlite_table_exists(connection: &Connection, table: &str) -> bool {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1",
            [table],
            |_| Ok(()),
        )
        .is_ok()
}

fn collect_model_catalog_from_history(
    target: &str,
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let mut history_params = json!({
        "agent": target,
        "limit": param_u64(params, "historyModelCatalogLimit").unwrap_or(80),
        "historyModelCatalogFileLimit": param_u64(params, "historyModelCatalogFileLimit").unwrap_or(80),
    });
    if let Some(object) = history_params.as_object_mut() {
        for key in [
            "homeDir",
            "stateRoot",
            "historyRoot",
            "root",
            "historyRootKind",
        ] {
            if let Some(value) = params.get(key) {
                object.insert(key.to_string(), value.clone());
            }
        }
    }
    match crate::domain::conversations::model_catalog(&history_params) {
        Ok(payload) => {
            let mut sources = BTreeSet::<String>::new();
            merge_model_catalog_value_into(&payload, "history", entries, &mut sources, diagnostics);
        }
        Err(error) => diagnostics.push(json!({
            "source": "history",
            "status": "failed",
            "message": error.to_string(),
        })),
    }
}

fn parse_model_config_document(path: &Path, raw: &str) -> Option<Value> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if extension == "toml" {
        return raw
            .parse::<toml::Value>()
            .ok()
            .and_then(|value| serde_json::to_value(value).ok());
    }
    serde_json::from_str::<Value>(&strip_json_comments(raw)).ok()
}

fn collect_model_catalog_from_value(
    value: &Value,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    global_efforts: &mut BTreeSet<String>,
) {
    collect_model_catalog_from_value_inner(value, source, entries, global_efforts, 0);
}

fn collect_model_catalog_from_value_inner(
    value: &Value,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    global_efforts: &mut BTreeSet<String>,
    depth: usize,
) {
    if depth > 8 {
        return;
    }
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                let normalized = normalize_model_catalog_key(key);
                if is_reasoning_option_key(&normalized) {
                    global_efforts.extend(option_names_from_value(child));
                }
                if is_model_scalar_key(&normalized) {
                    for name in model_names_from_value(child, false) {
                        add_model_catalog_entry(
                            entries,
                            &name,
                            source,
                            reasoning_efforts_from_value(child),
                        );
                    }
                } else if is_model_collection_key(&normalized) {
                    for name in model_names_from_value(child, true) {
                        add_model_catalog_entry(
                            entries,
                            &name,
                            source,
                            reasoning_efforts_from_value(child),
                        );
                    }
                }
                collect_model_catalog_from_value_inner(
                    child,
                    source,
                    entries,
                    global_efforts,
                    depth + 1,
                );
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_model_catalog_from_value_inner(
                    item,
                    source,
                    entries,
                    global_efforts,
                    depth + 1,
                );
            }
        }
        _ => {}
    }
}

fn normalize_model_catalog_key(key: &str) -> String {
    key.chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect()
}

fn is_model_scalar_key(key: &str) -> bool {
    matches!(
        key,
        "model"
            | "modelid"
            | "modelname"
            | "modellabel"
            | "defaultmodel"
            | "currentmodel"
            | "selectedmodel"
            | "activemodel"
            | "anthropicmodel"
            | "anthropicdefaultmodel"
            | "anthropicdefaulthaikumodel"
            | "anthropicdefaultopusmodel"
            | "anthropicdefaultsonnetmodel"
            | "claudecodemodel"
            | "claudecodesubagentmodel"
    )
}

fn is_model_collection_key(key: &str) -> bool {
    matches!(
        key,
        "models"
            | "supportedmodels"
            | "availablemodels"
            | "modeloptions"
            | "modelprofiles"
            | "modellist"
            | "modelcatalog"
    )
}

fn is_reasoning_option_key(key: &str) -> bool {
    matches!(
        key,
        "reasoningeffort"
            | "reasoningefforts"
            | "reasoninglevel"
            | "reasoninglevels"
            | "reasoningleveloptions"
            | "supportedreasoningefforts"
            | "supportedreasoninglevels"
            | "defaultreasoninglevel"
            | "reasoningeffortoptions"
            | "thinkinglevel"
            | "thinkinglevels"
            | "thinkingleveloptions"
            | "thinkingtype"
            | "thinkingtypes"
            | "thinkingtypeoptions"
            | "thinkingoptions"
            | "effort"
            | "efforts"
            | "effortlevel"
            | "effortlevels"
            | "effortoptions"
            | "modelreasoningeffort"
            | "claudecodeeffortlevel"
    )
}

fn model_names_from_value(value: &Value, include_object_keys: bool) -> Vec<String> {
    match value {
        Value::String(value) => {
            let trimmed = value.trim();
            if trimmed.starts_with('{') || trimmed.starts_with('[') {
                if let Ok(parsed) = serde_json::from_str::<Value>(trimmed) {
                    return model_names_from_value(&parsed, include_object_keys);
                }
            }
            sanitize_model_name(value).into_iter().collect()
        }
        Value::Array(items) => items
            .iter()
            .flat_map(|item| model_names_from_value(item, include_object_keys))
            .collect(),
        Value::Object(object) => {
            if let Some(name) = model_name_from_object(object) {
                return vec![name];
            }
            let mut names = Vec::<String>::new();
            if include_object_keys {
                for (key, child) in object {
                    if looks_like_model_name(key) {
                        names.push(key.trim().to_string());
                    }
                    names.extend(model_names_from_value(child, true));
                }
            }
            names
        }
        _ => Vec::new(),
    }
}

fn model_name_from_value(value: &Value) -> String {
    match value {
        Value::String(value) => sanitize_model_name(value).unwrap_or_default(),
        Value::Object(object) => model_name_from_object(object).unwrap_or_default(),
        _ => String::new(),
    }
}

fn model_name_from_object(object: &Map<String, Value>) -> Option<String> {
    model_identifier_from_object(object).or_else(|| model_display_name_from_object(object, ""))
}

fn model_identifier_from_object(object: &Map<String, Value>) -> Option<String> {
    for key in [
        "slug",
        "model",
        "modelName",
        "model_name",
        "name",
        "id",
        "modelId",
        "model_id",
    ] {
        let name = object
            .get(key)
            .and_then(Value::as_str)
            .and_then(sanitize_model_name);
        if name.is_some() {
            return name;
        }
    }
    None
}

fn model_display_name_from_value(value: &Value, fallback: &str) -> Option<String> {
    match value {
        Value::String(value) => {
            sanitize_model_name(value).map(|name| canonical_model_display_name(&name))
        }
        Value::Object(object) => model_display_name_from_object(object, fallback),
        _ => sanitize_model_name(fallback).map(|name| canonical_model_display_name(&name)),
    }
}

fn model_display_name_from_object(object: &Map<String, Value>, fallback: &str) -> Option<String> {
    for key in [
        "displayName",
        "display_name",
        "label",
        "title",
        "modelLabel",
        "model_label",
        "name",
    ] {
        let name = object
            .get(key)
            .and_then(Value::as_str)
            .and_then(sanitize_model_name);
        if let Some(name) = name {
            return Some(canonical_model_display_name(&name));
        }
    }
    sanitize_model_name(fallback).map(|name| canonical_model_display_name(&name))
}

fn provider_id_from_model_value(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => provider_id_from_model_object(object),
        _ => None,
    }
}

fn provider_id_from_model_object(object: &Map<String, Value>) -> Option<String> {
    for key in [
        "providerID",
        "providerId",
        "provider_id",
        "providerKey",
        "provider_key",
    ] {
        let provider_id = object
            .get(key)
            .and_then(Value::as_str)
            .and_then(sanitize_option_name);
        if provider_id.is_some() {
            return provider_id;
        }
    }
    None
}

fn provider_name_from_model_value(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => provider_name_from_model_object(object),
        _ => None,
    }
}

fn provider_name_from_model_object(object: &Map<String, Value>) -> Option<String> {
    for key in [
        "providerName",
        "provider_name",
        "providerLabel",
        "provider_label",
        "vendor",
        "vendorName",
        "vendor_name",
        "owner",
        "provider",
    ] {
        let provider_name = object
            .get(key)
            .and_then(Value::as_str)
            .and_then(sanitize_option_name);
        if provider_name.is_some() {
            return provider_name;
        }
    }
    None
}

fn reasoning_efforts_from_value(value: &Value) -> BTreeSet<String> {
    let mut efforts = BTreeSet::<String>::new();
    collect_reasoning_efforts_from_value(value, &mut efforts, 0);
    efforts
}

fn collect_reasoning_efforts_from_value(
    value: &Value,
    efforts: &mut BTreeSet<String>,
    depth: usize,
) {
    if depth > 4 {
        return;
    }
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                let normalized = normalize_model_catalog_key(key);
                if is_reasoning_option_key(&normalized) {
                    efforts.extend(option_names_from_value(child));
                }
                if normalized == "reasoning" || normalized == "thinking" {
                    collect_reasoning_efforts_from_value(child, efforts, depth + 1);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_reasoning_efforts_from_value(item, efforts, depth + 1);
            }
        }
        _ => {}
    }
}

fn option_names_from_value(value: &Value) -> BTreeSet<String> {
    match value {
        Value::String(value) => sanitize_option_name(value).into_iter().collect(),
        Value::Array(items) => items
            .iter()
            .flat_map(option_names_from_value)
            .collect::<BTreeSet<_>>(),
        Value::Object(object) => {
            for key in [
                "displayName",
                "display_name",
                "label",
                "title",
                "name",
                "value",
                "effort",
                "level",
                "id",
            ] {
                if let Some(name) = object
                    .get(key)
                    .and_then(Value::as_str)
                    .and_then(sanitize_option_name)
                {
                    return [name].into_iter().collect();
                }
            }
            object
                .iter()
                .filter_map(|(key, value)| {
                    if value.as_bool() == Some(true) {
                        sanitize_option_name(key)
                    } else {
                        None
                    }
                })
                .collect()
        }
        _ => BTreeSet::new(),
    }
}

fn collect_model_catalog_entries_from_collection_value(
    value: &Value,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) {
    match value {
        Value::Array(items) => {
            for item in items {
                collect_model_catalog_entries_from_collection_value(item, source, entries);
            }
        }
        Value::Object(object) => {
            if !model_catalog_object_is_selectable(object) {
                return;
            }
            if let Some(name) = model_name_from_object(object) {
                let display_name = model_display_name_from_object(object, &name);
                add_model_catalog_entry_with_provider(
                    entries,
                    &name,
                    display_name.as_deref(),
                    provider_id_from_model_object(object).as_deref(),
                    provider_name_from_model_object(object).as_deref(),
                    source,
                    reasoning_efforts_from_value(value),
                );
                return;
            }
            for (key, child) in object {
                if looks_like_model_name(key) {
                    add_model_catalog_entry(
                        entries,
                        key,
                        source,
                        reasoning_efforts_from_value(child),
                    );
                }
                collect_model_catalog_entries_from_collection_value(child, source, entries);
            }
        }
        _ => {
            for name in model_names_from_value(value, true) {
                add_model_catalog_entry(entries, &name, source, BTreeSet::new());
            }
        }
    }
}

fn model_catalog_object_is_selectable(object: &Map<String, Value>) -> bool {
    if object
        .get("enabled")
        .or_else(|| object.get("isEnabled"))
        .or_else(|| object.get("selectable"))
        .and_then(Value::as_bool)
        == Some(false)
    {
        return false;
    }
    let visibility = object
        .get("visibility")
        .or_else(|| object.get("display"))
        .and_then(Value::as_str)
        .map(|value| value.trim().to_ascii_lowercase());
    !matches!(visibility.as_deref(), Some("hide" | "hidden" | "disabled"))
}

fn add_model_catalog_entry(
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    name: &str,
    source: &str,
    reasoning_efforts: BTreeSet<String>,
) {
    add_model_catalog_entry_with_provider(
        entries,
        name,
        None,
        None,
        None,
        source,
        reasoning_efforts,
    );
}

fn add_model_catalog_entry_with_provider(
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    name: &str,
    display_name: Option<&str>,
    provider_id: Option<&str>,
    provider_name: Option<&str>,
    source: &str,
    reasoning_efforts: BTreeSet<String>,
) {
    let Some(name) = sanitize_model_name(name) else {
        return;
    };
    let provider_id = provider_id.and_then(sanitize_option_name);
    let provider_name = provider_name.and_then(sanitize_option_name);
    let provider_key = provider_id
        .as_ref()
        .or(provider_name.as_ref())
        .map(|value| value.to_ascii_lowercase());
    let key = match provider_key {
        Some(provider_key) => format!("{}\u{1f}{}", provider_key, name.to_ascii_lowercase()),
        None => name.to_ascii_lowercase(),
    };
    let display_name = display_name
        .and_then(sanitize_model_name)
        .map(|value| canonical_model_display_name(&value))
        .unwrap_or_else(|| canonical_model_display_name(&name));
    let provider = provider_name.clone().or_else(|| {
        provider_id
            .as_deref()
            .and_then(provider_label_from_provider_id)
    });
    let entry_name = name.clone();
    let entry = entries.entry(key).or_insert_with(|| ModelCatalogEntry {
        provider,
        provider_id: provider_id.clone(),
        provider_inferred: false,
        name: entry_name,
        display_name: display_name.clone(),
        sources: BTreeSet::new(),
        reasoning_efforts: BTreeSet::new(),
    });
    if prefer_model_display_name(&entry.name, &entry.display_name, &display_name) {
        entry.display_name = display_name;
    }
    if entry.provider_id.is_none() {
        entry.provider_id = provider_id;
    }
    if let Some(provider_name) = provider_name {
        entry.provider = Some(provider_name);
        entry.provider_inferred = false;
    } else if let Some(provider_id) = entry.provider_id.as_deref() {
        if entry.provider.is_none() || entry.provider_inferred {
            entry.provider = provider_label_from_provider_id(provider_id);
        }
        entry.provider_inferred = false;
    }
    entry.sources.insert(source.to_string());
    entry.reasoning_efforts.extend(reasoning_efforts);
}

fn sanitize_model_name(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 160
        || trimmed.contains('\n')
        || trimmed.contains('\r')
        || trimmed.starts_with('{')
        || trimmed.starts_with('[')
        || trimmed.starts_with('$')
        || trimmed.starts_with("http://")
        || trimmed.starts_with("https://")
        || trimmed.to_ascii_lowercase().contains("api_key")
    {
        return None;
    }
    Some(trimmed.to_string())
}

fn canonical_model_display_name(value: &str) -> String {
    let trimmed = value.trim();
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("gpt-") {
        return format!("GPT-{}", canonical_hyphen_suffix(&lower[4..]));
    }
    if lower.starts_with("deepseek-") {
        return format!("DeepSeek {}", canonical_space_suffix(&lower[9..]));
    }
    trimmed.to_string()
}

fn canonical_hyphen_suffix(value: &str) -> String {
    value
        .split('-')
        .filter(|part| !part.is_empty())
        .map(canonical_model_part)
        .collect::<Vec<_>>()
        .join("-")
}

fn canonical_space_suffix(value: &str) -> String {
    value
        .split('-')
        .filter(|part| !part.is_empty())
        .map(canonical_model_part)
        .collect::<Vec<_>>()
        .join(" ")
}

fn canonical_model_part(value: &str) -> String {
    match value {
        "api" => "API".to_string(),
        "codex" => "Codex".to_string(),
        "flash" => "Flash".to_string(),
        "mini" => "Mini".to_string(),
        "oss" => "OSS".to_string(),
        "pro" => "Pro".to_string(),
        "spark" => "Spark".to_string(),
        value if value.starts_with('v') && value[1..].chars().all(|ch| ch.is_ascii_digit()) => {
            value.to_ascii_uppercase()
        }
        value => {
            let mut chars = value.chars();
            match chars.next() {
                Some(first) if first.is_ascii_alphabetic() => {
                    format!("{}{}", first.to_ascii_uppercase(), chars.as_str())
                }
                Some(first) => format!("{first}{}", chars.as_str()),
                None => String::new(),
            }
        }
    }
}

fn prefer_model_display_name(name: &str, current: &str, candidate: &str) -> bool {
    if candidate.trim().is_empty() || current == candidate {
        return false;
    }
    current.trim().is_empty()
        || current == name
        || current == canonical_model_display_name(name)
        || (candidate.chars().any(|ch| ch.is_ascii_uppercase())
            && !current.chars().any(|ch| ch.is_ascii_uppercase()))
}

fn sanitize_option_name(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 80
        || trimmed.contains('\n')
        || trimmed.contains('\r')
        || trimmed.starts_with('$')
    {
        return None;
    }
    Some(trimmed.to_string())
}

fn looks_like_model_name(value: &str) -> bool {
    let trimmed = value.trim();
    if sanitize_model_name(trimmed).is_none() {
        return false;
    }
    let lower = trimmed.to_ascii_lowercase();
    if matches!(
        lower.as_str(),
        "default" | "provider" | "providers" | "metadata" | "settings" | "options"
    ) {
        return false;
    }
    lower.contains("gpt")
        || lower.contains("claude")
        || lower.contains("gemini")
        || lower.contains("deepseek")
        || lower.contains("kimi")
        || lower.contains("llama")
        || lower.contains("qwen")
        || lower.contains("mistral")
        || lower.contains("sonnet")
        || lower.contains("opus")
        || lower.contains("haiku")
        || lower.contains("flash")
        || lower.contains("pro")
        || lower.contains("oss")
        || lower.contains('-')
        || lower.chars().any(|ch| ch.is_ascii_digit())
}

fn provider_label_from_provider_id(provider_id: &str) -> Option<String> {
    let normalized = provider_id.trim();
    if normalized.is_empty() {
        return None;
    }
    let lower = normalized.to_ascii_lowercase();
    let label = match lower.as_str() {
        "anthropic" | "claude" => "Anthropic".to_string(),
        "chatgpt" | "openai" => "OpenAI".to_string(),
        "deepseek" => "DeepSeek".to_string(),
        "gemini" | "google" => "Google".to_string(),
        "kilo" => "Kilo".to_string(),
        "kimi" | "moonshot" => "Moonshot".to_string(),
        "nvidia" => "NVIDIA".to_string(),
        _ => normalized
            .split(['-', '_'])
            .filter(|part| !part.is_empty())
            .map(|part| {
                let mut chars = part.chars();
                match chars.next() {
                    Some(first) => {
                        let mut word = String::new();
                        word.extend(first.to_uppercase());
                        word.push_str(chars.as_str());
                        word
                    }
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
    };
    sanitize_option_name(&label)
}

fn build_model_catalog(
    entries: BTreeMap<String, ModelCatalogEntry>,
    sources: BTreeSet<String>,
    diagnostics: Vec<Value>,
) -> Value {
    let models = entries
        .into_values()
        .map(model_catalog_entry_json)
        .collect::<Vec<_>>();
    let status = if !models.is_empty() {
        "available"
    } else if sources.is_empty() {
        "unavailable"
    } else {
        "empty"
    };
    json!({
        "schemaVersion": 1,
        "status": status,
        "sources": sources.into_iter().collect::<Vec<_>>(),
        "models": models,
        "diagnostics": diagnostics,
    })
}

fn model_catalog_entry_json(entry: ModelCatalogEntry) -> Value {
    json!({
        "name": entry.name,
        "displayName": entry.display_name,
        "providerId": entry.provider_id.unwrap_or_default(),
        "provider": entry.provider.unwrap_or_default(),
        "providerInferred": entry.provider_inferred,
        "sources": entry.sources.into_iter().collect::<Vec<_>>(),
        "reasoningEfforts": entry.reasoning_efforts.into_iter().collect::<Vec<_>>(),
    })
}

fn remote_history_roots_for(target: &str, overrides: Option<&Value>) -> Vec<String> {
    let location = overrides
        .and_then(|value| value.get("execution-location"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    if location.is_empty() || location == "local" {
        return Vec::new();
    }
    let context = overrides
        .and_then(Value::as_object)
        .map(|object| {
            object
                .get("remote-id")
                .or_else(|| object.get("orb-vm"))
                .or_else(|| object.get("openclaw-vm"))
                .or_else(|| object.get("hermes-vm"))
                .and_then(Value::as_str)
                .unwrap_or("default")
                .to_string()
        })
        .unwrap_or_else(|| "default".to_string());
    let prefix = format!("lico-remote://{}/{}/$HOME", location, context);
    match target {
        "antigravity" => vec![
            format!("{}/.config/Antigravity IDE", prefix),
            format!("{}/.gemini/antigravity", prefix),
            format!("{}/.gemini/antigravity-ide", prefix),
        ],
        "code" => vec![
            format!("{}/.config/Code/User/workspaceStorage", prefix),
            format!("{}/.config/Code/User/globalStorage", prefix),
        ],
        "codex" => vec![
            format!("{}/.codex/history.jsonl", prefix),
            format!("{}/.codex/session_index.jsonl", prefix),
            format!("{}/.codex/sessions", prefix),
            format!("{}/.codex/archived_sessions", prefix),
            format!("{}/.codex/memories", prefix),
        ],
        "claude-code" => vec![
            format!("{}/.claude/projects", prefix),
            format!("{}/.claude.json", prefix),
        ],
        "copilot" => vec![
            format!("{}/.config/Code/User/workspaceStorage", prefix),
            format!("{}/.config/Code/User/globalStorage", prefix),
        ],
        "cursor" => vec![
            format!("{}/.config/Cursor/User/workspaceStorage", prefix),
            format!("{}/.config/Cursor/User/globalStorage", prefix),
        ],
        "hermes" => vec![
            format!("{}/.hermes", prefix),
            format!("{}/.config/hermes", prefix),
        ],
        "kimi" => vec![
            format!("{}/.config/Kimi", prefix),
            format!("{}/.local/share/Kimi", prefix),
        ],
        "kimi-code" => vec![
            format!("{}/.kimi-code/session_index.jsonl", prefix),
            format!("{}/.kimi-code/sessions", prefix),
        ],
        "opencode" => vec![
            format!("{}/.config/opencode", prefix),
            format!("{}/.local/share/opencode", prefix),
        ],
        "kilo-code" => vec![
            format!("{}/.local/share/kilo/kilo.db", prefix),
            format!("{}/.local/share/kilo/storage/session_diff", prefix),
            format!("{}/.local/share/kilo/storage/session_share", prefix),
            format!("{}/.local/share/kilo/log", prefix),
            format!("{}/.config/kilo", prefix),
        ],
        "openclaw" => vec![
            format!("{}/.openclaw", prefix),
            format!("{}/.config/openclaw", prefix),
        ],
        _ => Vec::new(),
    }
}

fn manual_targets(store: &ClientStateStore) -> Result<Vec<ManualTarget>> {
    let document = store.read_collection("targets")?;
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut manual = Vec::new();
    for item in items {
        let Some(target) = item
            .get("target")
            .and_then(Value::as_str)
            .map(normalize_target)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        let Ok(def) = target_def(&target) else {
            continue;
        };
        manual.push(ManualTarget {
            target: def.id.to_string(),
            label: item
                .get("label")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(def.label)
                .to_string(),
            kind: item
                .get("kind")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(def.kind)
                .to_string(),
            config_path: optional_path(&item, "configPath"),
            binary_path: optional_path(&item, "binaryPath"),
            history_roots: optional_paths(&item, "historyRoots")
                .into_iter()
                .chain(optional_path(&item, "historyRoot"))
                .collect(),
        });
    }
    Ok(manual)
}

fn upsert_manual_target(
    store: &ClientStateStore,
    def: &TargetDef,
    params: &Value,
) -> Result<Value> {
    let mut document = store.read_collection("targets")?;
    let mut items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let now = timestamp();
    let existing = items.iter().position(|item| {
        item.get("target")
            .and_then(Value::as_str)
            .map(normalize_target)
            .as_deref()
            == Some(def.id)
    });
    let created_at = existing
        .and_then(|index| {
            items[index]
                .get("createdAt")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| now.clone());
    let history_roots = param_paths(params, &["historyRoots", "historyRoot"]);
    let record = json!({
        "target": def.id,
        "label": param_string(params, "label").unwrap_or_else(|| def.label.to_string()),
        "kind": param_string(params, "kind").unwrap_or_else(|| def.kind.to_string()),
        "manual": true,
        "configPath": param_string(params, "configPath"),
        "binaryPath": param_string(params, "binaryPath"),
        "historyRoots": history_roots
            .iter()
            .map(|path| display_path(path.clone()))
            .collect::<Vec<_>>(),
        "createdAt": created_at,
        "updatedAt": now
    });
    match existing {
        Some(index) => items[index] = record.clone(),
        None => items.push(record.clone()),
    }
    document["items"] = Value::Array(items);
    store.write_collection("targets", document)?;
    Ok(record)
}

fn optional_path(item: &Value, key: &str) -> Option<PathBuf> {
    item.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn optional_paths(item: &Value, key: &str) -> Vec<PathBuf> {
    match item.get(key) {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .flat_map(split_path_list)
            .map(PathBuf::from)
            .collect(),
        Some(Value::String(value)) => split_path_list(value)
            .into_iter()
            .map(PathBuf::from)
            .collect(),
        _ => Vec::new(),
    }
}

fn param_string(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn param_u64(params: &Value, key: &str) -> Option<u64> {
    params.get(key).and_then(|value| {
        value
            .as_u64()
            .or_else(|| value.as_str()?.parse::<u64>().ok())
    })
}

fn param_bool(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(|value| match value {
        Value::Bool(value) => Some(*value),
        Value::String(value) => match value.trim().to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" => Some(true),
            "false" | "0" | "no" => Some(false),
            _ => None,
        },
        _ => None,
    })
}

fn param_paths(params: &Value, keys: &[&str]) -> Vec<PathBuf> {
    keys.iter()
        .filter_map(|key| params.get(*key))
        .flat_map(|value| match value {
            Value::Array(items) => items
                .iter()
                .filter_map(Value::as_str)
                .flat_map(split_path_list)
                .map(PathBuf::from)
                .collect::<Vec<_>>(),
            Value::String(value) => split_path_list(value)
                .into_iter()
                .map(PathBuf::from)
                .collect::<Vec<_>>(),
            _ => Vec::new(),
        })
        .collect()
}

fn split_path_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect()
}

fn target_def(target: &str) -> Result<TargetDef> {
    let normalized = normalize_target(target);
    target_defs()
        .into_iter()
        .find(|def| def.id == normalized)
        .ok_or_else(|| anyhow!("Unsupported target adapter: {}", target))
}

fn target_param(params: &Value) -> Result<String> {
    params
        .get("target")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("positionals")
                .and_then(Value::as_array)
                .and_then(|items| items.first())
                .and_then(Value::as_str)
        })
        .map(normalize_target)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("Missing --target <target>"))
}

fn normalize_target(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "claude" | "claude_code" | "claudecode" => "claude-code".to_string(),
        "kilo" | "kilo_code" | "kilocode" => "kilo-code".to_string(),
        "vscode" | "vs-code" | "vs_code" => "code".to_string(),
        "github-copilot" => "copilot".to_string(),
        "kimi_code" | "kimicode" => "kimi-code".to_string(),
        "open-code" | "open_code" => "opencode".to_string(),
        "openclaw-kate" | "openclaw_kate" => "openclaw".to_string(),
        "hermes-agent" | "hermes_serena" | "hermes-serena" => "hermes".to_string(),
        other => other.to_string(),
    }
}

fn target_fields(target: &str) -> Value {
    target_fields_with_values(target, "<base-url>/mcp", "<token-ref>")
}

fn target_fields_with_values(target: &str, base_url: &str, token_ref: &str) -> Value {
    let mcp_url = mcp_url(base_url);
    match target {
        "opencode" => json!([
            {"path": "mcp.lico.type", "value": "remote"},
            {"path": "mcp.lico.url", "value": mcp_url},
            {"path": "mcp.lico.headers.X-LicoLite-Api-Key", "value": token_ref},
            {"path": "mcp.lico.enabled", "value": true}
        ]),
        "antigravity" => json!([
            {"path": "mcpServers.lico.serverUrl", "value": mcp_url},
            {"path": "mcpServers.lico.headers.X-LicoLite-Api-Key", "value": token_ref},
            {"path": "mcpServers.lico.disabled", "value": false}
        ]),
        "codex" => json!([
            {"path": "mcp_servers.lico.url", "value": mcp_url},
            {"path": "mcp_servers.lico.bearer_token_env_var", "value": "LICO_MCP_TOKEN"}
        ]),
        "claude-code" | "copilot" => json!([
            {"path": "cli.mcp.command", "value": format!("{} mcp add", target)},
            {"path": "cli.mcp.transport", "value": "http"},
            {"path": "cli.mcp.url", "value": mcp_url},
            {"path": "cli.mcp.headers.X-LicoLite-Api-Key", "value": token_ref}
        ]),
        "kilo-code" => json!([
            {"path": "mcp.lico.type", "value": "remote"},
            {"path": "mcp.lico.url", "value": mcp_url},
            {"path": "mcp.lico.headers.X-LicoLite-Api-Key", "value": token_ref},
            {"path": "mcp.lico.enabled", "value": true}
        ]),
        "openclaw" => json!([
            {"path": "vm.name", "value": "<vm>"},
            {"path": "mcp.lico.url", "value": mcp_url},
            {"path": "mcp.lico.headers.X-LicoLite-Api-Key", "value": token_ref}
        ]),
        "hermes" => json!([
            {"path": "vm.name", "value": "<vm>"},
            {"path": "hermes.mcp.lico.url", "value": mcp_url},
            {"path": "hermes.mcp.lico.auth", "value": "header"},
            {"path": "hermes.mcp.lico.headers.X-LicoLite-Api-Key", "value": token_ref}
        ]),
        "cursor" => json!([
            {"path": "mcpServers.lico.command", "value": "lico-mcp"},
            {"path": "mcpServers.lico.args", "value": ["server"]}
        ]),
        _ => json!([]),
    }
}

fn apply_structured_patch(
    target: &str,
    current: &str,
    base_url: &str,
    token_ref: &str,
) -> Result<String> {
    match target {
        "opencode" | "antigravity" | "cursor" | "openclaw" => {
            apply_json_patch(target, current, base_url, token_ref)
        }
        _ => Err(anyhow!("Unsupported target adapter: {}", target)),
    }
}

fn apply_json_patch(
    target: &str,
    current: &str,
    base_url: &str,
    token_ref: &str,
) -> Result<String> {
    let parsed = if current.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(&strip_json_comments(current))
            .map_err(|error| anyhow!("Unable to parse target JSON config: {}", error))?
    };
    let mut config = parsed.as_object().cloned().unwrap_or_else(Map::new);
    let patch = json_patch_entries(target, base_url, token_ref);
    for (path, value) in patch {
        set_json_path(&mut config, &path, value)?;
    }
    Ok(format!(
        "{}\n",
        serde_json::to_string_pretty(&Value::Object(config))?
    ))
}

#[allow(dead_code)]
fn apply_codex_patch(current: &str, base_url: &str) -> Result<String> {
    let mut root = if current.trim().is_empty() {
        toml::map::Map::new()
    } else {
        current
            .parse::<toml::Value>()
            .map_err(|error| anyhow!("Unable to parse Codex TOML config: {}", error))?
            .as_table()
            .cloned()
            .ok_or_else(|| anyhow!("Codex TOML config must be a table"))?
    };
    let mcp_servers = root
        .entry("mcp_servers".to_string())
        .or_insert_with(|| toml::Value::Table(toml::map::Map::new()))
        .as_table_mut()
        .ok_or_else(|| anyhow!("Codex mcp_servers must be a table"))?;
    let mut lico = toml::map::Map::new();
    lico.insert("url".to_string(), toml::Value::String(mcp_url(base_url)));
    lico.insert(
        "bearer_token_env_var".to_string(),
        toml::Value::String("LICO_MCP_TOKEN".to_string()),
    );
    mcp_servers.insert("lico".to_string(), toml::Value::Table(lico));
    Ok(toml::to_string_pretty(&toml::Value::Table(root))?)
}

fn json_patch_entries(target: &str, base_url: &str, token_ref: &str) -> Vec<(String, Value)> {
    let mcp_url = mcp_url(base_url);
    match target {
        "opencode" => vec![
            ("mcp.lico.type".to_string(), json!("remote")),
            ("mcp.lico.url".to_string(), json!(mcp_url)),
            (
                "mcp.lico.headers.X-LicoLite-Api-Key".to_string(),
                json!(token_ref),
            ),
            ("mcp.lico.enabled".to_string(), json!(true)),
        ],
        "antigravity" => vec![
            ("mcpServers.lico.serverUrl".to_string(), json!(mcp_url)),
            (
                "mcpServers.lico.headers.X-LicoLite-Api-Key".to_string(),
                json!(token_ref),
            ),
            ("mcpServers.lico.disabled".to_string(), json!(false)),
        ],
        "openclaw" => vec![
            ("mcp.lico.type".to_string(), json!("remote")),
            ("mcp.lico.url".to_string(), json!(mcp_url)),
            (
                "mcp.lico.headers.X-LicoLite-Api-Key".to_string(),
                json!(token_ref),
            ),
            ("mcp.lico.enabled".to_string(), json!(true)),
        ],
        "cursor" => vec![
            ("mcpServers.lico.command".to_string(), json!("lico-mcp")),
            ("mcpServers.lico.args".to_string(), json!(["server"])),
        ],
        _ => Vec::new(),
    }
}

fn set_json_path(root: &mut Map<String, Value>, path: &str, value: Value) -> Result<()> {
    if path.is_empty() {
        return Err(anyhow!("Empty config path"));
    }
    let mut current = root;
    let parts = path.split('.').collect::<Vec<_>>();
    let parent_count = parts.len().saturating_sub(1);
    for (idx, part) in parts.iter().enumerate().take(parent_count) {
        let entry = current
            .entry((*part).to_string())
            .or_insert_with(|| Value::Object(Map::new()));
        if !entry.is_object() {
            return Err(anyhow!(
                "field_conflict: path segment '{}' is a {} but expected an object for path '{}'",
                part,
                value_type_name(entry),
                path
            ));
        }
        current = entry
            .as_object_mut()
            .ok_or_else(|| anyhow!("Unable to create config object for {}", path))?;
        let _ = idx;
    }
    let Some(last) = parts.last() else {
        return Err(anyhow!("Empty config path"));
    };
    current.insert((*last).to_string(), value);
    Ok(())
}

fn value_type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn config_has_jsonc_comments(path: &Path) -> bool {
    if let Ok(content) = fs::read_to_string(path) {
        let mut in_string = false;
        let mut escaped = false;
        let mut chars = content.chars().peekable();
        while let Some(ch) = chars.next() {
            if in_string {
                escaped = ch == '\\' && !escaped;
                if ch == '"' && !escaped {
                    in_string = false;
                }
                if ch != '\\' {
                    escaped = false;
                }
                continue;
            }
            if ch == '"' {
                in_string = true;
                continue;
            }
            if ch == '/' {
                if let Some('/') = chars.peek() {
                    return true;
                }
                if let Some('*') = chars.peek() {
                    return true;
                }
            }
        }
    }
    false
}

fn strip_json_comments(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    let mut in_string = false;
    let mut escaped = false;
    while let Some(ch) = chars.next() {
        if in_string {
            escaped = ch == '\\' && !escaped;
            if ch == '"' && !escaped {
                in_string = false;
            }
            output.push(ch);
            if ch != '\\' {
                escaped = false;
            }
            continue;
        }
        if ch == '"' {
            in_string = true;
            output.push(ch);
            continue;
        }
        if ch == '/' {
            match chars.peek() {
                Some('/') => {
                    chars.next();
                    for next in chars.by_ref() {
                        if next == '\n' {
                            output.push('\n');
                            break;
                        }
                    }
                    continue;
                }
                Some('*') => {
                    chars.next();
                    let mut previous = '\0';
                    for next in chars.by_ref() {
                        if previous == '*' && next == '/' {
                            break;
                        }
                        previous = next;
                    }
                    continue;
                }
                _ => {}
            }
        }
        output.push(ch);
    }
    output
}

fn resolve_config_path(def: &TargetDef, params: &Value) -> Result<PathBuf> {
    params
        .get("configPath")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .or_else(|| stored_config_path(def, params).ok().flatten())
        .or_else(|| default_config_path_with_params(def.id, params))
        .ok_or_else(|| anyhow!("missing_config_path: {}", def.label))
}

fn stored_config_path(def: &TargetDef, params: &Value) -> Result<Option<PathBuf>> {
    let store = client_state_store(params)?;
    Ok(manual_targets(&store)?
        .into_iter()
        .find(|item| item.target == def.id)
        .and_then(|item| item.config_path))
}

fn token_ref(params: &Value) -> String {
    token_ref_with_env(params, std::env::var("LICO_MCP_TOKEN").ok())
}

fn token_ref_with_env(params: &Value, mcp_token: Option<String>) -> String {
    params
        .get("token")
        .or_else(|| params.get("apiKey"))
        .or_else(|| params.get("licoApiKey"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .or_else(|| {
            mcp_token
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        })
        .unwrap_or_else(|| "${LICO_MCP_TOKEN}".to_string())
}

fn mcp_url(base_url: &str) -> String {
    if base_url.ends_with("/mcp") {
        base_url.to_string()
    } else {
        format!("{}/mcp", base_url.trim_end_matches('/'))
    }
}

#[allow(dead_code)]
fn normalize_base_url_with_env(params: &Value, mcp_url: Option<String>) -> String {
    params
        .get("baseUrl")
        .or_else(|| params.get("url"))
        .and_then(Value::as_str)
        .and_then(|v| {
            let trimmed = v.trim().trim_end_matches('/');
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        })
        .unwrap_or_else(|| {
            mcp_url
                .as_deref()
                .map(|s| s.trim().trim_end_matches('/').to_string())
                .unwrap_or_else(|| "http://127.0.0.1:7228".to_string())
        })
}

#[allow(dead_code)]
fn extract_discovery_base_url(value: &Value) -> Option<String> {
    let object = value.as_object()?;
    for key in ["httpUrl", "mcpUrl", "url", "baseUrl", "endpoint"] {
        if let Some(url) = object.get(key).and_then(Value::as_str) {
            let trimmed = url.trim().trim_end_matches('/');
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    if let Some(servers) = object.get("servers") {
        if let Some(active) = object.get("activeServer").and_then(Value::as_str) {
            if let Some(server) = servers.get(active) {
                if let Some(url) = extract_discovery_base_url(server) {
                    return Some(url);
                }
            }
        }
        if let Some(url) = extract_first_collection_base_url(servers) {
            return Some(url);
        }
    }
    for key in ["server", "service", "discovery", "mcp"] {
        if let Some(url) = object.get(key).and_then(extract_discovery_base_url) {
            return Some(url);
        }
    }
    for key in ["candidates", "items"] {
        if let Some(url) = object.get(key).and_then(extract_first_collection_base_url) {
            return Some(url);
        }
    }
    None
}

#[allow(dead_code)]
fn extract_first_collection_base_url(value: &Value) -> Option<String> {
    if let Some(items) = value.as_array() {
        return items.iter().find_map(extract_discovery_base_url);
    }
    value
        .as_object()
        .and_then(|items| items.values().find_map(extract_discovery_base_url))
}

fn build_field_conflict_error(
    target: &str,
    config_path: &Path,
    error_msg: &str,
    current: &str,
) -> Value {
    let conflicts = parse_field_conflicts(error_msg, current);
    json!({
        "ok": false,
        "status": "field_conflict",
        "target": target,
        "configPath": display_path(config_path.to_path_buf()),
        "conflicts": conflicts
    })
}

fn parse_field_conflicts(error_msg: &str, _current: &str) -> Vec<Value> {
    let mut conflicts = Vec::new();
    if let Some(rest) = error_msg.strip_prefix("field_conflict: ") {
        let parts: Vec<&str> = rest.splitn(2, " is a ").collect();
        if parts.len() == 2 {
            let _path_segment = parts[0].trim().trim_matches('\'');
            let rest = parts[1];
            let type_parts: Vec<&str> = rest
                .splitn(2, " but expected an object for path ")
                .collect();
            if type_parts.len() == 2 {
                let current_type = type_parts[0].trim().trim_matches('\'');
                let full_path = type_parts[1].trim().trim_matches('\'');
                conflicts.push(json!({
                    "path": full_path,
                    "reason": "expected_object",
                    "currentType": current_type,
                    "proposedType": "object"
                }));
            }
        }
    }
    if conflicts.is_empty() {
        conflicts.push(json!({
            "path": "",
            "reason": "unknown",
            "currentType": "unknown",
            "proposedType": "unknown",
            "rawError": error_msg
        }));
    }
    conflicts
}

fn snapshot_id_from_params(params: &Value) -> Result<String> {
    params
        .get("snapshotId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("Missing --snapshot-id or --snapshot-path"))
}

fn client_state_store(params: &Value) -> Result<ClientStateStore> {
    if let Some(root) = params
        .get("stateRoot")
        .or_else(|| params.get("clientStateRoot"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return ClientStateStore::new(PathBuf::from(root));
    }
    if let Some(portable_dir) = params
        .get("portableDir")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return ClientStateStore::new(PathBuf::from(portable_dir).join("future-client"));
    }
    ClientStateStore::portable()
}

fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{}", now.as_secs(), now.subsec_nanos())
}

fn atomic_write(path: &Path, content: &str) -> Result<()> {
    atomic_write_private_text(path, content)
}

fn hash_text(content: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(content.as_bytes());
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
fn snapshot_stamp() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{}", now.as_secs(), now.subsec_nanos())
}

#[cfg(test)]
fn default_config_path(target: &str) -> Option<PathBuf> {
    default_config_path_with_params(target, &Value::Null)
}

fn default_config_path_with_params(target: &str, params: &Value) -> Option<PathBuf> {
    let home = UserDirs::new()?.home_dir().to_path_buf();
    if target == "kimi-code"
        && let Some(root) = kimi_code_home_override(params, &home)
    {
        return Some(root.join("config.toml"));
    }
    let app_data = default_app_data_dir(&home);
    default_config_path_for_platform(target, std::env::consts::OS, &home, &app_data)
}

fn default_detection_path_with_params(target: &str, params: &Value) -> Option<PathBuf> {
    let home = UserDirs::new()?.home_dir().to_path_buf();
    if target == "kimi-code"
        && let Some(root) = kimi_code_home_override(params, &home)
    {
        return root.exists().then_some(root);
    }
    let app_data = default_app_data_dir(&home);
    default_detection_path_for_platform(target, std::env::consts::OS, &home, &app_data)
}

fn kimi_code_home_override(params: &Value, home: &Path) -> Option<PathBuf> {
    param_string(params, "kimiCodeHome")
        .or_else(|| env::var("KIMI_CODE_HOME").ok())
        .map(|value| expand_home_root(&value, home))
}

fn expand_home_root(value: &str, home: &Path) -> PathBuf {
    let trimmed = value.trim();
    if trimmed == "~" {
        return home.to_path_buf();
    }
    if let Some(relative) = trimmed
        .strip_prefix("~/")
        .or_else(|| trimmed.strip_prefix("~\\"))
    {
        return home.join(relative);
    }
    PathBuf::from(trimmed)
}

fn default_app_data_dir(home: &Path) -> PathBuf {
    if let Ok(value) = env::var("APPDATA") {
        if !value.trim().is_empty() {
            return PathBuf::from(value);
        }
    }
    directories::BaseDirs::new()
        .map(|dirs| dirs.data_dir().to_path_buf())
        .unwrap_or_else(|| home.join("AppData").join("Roaming"))
}

fn default_config_path_for_platform(
    target: &str,
    platform: &str,
    home: &Path,
    app_data: &Path,
) -> Option<PathBuf> {
    match target {
        "codex" => Some(home.join(".codex").join("config.toml")),
        "code" if platform == "windows" => {
            Some(app_data.join("Code").join("User").join("settings.json"))
        }
        "code" if platform == "macos" => Some(
            home.join("Library")
                .join("Application Support")
                .join("Code")
                .join("User")
                .join("settings.json"),
        ),
        "code" => Some(
            home.join(".config")
                .join("Code")
                .join("User")
                .join("settings.json"),
        ),
        "opencode" if platform == "windows" => {
            Some(app_data.join("opencode").join("opencode.jsonc"))
        }
        "opencode" => Some(home.join(".config").join("opencode").join("opencode.jsonc")),
        "antigravity" => Some(
            home.join(".gemini")
                .join("antigravity")
                .join("mcp_config.json"),
        ),
        "cursor" if platform == "windows" => Some(
            app_data
                .join("Cursor")
                .join("User")
                .join("globalStorage")
                .join("saoudrizwan.claude-dev")
                .join("settings")
                .join("cline_mcp_settings.json"),
        ),
        "cursor" if platform == "macos" => Some(
            home.join("Library")
                .join("Application Support")
                .join("Cursor")
                .join("User")
                .join("globalStorage")
                .join("saoudrizwan.claude-dev")
                .join("settings")
                .join("cline_mcp_settings.json"),
        ),
        "cursor" => Some(
            home.join(".config")
                .join("Cursor")
                .join("User")
                .join("globalStorage")
                .join("saoudrizwan.claude-dev")
                .join("settings")
                .join("cline_mcp_settings.json"),
        ),
        "kilo-code" if platform == "windows" => Some(app_data.join("kilo").join("kilo.json")),
        "kilo-code" => Some(home.join(".config").join("kilo").join("kilo.json")),
        "kimi-code" => Some(home.join(".kimi-code").join("config.toml")),
        "kimi" if platform == "windows" => Some(app_data.join("Kimi").join("config.json")),
        "kimi" if platform == "macos" => Some(
            home.join("Library")
                .join("Application Support")
                .join("Kimi")
                .join("config.json"),
        ),
        "kimi" => Some(home.join(".config").join("Kimi").join("config.json")),
        "openclaw" => None,
        "claude-code" => Some(home.join(".claude").join("settings.json")),
        "copilot" => None,
        "hermes" => None,
        _ => None,
    }
}

fn default_detection_path_for_platform(
    target: &str,
    platform: &str,
    home: &Path,
    app_data: &Path,
) -> Option<PathBuf> {
    default_detection_paths_for_platform(target, platform, home, app_data)
        .into_iter()
        .find(|path| path.exists())
        .or_else(|| {
            if target == "kilo-code" {
                kilo_code_extension_roots(home)
                    .into_iter()
                    .find_map(existing_kilo_code_extension_dir)
            } else {
                None
            }
        })
}

fn default_detection_paths_for_platform(
    target: &str,
    platform: &str,
    home: &Path,
    app_data: &Path,
) -> Vec<PathBuf> {
    match target {
        "cursor" => match platform {
            "windows" => vec![app_data.join("Cursor")],
            "macos" => vec![
                home.join("Library")
                    .join("Application Support")
                    .join("Cursor"),
            ],
            _ => vec![home.join(".config").join("Cursor")],
        },
        "kilo-code" => {
            let storage_roots = match platform {
                "windows" => vec![
                    app_data.join("Code"),
                    app_data.join("Code - Insiders"),
                    app_data.join("Cursor"),
                    app_data.join("VSCodium"),
                ],
                "macos" => {
                    let app_support = home.join("Library").join("Application Support");
                    vec![
                        app_support.join("Code"),
                        app_support.join("Code - Insiders"),
                        app_support.join("Cursor"),
                        app_support.join("VSCodium"),
                    ]
                }
                _ => vec![
                    home.join(".config").join("Code"),
                    home.join(".config").join("Code - Insiders"),
                    home.join(".config").join("Cursor"),
                    home.join(".config").join("VSCodium"),
                ],
            };
            storage_roots
                .into_iter()
                .map(|root| {
                    root.join("User")
                        .join("globalStorage")
                        .join("kilocode.kilo-code")
                })
                .collect()
        }
        "kimi-code" => vec![
            home.join(".kimi-code").join("config.toml"),
            home.join(".kimi-code").join("session_index.jsonl"),
            home.join(".kimi-code").join("sessions"),
        ],
        "kimi" => match platform {
            "windows" => vec![app_data.join("Kimi"), app_data.join("com.moonshot.kimi")],
            "macos" => {
                let app_support = home.join("Library").join("Application Support");
                vec![
                    app_support.join("Kimi"),
                    app_support.join("com.moonshot.kimi"),
                ]
            }
            _ => vec![
                home.join(".config").join("Kimi"),
                home.join(".local").join("share").join("Kimi"),
            ],
        },
        _ => Vec::new(),
    }
}

fn kilo_code_extension_roots(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(".vscode").join("extensions"),
        home.join(".vscode-insiders").join("extensions"),
        home.join(".cursor").join("extensions"),
        home.join(".vscodium").join("extensions"),
    ]
}

fn existing_kilo_code_extension_dir(root: PathBuf) -> Option<PathBuf> {
    let entries = fs::read_dir(root).ok()?;
    for entry in entries.filter_map(|entry| entry.ok()) {
        let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
        if name == "kilocode.kilo-code" || name.starts_with("kilocode.kilo-code-") {
            return Some(entry.path());
        }
    }
    None
}

fn target_uses_running_process_detection(target: &str) -> bool {
    matches!(
        target,
        "claude-code" | "codex" | "code" | "cursor" | "kilo-code" | "kimi" | "kimi-code"
    )
}

fn running_process_for(def: &TargetDef, scan_context: &mut ScanContext) -> Option<String> {
    let running_processes = scan_context.running_processes();
    for name in def.process_names {
        let normalized = normalize_process_name(name);
        if running_processes.contains(&normalized) {
            return Some((*name).to_string());
        }
    }
    None
}

fn running_process_names_from_params(params: &Value) -> Option<BTreeSet<String>> {
    let value = params.get("runningProcessNames")?;
    let mut names = BTreeSet::<String>::new();
    match value {
        Value::Array(items) => {
            for item in items.iter().filter_map(Value::as_str) {
                insert_process_name(&mut names, item);
            }
        }
        Value::String(value) => {
            for item in value.split(',') {
                insert_process_name(&mut names, item);
            }
        }
        _ => {}
    }
    Some(names)
}

#[cfg(windows)]
fn current_running_process_names() -> BTreeSet<String> {
    let Ok(output) = Command::new("tasklist")
        .args(["/fo", "csv", "/nh"])
        .output()
    else {
        return BTreeSet::new();
    };
    if !output.status.success() {
        return BTreeSet::new();
    }
    let text = String::from_utf8_lossy(&output.stdout);
    tasklist_process_names(&text)
}

#[cfg(not(windows))]
fn current_running_process_names() -> BTreeSet<String> {
    BTreeSet::new()
}

#[cfg(windows)]
fn tasklist_process_names(text: &str) -> BTreeSet<String> {
    let mut names = BTreeSet::<String>::new();
    for line in text.lines() {
        if let Some(name) = first_csv_field(line) {
            insert_process_name(&mut names, &name);
        }
    }
    names
}

#[cfg(windows)]
fn first_csv_field(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(rest) = trimmed.strip_prefix('"') {
        let mut value = String::new();
        let mut chars = rest.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch == '"' {
                if chars.peek() == Some(&'"') {
                    value.push('"');
                    chars.next();
                    continue;
                }
                return Some(value);
            }
            value.push(ch);
        }
        return None;
    }
    trimmed.split(',').next().map(str::trim).map(str::to_string)
}

fn insert_process_name(names: &mut BTreeSet<String>, value: &str) {
    let normalized = normalize_process_name(value);
    if normalized.is_empty() {
        return;
    }
    names.insert(normalized.clone());
    if let Some(stem) = normalized.strip_suffix(".exe") {
        names.insert(stem.to_string());
    }
}

fn normalize_process_name(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn config_has_lico(path: &Path) -> bool {
    let Ok(content) = std::fs::read_to_string(path) else {
        return false;
    };
    content.contains("\"lico\"")
        || content.contains("[mcp_servers.lico]")
        || content.contains("lico-mcp")
}

fn find_binary(names: &[&str]) -> Option<PathBuf> {
    let dirs = binary_search_dirs();
    find_binary_in_dirs(names, &dirs)
}

fn find_target_binary(def: &TargetDef, params: &Value) -> Option<PathBuf> {
    if def.id != "cursor" {
        return find_binary(def.binary_names);
    }
    let dirs = binary_search_dirs();
    // `agent` is intentionally generic. Name priority plus an ACP initialize
    // probe prevents an unrelated executable from becoming Cursor's runtime
    // candidate while retaining Cursor's current primary CLI name and alias.
    for name in def.binary_names {
        if let Some(candidate) = find_binary_in_dirs(&[*name], &dirs)
            && cursor_binary_supports_acp(&candidate, params)
        {
            return Some(candidate);
        }
    }
    None
}

fn cursor_binary_supports_acp(binary: &Path, params: &Value) -> bool {
    let cwd = param_string(params, "workingDirectory")
        .or_else(|| param_string(params, "cwd"))
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| env::current_dir().ok());
    let Some(cwd) = cwd else {
        return false;
    };
    runtime_adapters::probe_runtime_driver("cursor", binary, &cwd)
        .get("supported")
        .and_then(Value::as_bool)
        == Some(true)
}

fn find_binary_in_dirs(names: &[&str], dirs: &[PathBuf]) -> Option<PathBuf> {
    for dir in dirs {
        for name in names {
            for candidate in binary_candidate_paths(dir, name) {
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
    }
    None
}

fn binary_search_dirs() -> Vec<PathBuf> {
    let mut dirs = env::var_os("PATH")
        .map(|path_var| env::split_paths(&path_var).collect::<Vec<_>>())
        .unwrap_or_default();
    dirs.extend(common_windows_binary_dirs());
    dedupe_paths(dirs)
}

fn binary_candidate_paths(dir: &Path, name: &str) -> Vec<PathBuf> {
    #[cfg(not(target_os = "windows"))]
    let candidates = vec![dir.join(name)];

    #[cfg(target_os = "windows")]
    let mut candidates = vec![dir.join(name)];
    #[cfg(target_os = "windows")]
    {
        if Path::new(name).extension().is_none() {
            for extension in windows_binary_extensions() {
                candidates.push(dir.join(format!("{}{}", name, extension)));
            }
        }
    }
    dedupe_paths(candidates)
}

#[cfg(target_os = "windows")]
fn windows_binary_extensions() -> Vec<String> {
    let mut extensions = env::var("PATHEXT")
        .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string())
        .split(';')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            if value.starts_with('.') {
                value.to_string()
            } else {
                format!(".{}", value)
            }
        })
        .collect::<Vec<_>>();
    for extension in [".exe", ".cmd", ".bat", ".com"] {
        if !extensions
            .iter()
            .any(|value| value.eq_ignore_ascii_case(extension))
        {
            extensions.push(extension.to_string());
        }
    }
    extensions
}

#[cfg(target_os = "windows")]
fn common_windows_binary_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::<PathBuf>::new();
    if let Ok(value) = env::var("APPDATA") {
        if !value.trim().is_empty() {
            dirs.push(PathBuf::from(value).join("npm"));
        }
    }
    if let Ok(value) = env::var("LOCALAPPDATA") {
        if !value.trim().is_empty() {
            let local = PathBuf::from(value);
            dirs.push(local.join("Microsoft").join("WindowsApps"));
            dirs.push(local.join("Programs").join("Microsoft VS Code").join("bin"));
            dirs.push(
                local
                    .join("Programs")
                    .join("Microsoft VS Code Insiders")
                    .join("bin"),
            );
            dirs.push(
                local
                    .join("Programs")
                    .join("Cursor")
                    .join("resources")
                    .join("app")
                    .join("bin"),
            );
        }
    }
    for var in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Ok(value) = env::var(var) {
            if !value.trim().is_empty() {
                let root = PathBuf::from(value);
                dirs.push(root.join("Microsoft VS Code").join("bin"));
                dirs.push(root.join("Microsoft VS Code Insiders").join("bin"));
                dirs.push(
                    root.join("Cursor")
                        .join("resources")
                        .join("app")
                        .join("bin"),
                );
            }
        }
    }
    dirs
}

#[cfg(not(target_os = "windows"))]
fn common_windows_binary_dirs() -> Vec<PathBuf> {
    Vec::new()
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = BTreeSet::<String>::new();
    let mut out = Vec::<PathBuf>::new();
    for path in paths {
        let key = path.to_string_lossy().to_ascii_lowercase();
        if seen.insert(key) {
            out.push(path);
        }
    }
    out
}

fn display_path(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::mcp_trust;

    fn signed_receipt_discovery(endpoint: &str, path: &Path) -> String {
        use rand::RngCore;
        let mut bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        let secret_bytes = bytes;
        let mcp_url = format!("{}/mcp", endpoint.trim_end_matches('/'));
        let (receipt, public_key) = mcp_trust::test_signed_receipt(
            endpoint,
            &mcp_url,
            "test-key",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );
        let doc = json!({
            "url": endpoint,
            "trustReceipt": receipt,
            "pinnedPublicKey": public_key
        });
        fs::write(path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
        public_key
    }

    fn forged_discovery(endpoint: &str, path: &Path) {
        fs::write(
            path,
            format!(r#"{{"url":"{}","handshakeVerified":true}}"#, endpoint),
        )
        .unwrap();
    }

    #[test]
    fn scan_includes_required_first_targets() {
        let scan = scan_targets_with_params(&json!({
            "includeAccessibleEnvironments": false
        }))
        .unwrap();
        let ids = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["target"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            ids,
            vec![
                "openclaw",
                "claude-code",
                "codex",
                "code",
                "antigravity",
                "opencode",
                "copilot",
                "kilo-code",
                "cursor",
                "hermes",
                "kimi",
                "kimi-code"
            ]
        );
    }

    #[test]
    fn target_ids_are_unique_and_runtime_projection_matches_packaging_authority() {
        let definitions = target_defs();
        let unique = definitions
            .iter()
            .map(|definition| definition.id)
            .collect::<BTreeSet<_>>();
        assert_eq!(unique.len(), definitions.len());

        let projected = definitions
            .iter()
            .filter_map(|definition| {
                runtime_adapters::runtime_driver_profile(definition.id).map(|_| definition.id)
            })
            .collect::<BTreeSet<_>>();
        let packaged = runtime_adapters::PACKAGED_RUNTIME_ADAPTER_IDS
            .iter()
            .copied()
            .collect::<BTreeSet<_>>();
        assert_eq!(projected, packaged);
    }

    #[test]
    fn scan_merges_installer_accessible_environment_targets() {
        let dir = temp_test_dir("installer-scan");
        let script = dir.join("fake-lico-mcp.mjs");
        fs::write(
            &script,
            r#"console.log(JSON.stringify({
  ok: true,
  candidates: [
    {
      id: "codex:docker:abc123:/usr/local/bin/codex",
      target: "codex",
      label: "Codex (devbox)",
      status: "detected",
      detail: "Codex executable at /usr/local/bin/codex",
      optionOverrides: {
        "execution-location": "docker",
        "remote-kind": "docker",
        "remote-id": "abc123",
        "remote-name": "devbox",
        "remote-bin": "docker",
        "codex-bin": "/usr/local/bin/codex",
        "models": ["gpt-5.5"]
      }
    },
    {
      id: "codex:local:/opt/codex",
      target: "codex",
      label: "Codex local duplicate",
      status: "detected",
      optionOverrides: {
        "execution-location": "local",
        "codex-bin": "/opt/codex"
      }
    },
    {
      id: "hermes:local:/opt/pkg/bin/hermes",
      target: "hermes",
      label: "Hermes local package manager path",
      status: "detected",
      detail: "Hermes CLI at /opt/pkg/bin/hermes",
      optionOverrides: {
        "execution-location": "local",
        "hermes-bin": "/opt/pkg/bin/hermes",
        "modelCatalog": {
          "models": [{"name": "hermes-local-model"}]
        }
      }
    }
  ]
}));
"#,
        )
        .unwrap();

        let scan = scan_targets_with_params(&json!({
            "includeAccessibleEnvironments": true,
            "includeHistoryModelCatalog": false,
            "installerScanCommand": display_path(script)
        }))
        .unwrap();

        assert_eq!(scan["ok"], true);
        assert!(
            scan["scanScopes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|scope| scope == "installer-accessible-environments")
        );
        let docker_codex = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["id"] == "codex:docker:abc123:/usr/local/bin/codex")
            .unwrap();
        assert_eq!(docker_codex["target"], "codex");
        assert_eq!(
            docker_codex["scanSource"],
            "installer-accessible-environments"
        );
        assert_eq!(docker_codex["location"], "docker");
        assert_eq!(docker_codex["environment"]["id"], "abc123");
        assert_eq!(docker_codex["binaryPath"], "/usr/local/bin/codex");
        assert_eq!(docker_codex["modelCatalog"]["models"][0]["name"], "gpt-5.5");
        assert!(
            docker_codex["remoteHistoryRoots"]
                .as_array()
                .unwrap()
                .iter()
                .any(|root| root == "lico-remote://docker/abc123/$HOME/.codex/sessions")
        );
        assert!(
            scan["candidates"]
                .as_array()
                .unwrap()
                .iter()
                .all(|item| item["id"] != "codex:local:/opt/codex")
        );
        let hermes = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["target"] == "hermes" && item["location"] == "local")
            .unwrap();
        assert_eq!(hermes["status"], "detected");
        assert_eq!(hermes["binaryPath"], "/opt/pkg/bin/hermes");
        assert_eq!(
            hermes["scanSource"],
            "host-adapter-defaults+installer-accessible-environments"
        );
        assert_eq!(
            hermes["modelCatalog"]["models"][0]["name"],
            "hermes-local-model"
        );
    }

    #[test]
    fn model_catalog_reads_models_from_client_config() {
        let dir = temp_test_dir("model-catalog-config");
        let config_path = dir.join("config.toml");
        fs::write(
            &config_path,
            r#"
model = "gpt-5.5"
model_reasoning_effort = "high"

[profiles.review]
model = "gpt-5.4-mini"
"#,
        )
        .unwrap();

        let catalog = model_catalog_for_target(
            "codex",
            Some(&config_path),
            None,
            None,
            &json!({"includeHistoryModelCatalog": false}),
        );
        let models = catalog["models"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["name"] == "gpt-5.5"
                && model["displayName"] == "GPT-5.5"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("high"))
        }));
        assert!(models.iter().any(|model| {
            model["name"] == "gpt-5.4-mini" && model["displayName"] == "GPT-5.4-Mini"
        }));
        let rendered = serde_json::to_string(&catalog).unwrap();
        assert!(!rendered.contains("api_key"));
    }

    #[test]
    fn model_catalog_reads_codex_structured_model_catalog() {
        let home = temp_test_dir("codex-model-catalog");
        let catalog_path = home
            .join(".codex")
            .join("model-catalogs")
            .join("available.json");
        fs::create_dir_all(catalog_path.parent().unwrap()).unwrap();
        fs::write(
            &catalog_path,
            json!({
                "models": [
                    {
                        "slug": "gpt-5.4",
                        "display_name": "gpt-5.4",
                        "supported_reasoning_levels": [
                            {"effort": "medium"}
                        ]
                    },
                    {
                        "slug": "gpt-5.4-mini",
                        "display_name": "GPT-5.4-Mini",
                        "supported_reasoning_levels": [
                            {"effort": "low"},
                            {"effort": "medium"},
                            {"effort": "high"},
                            {"effort": "xhigh"}
                        ]
                    },
                    {
                        "slug": "deepseek-v4-pro",
                        "display_name": "DeepSeek V4 Pro",
                        "supported_reasoning_levels": [
                            {"effort": "high"}
                        ]
                    },
                    {
                        "slug": "codex-auto-review",
                        "display_name": "Codex Auto Review",
                        "visibility": "hide",
                        "supported_reasoning_levels": [
                            {"effort": "high"}
                        ]
                    }
                ]
            })
            .to_string(),
        )
        .unwrap();

        let catalog = model_catalog_for_target(
            "codex",
            None,
            None,
            None,
            &json!({
                "homeDir": display_path(home),
                "includeHistoryModelCatalog": false,
            }),
        );
        let models = catalog["models"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["name"] == "gpt-5.4"
                && model["displayName"] == "GPT-5.4"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("medium"))
        }));
        assert!(models.iter().any(|model| {
            model["name"] == "gpt-5.4-mini"
                && model["displayName"] == "GPT-5.4-Mini"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("xhigh"))
        }));
        assert!(models.iter().any(|model| {
            model["name"] == "deepseek-v4-pro"
                && model["displayName"] == "DeepSeek V4 Pro"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("high"))
        }));
        assert!(
            !models
                .iter()
                .any(|model| model["name"] == "codex-auto-review")
        );
    }

    #[test]
    fn model_catalog_reads_claude_code_settings_models() {
        let home = temp_test_dir("claude-code-model-catalog");
        let settings_path = home.join(".claude").join("settings.json");
        fs::create_dir_all(settings_path.parent().unwrap()).unwrap();
        fs::write(
            &settings_path,
            json!({
                "env": {
                    "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-flash",
                    "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-pro",
                    "CLAUDE_CODE_EFFORT_LEVEL": "xhigh"
                }
            })
            .to_string(),
        )
        .unwrap();

        let catalog = model_catalog_for_target(
            "claude-code",
            None,
            None,
            None,
            &json!({
                "homeDir": display_path(home),
                "includeHistoryModelCatalog": false,
            }),
        );
        let models = catalog["models"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["name"] == "deepseek-v4-pro[1m]"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("xhigh"))
        }));
        assert!(
            models
                .iter()
                .any(|model| model["name"] == "deepseek-v4-flash")
        );
        assert!(
            models
                .iter()
                .any(|model| model["name"] == "deepseek-v4-pro")
        );
    }

    #[test]
    fn model_catalog_preserves_antigravity_available_model_names() {
        let catalog = model_catalog_for_target(
            "antigravity",
            None,
            None,
            None,
            &json!({
                "includeHistoryModelCatalog": false,
                "antigravityAvailableModelsJson": json!({
                    "models": {
                        "gemini-flash-medium": {
                            "displayName": "Gemini 3.5 Flash (Medium)",
                            "quotaInfo": {"remainingFraction": 0.8}
                        },
                        "claude-opus-thinking": {
                            "displayName": "Claude Opus 4.6 (Thinking)",
                            "quotaInfo": {"remainingFraction": 0.6}
                        }
                    }
                }).to_string()
            }),
        );

        let names = catalog["models"]
            .as_array()
            .unwrap()
            .iter()
            .map(|model| model["name"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert!(names.contains(&"Gemini 3.5 Flash (Medium)"));
        assert!(names.contains(&"Claude Opus 4.6 (Thinking)"));
    }

    #[test]
    fn model_catalog_reads_antigravity_cli_model_lines() {
        let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
        let added = collect_model_catalog_from_cli_lines(
            r#"
Gemini 3.5 Flash (Medium)
Gemini 3.5 Flash (High)
Claude Opus 4.6 (Thinking)
"#,
            "antigravity-cli:models",
            &mut entries,
        );

        assert_eq!(added, 3);
        assert!(entries.values().any(|entry| {
            entry.name == "Gemini 3.5 Flash (Medium)" && entry.provider.is_none()
        }));
        assert!(entries.values().all(|entry| !entry.provider_inferred));
    }

    #[test]
    fn model_collection_cache_reads_root_model_array() {
        let dir = temp_test_dir("model-catalog-cache");
        let cache_path = dir.join("models.json");
        fs::write(
            &cache_path,
            json!([
                {
                    "id": "gpt-5.5",
                    "name": "GPT-5.5",
                    "vendor": "OpenAI"
                },
                {
                    "id": "claude-sonnet-4.6",
                    "name": "Claude Sonnet 4.6",
                    "vendor": "Anthropic"
                }
            ])
            .to_string(),
        )
        .unwrap();

        let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
        let mut diagnostics = Vec::<Value>::new();
        collect_model_catalog_from_model_collection_path(
            &cache_path,
            "model-cache",
            &mut entries,
            &mut diagnostics,
        );

        assert!(diagnostics.is_empty());
        assert!(entries.values().any(|entry| {
            entry.name == "GPT-5.5" && entry.provider.as_deref() == Some("OpenAI")
        }));
        assert!(entries.values().any(|entry| {
            entry.name == "Claude Sonnet 4.6" && entry.provider.as_deref() == Some("Anthropic")
        }));
    }

    #[test]
    fn kilo_model_catalog_reads_vscode_state_and_local_db() {
        let home = temp_test_dir("kilo-model-catalog");
        let vscode_state = home
            .join("Library")
            .join("Application Support")
            .join("Code")
            .join("User")
            .join("globalStorage")
            .join("state.vscdb");
        fs::create_dir_all(vscode_state.parent().unwrap()).unwrap();
        let connection = Connection::open(&vscode_state).unwrap();
        connection
            .execute(
                "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                (
                    "kilocode.kilo-code",
                    json!({
                        "recentModels": [
                            {
                                "providerID": "kilo",
                                "modelID": "anthropic/claude-opus-4.6",
                                "variant": "max"
                            }
                        ],
                        "favoriteModels": [
                            {
                                "providerID": "kilo",
                                "modelID": "~anthropic/claude-opus-latest"
                            }
                        ],
                        "variantSelections": {
                            "agent/code/kilo/anthropic/claude-opus-4.6": "low"
                        }
                    })
                    .to_string(),
                ),
            )
            .unwrap();
        drop(connection);

        let kilo_db = home
            .join(".local")
            .join("share")
            .join("kilo")
            .join("kilo.db");
        fs::create_dir_all(kilo_db.parent().unwrap()).unwrap();
        let connection = Connection::open(&kilo_db).unwrap();
        connection
            .execute(
                "CREATE TABLE session_message (type TEXT, time_created INTEGER, data TEXT)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO session_message (type, time_created, data) VALUES (?1, ?2, ?3)",
                (
                    "model-switched",
                    1_i64,
                    json!({
                        "model": {
                            "providerID": "kilo",
                            "id": "deepseek/deepseek-v4",
                            "variant": "default"
                        }
                    })
                    .to_string(),
                ),
            )
            .unwrap();
        drop(connection);

        let catalog = model_catalog_for_target(
            "kilo-code",
            None,
            None,
            None,
            &json!({
                "homeDir": display_path(home),
                "includeHistoryModelCatalog": false,
            }),
        );
        let models = catalog["models"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["name"] == "anthropic/claude-opus-4.6"
                && model["providerId"] == "kilo"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("max"))
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("low"))
        }));
        assert!(
            models
                .iter()
                .any(|model| model["name"] == "~anthropic/claude-opus-latest"
                    && model["providerId"] == "kilo")
        );
        assert!(
            models
                .iter()
                .any(|model| model["name"] == "deepseek/deepseek-v4"
                    && model["providerId"] == "kilo")
        );
    }

    #[test]
    fn remote_history_roots_cover_known_remote_targets() {
        let overrides = json!({
            "execution-location": "docker",
            "remote-id": "known-target-box"
        });
        for target in [
            "antigravity",
            "claude-code",
            "code",
            "codex",
            "copilot",
            "cursor",
            "hermes",
            "kilo-code",
            "kimi",
            "kimi-code",
            "openclaw",
            "opencode",
        ] {
            assert!(
                !remote_history_roots_for(target, Some(&overrides)).is_empty(),
                "expected remote history roots for {}",
                target
            );
        }
    }

    #[test]
    fn windows_default_config_paths_use_appdata_not_macos_application_support() {
        let home = PathBuf::from(r"C:\Profile\lico");
        let app_data = home.join("AppData").join("Roaming");
        let code = default_config_path_for_platform("code", "windows", &home, &app_data).unwrap();
        let cursor =
            default_config_path_for_platform("cursor", "windows", &home, &app_data).unwrap();
        let opencode =
            default_config_path_for_platform("opencode", "windows", &home, &app_data).unwrap();
        let kilo =
            default_config_path_for_platform("kilo-code", "windows", &home, &app_data).unwrap();
        let codex = default_config_path_for_platform("codex", "windows", &home, &app_data).unwrap();

        for path in [&code, &cursor, &opencode, &kilo] {
            let display = path.to_string_lossy();
            assert!(display.contains("AppData"));
            assert!(!display.contains("Library"));
            assert!(!display.contains("Application Support"));
        }
        assert!(code.ends_with(Path::new("Code").join("User").join("settings.json")));
        assert!(
            cursor.ends_with(
                Path::new("Cursor")
                    .join("User")
                    .join("globalStorage")
                    .join("saoudrizwan.claude-dev")
                    .join("settings")
                    .join("cline_mcp_settings.json")
            )
        );
        assert!(opencode.ends_with(Path::new("opencode").join("opencode.jsonc")));
        assert!(kilo.ends_with(Path::new("kilo").join("kilo.json")));
        assert_eq!(codex, home.join(".codex").join("config.toml"));
    }

    #[test]
    fn kimi_default_paths_use_expected_platform_locations() {
        let home = PathBuf::from("<user-home>");
        let app_data = home.join("Library").join("Application Support");
        let config = default_config_path_for_platform("kimi", "macos", &home, &app_data).unwrap();
        assert!(config.ends_with(Path::new("Kimi").join("config.json")));
        assert!(config.starts_with(&app_data));
        let detection = default_detection_paths_for_platform("kimi", "macos", &home, &app_data);
        assert!(detection.iter().any(|path| path.ends_with("Kimi")));
        assert!(
            detection
                .iter()
                .any(|path| path.ends_with("com.moonshot.kimi"))
        );

        let home = PathBuf::from(r"X:\Profile\example");
        let app_data = home.join("AppData").join("Roaming");
        let config = default_config_path_for_platform("kimi", "windows", &home, &app_data).unwrap();
        assert!(config.ends_with(Path::new("Kimi").join("config.json")));
        assert!(config.starts_with(&app_data));
        let detection = default_detection_paths_for_platform("kimi", "windows", &home, &app_data);
        assert!(detection.iter().any(|path| path.ends_with("Kimi")));
        assert!(
            detection
                .iter()
                .any(|path| path.ends_with("com.moonshot.kimi"))
        );

        let home = PathBuf::from("<user-home>");
        let app_data = home.join(".local").join("share");
        let config = default_config_path_for_platform("kimi", "linux", &home, &app_data).unwrap();
        assert!(config.ends_with(Path::new("Kimi").join("config.json")));
        assert!(config.starts_with(home.join(".config")));
        let detection = default_detection_paths_for_platform("kimi", "linux", &home, &app_data);
        assert!(detection.iter().any(|path| path.ends_with("Kimi")));
        assert!(
            detection
                .iter()
                .any(|path| path.ends_with(".local/share/Kimi"))
        );
    }

    #[test]
    fn cursor_detection_keeps_desktop_state_and_acp_cli_candidates_separate() {
        let home = temp_test_dir("cursor-persistent-detection");
        let app_data = home.join("Library").join("Application Support");
        let cursor_state = app_data.join("Cursor");
        fs::create_dir_all(&cursor_state).unwrap();

        assert_eq!(
            default_detection_path_for_platform("cursor", "macos", &home, &app_data),
            Some(cursor_state)
        );
        let cursor = target_def("cursor").unwrap();
        assert_eq!(cursor.label, "Cursor - IDE");
        assert_eq!(cursor.binary_names, &["cursor-agent", "cursor"]);
        assert!(!cursor.process_names.contains(&"agent"));
        assert!(cursor.process_names.contains(&"cursor"));
    }

    #[test]
    fn kimi_code_target_uses_official_cli_home_and_binary() {
        let home = temp_test_dir("kimi-code-target");
        let app_data = home.join("Library").join("Application Support");
        let default_root = home.join(".kimi-code");
        fs::create_dir_all(default_root.join("sessions")).unwrap();

        assert_eq!(
            default_config_path_for_platform("kimi-code", "macos", &home, &app_data),
            Some(default_root.join("config.toml"))
        );
        assert_eq!(
            default_detection_path_for_platform("kimi-code", "macos", &home, &app_data),
            Some(default_root.join("sessions"))
        );

        let custom_root = home.join("custom-kimi-code");
        assert_eq!(
            kimi_code_home_override(
                &json!({"kimiCodeHome": custom_root.to_string_lossy()}),
                &home,
            ),
            Some(custom_root)
        );

        let target = target_def("kimi-code").unwrap();
        assert_eq!(target.label, "Kimi Code - CLI");
        assert_eq!(target.kind, "cli");
        assert_eq!(target.binary_names, &["kimi"]);
        assert!(!target.process_names.contains(&"com.moonshot.kimi"));
        assert!(target_uses_running_process_detection("kimi-code"));

        let desktop = target_def("kimi").unwrap();
        assert_eq!(desktop.label, "Kimi - Desktop");
        assert_eq!(desktop.kind, "desktop-agent");
        assert!(desktop.binary_names.is_empty());
        assert!(desktop.process_names.contains(&"com.moonshot.kimi"));
        assert!(target_uses_running_process_detection("kimi"));
    }

    #[test]
    fn kilo_code_detection_paths_include_vscode_global_storage() {
        let home = PathBuf::from("<user-home>");
        let app_data = home.join("Library").join("Application Support");
        let paths = default_detection_paths_for_platform("kilo-code", "macos", &home, &app_data);

        assert!(paths.iter().any(|path| {
            path.ends_with(
                Path::new("Code")
                    .join("User")
                    .join("globalStorage")
                    .join("kilocode.kilo-code"),
            )
        }));
        assert!(paths.iter().any(|path| {
            path.ends_with(
                Path::new("Cursor")
                    .join("User")
                    .join("globalStorage")
                    .join("kilocode.kilo-code"),
            )
        }));
    }

    #[test]
    fn kilo_code_detection_path_uses_global_storage_when_present() {
        let home = temp_test_dir("kilo-global-storage");
        let app_data = home.join("Library").join("Application Support");
        let storage = home
            .join("Library")
            .join("Application Support")
            .join("Code")
            .join("User")
            .join("globalStorage")
            .join("kilocode.kilo-code");
        fs::create_dir_all(&storage).unwrap();

        let detected =
            default_detection_path_for_platform("kilo-code", "macos", &home, &app_data).unwrap();

        assert_eq!(detected, storage);
    }

    #[test]
    fn kilo_code_detection_path_uses_extension_install_dir_when_present() {
        let home = temp_test_dir("kilo-extension-dir");
        let app_data = home.join(".config");
        let extension = home
            .join(".vscode")
            .join("extensions")
            .join("kilocode.kilo-code-4.0.0");
        fs::create_dir_all(&extension).unwrap();

        let detected =
            default_detection_path_for_platform("kilo-code", "linux", &home, &app_data).unwrap();

        assert_eq!(detected, extension);
    }

    #[test]
    fn kilo_code_uses_running_process_detection() {
        assert!(target_uses_running_process_detection("kilo-code"));
    }

    #[test]
    fn scan_uses_running_process_names_as_local_detection_signal() {
        let dir = temp_test_dir("running-process-target-scan");
        let scan = scan_targets_with_params(&json!({
            "includeAccessibleEnvironments": false,
            "stateRoot": display_path(dir.join("future-client")),
            "runningProcessNames": ["openclaw.exe"]
        }))
        .unwrap();

        let openclaw = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["target"] == "openclaw")
            .unwrap();
        assert_eq!(openclaw["status"], "detected");
        assert!(openclaw["detail"].as_str().unwrap().contains("process:"));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn find_binary_in_dirs_accepts_windows_command_wrappers() {
        let dir = temp_test_dir("windows-command-wrapper");
        let wrapper = dir.join("codex.cmd");
        fs::write(&wrapper, "@echo off\r\n").unwrap();

        let found = find_binary_in_dirs(&["codex"], &[dir]).unwrap();
        assert!(
            found
                .to_string_lossy()
                .eq_ignore_ascii_case(&wrapper.to_string_lossy())
        );
    }

    #[test]
    fn targets_add_persists_manual_entry_and_scan_uses_it() {
        let dir = temp_test_dir("manual-target");
        let state_root = dir.join("future-client");
        let config_path = dir.join("openclaw-mcp.json");
        let history_root = dir.join("openclaw-history");

        let added = add_target(&json!({
            "target": "openclaw",
            "stateRoot": display_path(state_root.clone()),
            "configPath": display_path(config_path.clone()),
            "historyRoot": display_path(history_root.clone()),
            "label": "OpenClaw VM"
        }))
        .unwrap();

        assert_eq!(added["ok"], true);
        assert_eq!(added["record"]["target"], "openclaw");
        assert_eq!(added["activity"]["type"], "target.manual.saved");

        let store =
            crate::platform::client_state::ClientStateStore::new(state_root.clone()).unwrap();
        let saved = store.read_collection("targets").unwrap();
        assert_eq!(saved["items"][0]["target"], "openclaw");
        assert_eq!(saved["items"][0]["manual"], true);
        assert_eq!(
            saved["items"][0]["historyRoots"][0],
            display_path(history_root.clone())
        );

        let scan = scan_targets_with_params(&json!({
            "stateRoot": display_path(state_root.clone())
        }))
        .unwrap();
        let openclaw = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["target"] == "openclaw")
            .unwrap();
        assert_eq!(openclaw["manual"], true);
        assert_eq!(openclaw["label"], "OpenClaw VM");
        assert_eq!(openclaw["status"], "manual");
        assert_eq!(openclaw["configPath"], display_path(config_path.clone()));
        assert_eq!(
            openclaw["historyRoots"][0],
            display_path(history_root.clone())
        );

        let inspected = inspect_target_with_params(&json!({
            "target": "openclaw",
            "stateRoot": display_path(state_root.clone())
        }))
        .unwrap();
        assert_eq!(inspected["target"]["manual"], true);
        assert_eq!(
            inspected["target"]["configPath"],
            display_path(config_path.clone())
        );
        assert_eq!(
            inspected["target"]["historyRoots"][0],
            display_path(history_root)
        );

        let plan = mcp_config_plan(&json!({
            "target": "openclaw",
            "stateRoot": display_path(state_root)
        }))
        .unwrap();
        assert_eq!(plan["plan"]["configPath"], display_path(config_path));
    }

    #[test]
    fn opencode_plan_exposes_real_remote_mcp_shape() {
        let plan = mcp_config_plan(&json!({"target": "opencode"})).unwrap();
        let fields = plan["plan"]["fields"].as_array().unwrap();
        let paths = fields
            .iter()
            .map(|item| item["path"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert!(paths.contains(&"mcp.lico.url"));
        assert!(paths.contains(&"mcp.lico.headers.X-LicoLite-Api-Key"));
        assert!(paths.contains(&"mcp.lico.enabled"));
    }

    #[test]
    fn mcp_config_plan_uses_discovery_file_endpoint_before_default() {
        let dir = temp_test_dir("discovery-file");
        let discovery_file = dir.join("mcp-discovery.json");
        fs::write(
            &discovery_file,
            r#"{"httpUrl":"http://lico-device.local:7228/mcp"}"#,
        )
        .unwrap();

        let plan = mcp_config_plan(&json!({
            "target": "opencode",
            "discoveryFile": display_path(discovery_file)
        }))
        .unwrap();
        let fields = plan["plan"]["fields"].as_array().unwrap();
        let url = fields
            .iter()
            .find(|item| item["path"] == "mcp.lico.url")
            .and_then(|item| item["value"].as_str())
            .unwrap();
        assert_eq!(url, "http://lico-device.local:7228/mcp");
    }

    #[test]
    fn mcp_config_plan_uses_active_registry_server_endpoint() {
        let dir = temp_test_dir("registry-file");
        let registry_file = dir.join("servers.json");
        fs::write(
            &registry_file,
            r#"{
  "activeServer": "vm",
  "servers": {
    "local": { "httpUrl": "http://127.0.0.1:7228/mcp" },
    "vm": { "httpUrl": "http://orbstack-host.local:7228/mcp" }
  }
}"#,
        )
        .unwrap();

        let plan = mcp_config_plan(&json!({
            "target": "opencode",
            "registryFile": display_path(registry_file)
        }))
        .unwrap();
        let fields = plan["plan"]["fields"].as_array().unwrap();
        let url = fields
            .iter()
            .find(|item| item["path"] == "mcp.lico.url")
            .and_then(|item| item["value"].as_str())
            .unwrap();
        assert_eq!(url, "http://orbstack-host.local:7228/mcp");
    }

    #[test]
    fn config_write_opencode_apply_uses_snapshot_and_preserves_unrelated_config() {
        let dir = temp_test_dir("opencode-apply");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("future-client");
        fs::write(
            &config_path,
            r#"{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "other": {
      "type": "remote",
      "url": "https://example.test/mcp",
      "enabled": true
    }
  }
}"#,
        )
        .unwrap();

        let discovery_file = dir.join("mcp-discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let result = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root.clone()),
            "discoveryFile": display_path(discovery_file.clone()),
            "token": "test-token"
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(result["status"], "applied");
        let updated: Value =
            serde_json::from_str(&fs::read_to_string(&config_path).unwrap()).unwrap();
        assert_eq!(updated["$schema"], "https://opencode.ai/config.json");
        assert_eq!(updated["mcp"]["other"]["url"], "https://example.test/mcp");
        assert_eq!(updated["mcp"]["lico"]["type"], "remote");
        assert_eq!(updated["mcp"]["lico"]["url"], "http://127.0.0.1:7228/mcp");
        assert_eq!(
            updated["mcp"]["lico"]["headers"]["X-LicoLite-Api-Key"],
            "test-token"
        );
        assert_eq!(updated["mcp"]["lico"]["enabled"], true);
        let snapshot_path = PathBuf::from(result["snapshotPath"].as_str().unwrap());
        assert!(snapshot_path.exists());
        assert!(snapshot_path.starts_with(state_root.join("snapshots")));
        assert!(!dir.join(".lico-snapshots").exists());
        assert_eq!(result["activity"]["type"], "mcp.config.applied");
        let store = crate::platform::client_state::ClientStateStore::new(state_root).unwrap();
        let activity = store
            .activity_log()
            .list(&json!({"type": "mcp.config.applied", "target": "opencode"}))
            .unwrap();
        assert_eq!(activity["events"].as_array().unwrap().len(), 1);
        let snapshots = store
            .snapshot_store()
            .list(&json!({"target": "opencode"}))
            .unwrap();
        assert_eq!(snapshots["snapshots"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn config_write_rollback_restores_snapshot_content() {
        let dir = temp_test_dir("opencode-rollback");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("future-client");
        let original = r#"{"mcp":{"other":{"enabled":true}}}"#;
        fs::write(&config_path, original).unwrap();

        let discovery_file = dir.join("mcp-discovery.json");
        signed_receipt_discovery("http://localhost:7228", &discovery_file);

        let apply = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root.clone()),
            "discoveryFile": display_path(discovery_file),
            "token": "rollback-token"
        }))
        .unwrap();
        assert_ne!(fs::read_to_string(&config_path).unwrap(), original);

        let rollback = mcp_config_rollback(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root.clone()),
            "snapshotId": apply["snapshotId"].as_str().unwrap()
        }))
        .unwrap();

        assert_eq!(rollback["ok"], true);
        assert_eq!(rollback["restoredSnapshotId"], apply["snapshotId"]);
        assert_eq!(rollback["activity"]["type"], "mcp.config.rolled_back");
        assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
    }

    #[test]
    fn config_write_snapshot_redacts_existing_credentials() {
        let dir = temp_test_dir("opencode-redacted-rollback");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("future-client");
        fs::write(
            &config_path,
            r#"{"mcp":{"lico":{"type":"remote","url":"http://old.example/mcp","headers":{"X-LicoLite-Api-Key":"old-token"},"enabled":true}}}"#,
        )
        .unwrap();

        let discovery_file = dir.join("mcp-discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let apply = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root.clone()),
            "discoveryFile": display_path(discovery_file),
            "token": "new-token"
        }))
        .unwrap();
        let snapshot_path = PathBuf::from(apply["snapshotPath"].as_str().unwrap());
        let snapshot_raw = fs::read_to_string(snapshot_path).unwrap();
        assert!(!snapshot_raw.contains("old-token"));
        assert!(snapshot_raw.contains("<redacted-secret>"));

        let rollback = mcp_config_rollback(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root),
            "snapshotId": apply["snapshotId"].as_str().unwrap()
        }))
        .unwrap();

        assert_eq!(rollback["redactionApplied"], true);
        let restored = fs::read_to_string(&config_path).unwrap();
        assert!(restored.contains("<redacted-secret>"));
        assert!(!restored.contains("old-token"));
        assert!(!restored.contains("new-token"));
    }

    #[test]
    fn config_write_expected_hash_prevents_stale_overwrite() {
        let dir = temp_test_dir("opencode-conflict");
        let config_path = dir.join("opencode.jsonc");
        fs::write(&config_path, r#"{"mcp":{}}"#).unwrap();

        let discovery_file = dir.join("mcp-discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let result = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "expectedHash": "stale",
            "token": "blocked",
            "discoveryFile": display_path(discovery_file.clone())
        }))
        .unwrap();

        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "field_conflict");
        assert_eq!(fs::read_to_string(&config_path).unwrap(), r#"{"mcp":{}}"#);
    }

    #[test]
    fn targets_public_inspect_entrypoint_uses_default_scan_path() {
        let inspected = inspect_target("opencode").unwrap();
        assert_eq!(inspected["target"]["target"], "opencode");
    }

    #[test]
    fn targets_target_params_and_aliases_are_normalized() {
        assert_eq!(
            target_param(&json!({"positionals": ["open_code"]})).unwrap(),
            "opencode"
        );
        assert_eq!(normalize_target("vscode"), "code");
        assert_eq!(normalize_target("claude"), "claude-code");
        assert_eq!(normalize_target("kilo-code"), "kilo-code");
        assert_eq!(normalize_target("kimi_code"), "kimi-code");
        assert_eq!(normalize_target("kimi-code"), "kimi-code");
        assert_eq!(normalize_target("moonshot"), "moonshot");
        assert_eq!(normalize_target("moonshot"), "moonshot");
        assert_eq!(normalize_target("kimi"), "kimi");
    }

    #[test]
    fn targets_add_updates_existing_manual_entry_created_at() {
        let dir = temp_test_dir("manual-update");
        let state_root = dir.join("future-client");
        let first = add_target(&json!({
            "target": "opencode",
            "stateRoot": display_path(state_root.clone()),
            "label": "First"
        }))
        .unwrap();
        let second = add_target(&json!({
            "target": "opencode",
            "stateRoot": display_path(state_root),
            "label": "Second"
        }))
        .unwrap();
        assert_eq!(first["record"]["createdAt"], second["record"]["createdAt"]);
        assert_eq!(second["record"]["label"], "Second");
    }

    #[test]
    fn targets_config_apply_raises_missing_path_for_target_without_default_path() {
        let result = mcp_config_apply(&json!({"target": "openclaw"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "missing_config_path");
    }

    #[test]
    fn targets_rollback_from_snapshot_path_without_snapshot_store() {
        let dir = temp_test_dir("rollback-path");
        let state_root = dir.join("future-client");
        let config_path = dir.join("opencode.jsonc");
        fs::write(&config_path, r#"{"existing":true}"#).unwrap();
        let snapshot_path = dir.join("snapshot.json");
        let snapshot = json!({
            "schemaVersion": 1,
            "snapshotId": "manual-snapshot",
            "sourcePath": display_path(config_path.clone()),
            "existed": true,
            "content": r#"{"rollback":"snapshot"}"#
        });
        fs::write(
            &snapshot_path,
            serde_json::to_string_pretty(&snapshot).unwrap(),
        )
        .unwrap();

        let result = mcp_config_rollback(&json!({
            "target": "opencode",
            "stateRoot": display_path(state_root),
            "snapshotPath": display_path(snapshot_path)
        }))
        .unwrap();
        assert_eq!(result["status"], "rolled_back");
        assert_eq!(result["restoredSnapshotId"], "manual-snapshot");
        assert_eq!(
            fs::read_to_string(&config_path).unwrap(),
            r#"{"rollback":"snapshot"}"#
        );
    }

    #[test]
    fn targets_rollback_snapshot_path_removes_config_when_snapshot_marked_missing() {
        let dir = temp_test_dir("rollback-missing");
        let state_root = dir.join("future-client");
        let config_path = dir.join("opencode.jsonc");
        fs::write(&config_path, r#"{"before":true}"#).unwrap();
        let snapshot_path = dir.join("snapshot-missing.json");
        let snapshot = json!({
            "schemaVersion": 1,
            "snapshotId": "manual-snapshot",
            "sourcePath": display_path(config_path.clone()),
            "existed": false,
            "content": r#"{"new":"snapshot"}"#
        });
        fs::write(
            &snapshot_path,
            serde_json::to_string_pretty(&snapshot).unwrap(),
        )
        .unwrap();

        let result = mcp_config_rollback(&json!({
            "target": "opencode",
            "stateRoot": display_path(state_root),
            "snapshotPath": display_path(snapshot_path)
        }))
        .unwrap();
        assert_eq!(result["status"], "rolled_back");
        assert!(!config_path.exists());
    }

    #[test]
    fn targets_scan_candidate_discovery_variants_are_supported() {
        assert_eq!(
            extract_discovery_base_url(&json!({"discovery": {"httpUrl": "http://discovery:7228"}}))
                .unwrap(),
            "http://discovery:7228"
        );
        assert_eq!(
            extract_discovery_base_url(
                &json!({"candidates": [{"httpUrl": "http://candidate:7228/mcp"}]})
            )
            .unwrap(),
            "http://candidate:7228/mcp"
        );
    }

    #[test]
    fn targets_target_path_and_patch_helpers_cover_error_paths() {
        let root = json!({"mcp": 1});
        let mut root_map = root.as_object().cloned().unwrap_or_default();
        let err = set_json_path(&mut root_map, "mcp.enabled", json!(true));
        assert!(err.is_err());
        assert!(err.unwrap_err().to_string().contains("field_conflict"));
        assert_eq!(root_map["mcp"], json!(1));

        let mut empty = json!({});
        let mut empty_map = empty.as_object_mut().unwrap();
        assert!(set_json_path(&mut empty_map, "", json!(1)).is_err());
    }

    #[test]
    fn targets_strip_json_comments_handles_line_and_block_forms() {
        let stripped = strip_json_comments(
            r#"{"mcp":{"x":1}} // line
            /* block */
            {"mcp":{"y":2}}"#,
        );
        let compact = stripped.replace('\n', "");
        assert!(compact.contains(r#"{"mcp":{"x":1}}"#));
        assert!(compact.contains(r#"{"mcp":{"y":2}}"#));
        assert!(!compact.to_lowercase().contains("line"));
        assert!(!compact.to_lowercase().contains("block"));
    }

    #[test]
    fn targets_apply_helpers_hit_error_and_normalized_input_paths() {
        let current = r#"{ "mcp": {"enabled": true}, /* comment */ "other": 1 }"#;
        let updated =
            apply_json_patch("opencode", current, "http://127.0.0.1:7228", "token").unwrap();
        assert!(updated.contains("\"mcp\""));
        assert!(updated.contains("\"url\""));
        assert!(updated.contains("127.0.0.1:7228/mcp"));

        let codex_patch = apply_codex_patch("", "http://127.0.0.1:7228").unwrap();
        assert!(codex_patch.contains("LICO_MCP_TOKEN"));

        let unknown = apply_structured_patch("codex", "", "http://127.0.0.1:7228", "token");
        assert!(unknown.is_err());

        assert!(apply_json_patch("opencode", "[", "http://127.0.0.1:7228", "token").is_err());
    }

    #[test]
    fn targets_token_ref_comes_from_env_when_not_set() {
        let token = token_ref_with_env(
            &json!({"target": "opencode"}),
            Some("token-from-env".to_string()),
        );
        assert_eq!(token, "token-from-env");
    }

    #[test]
    fn targets_base_url_uses_env_when_not_in_params() {
        let base_url = normalize_base_url_with_env(
            &json!({"target": "opencode"}),
            Some("http://env-mcp:7228".to_string()),
        );
        assert_eq!(base_url, "http://env-mcp:7228");
    }

    #[test]
    fn targets_target_field_and_patch_variants_are_covered() {
        let codex = target_fields("codex")
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["path"].as_str().unwrap_or_default().to_string())
            .collect::<Vec<_>>();
        assert!(codex.contains(&"mcp_servers.lico.url".to_string()));
        assert!(codex.contains(&"mcp_servers.lico.bearer_token_env_var".to_string()));

        let antigravity = target_fields("antigravity")
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["path"].as_str().unwrap_or_default().to_string())
            .collect::<Vec<_>>();
        assert!(antigravity.contains(&"mcpServers.lico.serverUrl".to_string()));

        let kilo = target_fields("kilo-code")
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["path"].as_str().unwrap_or_default().to_string())
            .collect::<Vec<_>>();
        assert!(kilo.contains(&"mcp.lico.type".to_string()));

        let hermes = target_fields("hermes")
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["path"].as_str().unwrap_or_default().to_string())
            .collect::<Vec<_>>();
        assert!(
            hermes
                .iter()
                .any(|item| item.starts_with("hermes.mcp.lico"))
        );

        let cursor = target_fields("cursor")
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["path"].as_str().unwrap_or_default().to_string())
            .collect::<Vec<_>>();
        assert!(
            cursor
                .iter()
                .any(|item| item.contains("mcpServers.lico.command"))
        );
        assert!(cursor.contains(&"mcpServers.lico.args".to_string()));

        assert!(target_fields("mystery").as_array().unwrap().is_empty());
    }

    #[test]
    fn targets_target_apply_helpers_cover_empty_and_structured_variants() {
        let empty_json =
            apply_json_patch("opencode", "", "http://127.0.0.1:7228", "token").unwrap();
        assert!(empty_json.contains("\"mcp\""));

        let codex = apply_codex_patch("", "http://127.0.0.1:7228").unwrap();
        assert!(codex.contains("LICO_MCP_TOKEN"));

        let antigravity =
            apply_json_patch("antigravity", "{}", "http://127.0.0.1:7228", "token").unwrap();
        assert!(antigravity.contains("\"mcpServers\""));
        assert!(antigravity.contains("\"token\""));

        let cursor = json_patch_entries("cursor", "http://127.0.0.1:7228", "token");
        assert_eq!(cursor.len(), 2);
        assert!(
            cursor
                .iter()
                .any(|(path, _)| path == "mcpServers.lico.command")
        );
        assert!(
            cursor
                .iter()
                .any(|(path, _)| path == "mcpServers.lico.args")
        );

        let opencode_patch = json_patch_entries("opencode", "http://127.0.0.1:7228", "token");
        assert_eq!(opencode_patch.len(), 4);
        assert!(
            opencode_patch
                .iter()
                .any(|(path, value)| path == "mcp.lico.url"
                    && value == &json!("http://127.0.0.1:7228/mcp"))
        );

        let unknown = json_patch_entries("unknown", "http://127.0.0.1:7228", "token");
        assert!(unknown.is_empty());
    }

    #[test]
    fn targets_manual_target_filter_skips_invalid_items() {
        let store = test_store("manual-targets-invalid");
        let items = json!({
            "collection": "targets",
            "items": [
                {"target": "", "label": "bad-target"},
                {"target": "non-existent", "label": "missing"},
                {"target": "opencode", "label": "OpenCode"}
            ]
        });
        store.write_collection("targets", items).unwrap();

        let items = manual_targets(&store).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].target, "opencode");
    }

    #[test]
    fn targets_discovery_url_extracts_from_nested_server_variants() {
        assert_eq!(
            extract_discovery_base_url(&json!({"servers":{"active":{"url":"http://active.local:7228/mcp"}, "other":{"url":"http://other.local:7228/mcp"}}, "activeServer":"active"})).unwrap(),
            "http://active.local:7228/mcp"
        );
        assert_eq!(
            extract_discovery_base_url(
                &json!({"server":{"endpoint":"https://example.service:7228/mcp"}})
            )
            .unwrap(),
            "https://example.service:7228/mcp"
        );
        assert_eq!(
            extract_discovery_base_url(
                &json!({"candidates":{"local":{"endpoint":"http://candidate.local:7228/mcp"}}})
            )
            .unwrap(),
            "http://candidate.local:7228/mcp"
        );
        assert!(extract_discovery_base_url(&json!({"server":{"bad":false}})).is_none());
        assert!(blank_url_is_none("   "));
    }

    fn blank_url_is_none(value: &str) -> bool {
        value.trim().trim_end_matches('/').is_empty()
    }

    #[test]
    fn targets_uses_portable_dir_state_root_and_default_config_path_fallback() {
        let dir = temp_test_dir("portable-state-root");
        let portable_root = dir.join("portable");
        fs::create_dir_all(&portable_root).unwrap();
        let state_root = portable_root.join("future-client");
        let _ = state_root;

        let plan = mcp_config_plan(&json!({
            "target": "opencode",
            "baseUrl": "http://127.0.0.1:7228",
            "portableDir": portable_root.to_string_lossy()
        }))
        .unwrap();
        assert_eq!(plan["status"], "planned");

        assert!(default_config_path("openclaw").is_none());
    }

    #[test]
    fn targets_rollback_by_snapshot_id_reuses_snapshot_store() {
        let dir = temp_test_dir("rollback-snapshot-id");
        let config_path = dir.join("opencode.jsonc");
        fs::write(&config_path, "{}").unwrap();
        let state_root = dir.join("future-client");

        let discovery_file = dir.join("mcp-discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let applied = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root.clone()),
            "discoveryFile": display_path(discovery_file.clone()),
            "token": "snapshot-id-token",
        }))
        .unwrap();

        let rollback = mcp_config_rollback(&json!({
            "target": "opencode",
            "stateRoot": display_path(state_root),
            "snapshotId": applied["snapshotId"].as_str().unwrap()
        }))
        .unwrap();
        assert_eq!(rollback["status"], "rolled_back");
        assert_eq!(rollback["target"], "opencode");
    }

    #[test]
    fn plan_apply_allowed_false_for_unsupported_adapter() {
        let plan = mcp_config_plan(&json!({"target": "claude-code"})).unwrap();
        assert_eq!(plan["applyAllowed"], false);
        assert_eq!(plan["applyBlockedReason"], "adapter_unsupported");
        assert_eq!(plan["requiredAction"], "manual_config");
    }

    #[test]
    fn plan_apply_allowed_false_for_codex() {
        let plan = mcp_config_plan(&json!({"target": "codex"})).unwrap();
        assert_eq!(plan["applyAllowed"], false);
        assert_eq!(plan["applyBlockedReason"], "adapter_unsupported");
    }

    #[test]
    fn plan_apply_allowed_false_for_kilo_code() {
        let plan = mcp_config_plan(&json!({"target": "kilo-code"})).unwrap();
        assert_eq!(plan["applyAllowed"], false);
        assert_eq!(plan["applyBlockedReason"], "adapter_unsupported");
    }

    #[test]
    fn plan_apply_allowed_false_for_hermes() {
        let plan = mcp_config_plan(&json!({"target": "hermes"})).unwrap();
        assert_eq!(plan["applyAllowed"], false);
        assert_eq!(plan["applyBlockedReason"], "adapter_unsupported");
    }

    #[test]
    fn plan_apply_allowed_false_when_verification_required() {
        let dir = temp_test_dir("plan-no-verify");
        let discovery_file = dir.join("discovery.json");
        fs::write(&discovery_file, r#"{"url": "http://127.0.0.1:7228"}"#).unwrap();

        let plan = mcp_config_plan(&json!({
            "target": "opencode",
            "discoveryFile": display_path(discovery_file)
        }))
        .unwrap();
        assert_eq!(plan["applyAllowed"], false);
        assert_eq!(plan["applyBlockedReason"], "verification_required");
    }

    #[test]
    fn plan_apply_allowed_true_with_valid_receipt_and_config_path() {
        let dir = temp_test_dir("plan-valid");
        let config_path = dir.join("opencode.jsonc");
        fs::write(&config_path, "{}").unwrap();
        let discovery_file = dir.join("discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let plan = mcp_config_plan(&json!({
            "target": "opencode",
            "discoveryFile": display_path(discovery_file),
            "configPath": display_path(config_path)
        }))
        .unwrap();
        assert_eq!(plan["applyAllowed"], true);
        assert_eq!(plan["applyBlockedReason"], "none");
    }

    #[test]
    fn apply_forged_discovery_returns_verification_required() {
        let dir = temp_test_dir("apply-forged");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("future-client");
        let original = r#"{"mcp":{"other":{"enabled":true}}}"#;
        fs::write(&config_path, original).unwrap();

        let discovery_file = dir.join("discovery.json");
        forged_discovery("http://127.0.0.1:7228", &discovery_file);

        let result = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root),
            "discoveryFile": display_path(discovery_file)
        }))
        .unwrap();

        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "verification_required");
        assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
    }

    #[test]
    fn apply_unsupported_adapter_returns_unsupported() {
        let result = mcp_config_apply(&json!({"target": "claude-code"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "unsupported_adapter_action");
    }

    #[test]
    fn apply_codex_returns_unsupported() {
        let result = mcp_config_apply(&json!({"target": "codex"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "unsupported_adapter_action");
    }

    #[test]
    fn apply_kilo_code_returns_unsupported() {
        let result = mcp_config_apply(&json!({"target": "kilo-code"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "unsupported_adapter_action");
    }

    #[test]
    fn apply_non_object_path_returns_field_conflict() {
        let dir = temp_test_dir("apply-non-object");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("future-client");
        let original = r#"{"mcp": 1}"#;
        fs::write(&config_path, original).unwrap();

        let discovery_file = dir.join("discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let result = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root),
            "discoveryFile": display_path(discovery_file.clone()),
            "token": "test-token"
        }))
        .unwrap();

        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "field_conflict");
        assert!(!result["conflicts"].as_array().unwrap().is_empty());
        assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
    }

    #[test]
    fn apply_jsonc_with_comments_returns_format_loss() {
        let dir = temp_test_dir("apply-jsonc");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("future-client");
        let original = "{\n  \"mcp\": {},\n  // comment line\n  \"other\": 1\n}";
        fs::write(&config_path, original).unwrap();

        let discovery_file = dir.join("discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let result = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root),
            "discoveryFile": display_path(discovery_file.clone()),
            "token": "test-token"
        }))
        .unwrap();

        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "format_loss_confirmation_required");
        assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
    }

    #[test]
    fn apply_jsonc_with_comments_explicit_rewrite_succeeds() {
        let dir = temp_test_dir("apply-jsonc-explicit");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("future-client");
        let original = "{\n  \"mcp\": {},\n  // comment line\n  \"other\": 1\n}";
        fs::write(&config_path, original).unwrap();

        let discovery_file = dir.join("discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let result = mcp_config_apply(&json!({
            "target": "opencode",
            "configPath": display_path(config_path.clone()),
            "stateRoot": display_path(state_root),
            "discoveryFile": display_path(discovery_file.clone()),
            "explicitFormatRewrite": true,
            "token": "test-token"
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(result["status"], "applied");
        assert_ne!(fs::read_to_string(&config_path).unwrap(), original);
    }

    #[test]
    fn adapter_supports_action_is_unified() {
        assert!(adapter_supports_action("opencode", "mcp.config.apply"));
        assert!(adapter_supports_action("openclaw", "mcp.config.apply"));
        assert!(!adapter_supports_action("codex", "mcp.config.apply"));
        assert!(!adapter_supports_action("claude-code", "mcp.config.apply"));
        assert!(!adapter_supports_action("kilo-code", "mcp.config.apply"));
        assert!(adapter_supports_action("codex", "mcp.config.plan"));
        assert!(!adapter_supports_action("codex", "mcp.plugin.update"));
        assert!(adapter_supports_action("codex", "skill.install"));
        assert!(adapter_supports_action("claude-code", "skill.install"));
        assert!(!adapter_supports_action("copilot", "skill.install"));
        for target in runtime_adapters::PACKAGED_RUNTIME_ADAPTER_IDS {
            assert!(
                !adapter_supports_action(target, "runtime.message.send"),
                "non-ready adapter advertised release sending: {target}"
            );
        }
    }

    #[test]
    fn scan_candidate_has_adapter_capabilities_and_supported_actions() {
        let dir = temp_test_dir("scan-caps");
        let state_root = dir.join("future-client");
        let scan = scan_targets_with_params(&json!({
            "stateRoot": display_path(state_root)
        }))
        .unwrap();

        let opencode = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["target"] == "opencode")
            .unwrap();
        assert_eq!(opencode["adapterStatus"], "implemented");
        assert_eq!(
            opencode["adapterCapabilities"]["configApply"],
            "implemented"
        );
        assert!(
            opencode["supportedActions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "mcp.plugin.update")
        );
        assert_eq!(
            opencode["adapterCapabilities"]["conversationProtocol"],
            runtime_adapters::runtime_driver_profile("opencode")
                .unwrap()
                .protocol
        );
        assert_eq!(
            opencode["adapterCapabilities"]["conversationReadiness"],
            "unverified"
        );
        assert_eq!(
            opencode["adapterCapabilities"]["conversationDriver"],
            "implemented"
        );
        assert_eq!(
            opencode["adapterCapabilities"]["conversationBlocker"],
            "evidence_missing"
        );

        let codex = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["target"] == "codex")
            .unwrap();
        assert_eq!(codex["adapterStatus"], "partial");
        assert_eq!(codex["adapterCapabilities"]["configApply"], "unsupported");
        assert!(
            !codex["supportedActions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "mcp.plugin.update")
        );
        assert!(
            codex["supportedActions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "skill.install")
        );
        assert_eq!(
            codex["adapterCapabilities"]["conversationReadiness"],
            "unverified"
        );
        assert!(
            !codex["supportedActions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "runtime.message.send")
        );

        let copilot = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["target"] == "copilot")
            .unwrap();
        assert_eq!(
            copilot["adapterCapabilities"]["conversationReadiness"],
            "unverified"
        );
        assert!(
            !copilot["supportedActions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "runtime.message.send")
        );

        let cursor = scan["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["target"] == "cursor")
            .unwrap();
        assert!(
            !cursor["supportedActions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "runtime.message.send")
        );
    }

    fn test_store(name: &str) -> crate::platform::client_state::ClientStateStore {
        let dir = temp_test_dir(&format!("target-test-store-{}", name));
        crate::platform::client_state::ClientStateStore::new(dir).unwrap()
    }

    fn temp_test_dir(name: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!("lico-targets-{}-{}", name, snapshot_stamp()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
