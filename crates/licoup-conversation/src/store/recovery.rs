//! Durable cold recovery for a host terminated during a turn.

use super::{ConversationStore, StoreResult, enum_wire, new_id, now_ms};
use crate::{DispatchState, EventPartKind, TurnState};
use rusqlite::params;

const HOST_INTERRUPTED: &str = "host_lifecycle_interrupted";

/// Privacy-safe result of rebuilding process state from SQLite.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ColdRecoveryReport {
    pub recovered_dispatches: usize,
    pub finalized_events: usize,
    pub interrupted_turns: usize,
}

/// Public host-neutral recovery boundary. Desktop restart and mobile resume
/// invoke this same operation; no process-memory snapshot participates.
pub trait ColdRecoverableConversationStore {
    fn cold_recover(&self) -> StoreResult<ColdRecoveryReport>;
}

impl ColdRecoverableConversationStore for ConversationStore {
    fn cold_recover(&self) -> StoreResult<ColdRecoveryReport> {
        self.with_connection(|connection| {
            let transaction = connection.unchecked_transaction()?;
            let recoverable = {
                let mut statement = transaction.prepare(
                    "SELECT d.id, d.conversation_id, e.id
                     FROM conversation_dispatches d
                     LEFT JOIN events e ON e.conversation_id=d.conversation_id
                       AND e.correlation_id=d.id AND e.author_membership_id=d.membership_id
                       AND e.kind='message' AND e.finalized=0
                     WHERE d.state IN ('accepted','running','cancel-requested')
                     ORDER BY d.created_at, d.id",
                )?;
                statement
                    .query_map([], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, Option<String>>(2)?,
                        ))
                    })?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            };
            let mut report = ColdRecoveryReport::default();
            for (dispatch_id, conversation_id, event_id) in recoverable {
                let changed = transaction.execute(
                    "UPDATE conversation_dispatches
                     SET state=?2, error_code=?3, updated_at=?4
                     WHERE id=?1 AND state IN ('accepted','running','cancel-requested')",
                    params![
                        dispatch_id,
                        enum_wire(DispatchState::Failed)?,
                        HOST_INTERRUPTED,
                        now_ms(),
                    ],
                )?;
                if changed > 0 {
                    report.recovered_dispatches += 1;
                    report.interrupted_turns += transaction.execute(
                        "UPDATE direct_turns SET state=?2
                         WHERE id=?1 AND state IN ('claimed','running')",
                        params![dispatch_id, enum_wire(TurnState::Interrupted)?],
                    )?;
                }
                // A dispatch row repeated by the join (more than one unfinalized
                // message event correlated to it) reports changed == 0 on its
                // later rows; every joined event is still finalized exactly
                // once through its own finalized=0 guard.
                if let Some(event_id) = event_id {
                    let ordinal: i64 = transaction.query_row(
                        "SELECT COALESCE(MAX(ordinal), -1)+1 FROM event_parts WHERE event_id=?1",
                        params![event_id],
                        |row| row.get(0),
                    )?;
                    transaction.execute(
                        "INSERT INTO event_parts(id, event_id, ordinal, kind, content, created_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                        params![
                            new_id("part"),
                            event_id,
                            ordinal,
                            enum_wire(EventPartKind::Diagnostic)?,
                            serde_json::json!({"code": HOST_INTERRUPTED}).to_string(),
                            now_ms(),
                        ],
                    )?;
                    report.finalized_events += transaction.execute(
                        "UPDATE events SET finalized=1 WHERE id=?1 AND finalized=0",
                        params![event_id],
                    )?;
                    super::bump_revision(&transaction, &conversation_id, now_ms())?;
                }
            }
            transaction.commit()?;
            Ok(report)
        })
    }
}

impl ConversationStore {
    /// Rebuild durable state after an unclean host stop. Idempotent: once all
    /// interrupted rows are terminal, later opens report an empty recovery.
    pub fn cold_recover(&self) -> StoreResult<ColdRecoveryReport> {
        ColdRecoverableConversationStore::cold_recover(self)
    }
}
