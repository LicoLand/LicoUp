//! Closed configuration plans for connecting supported coding agents to the
//! loopback LicoUp Gateway. Plans never contain upstream provider credentials.

use anyhow::{Result, anyhow, ensure};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

pub const GATEWAY_AGENT_CONFIG_SCHEMA: &str = "licoup.llm-gateway-agent-config.v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum GatewayAgentTarget {
    Codex,
    ClaudeCode,
}

impl GatewayAgentTarget {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "codex" => Ok(Self::Codex),
            "claude-code" | "claude" => Ok(Self::ClaudeCode),
            _ => Err(anyhow!("llm_gateway_agent_adapter_unsupported")),
        }
    }
    pub fn agent_id(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude-code",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayAgentConfigPlan {
    pub schema_version: &'static str,
    pub agent_id: &'static str,
    pub destination: PathBuf,
    pub content: String,
    pub contains_upstream_secret: bool,
    pub confirmation_digest: String,
}

pub fn plan_agent_config(
    target: GatewayAgentTarget,
    agent_config_root: &Path,
    gateway_port: u16,
    local_token_helper: &Path,
) -> Result<GatewayAgentConfigPlan> {
    ensure!(gateway_port > 0, "llm_gateway_port_invalid");
    ensure!(
        agent_config_root.is_absolute() && local_token_helper.is_absolute(),
        "llm_gateway_agent_config_path_invalid"
    );
    let base_url = format!("http://127.0.0.1:{gateway_port}");
    let (destination, content) = match target {
        GatewayAgentTarget::Codex => {
            let helper = toml_string(local_token_helper.to_string_lossy().as_ref())?;
            let base = toml_string(&base_url)?;
            (
                agent_config_root.join("licoup-gateway.config.toml"),
                format!(
                    "model_provider = \"licoup-gateway\"\n\n[model_providers.licoup-gateway]\nname = \"LicoUp Gateway\"\nbase_url = {base}\nwire_api = \"responses\"\n[model_providers.licoup-gateway.auth]\ncommand = {helper}\nargs = [\"gateway\", \"client-token\", \"--agent\", \"codex\"]\ntimeout_ms = 5000\nrefresh_interval_ms = 300000\n"
                ),
            )
        }
        GatewayAgentTarget::ClaudeCode => {
            let destination = agent_config_root.join("settings.licoup-gateway.json");
            let document = serde_json::json!({
                "env": { "ANTHROPIC_BASE_URL": base_url },
                "apiKeyHelper": format!("{} gateway client-token --agent claude-code", local_token_helper.display())
            });
            (
                destination,
                format!("{}\n", serde_json::to_string_pretty(&document)?),
            )
        }
    };
    let digest = Sha256::digest(
        [
            target.agent_id().as_bytes(),
            destination.to_string_lossy().as_bytes(),
            content.as_bytes(),
        ]
        .concat(),
    );
    let confirmation_digest = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(GatewayAgentConfigPlan {
        schema_version: GATEWAY_AGENT_CONFIG_SCHEMA,
        agent_id: target.agent_id(),
        destination,
        content,
        contains_upstream_secret: false,
        confirmation_digest,
    })
}

fn toml_string(value: &str) -> Result<String> {
    ensure!(
        !value.chars().any(char::is_control),
        "llm_gateway_agent_config_path_invalid"
    );
    Ok(format!(
        "\"{}\"",
        value.replace('\\', "\\\\").replace('"', "\\\"")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_and_claude_plans_use_loopback_and_never_embed_upstream_keys() {
        for target in [GatewayAgentTarget::Codex, GatewayAgentTarget::ClaudeCode] {
            let plan = plan_agent_config(
                target,
                Path::new("/synthetic/config"),
                15722,
                Path::new("/synthetic/lico-native"),
            )
            .unwrap();
            assert!(plan.content.contains("127.0.0.1:15722"));
            assert!(!plan.contains_upstream_secret);
            assert!(!plan.content.contains("credentialProvider"));
            assert!(!plan.content.contains("sk-"));
        }
    }
    #[test]
    fn unknown_agents_fail_closed() {
        assert!(GatewayAgentTarget::parse("unknown").is_err());
    }
}
