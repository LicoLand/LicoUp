// connectors commands: connectors list|sync|status, connectors mirror inspect,
// knowledge-cache, mail, source-queue, mcp-local-bridge, agent message send, agents pair

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    // Exact path first, then rest-capture for sub-action dispatch
    table.register_rest(
        &["connectors", "mirror", "inspect"],
        handle_connectors_mirror,
        "Inspect connector mirror",
    );
    table.register_rest(
        &["connectors"],
        handle_connectors,
        "Connector list|sync|status",
    );
    table.register_rest(
        &["knowledge-cache"],
        handle_knowledge_cache,
        "Knowledge cache sync|search|evidence|get|status",
    );
    table.register_rest(&["mail"], handle_mail, "Mail preview|enqueue|status|cancel");
    table.register_rest(
        &["source-queue"],
        handle_source_queue,
        "Source queue add|list|status|pause|resume|retry|cancel|drain",
    );
    table.register_rest(
        &["mcp-local-bridge"],
        handle_mcp_local_bridge,
        "MCP local bridge plan|start|stop|status|register",
    );
    table.register_rest(
        &["agent", "message", "send"],
        handle_agent_message_send,
        "Send agent message",
    );
    table.register_rest(
        &["agents", "pair"],
        handle_agents_pair,
        "Agent pair request|approve|revoke|list",
    );
}

fn handle_connectors(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "list" => crate::connectors::list(&params)?,
        "sync" => crate::connectors::sync(&params)?,
        "status" => crate::connectors::status(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_connectors_mirror(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(crate::connectors::mirror_inspect(
        &params,
    )?))
}

fn handle_knowledge_cache(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "sync" => crate::knowledge_cache::sync(&params)?,
        "search" => crate::knowledge_cache::search(&params)?,
        "evidence" => crate::knowledge_cache::evidence(&params)?,
        "get" => crate::knowledge_cache::get(&params)?,
        "status" => crate::knowledge_cache::status(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_mail(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "preview" => crate::mail::preview(&params)?,
        "enqueue" => crate::mail::enqueue(&params)?,
        "status" => crate::mail::status(&params)?,
        "cancel" => crate::mail::cancel(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_source_queue(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "add" => crate::source_queue::add(&params)?,
        "list" => crate::source_queue::list(&params)?,
        "status" => crate::source_queue::status(&params)?,
        "pause" => crate::source_queue::pause(&params)?,
        "resume" => crate::source_queue::resume(&params)?,
        "retry" => crate::source_queue::retry(&params)?,
        "cancel" => crate::source_queue::cancel(&params)?,
        "drain" => crate::source_queue::drain(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_mcp_local_bridge(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "plan" => crate::mcp_local_bridge::plan(&params)?,
        "start" => crate::mcp_local_bridge::start(&params)?,
        "stop" => crate::mcp_local_bridge::stop(&params)?,
        "status" => crate::mcp_local_bridge::status(&params)?,
        "register" => crate::mcp_local_bridge::register(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_agent_message_send(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(crate::runtime_adapters::send_message(
        &params,
    )?))
}

fn handle_agents_pair(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "request" => crate::skill_hub::pair_request(&params)?,
        "approve" => crate::skill_hub::pair_approve(&params)?,
        "revoke" => crate::skill_hub::pair_revoke(&params)?,
        "list" => crate::skill_hub::pair_list(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}
