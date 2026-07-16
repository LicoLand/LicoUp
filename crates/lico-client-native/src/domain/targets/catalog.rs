use crate::platform::runtime_adapters;
use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::Path;

#[derive(Clone, Debug)]
pub(super) struct TargetDef {
    pub(super) id: &'static str,
    pub(super) label: &'static str,
    pub(super) kind: &'static str,
    pub(super) config_hint: &'static str,
    pub(super) binary_names: &'static [&'static str],
    pub(super) process_names: &'static [&'static str],
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
    pub manual: bool,
    pub adapter_status: String,
    pub adapter_capabilities: AdapterCapabilities,
    pub supported_actions: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scan_source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_catalog: Option<Value>,
}

pub(super) fn target_supports_skill_install(target: &str) -> bool {
    matches!(target, "codex" | "claude-code")
}

pub(super) fn candidate_runtime_is_ready(
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

pub(super) fn adapter_capabilities_for(target: &str) -> AdapterCapabilities {
    let mut capabilities = AdapterCapabilities {
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

pub(super) fn target_defs() -> Vec<TargetDef> {
    vec![
        TargetDef {
            id: "openclaw",
            label: "OpenClaw - CLI",
            kind: "vm-cli",
            config_hint: "OpenClaw runtime configuration",
            binary_names: &["openclaw"],
            process_names: &["openclaw.exe", "openclaw"],
        },
        TargetDef {
            id: "claude-code",
            label: "Claude Code - CLI",
            kind: "cli",
            config_hint: "Claude Code runtime configuration",
            binary_names: &["claude"],
            process_names: &["claude.exe", "claude"],
        },
        TargetDef {
            id: "codex",
            label: "ChatGPT Codex - CLI",
            kind: "cli",
            config_hint: "Codex runtime configuration",
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
            config_hint: "Antigravity runtime configuration",
            binary_names: &["agy", "antigravity"],
            process_names: &["agy.exe", "agy", "antigravity.exe", "antigravity"],
        },
        TargetDef {
            id: "opencode",
            label: "OpenCode - CLI",
            kind: "cli",
            config_hint: "OpenCode runtime configuration",
            binary_names: &["opencode"],
            process_names: &["opencode.exe", "opencode"],
        },
        TargetDef {
            id: "copilot",
            label: "GitHub Copilot - CLI",
            kind: "cli",
            config_hint: "Copilot runtime configuration",
            binary_names: &["copilot"],
            process_names: &["copilot.exe", "copilot"],
        },
        TargetDef {
            id: "kilo-code",
            label: "Kilo Code - CLI",
            kind: "cli",
            config_hint: "Kilo Code runtime configuration",
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
            config_hint: "Cursor runtime configuration and desktop history",
            binary_names: &["cursor-agent", "cursor"],
            process_names: &["cursor-agent.exe", "cursor-agent", "cursor.exe", "cursor"],
        },
        TargetDef {
            id: "hermes",
            label: "Hermes Agent - CLI",
            kind: "vm-cli",
            config_hint: "Hermes Agent runtime configuration",
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
        TargetDef {
            id: "pi",
            label: "Pi Agent - CLI",
            kind: "cli",
            config_hint: "Pi Coding Agent CLI configuration and sessions",
            binary_names: &["pi"],
            process_names: &["pi.exe", "pi"],
        },
    ]
}

pub(super) fn target_def(target: &str) -> Result<TargetDef> {
    let normalized = normalize_target(target);
    target_defs()
        .into_iter()
        .find(|def| def.id == normalized)
        .ok_or_else(|| anyhow!("Unsupported target adapter: {}", target))
}

pub(super) fn normalize_target(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "claude" | "claude_code" | "claudecode" => "claude-code".to_string(),
        "kilo" | "kilo_code" | "kilocode" => "kilo-code".to_string(),
        "vscode" | "vs-code" | "vs_code" => "code".to_string(),
        "github-copilot" => "copilot".to_string(),
        "kimi_code" | "kimicode" => "kimi-code".to_string(),
        "pi-agent" | "pi_agent" | "pi-coding-agent" | "pi_coding_agent" => "pi".to_string(),
        "open-code" | "open_code" => "opencode".to_string(),
        "openclaw-kate" | "openclaw_kate" => "openclaw".to_string(),
        "hermes-agent" | "hermes_serena" | "hermes-serena" => "hermes".to_string(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn canonical_catalog_has_unique_ids_and_aliases_resolve() {
        let defs = target_defs();
        let ids = defs.iter().map(|def| def.id).collect::<BTreeSet<_>>();
        assert_eq!(ids.len(), defs.len());
        assert_eq!(normalize_target("vscode"), "code");
        assert_eq!(normalize_target("kimi_code"), "kimi-code");
        assert_eq!(target_def("claude").unwrap().id, "claude-code");
    }

    #[test]
    fn skill_install_is_limited_to_supported_local_agents() {
        assert!(target_supports_skill_install("claude-code"));
        assert!(target_supports_skill_install("codex"));
        assert!(!target_supports_skill_install("copilot"));
    }
}
