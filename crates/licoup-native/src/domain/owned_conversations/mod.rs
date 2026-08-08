//! LicoUp-owned conversation catalog: query, export, and import.
//!
//! Reads the parent-owned projection store under
//! `{portable}/client-state/agent-conversation-projections.json` and the
//! default Lico group room. Does not rewrite third-party native history.

mod catalog;

pub use catalog::{
    OwnedConversationMatchMode, OwnedConversationRecord, export_owned_conversations,
    get_owned_conversation, import_owned_conversations, list_owned_conversations,
    search_owned_conversations,
};
