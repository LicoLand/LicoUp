use super::{AdmittedCommand, CliExecution};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::domain::group_conversation::{
    GroupConversationStore, GroupTurnRequest, TurnTakingPolicy, plan_turn,
};
use crate::platform::paths::portable_data_dir;

pub(super) fn handle_group_ensure(_command: AdmittedCommand) -> Result<CliExecution> {
    let root = portable_data_dir()?;
    let store = GroupConversationStore::open(&root)?;
    let record = store.ensure_default_lico_room(&root)?;
    Ok(CliExecution::Json(serde_json::to_value(record)?))
}

pub(super) fn handle_group_plan_turn(mut command: AdmittedCommand) -> Result<CliExecution> {
    let input = match command.take_option_json("stdin-json") {
        Some(Value::Object(input)) => input,
        Some(_) => return Err(anyhow!("group_conversation_plan_input_invalid")),
        None => return Err(anyhow!("group_conversation_plan_input_required")),
    };
    let root = portable_data_dir()?;
    let store = GroupConversationStore::open(&root)?;
    let room_id = input
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("lico-group-default");
    let record = store
        .load(room_id)?
        .ok_or_else(|| anyhow!("group_conversation_not_found"))?;
    let user_text = input
        .get("userText")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let policy = input
        .get("policy")
        .and_then(Value::as_str)
        .map(|raw| match raw {
            "mention-only" => TurnTakingPolicy::MentionOnly,
            "parallel-selected" => TurnTakingPolicy::ParallelSelected,
            _ => TurnTakingPolicy::FlywheelMainDispatch,
        })
        .unwrap_or(record.turn_taking);
    let selected_agent_ids = input
        .get("selectedAgentIds")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let planned = plan_turn(
        &record.roster,
        &GroupTurnRequest {
            user_text,
            policy,
            selected_agent_ids,
        },
    );
    Ok(CliExecution::Json(json!({
        "ok": true,
        "id": record.id,
        "planned": planned,
    })))
}
