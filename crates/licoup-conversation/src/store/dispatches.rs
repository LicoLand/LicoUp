//! Membership-scoped dispatch repository boundary.

use super::{ConversationStore, StoreResult, new_id, now_ms, validate_identifier};
use crate::{
    ConversationDispatch, SubagentDispatchClaim, SubagentDispatchClaimState, SubagentMeshEdge,
};
use anyhow::anyhow;
use rusqlite::{OptionalExtension, TransactionBehavior, params};

/// The bounded multi-hop contract counts the direct edge as depth one.
pub const MAX_SUBAGENT_INVOCATION_DEPTH: u8 = 4;

/// Durable dispatch reads used to rebuild runtime state after host loss.
pub trait DispatchRepository {
    fn dispatch(&self, dispatch_id: &str) -> StoreResult<Option<ConversationDispatch>>;
    fn latest_resumable(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> StoreResult<Option<ConversationDispatch>>;
    fn subagent_claim(&self, dispatch_id: &str) -> StoreResult<Option<SubagentDispatchClaim>>;
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

    fn subagent_claim(&self, dispatch_id: &str) -> StoreResult<Option<SubagentDispatchClaim>> {
        ConversationStore::subagent_claim(self, dispatch_id)
    }
}

impl ConversationStore {
    /// Atomically validate both active Agent Memberships, server-owned lineage,
    /// depth and duplicate-edge admission before any adapter effect can start.
    pub fn claim_subagent_dispatch(
        &self,
        conversation_id: &str,
        caller_membership_id: &str,
        target_membership_id: &str,
        parent_dispatch_id: Option<&str>,
    ) -> StoreResult<SubagentDispatchClaim> {
        validate_identifier(conversation_id, "conversation_id")?;
        validate_identifier(caller_membership_id, "caller_membership_id")?;
        validate_identifier(target_membership_id, "target_membership_id")?;
        if caller_membership_id == target_membership_id {
            return Err(anyhow!("subagent_self_call_rejected"));
        }
        if let Some(parent) = parent_dispatch_id {
            validate_identifier(parent, "parent_dispatch_id")?;
        }

        let dispatch_id = new_id("subagent");
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;

            for membership_id in [caller_membership_id, target_membership_id] {
                let admitted: Option<i64> = transaction
                    .query_row(
                        "SELECT 1 FROM memberships m JOIN principals p ON p.id=m.principal_id
                         WHERE m.id=?1 AND m.conversation_id=?2 AND m.status='active'
                           AND p.kind='agent' AND p.agent_id IS NOT NULL",
                        params![membership_id, conversation_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if admitted.is_none() {
                    return Err(anyhow!(if membership_id == caller_membership_id {
                        "subagent_caller_membership_inactive"
                    } else {
                        "subagent_target_membership_inactive"
                    }));
                }
            }

            reconcile_subagent_claims(&transaction, conversation_id)?;

            let duplicate: bool = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM subagent_dispatch_claims
                 WHERE conversation_id=?1 AND caller_membership_id=?2
                   AND target_membership_id=?3 AND state IN (
                     'claimed','running','cancel-requested','reconciliation-required'
                   ))",
                params![conversation_id, caller_membership_id, target_membership_id],
                |row| row.get(0),
            )?;
            if duplicate {
                return Err(anyhow!("subagent_duplicate_active_edge"));
            }

            let mut depth = 1_u8;
            if let Some(parent_dispatch_id) = parent_dispatch_id {
                let mut cursor = Some(parent_dispatch_id.to_owned());
                let mut first = true;
                let mut observed = std::collections::BTreeSet::new();
                while let Some(parent_id) = cursor.take() {
                    if !observed.insert(parent_id.clone()) {
                        return Err(anyhow!("subagent_lineage_cycle"));
                    }
                    let parent: Option<(String, String, String, Option<String>, i64)> = transaction
                        .query_row(
                            "SELECT conversation_id, caller_membership_id,
                                    target_membership_id, parent_dispatch_id, depth
                             FROM subagent_dispatch_claims WHERE id=?1",
                            params![parent_id],
                            |row| {
                                Ok((
                                    row.get(0)?,
                                    row.get(1)?,
                                    row.get(2)?,
                                    row.get(3)?,
                                    row.get(4)?,
                                ))
                            },
                        )
                        .optional()?;
                    let Some((
                        parent_conversation,
                        ancestor_caller,
                        ancestor_target,
                        next,
                        parent_depth,
                    )) = parent
                    else {
                        return Err(anyhow!("subagent_parent_dispatch_unavailable"));
                    };
                    if parent_conversation != conversation_id {
                        return Err(anyhow!("subagent_cross_conversation_rejected"));
                    }
                    if first && ancestor_target != caller_membership_id {
                        return Err(anyhow!("subagent_lineage_caller_mismatch"));
                    }
                    if ancestor_caller == target_membership_id
                        || ancestor_target == target_membership_id
                    {
                        return Err(anyhow!("subagent_repeated_ancestor"));
                    }
                    if first {
                        let next_depth = parent_depth
                            .checked_add(1)
                            .ok_or_else(|| anyhow!("subagent_depth_exceeded"))?;
                        depth = u8::try_from(next_depth)
                            .map_err(|_| anyhow!("subagent_depth_exceeded"))?;
                    }
                    first = false;
                    cursor = next;
                }
            }
            if depth > MAX_SUBAGENT_INVOCATION_DEPTH {
                return Err(anyhow!("subagent_depth_exceeded"));
            }

            transaction.execute(
                "INSERT INTO subagent_dispatch_claims(
                   id, conversation_id, caller_membership_id, target_membership_id,
                   parent_dispatch_id, depth, state, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'claimed', ?7, ?7)",
                params![
                    dispatch_id,
                    conversation_id,
                    caller_membership_id,
                    target_membership_id,
                    parent_dispatch_id,
                    i64::from(depth),
                    now,
                ],
            )?;
            transaction.commit()?;
            Ok(SubagentDispatchClaim {
                id: dispatch_id,
                conversation_id: conversation_id.to_owned(),
                caller_membership_id: caller_membership_id.to_owned(),
                target_membership_id: target_membership_id.to_owned(),
                parent_dispatch_id: parent_dispatch_id.map(str::to_owned),
                depth,
                state: SubagentDispatchClaimState::Claimed,
                created_at_unix_ms: now,
                updated_at_unix_ms: now,
            })
        })
    }

    pub fn subagent_claim(&self, dispatch_id: &str) -> StoreResult<Option<SubagentDispatchClaim>> {
        validate_identifier(dispatch_id, "dispatch_id")?;
        self.with_connection(|connection| {
            connection
                .query_row(
                    "SELECT id, conversation_id, caller_membership_id,
                            target_membership_id, parent_dispatch_id, depth, state,
                            created_at, updated_at
                     FROM subagent_dispatch_claims WHERE id=?1",
                    params![dispatch_id],
                    claim_from_row,
                )
                .optional()
                .map_err(Into::into)
        })
    }

    pub fn active_subagent_claim(
        &self,
        conversation_id: &str,
        caller_membership_id: &str,
        target_membership_id: &str,
    ) -> StoreResult<Option<SubagentDispatchClaim>> {
        validate_identifier(conversation_id, "conversation_id")?;
        validate_identifier(caller_membership_id, "caller_membership_id")?;
        validate_identifier(target_membership_id, "target_membership_id")?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            reconcile_subagent_claims(&transaction, conversation_id)?;
            let claim = transaction
                .query_row(
                    "SELECT id, conversation_id, caller_membership_id,
                            target_membership_id, parent_dispatch_id, depth, state,
                            created_at, updated_at
                     FROM subagent_dispatch_claims
                     WHERE conversation_id=?1 AND caller_membership_id=?2
                       AND target_membership_id=?3 AND state IN (
                         'claimed','running','cancel-requested','reconciliation-required'
                       )
                     ORDER BY updated_at DESC, id DESC LIMIT 1",
                    params![conversation_id, caller_membership_id, target_membership_id],
                    claim_from_row,
                )
                .optional()?;
            transaction.commit()?;
            Ok(claim)
        })
    }

    pub fn update_subagent_claim_state(
        &self,
        dispatch_id: &str,
        next: SubagentDispatchClaimState,
    ) -> StoreResult<()> {
        validate_identifier(dispatch_id, "dispatch_id")?;
        self.with_connection(|connection| {
            let current: Option<String> = connection
                .query_row(
                    "SELECT state FROM subagent_dispatch_claims WHERE id=?1",
                    params![dispatch_id],
                    |row| row.get(0),
                )
                .optional()?;
            let Some(current) = current else {
                return Err(anyhow!("subagent_dispatch_not_found"));
            };
            if !valid_claim_transition(&current, next) {
                return Err(anyhow!("subagent_dispatch_transition_invalid"));
            }
            connection.execute(
                "UPDATE subagent_dispatch_claims SET state=?2, updated_at=?3 WHERE id=?1",
                params![dispatch_id, next.as_str(), now_ms()],
            )?;
            Ok(())
        })
    }

    pub fn record_subagent_mcp_inbound(
        &self,
        conversation_id: &str,
        caller_membership_id: Option<&str>,
        target_membership_id: Option<&str>,
        tool: &str,
        outcome: &str,
    ) -> StoreResult<()> {
        validate_identifier(conversation_id, "conversation_id")?;
        if !matches!(
            tool,
            "lico_subagent_delegate" | "lico_subagent_continue" | "lico_subagent_cancel"
        ) {
            return Err(anyhow!("subagent_mcp_inbound_tool_unsupported"));
        }
        if outcome.trim().is_empty() || outcome.len() > 128 {
            return Err(anyhow!("subagent_mcp_inbound_outcome_invalid"));
        }
        if let Some(caller) = caller_membership_id {
            validate_identifier(caller, "caller_membership_id")?;
        }
        if let Some(target) = target_membership_id {
            validate_identifier(target, "target_membership_id")?;
        }
        let id = new_id("mcp-in");
        let now = now_ms();
        self.with_connection(|connection| {
            connection.execute(
                "INSERT INTO subagent_mcp_inbound(
                   id, conversation_id, caller_membership_id, target_membership_id,
                   tool, outcome, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    id,
                    conversation_id,
                    caller_membership_id,
                    target_membership_id,
                    tool,
                    outcome,
                    now
                ],
            )?;
            Ok(())
        })
    }

    pub fn subagent_mesh_edge(
        &self,
        conversation_id: &str,
        caller_membership_id: &str,
        target_membership_id: &str,
    ) -> StoreResult<SubagentMeshEdge> {
        validate_identifier(conversation_id, "conversation_id")?;
        validate_identifier(caller_membership_id, "caller_membership_id")?;
        validate_identifier(target_membership_id, "target_membership_id")?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            reconcile_subagent_claims(&transaction, conversation_id)?;
            let mut inbound = SubagentMeshEdge::default();
            {
                let mut statement = transaction.prepare(
                    "SELECT tool, outcome FROM subagent_mcp_inbound
                     WHERE conversation_id=?1 AND caller_membership_id=?2
                       AND target_membership_id=?3
                     ORDER BY created_at ASC, id ASC",
                )?;
                let rows = statement.query_map(
                    params![conversation_id, caller_membership_id, target_membership_id],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
                )?;
                for row in rows {
                    let (tool, outcome) = row?;
                    match tool.as_str() {
                        "lico_subagent_delegate" => {
                            inbound.inbound_delegate = true;
                            inbound.delegate_outcome = Some(outcome);
                        }
                        "lico_subagent_continue" => {
                            inbound.inbound_continue = true;
                            inbound.continue_outcome = Some(outcome);
                        }
                        "lico_subagent_cancel" => {
                            inbound.inbound_cancel = true;
                            inbound.cancel_outcome = Some(outcome);
                        }
                        _ => {}
                    }
                }
            }
            inbound.claim_state = transaction
                .query_row(
                    "SELECT state FROM subagent_dispatch_claims
                     WHERE conversation_id=?1 AND caller_membership_id=?2
                       AND target_membership_id=?3
                     ORDER BY updated_at DESC, id DESC LIMIT 1",
                    params![conversation_id, caller_membership_id, target_membership_id],
                    |row| row.get(0),
                )
                .optional()?;
            inbound.dispatch_state = transaction
                .query_row(
                    "SELECT d.state FROM conversation_dispatches d
                     JOIN subagent_dispatch_claims c ON d.id=c.id
                     WHERE c.conversation_id=?1 AND c.caller_membership_id=?2
                       AND c.target_membership_id=?3
                     ORDER BY c.updated_at DESC, c.id DESC LIMIT 1",
                    params![conversation_id, caller_membership_id, target_membership_id],
                    |row| row.get(0),
                )
                .optional()?;
            transaction.commit()?;
            Ok(inbound)
        })
    }
}

/// Project terminal PersistentTurn state back into the private lineage claim.
/// This is reconciliation, not a second terminal authority: the canonical
/// `conversation_dispatches` row is the source and this claim only controls
/// admission of the next edge.
fn reconcile_subagent_claims(
    transaction: &super::CountedTransaction<'_>,
    conversation_id: &str,
) -> StoreResult<()> {
    transaction.execute(
        "UPDATE subagent_dispatch_claims
         SET state = CASE (
           SELECT d.state FROM conversation_dispatches d
           WHERE d.id=subagent_dispatch_claims.id
         )
           WHEN 'completed' THEN 'completed'
           WHEN 'failed' THEN 'failed'
           WHEN 'cancelled' THEN 'cancelled'
           WHEN 'cancel-requested' THEN 'cancel-requested'
           WHEN 'running' THEN 'running'
           WHEN 'accepted' THEN 'running'
           ELSE state
         END,
         updated_at=?2
         WHERE conversation_id=?1
           AND state IN ('claimed','running','cancel-requested','reconciliation-required')
           AND EXISTS (
             SELECT 1 FROM conversation_dispatches d
             WHERE d.id=subagent_dispatch_claims.id
           )",
        params![conversation_id, now_ms()],
    )?;
    Ok(())
}

fn valid_claim_transition(current: &str, next: SubagentDispatchClaimState) -> bool {
    use SubagentDispatchClaimState as State;
    matches!(
        (current, next),
        (
            "claimed",
            State::Running | State::Failed | State::ReconciliationRequired
        ) | (
            "running",
            State::Completed
                | State::Failed
                | State::CancelRequested
                | State::ReconciliationRequired
        ) | (
            "cancel-requested",
            State::Cancelled | State::Completed | State::Failed | State::ReconciliationRequired
        ) | (
            "reconciliation-required",
            State::Running | State::Completed | State::Failed | State::Cancelled
        )
    )
}

fn claim_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SubagentDispatchClaim> {
    let state: String = row.get(6)?;
    let state = match state.as_str() {
        "claimed" => SubagentDispatchClaimState::Claimed,
        "running" => SubagentDispatchClaimState::Running,
        "cancel-requested" => SubagentDispatchClaimState::CancelRequested,
        "reconciliation-required" => SubagentDispatchClaimState::ReconciliationRequired,
        "completed" => SubagentDispatchClaimState::Completed,
        "failed" => SubagentDispatchClaimState::Failed,
        "cancelled" => SubagentDispatchClaimState::Cancelled,
        _ => return Err(rusqlite::Error::InvalidQuery),
    };
    let depth: i64 = row.get(5)?;
    let depth =
        u8::try_from(depth).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(5, depth))?;
    Ok(SubagentDispatchClaim {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        caller_membership_id: row.get(2)?,
        target_membership_id: row.get(3)?,
        parent_dispatch_id: row.get(4)?,
        depth,
        state,
        created_at_unix_ms: row.get(7)?,
        updated_at_unix_ms: row.get(8)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MembershipAccess, Principal, PrincipalKind};

    fn fixture() -> (ConversationStore, String, Vec<String>) {
        let store = ConversationStore::open_in_memory().unwrap();
        let owner = Principal {
            id: "human:owner".into(),
            kind: PrincipalKind::Human,
            display_name: "Owner".into(),
            agent_id: None,
            created_at_unix_ms: 1,
        };
        let agents = [
            "codex",
            "cursor",
            "antigravity",
            "codex-next",
            "cursor-next",
            "antigravity-next",
        ]
        .into_iter()
        .map(|id| {
            (
                Principal {
                    id: format!("agent:{id}"),
                    kind: PrincipalKind::Agent,
                    display_name: id.into(),
                    agent_id: Some(id.into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )
        })
        .collect::<Vec<_>>();
        let conversation = store
            .create_conversation_with_members("Mesh", owner, &agents)
            .unwrap();
        let memberships = conversation
            .memberships
            .iter()
            .filter(|membership| membership.principal.kind == PrincipalKind::Agent)
            .map(|membership| membership.id.clone())
            .collect();
        (store, conversation.id, memberships)
    }

    #[test]
    fn lineage_rejects_self_cycle_depth_and_duplicate_without_claim_residue() {
        let (store, conversation, membership) = fixture();
        assert_eq!(
            store
                .claim_subagent_dispatch(&conversation, &membership[0], &membership[0], None)
                .unwrap_err()
                .to_string(),
            "subagent_self_call_rejected"
        );
        let first = store
            .claim_subagent_dispatch(&conversation, &membership[0], &membership[1], None)
            .unwrap();
        assert_eq!(first.depth, 1);
        assert_eq!(
            store
                .claim_subagent_dispatch(&conversation, &membership[0], &membership[1], None)
                .unwrap_err()
                .to_string(),
            "subagent_duplicate_active_edge"
        );
        let second = store
            .claim_subagent_dispatch(
                &conversation,
                &membership[1],
                &membership[2],
                Some(&first.id),
            )
            .unwrap();
        assert_eq!(second.depth, 2);
        assert_eq!(
            store
                .claim_subagent_dispatch(
                    &conversation,
                    &membership[2],
                    &membership[0],
                    Some(&second.id),
                )
                .unwrap_err()
                .to_string(),
            "subagent_repeated_ancestor"
        );
        let third = store
            .claim_subagent_dispatch(
                &conversation,
                &membership[2],
                &membership[3],
                Some(&second.id),
            )
            .unwrap();
        let fourth = store
            .claim_subagent_dispatch(
                &conversation,
                &membership[3],
                &membership[4],
                Some(&third.id),
            )
            .unwrap();
        assert_eq!(fourth.depth, MAX_SUBAGENT_INVOCATION_DEPTH);
        assert_eq!(
            store
                .claim_subagent_dispatch(
                    &conversation,
                    &membership[4],
                    &membership[5],
                    Some(&fourth.id),
                )
                .unwrap_err()
                .to_string(),
            "subagent_depth_exceeded"
        );
    }

    #[test]
    fn terminal_persistent_turn_reconciles_active_edge_before_next_claim() {
        let (store, conversation, membership) = fixture();
        let claim = store
            .claim_subagent_dispatch(&conversation, &membership[0], &membership[1], None)
            .unwrap();
        let target_agent = store
            .get(&conversation)
            .unwrap()
            .memberships
            .into_iter()
            .find(|candidate| candidate.id == membership[1])
            .and_then(|candidate| candidate.principal.agent_id)
            .unwrap();
        let scope = store
            .prepare_runtime_dispatch(
                &target_agent,
                "native-cursor",
                "synthetic input",
                Some(&conversation),
                Some(&membership[1]),
                Some("subagent-mcp"),
                Some(&claim.id),
            )
            .unwrap();
        store
            .finish_runtime_dispatch(
                &scope,
                &serde_json::json!({"output":"done"}),
                crate::DispatchState::Completed,
                None,
            )
            .unwrap();
        let next = store
            .claim_subagent_dispatch(&conversation, &membership[0], &membership[1], None)
            .unwrap();
        assert_ne!(next.id, claim.id);
        assert_eq!(
            store.subagent_claim(&claim.id).unwrap().unwrap().state,
            SubagentDispatchClaimState::Completed
        );
    }

    #[test]
    fn inbound_rows_project_last_outcome_per_tool_without_claim() {
        let (store, conversation, membership) = fixture();
        store
            .record_subagent_mcp_inbound(
                &conversation,
                Some(&membership[0]),
                Some(&membership[1]),
                "lico_subagent_delegate",
                "subagent_self_call_rejected",
            )
            .unwrap();
        store
            .record_subagent_mcp_inbound(
                &conversation,
                Some(&membership[0]),
                Some(&membership[1]),
                "lico_subagent_delegate",
                "accepted",
            )
            .unwrap();
        store
            .record_subagent_mcp_inbound(
                &conversation,
                Some(&membership[0]),
                Some(&membership[1]),
                "lico_subagent_continue",
                "accepted",
            )
            .unwrap();
        store
            .record_subagent_mcp_inbound(
                &conversation,
                Some(&membership[0]),
                Some(&membership[1]),
                "lico_subagent_cancel",
                "subagent_cancel_unavailable",
            )
            .unwrap();
        assert_eq!(
            store
                .record_subagent_mcp_inbound(
                    &conversation,
                    Some(&membership[0]),
                    Some(&membership[1]),
                    "lico_subagents_list",
                    "accepted",
                )
                .unwrap_err()
                .to_string(),
            "subagent_mcp_inbound_tool_unsupported"
        );
        let edge = store
            .subagent_mesh_edge(&conversation, &membership[0], &membership[1])
            .unwrap();
        assert_eq!(
            edge,
            SubagentMeshEdge {
                inbound_delegate: true,
                inbound_continue: true,
                inbound_cancel: true,
                delegate_outcome: Some("accepted".into()),
                continue_outcome: Some("accepted".into()),
                cancel_outcome: Some("subagent_cancel_unavailable".into()),
                claim_state: None,
                dispatch_state: None,
            }
        );
        let other = store
            .subagent_mesh_edge(&conversation, &membership[1], &membership[0])
            .unwrap();
        assert_eq!(other, SubagentMeshEdge::default());
    }
}
