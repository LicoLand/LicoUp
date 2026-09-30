//! Model Context Protocol integration: the single authority for the MCP
//! registry, transport and approval of MCP servers.
//!
//! The registry installs and removes one namespaced, LicoUp-owned MCP entry per
//! provider and delivers the bundled usage Skill with the same approval; the
//! transport carries MCP messages over stdio and streamable HTTP; the approval
//! binds a transfer or a registration to an explicit, digest-bound confirmation.
//! The independently buildable adapter for the public CLI process contract lives
//! here too: only that process contract crosses into LicoUp, and no scheduler,
//! history store or kernel source is linked.
pub mod antigravity_subagent_mcp_manager;
pub mod application;
pub mod claude_code_subagent_mcp_manager;
pub mod cursor_subagent_mcp_manager;
pub mod guide_skill;
pub mod lifecycle;
pub mod mcp;
pub mod mcp_adapter;
pub mod mcp_approval_plan_store;
pub mod mcp_service_process;
pub mod mcp_streamable_http;
pub mod private_state;
pub mod provider_mcp_registration;
mod server;
pub mod transport;
#[cfg(any(windows, test))]
mod windows_private_state;
mod wire;
pub use server::*;
pub use wire::*;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Map, Value};
    mod server;
    fn object(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }
}
