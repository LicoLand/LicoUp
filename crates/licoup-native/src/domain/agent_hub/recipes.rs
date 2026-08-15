//! Warehouse Manifest plus one TOML install recipe per agent.

use super::argv::{self, ArgvKind};
use super::contract::{
    ADAPTATION_DEEP, ADAPTATION_PARTIAL, ADAPTATION_PENDING, AgentHubManifest, AgentRecipe,
    AgentTomlDocument, FIRST_BATCH_IDS, HOST_SCOPE, ManifestAgent, PARTIAL_ADAPTATION_ID,
    PENDING_ADAPTATION_ID, PLUGIN_MANAGEMENT_BOUNDARY, RecipeRegistryDocument, SCHEMA_VERSION,
};
use anyhow::{Result, anyhow, ensure};
use std::sync::OnceLock;
use url::Url;

const MANIFEST_TOML: &str = include_str!("../../../resources/agent-hub/manifest.toml");

static WAREHOUSE: OnceLock<Warehouse> = OnceLock::new();

pub struct Warehouse {
    pub manifest: AgentHubManifest,
    pub registry: RecipeRegistryDocument,
}

pub fn warehouse() -> Result<&'static Warehouse> {
    if let Some(loaded) = WAREHOUSE.get() {
        return Ok(loaded);
    }
    let loaded = load_warehouse(MANIFEST_TOML)?;
    Ok(WAREHOUSE.get_or_init(|| loaded))
}

pub fn manifest() -> Result<&'static AgentHubManifest> {
    Ok(&warehouse()?.manifest)
}

pub fn registry() -> Result<&'static RecipeRegistryDocument> {
    Ok(&warehouse()?.registry)
}

pub fn parse_manifest(raw: &str) -> Result<AgentHubManifest> {
    let document: AgentHubManifest = toml::from_str(raw)
        .map_err(|error| anyhow!("agent hub manifest is invalid TOML: {error}"))?;
    validate_manifest(&document)?;
    Ok(document)
}

pub fn parse_agent_toml(raw: &str) -> Result<AgentTomlDocument> {
    toml::from_str(raw).map_err(|error| anyhow!("agent recipe is invalid TOML: {error}"))
}

pub fn agent_recipe<'a>(
    document: &'a RecipeRegistryDocument,
    agent_id: &str,
) -> Result<&'a AgentRecipe> {
    document
        .agents
        .iter()
        .find(|agent| agent.id == agent_id)
        .ok_or_else(|| anyhow!("recipe_not_found"))
}

fn load_warehouse(manifest_raw: &str) -> Result<Warehouse> {
    let manifest = parse_manifest(manifest_raw)?;
    let mut agents = Vec::with_capacity(manifest.agents.len());
    for entry in &manifest.agents {
        let raw = agent_toml_source(entry)?;
        let document = parse_agent_toml(raw)?;
        let agent = merge_agent(entry, document)?;
        validate_agent(&agent)?;
        agents.push(agent);
    }
    let registry = RecipeRegistryDocument {
        schema_version: manifest.schema_version.clone(),
        host_scope: manifest.host_scope.clone(),
        plugin_management_boundary: manifest.plugin_management_boundary.clone(),
        adaptation_tags: manifest.adaptation_tags.clone(),
        channel_kinds: manifest.channel_kinds.clone(),
        agents,
    };
    Ok(Warehouse { manifest, registry })
}

fn merge_agent(entry: &ManifestAgent, document: AgentTomlDocument) -> Result<AgentRecipe> {
    ensure!(
        document.id == entry.id,
        "agent toml id must match manifest id {}",
        entry.id
    );
    Ok(AgentRecipe {
        id: entry.id.clone(),
        label: entry.label.clone(),
        adaptation: entry.adaptation.clone(),
        binary_names: document.binary_names,
        protocol: entry.protocol.clone(),
        license: entry.license.clone(),
        summary: entry.summary.clone(),
        homepage: entry.homepage.clone(),
        requires_login: entry.requires_login,
        connection_modes: entry.connection_modes.clone(),
        official_docs: document.official_docs,
        channels: document.channels,
        unsupported: document.unsupported,
    })
}

fn agent_toml_source(entry: &ManifestAgent) -> Result<&'static str> {
    let expected = format!("{}.toml", entry.id);
    ensure!(
        entry.file == expected,
        "manifest file for {} must be {}",
        entry.id,
        expected
    );
    match entry.id.as_str() {
        "codex" => Ok(include_str!("../../../resources/agent-hub/codex.toml")),
        "cursor" => Ok(include_str!("../../../resources/agent-hub/cursor.toml")),
        "opencode" => Ok(include_str!("../../../resources/agent-hub/opencode.toml")),
        "claude-code" => Ok(include_str!(
            "../../../resources/agent-hub/claude-code.toml"
        )),
        "pi" => Ok(include_str!("../../../resources/agent-hub/pi.toml")),
        "openclaw" => Ok(include_str!("../../../resources/agent-hub/openclaw.toml")),
        "hermes" => Ok(include_str!("../../../resources/agent-hub/hermes.toml")),
        "antigravity" => Ok(include_str!(
            "../../../resources/agent-hub/antigravity.toml"
        )),
        "deepseek-harness" => Ok(include_str!(
            "../../../resources/agent-hub/deepseek-harness.toml"
        )),
        _ => Err(anyhow!("recipe_not_found")),
    }
}

fn validate_manifest(document: &AgentHubManifest) -> Result<()> {
    ensure!(
        document.schema_version == SCHEMA_VERSION,
        "agent hub manifest schema version is unsupported"
    );
    ensure!(
        document.host_scope == HOST_SCOPE,
        "agent hub host scope must be desktop"
    );
    ensure!(
        document.plugin_management_boundary == PLUGIN_MANAGEMENT_BOUNDARY,
        "agent hub must not own adapter plugin lifecycle"
    );
    ensure!(
        document.agents.len() == FIRST_BATCH_IDS.len(),
        "catalog recipe count must match the supported target list"
    );
    for (index, expected_id) in FIRST_BATCH_IDS.iter().enumerate() {
        ensure!(
            document.agents[index].id == *expected_id,
            "first-batch recipe order is fixed"
        );
    }
    for agent in &document.agents {
        let expected_adaptation = if agent.id == PARTIAL_ADAPTATION_ID {
            ADAPTATION_PARTIAL
        } else if agent.id == PENDING_ADAPTATION_ID {
            ADAPTATION_PENDING
        } else {
            ADAPTATION_DEEP
        };
        ensure!(
            agent.adaptation == expected_adaptation,
            "adaptation tag is incorrect for {}",
            agent.id
        );
        ensure!(
            !agent.summary.trim().is_empty(),
            "official summary is required for {}",
            agent.id
        );
        validate_https(&agent.homepage)?;
        if agent.id == "openclaw" || agent.id == "hermes" {
            ensure!(
                agent.connection_modes.iter().any(|mode| mode == "local")
                    && agent
                        .connection_modes
                        .iter()
                        .any(|mode| mode == "virtual-machine"),
                "{} must express local and virtual-machine connection on one card",
                agent.id
            );
        }
    }
    Ok(())
}

fn validate_agent(agent: &AgentRecipe) -> Result<()> {
    ensure!(
        agent.official_docs.starts_with("https://"),
        "official docs must be HTTPS"
    );
    let mut kinds = std::collections::BTreeSet::new();
    for channel in &agent.channels {
        ensure!(
            kinds.insert(channel.kind.as_str()),
            "channel kinds must be unique per agent"
        );
        validate_https(&channel.official_source)?;
        if channel.selectable {
            ensure!(
                !channel.install_argv.is_empty() || !channel.windows_install_argv.is_empty(),
                "selectable channel {} requires argv",
                channel.id
            );
            argv::validate(&channel.install_argv, ArgvKind::for_channel(&channel.kind))?;
            if !channel.windows_install_argv.is_empty() {
                argv::validate(
                    &channel.windows_install_argv,
                    ArgvKind::for_channel(&channel.kind),
                )?;
            }
            argv::validate(&channel.update_argv, ArgvKind::for_channel(&channel.kind))?;
            argv::validate(&channel.uninstall_argv, ArgvKind::Lifecycle)?;
            argv::validate(&channel.verify_argv, ArgvKind::Lifecycle)?;
        } else {
            ensure!(
                channel.install_argv.is_empty(),
                "non-selectable channel must not carry install argv"
            );
        }
        if let Some(artifact) = &channel.artifact {
            ensure!(
                !artifact.origin_host.is_empty(),
                "official artifact origin host is required"
            );
            validate_https_template(&artifact.url_template)?;
            let host = Url::parse(
                &artifact
                    .url_template
                    .replace("{version}", "latest")
                    .replace("{vendorOs}", "darwin")
                    .replace("{vendorArch}", "arm64")
                    .replace("{installer}", "install.sh"),
            )
            .ok()
            .and_then(|url| url.host_str().map(str::to_string));
            if let Some(host) = host {
                ensure!(
                    host == artifact.origin_host
                        || host.ends_with(&format!(".{}", artifact.origin_host)),
                    "artifact URL host must match originHost"
                );
            }
        }
        if channel.oses.contains(&"windows".to_string())
            && channel.selectable
            && channel.install_argv.first().map(String::as_str) == Some("bash")
        {
            ensure!(
                !channel.windows_install_argv.is_empty(),
                "windows official-artifact channels cannot use bash argv"
            );
        }
    }
    Ok(())
}

fn validate_https(value: &str) -> Result<()> {
    let url = Url::parse(value).map_err(|_| anyhow!("official source must be an HTTPS URL"))?;
    ensure!(url.scheme() == "https", "official source must be HTTPS");
    ensure!(url.host_str().is_some(), "official source host is required");
    Ok(())
}

fn validate_https_template(template: &str) -> Result<()> {
    let preview = template
        .replace("{version}", "latest")
        .replace("{vendorOs}", "darwin")
        .replace("{vendorArch}", "arm64")
        .replace("{installer}", "install.sh");
    validate_https(&preview)
}
