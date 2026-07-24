use super::params::text_param;
use crate::platform::{
    antigravity_driver, claude_code_driver, codex_app_server, copilot_driver, cursor_driver,
    hermes_driver, kilo_code_driver, kimi_code_driver, openclaw_driver, opencode_driver, pi_driver,
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
        }
    }
}
