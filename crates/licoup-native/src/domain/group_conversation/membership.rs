use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GroupParticipantKind {
    Human,
    Agent,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupParticipant {
    pub id: String,
    pub kind: GroupParticipantKind,
    pub display_name: String,
    /// Agent target id when kind is Agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupRoster {
    pub participants: Vec<GroupParticipant>,
    /// Flywheel main / dispatcher agent id when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub main_agent_id: Option<String>,
}

impl GroupRoster {
    pub fn contains_agent(&self, agent_id: &str) -> bool {
        self.participants.iter().any(|p| {
            p.kind == GroupParticipantKind::Agent && p.agent_id.as_deref() == Some(agent_id)
        })
    }

    pub fn upsert_agent(&mut self, agent_id: &str, display_name: &str) {
        if self.contains_agent(agent_id) {
            return;
        }
        self.participants.push(GroupParticipant {
            id: format!("agent:{agent_id}"),
            kind: GroupParticipantKind::Agent,
            display_name: display_name.to_string(),
            agent_id: Some(agent_id.to_string()),
        });
    }

    pub fn ensure_human(&mut self, display_name: &str) {
        if self
            .participants
            .iter()
            .any(|p| p.kind == GroupParticipantKind::Human)
        {
            return;
        }
        self.participants.insert(
            0,
            GroupParticipant {
                id: "human:local".into(),
                kind: GroupParticipantKind::Human,
                display_name: display_name.to_string(),
                agent_id: None,
            },
        );
    }
}
