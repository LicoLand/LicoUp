//! The host's own lanes, in the shape the moved crate reads them through its
//! port.
//!
//! None of these is any Agent's protocol: the conversation lane is this host's
//! control plane, the generic CLI lane is its fallback for catalog Agents that
//! ship no dedicated driver, the caller manager installs a plugin this host
//! ships, and the installation-state projection reduces the manager's answer to
//! one word. They arrive through the port for the same reason the per-Agent
//! halves do — the moved crate names no module above it.

use licoup_agent_drivers::runtime_adapters::port::{
    CallerManagerPort, CollaborationMcpPort, ConversationHostPort, GenericCliPort,
};
use serde_json::Value;

/// The conversation lane, as the Subagent mesh's two paths reach it.
pub(super) fn conversation_host() -> ConversationHostPort {
    ConversationHostPort {
        execute: |method, params| {
            crate::platform::conversation_host_client::execute(method, params)
                .map_err(|error| error.to_string())
        },
        execute_read_only: |method, params| {
            crate::platform::conversation_host_client::execute_read_only(method, params)
                .map_err(|error| error.to_string())
        },
    }
}

/// The generic CLI/PTY fallback lane.
pub(super) fn generic_cli() -> GenericCliPort {
    GenericCliPort {
        driver_id: crate::platform::generic_cli_driver::DRIVER_ID,
        resolve_executable: crate::platform::generic_cli_driver::resolve_executable,
        execute: |registration,
                  executable,
                  params,
                  text,
                  cwd,
                  timeout_ms,
                  max_stdout| {
            let result = crate::platform::generic_cli_driver::execute(
                registration,
                executable,
                params,
                text,
                cwd,
                timeout_ms,
                max_stdout,
            )?;
            Ok(licoup_agent_drivers::runtime_adapters::port::GenericCliRun {
                ok: result.ok,
                timed_out: result.timed_out,
                output: result.output,
                status_code: result.status_code,
                stdout_truncated: result.stdout_truncated,
                started_at: result.started_at,
                runtime_protocol: result.runtime_protocol,
            })
        },
    }
}

/// The caller-integration manager of the one Agent whose plugin this host
/// installs.
pub(super) fn caller_manager() -> CallerManagerPort {
    CallerManagerPort {
        plan_digest: |binary| {
            crate::platform::codex_plugin_manager::CodexPluginInstallPlan::prepare("codex", binary)
                .map(|plan| plan.digest().to_owned())
                .map_err(|_| ())
        },
        ready: |binary| {
            crate::platform::codex_plugin_manager::status(binary)
                == licoup_application::integration_state::IntegrationState::Ready
        },
        apply: |binary, digest, remove| {
            let plan =
                crate::platform::codex_plugin_manager::CodexPluginInstallPlan::prepare("codex", binary)
                    .map_err(|_| ())?;
            let mut permit = plan.approve(true, digest).map_err(|_| ())?;
            if remove {
                crate::platform::codex_plugin_manager::remove(&plan, &mut permit).map_err(|_| ())
            } else {
                crate::platform::codex_plugin_manager::install(&plan, &mut permit)
                    .map(|_| ())
                    .map_err(|_| ())
            }
        },
    }
}

/// Whether the one plugin-managing Agent's integration is installed.
pub(super) fn codex_plugin_installation_state(cli_executable: Option<&std::path::Path>) -> &'static str {
    use licoup_application::integration_state::IntegrationState;
    let Some(executable) = cli_executable else {
        return "unavailable";
    };
    match crate::platform::codex_plugin_manager::status(executable) {
        IntegrationState::Ready => "installed",
        IntegrationState::Missing => "not-installed",
        IntegrationState::Unavailable => "unavailable",
    }
}

/// End one Agent's persisted conversation, as the Subagent mesh reaches it.
pub(super) fn cleanup_conversation(params: &Value) -> Result<Value, String> {
    crate::platform::cleanup_conversation(params).map_err(|error| error.to_string())
}

/// The MCP servers one ACP runtime reaches this host's collaboration surface
/// through, as the ACP session transport reads them.
///
/// The registration is read out of this host's own client state, which is why
/// it is here rather than in the moved crate: the answer belongs to the host's
/// collaboration surface, not to any Agent's protocol. Measured, the function
/// it answers with validates the runtime identity, opens the client-state
/// store, and then reports no server — `acp_servers_in` has its whole body
/// disabled with "a local installation never activates outbound access", so the
/// transport's `mcpServers` is empty for every ACP runtime today. The port is
/// therefore behaviour-preserving and, for now, permanently empty; whether the
/// registration is restored or removed is a decision above this extraction.
pub(super) fn collaboration_mcp() -> CollaborationMcpPort {
    CollaborationMcpPort {
        acp_servers_for_runtime: |runtime_id| {
            crate::domain::collaboration_plugin::acp_servers_for_runtime(runtime_id)
                .map_err(|error| error.to_string())
        },
    }
}
