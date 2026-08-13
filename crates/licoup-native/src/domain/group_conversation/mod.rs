//! LicoUp-owned multi-agent group Conversation (peer participants).

mod membership;
mod store;
mod turn_taking;

pub use membership::{GroupParticipant, GroupParticipantKind, GroupRoster};
pub use store::{GroupAgentSessionBinding, GroupConversationRecord, GroupConversationStore};
pub use turn_taking::{GroupTurnRequest, TurnTakingPolicy, plan_turn};
