//! Membership-scoped dispatch repository boundary.

use super::{ConversationStore, StoreResult};
use crate::ConversationDispatch;

/// Durable dispatch reads used to rebuild runtime state after host loss.
pub trait DispatchRepository {
    fn dispatch(&self, dispatch_id: &str) -> StoreResult<Option<ConversationDispatch>>;
    fn latest_resumable(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> StoreResult<Option<ConversationDispatch>>;
}

impl DispatchRepository for ConversationStore {
    fn dispatch(&self, dispatch_id: &str) -> StoreResult<Option<ConversationDispatch>> {
        self.dispatch_record(dispatch_id)
    }

    fn latest_resumable(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> StoreResult<Option<ConversationDispatch>> {
        self.latest_resumable_dispatch(conversation_id, membership_id)
    }
}
