//! Local Subagents application façade for admitted native clients.

use super::{
    CallerContext, SubagentCallContext, production_application, tool_catalog,
    validate_tool_arguments,
};
use anyhow::{Result, anyhow};
use licoup_agent_runtime::ProviderId;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::sync::{Arc, atomic::AtomicBool};

pub(crate) fn catalog() -> Result<Value> {
    let app = production_application().map_err(|_| anyhow!("subagents_unavailable"))?;
    Ok(json!({"callers":app.caller_providers(),"tools":tool_catalog()}))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LocalCaller {
    provider_id: String,
    conversation_id: Option<String>,
    membership_id: Option<String>,
    parent_dispatch_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Invocation {
    name: String,
    arguments: Map<String, Value>,
    caller: LocalCaller,
}

pub(crate) fn execute(input: Value) -> Result<Value> {
    let request: Invocation =
        serde_json::from_value(input).map_err(|_| anyhow!("subagents_request_invalid"))?;
    if !validate_tool_arguments(&request.name, &request.arguments) {
        return Err(anyhow!("subagents_request_invalid"));
    }
    let app = production_application().map_err(|_| anyhow!("subagents_unavailable"))?;
    let caller = CallerContext {
        provider_id: ProviderId::parse(request.caller.provider_id)
            .map_err(|_| anyhow!("subagents_caller_invalid"))?,
        conversation_id: request.caller.conversation_id,
        membership_id: request.caller.membership_id,
        parent_dispatch_id: request.caller.parent_dispatch_id,
        // Local CLI is an authorized façade; membership/lineage checks remain
        // in the native domain. Remote authentication belongs to its adapter.
        authenticated: true,
    };
    if !app
        .caller_providers()
        .iter()
        .any(|p| p == caller.provider_id.as_str())
    {
        return Err(anyhow!("subagents_caller_invalid"));
    }
    let value = app.call_tool(
        SubagentCallContext {
            caller: &caller,
            cancelled: Arc::new(AtomicBool::new(false)),
        },
        &request.name,
        &request.arguments,
    );
    Ok(match value {
        Ok(result) => result,
        Err(error) => json!({"schemaVersion":"licoup.subagent.error.v1","reasonCode":error.code,
            "stage":error.stage,"retryable":error.retryable,"recovery":error.recovery,"isError":true}),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_invocation_rejects_unknown_fields_before_application_work() {
        let request = json!({
            "name": "lico_subagents_list",
            "arguments": {},
            "caller": {"providerId": "synthetic-provider"},
        });
        let mut top_level = request.clone();
        top_level["unknown"] = json!(true);
        let mut nested_caller = request;
        nested_caller["caller"]["authenticated"] = json!(true);
        for input in [top_level, nested_caller] {
            assert_eq!(
                execute(input).unwrap_err().to_string(),
                "subagents_request_invalid"
            );
        }
    }
}
