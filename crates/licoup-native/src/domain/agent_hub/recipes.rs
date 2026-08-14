//! Warehouse-static Agent install recipe registry.

use super::argv::{self, ArgvKind};
use super::contract::{
    RecipeRegistryDocument, ADAPTATION_DEEP, ADAPTATION_PARTIAL, FIRST_BATCH_IDS, HOST_SCOPE,
    PARTIAL_ADAPTATION_ID, PLUGIN_MANAGEMENT_BOUNDARY, SCHEMA_VERSION,
};
use anyhow::{anyhow, ensure, Result};
use std::sync::OnceLock;
use url::Url;

const RECIPE_JSON: &str = include_str!("../../../resources/agent-install-recipes.json");

static REGISTRY: OnceLock<RecipeRegistryDocument> = OnceLock::new();

pub fn registry() -> Result<&'static RecipeRegistryDocument> {
    if let Some(loaded) = REGISTRY.get() {
        return Ok(loaded);
    }
    let loaded = parse_registry(RECIPE_JSON)?;
    Ok(REGISTRY.get_or_init(|| loaded))
}

pub fn parse_registry(raw: &str) -> Result<RecipeRegistryDocument> {
    let document: RecipeRegistryDocument = serde_json::from_str(raw)
        .map_err(|error| anyhow!("agent install recipes are invalid JSON: {error}"))?;
    validate_registry(&document)?;
    Ok(document)
}

pub fn agent_recipe<'a>(
    document: &'a RecipeRegistryDocument,
    agent_id: &str,
) -> Result<&'a super::contract::AgentRecipe> {
    document
        .agents
        .iter()
        .find(|agent| agent.id == agent_id)
        .ok_or_else(|| anyhow!("recipe_not_found"))
}

fn validate_registry(document: &RecipeRegistryDocument) -> Result<()> {
    ensure!(
        document.schema_version == SCHEMA_VERSION,
        "agent install recipe schema version is unsupported"
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
        "first-batch recipe count must be eight"
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
        ensure!(
            agent.official_docs.starts_with("https://"),
            "official docs must be HTTPS"
        );
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
