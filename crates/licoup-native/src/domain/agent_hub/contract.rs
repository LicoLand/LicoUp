//! Agent Hub contract: recipe registry, capabilities, ownership, and lifecycle.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const SCHEMA_VERSION: &str = "v0.0.1:client-agent-install-recipes-1";
pub const HOST_SCOPE: &str = "desktop";
pub const PLUGIN_MANAGEMENT_BOUNDARY: &str = "adapter-plugins-only";
pub const FIRST_BATCH_IDS: [&str; 8] = [
    "codex",
    "cursor",
    "opencode",
    "claude-code",
    "pi",
    "openclaw",
    "hermes",
    "antigravity",
];
pub const DEEP_ADAPTATION_IDS: [&str; 7] = [
    "codex",
    "cursor",
    "opencode",
    "claude-code",
    "pi",
    "openclaw",
    "hermes",
];
pub const PARTIAL_ADAPTATION_ID: &str = "antigravity";

pub const ADAPTATION_DEEP: &str = "deep";
pub const ADAPTATION_PARTIAL: &str = "partial";
pub const ADAPTATION_PENDING: &str = "pending-evaluation";

pub const OWNERSHIP_NONE: &str = "none";
pub const OWNERSHIP_EXTERNAL: &str = "external";
pub const OWNERSHIP_OWNED: &str = "owned";

pub const LIFECYCLE_DISCOVERED: &str = "discovered";
pub const LIFECYCLE_PLANNED: &str = "planned";
pub const LIFECYCLE_CONFIRMED: &str = "confirmed";
pub const LIFECYCLE_APPLYING: &str = "applying";
pub const LIFECYCLE_VERIFYING: &str = "verifying";
pub const LIFECYCLE_RESCANNING: &str = "rescanning";
pub const LIFECYCLE_AVAILABLE: &str = "available";
pub const LIFECYCLE_NEEDS_LOGIN: &str = "needs-login";
pub const LIFECYCLE_FAILED: &str = "failed";

pub const CHANNEL_HOMEBREW: &str = "homebrew";
pub const CHANNEL_NPM: &str = "npm";
pub const CHANNEL_WINGET: &str = "winget";
pub const CHANNEL_OFFICIAL_ARTIFACT: &str = "official-artifact";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecipeRegistryDocument {
    pub schema_version: String,
    pub host_scope: String,
    pub plugin_management_boundary: String,
    pub adaptation_tags: Vec<String>,
    pub channel_kinds: Vec<String>,
    pub agents: Vec<AgentRecipe>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRecipe {
    pub id: String,
    pub label: String,
    pub adaptation: String,
    pub binary_names: Vec<String>,
    pub protocol: String,
    pub license: String,
    pub summary: String,
    pub homepage: String,
    #[serde(default)]
    pub requires_login: bool,
    #[serde(default)]
    pub connection_modes: Vec<String>,
    pub official_docs: String,
    pub channels: Vec<InstallChannel>,
    #[serde(default)]
    pub unsupported: Vec<UnsupportedCombination>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallChannel {
    pub id: String,
    pub kind: String,
    pub oses: Vec<String>,
    #[serde(default)]
    pub architectures: Vec<String>,
    pub priority: i32,
    #[serde(default)]
    pub official_recommended: bool,
    #[serde(default)]
    pub licoup_verified: bool,
    pub requires_manager: String,
    #[serde(default = "none_elevation")]
    pub elevation: String,
    #[serde(default = "user_scope")]
    pub scope: String,
    #[serde(default = "default_selectable")]
    pub selectable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unsupported_reason: Option<String>,
    pub package_coordinate: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package_form: Option<String>,
    pub official_source: String,
    pub version_policy: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<ArtifactSpec>,
    #[serde(default)]
    pub install_argv: Vec<String>,
    #[serde(default)]
    pub windows_install_argv: Vec<String>,
    #[serde(default)]
    pub update_argv: Vec<String>,
    #[serde(default)]
    pub uninstall_argv: Vec<String>,
    #[serde(default)]
    pub verify_argv: Vec<String>,
}

fn none_elevation() -> String {
    "none".to_string()
}

fn user_scope() -> String {
    "user".to_string()
}

fn default_selectable() -> bool {
    true
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactSpec {
    pub origin_host: String,
    pub url_template: String,
    #[serde(default)]
    pub vendor_os: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub vendor_arch: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub installer: std::collections::BTreeMap<String, String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UnsupportedCombination {
    pub oses: Vec<String>,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PlatformInstallCapabilities {
    pub os: String,
    pub architecture: String,
    pub managers: Vec<String>,
    pub scan_generation: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallOwnership {
    pub agent_id: String,
    pub channel_id: String,
    pub channel_kind: String,
    pub package_coordinate: String,
    pub installed_version: String,
    pub ownership: String,
    pub lifecycle: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryFact {
    pub agent_id: String,
    pub present: bool,
    pub location: String,
    pub scan_source: String,
    #[serde(default)]
    pub installed_version: String,
    #[serde(default)]
    pub latest_version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HubEvent {
    pub phase: String,
    pub code: String,
}

pub fn contract_surface() -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "hostScope": HOST_SCOPE,
        "pluginManagementBoundary": PLUGIN_MANAGEMENT_BOUNDARY,
        "firstBatchIds": FIRST_BATCH_IDS,
        "adaptation": {
            "deep": DEEP_ADAPTATION_IDS,
            "partial": [PARTIAL_ADAPTATION_ID],
            "pendingEvaluation": ADAPTATION_PENDING
        },
        "channelKinds": [CHANNEL_HOMEBREW, CHANNEL_NPM, CHANNEL_WINGET, CHANNEL_OFFICIAL_ARTIFACT],
        "ownership": [OWNERSHIP_NONE, OWNERSHIP_EXTERNAL, OWNERSHIP_OWNED],
        "lifecycle": [
            LIFECYCLE_DISCOVERED,
            LIFECYCLE_PLANNED,
            LIFECYCLE_CONFIRMED,
            LIFECYCLE_APPLYING,
            LIFECYCLE_VERIFYING,
            LIFECYCLE_RESCANNING,
            LIFECYCLE_AVAILABLE,
            LIFECYCLE_NEEDS_LOGIN,
            LIFECYCLE_FAILED
        ],
        "operations": ["install", "update", "uninstall", "verify", "rescan"],
        "confirmation": "single-use-plan-token"
    })
}
