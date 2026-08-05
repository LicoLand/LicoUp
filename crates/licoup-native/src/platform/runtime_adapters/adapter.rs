use super::params::text_param;
use crate::platform::{
    antigravity_driver, claude_code_driver, codex_app_server, copilot_driver, cursor_driver,
    hermes_driver, kilo_code_driver, kimi_code_driver, lico_agent_driver, openclaw_driver,
    opencode_driver, pi_driver,
};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RuntimeAdapter {
    Antigravity,
    ClaudeCode,
    Codex,
    Copilot,
    Cursor,
    Hermes,
    KiloCode,
    KimiCode,
    OpenClaw,
    OpenCode,
    Pi,
    LicoAgent,
}

/// Native delivery channels an agent itself ships, as opposed to a
/// LicoUp-installed adapter plugin or LicoUp-owned gateway. Detection of
/// `desktop` and `cli` is real filesystem detection;
/// `acp`, `rpc`, `gateway`, `local-server`, and `web-server` are capabilities
/// of the CLI/runtime itself, so their detection follows the CLI result.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeCapabilityKind {
    Desktop,
    Cli,
    Acp,
    Rpc,
    AppServer,
    Gateway,
    LocalServer,
    WebServer,
    TuiGateway,
}

impl NativeCapabilityKind {
    pub(crate) fn wire_name(self) -> &'static str {
        match self {
            Self::Desktop => "desktop",
            Self::Cli => "cli",
            Self::Acp => "acp",
            Self::Rpc => "rpc",
            Self::AppServer => "app-server",
            Self::Gateway => "gateway",
            Self::LocalServer => "local-server",
            Self::WebServer => "web-server",
            Self::TuiGateway => "tui-gateway",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "desktop" => Some(Self::Desktop),
            "cli" => Some(Self::Cli),
            "acp" => Some(Self::Acp),
            "rpc" => Some(Self::Rpc),
            "app-server" => Some(Self::AppServer),
            "gateway" => Some(Self::Gateway),
            "local-server" => Some(Self::LocalServer),
            "web-server" => Some(Self::WebServer),
            "tui-gateway" => Some(Self::TuiGateway),
            _ => None,
        }
    }
}

pub(crate) fn adapter_for_agent_public(agent_id: &str) -> Option<RuntimeAdapter> {
    adapter_for_agent(agent_id)
}

pub(crate) fn text_param_public(params: &Value, keys: &[&str]) -> Option<String> {
    text_param(params, keys)
}

pub(super) fn adapter_for_agent(agent_id: &str) -> Option<RuntimeAdapter> {
    match agent_id {
        "antigravity" => Some(RuntimeAdapter::Antigravity),
        "claude" | "claude-code" => Some(RuntimeAdapter::ClaudeCode),
        "codex" => Some(RuntimeAdapter::Codex),
        "copilot" | "github-copilot" => Some(RuntimeAdapter::Copilot),
        "cursor" | "cursor-agent" => Some(RuntimeAdapter::Cursor),
        "hermes" | "hermes-agent" => Some(RuntimeAdapter::Hermes),
        "kilo" | "kilocode" | "kilo-code" => Some(RuntimeAdapter::KiloCode),
        "kimi-code" | "kimicode" => Some(RuntimeAdapter::KimiCode),
        "openclaw" => Some(RuntimeAdapter::OpenClaw),
        "opencode" => Some(RuntimeAdapter::OpenCode),
        "pi" | "pi-agent" | "pi-coding-agent" => Some(RuntimeAdapter::Pi),
        "lico-agent" | "lico" => Some(RuntimeAdapter::LicoAgent),
        _ => None,
    }
}

impl RuntimeAdapter {
    pub(crate) fn id(self) -> &'static str {
        match self {
            Self::Antigravity => "antigravity",
            Self::ClaudeCode => "claude-code",
            Self::Codex => "codex",
            Self::Copilot => "copilot",
            Self::Cursor => "cursor",
            Self::Hermes => "hermes",
            Self::KiloCode => "kilo-code",
            Self::KimiCode => "kimi-code",
            Self::OpenClaw => "openclaw",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
            Self::LicoAgent => "lico-agent",
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Antigravity => "Antigravity - CLI",
            Self::ClaudeCode => "Claude Code - CLI",
            Self::Codex => "ChatGPT - Desktop",
            Self::Copilot => "GitHub Copilot - CLI",
            Self::Cursor => "Cursor - IDE",
            Self::Hermes => "Hermes Agent - CLI",
            Self::KiloCode => "Kilo Code - CLI",
            Self::KimiCode => "Kimi Code - CLI",
            Self::OpenClaw => "OpenClaw - CLI",
            Self::OpenCode => "OpenCode - CLI",
            Self::Pi => "Pi Agent - CLI",
            Self::LicoAgent => "Lico Agent - CLI",
        }
    }

    pub(crate) fn driver_id(self) -> &'static str {
        match self {
            Self::Antigravity => "antigravity-cli",
            Self::ClaudeCode => "claude-code-stream-json",
            Self::Codex => "codex-app-server",
            Self::Copilot => "copilot-acp",
            Self::Cursor => "cursor-cli",
            Self::Hermes => "hermes-acp",
            Self::KiloCode => "kilo-code-serve",
            Self::KimiCode => "kimi-code-acp",
            Self::OpenClaw => "openclaw-acp",
            Self::OpenCode => "opencode-serve",
            Self::Pi => "pi-rpc",
            Self::LicoAgent => "lico-agent-rpc",
        }
    }

    pub(crate) fn runtime_protocol(self) -> &'static str {
        match self {
            Self::Antigravity => antigravity_driver::RUNTIME_PROTOCOL,
            Self::ClaudeCode => claude_code_driver::RUNTIME_PROTOCOL,
            Self::Codex => codex_app_server::RUNTIME_PROTOCOL,
            Self::Copilot => copilot_driver::RUNTIME_PROTOCOL,
            Self::Cursor => cursor_driver::RUNTIME_PROTOCOL,
            Self::Hermes => hermes_driver::RUNTIME_PROTOCOL,
            Self::KiloCode => kilo_code_driver::RUNTIME_PROTOCOL,
            Self::KimiCode => kimi_code_driver::RUNTIME_PROTOCOL,
            Self::OpenClaw => openclaw_driver::RUNTIME_PROTOCOL,
            Self::OpenCode => opencode_driver::RUNTIME_PROTOCOL,
            Self::Pi => pi_driver::RUNTIME_PROTOCOL,
            Self::LicoAgent => lico_agent_driver::RUNTIME_PROTOCOL,
        }
    }

    pub(super) fn default_binary(self) -> &'static str {
        match self {
            Self::Antigravity => "agy",
            Self::ClaudeCode => "claude",
            Self::Codex => "codex",
            Self::Copilot => "copilot",
            Self::Cursor => "cursor-agent",
            Self::Hermes => "hermes",
            Self::KiloCode => "kilo",
            Self::KimiCode => "kimi",
            Self::OpenClaw => "openclaw",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
            Self::LicoAgent => "lico-agent",
        }
    }

    /// The LicoUp-managed adapter plugin this agent supports, if any. Only
    /// managed plugins with real install management may be listed here.
    pub(crate) fn managed_adapter_plugin_id(self) -> Option<&'static str> {
        match self {
            Self::Antigravity => Some("acp-bridge"),
            Self::Codex => Some("lico-up-codex"),
            _ => None,
        }
    }
}
