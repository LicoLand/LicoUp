use super::membership::GroupRoster;
use serde::{Deserialize, Serialize};

/// How a user message in a group Conversation is routed to agents.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TurnTakingPolicy {
    /// Flywheel main agent only. Peers are scheduled by LicoUp handoff, not
    /// by client fan-out of the same user text.
    #[default]
    FlywheelMainDispatch,
    MentionOnly,
    ParallelSelected,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupTurnRequest {
    pub user_text: String,
    pub policy: TurnTakingPolicy,
    /// Explicit agent ids for MentionOnly / ParallelSelected.
    #[serde(default)]
    pub selected_agent_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlannedAgentTurn {
    pub agent_id: String,
    pub role: PlannedTurnRole,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PlannedTurnRole {
    Dispatcher,
    Peer,
}

/// Plan which agents the client should drive for one user message.
/// `FlywheelMainDispatch` returns only the main dispatcher; peer speech comes
/// from LicoUp-owned subordinate handoffs projected into the group thread.
pub fn plan_turn(roster: &GroupRoster, request: &GroupTurnRequest) -> Vec<PlannedAgentTurn> {
    match request.policy {
        TurnTakingPolicy::FlywheelMainDispatch => {
            let Some(main) = roster.main_agent_id.as_deref() else {
                return Vec::new();
            };
            vec![PlannedAgentTurn {
                agent_id: main.to_string(),
                role: PlannedTurnRole::Dispatcher,
            }]
        }
        TurnTakingPolicy::MentionOnly | TurnTakingPolicy::ParallelSelected => request
            .selected_agent_ids
            .iter()
            .filter(|id| roster.contains_agent(id))
            .map(|id| PlannedAgentTurn {
                agent_id: id.clone(),
                role: PlannedTurnRole::Peer,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::group_conversation::membership::{GroupParticipantKind, GroupRoster};

    #[test]
    fn flywheel_dispatch_lists_main_only() {
        let mut roster = GroupRoster::default();
        roster.ensure_human("You");
        roster.upsert_agent("codex", "Codex");
        roster.upsert_agent("lico-agent", "Lico Agent");
        roster.main_agent_id = Some("codex".into());
        let planned = plan_turn(
            &roster,
            &GroupTurnRequest {
                user_text: "hi".into(),
                policy: TurnTakingPolicy::FlywheelMainDispatch,
                selected_agent_ids: vec![],
            },
        );
        assert_eq!(planned.len(), 1);
        assert_eq!(planned[0].agent_id, "codex");
        assert_eq!(planned[0].role, PlannedTurnRole::Dispatcher);
        assert!(!planned.iter().any(|p| p.agent_id == "lico-agent"));
        assert!(!planned.iter().any(|p| p.agent_id == "human:local"));
        let _ = GroupParticipantKind::Human;
    }
}
