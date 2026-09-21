//! What a reopen shows.
//!
//! The "all old or all new" rule cannot be answered while the process still
//! holds the connection that wrote: the question is what the *file* holds for
//! the next reader. These tests close every connection, reopen the same
//! synthetic database, and compare what they read against what the transaction
//! promised. The failing case is made to fail *inside* the write transaction at
//! an injected database fault — after the event, the checkpoint, and the
//! command rows have already been written in that same transaction — so what
//! rolls back is a partially applied commit, not a decision refused up front.

use anyhow::Result;
use licoup_workflow::{CommandStatus, ReducerEvent, RunSnapshot};
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_store::transactions::{NoticeRequest, StoreStatePort, WorkflowDatabase};
use std::sync::Arc;

use crate::support;

/// A database-level failpoint on the last table a commit writes.
///
/// The commit's statement order is event, checkpoint, commands, then delivery
/// intents, so this trigger fires after most of the transaction has already
/// succeeded. `RAISE(ABORT)` fails the insert; the adapter propagates the error
/// and the transaction is rolled back whole.
const INJECTED_FAULT: &str = "
CREATE TRIGGER injected_intent_fault BEFORE INSERT ON workflow_notice_intents
BEGIN SELECT RAISE(ABORT, 'injected fault'); END;";

const DROP_INJECTED_FAULT: &str = "DROP TRIGGER injected_intent_fault;";

fn notice(recipient: &str) -> NoticeRequest {
    NoticeRequest {
        recipient: recipient.to_owned(),
        kind: "timeline".to_owned(),
    }
}

#[test]
fn a_committed_transition_survives_a_reopen_and_a_failed_one_leaves_the_file_old() -> Result<()> {
    let path = support::scratch_path("reopen");

    let committed: RunSnapshot;
    let failed_head: RunSnapshot;
    let failed_command_id: String;
    {
        let database = Arc::new(WorkflowDatabase::open(&path)?);
        support::seed_definition(
            &database,
            support::REVISION,
            support::SEMANTICS,
            &support::actor_workflow(2),
        )?;

        // All new: one transition committed together with the intent it owes.
        let port = support::graph(&database, "run-committed")?;
        let head = port.checkpoint("run-committed")?;
        committed = port
            .commit_with_notices(
                "run-committed",
                head.sequence,
                ReducerEvent::CancelRequested,
                &[notice("owner-timeline")],
            )?
            .snapshot;

        // All old: the same transition on another run hits the injected fault
        // inside the write transaction.
        let failing = support::graph(&database, "run-failed")?;
        failed_head = failing.checkpoint("run-failed")?;
        failed_command_id = failed_head
            .commands
            .values()
            .find(|command| command.status == CommandStatus::Pending)
            .expect("the started run holds a pending command")
            .id
            .clone();
        database.write(|transaction, _| {
            transaction.execute_batch(INJECTED_FAULT)?;
            Ok(())
        })?;
        let error = failing
            .commit_with_notices(
                "run-failed",
                failed_head.sequence,
                ReducerEvent::CancelRequested,
                &[notice("owner-timeline")],
            )
            .expect_err("the injected fault fails the commit")
            .to_string();
        assert!(
            error.contains("injected fault"),
            "the commit failed at the injected statement, not before it: {error}"
        );
    }

    // Reopen one: the committed transition is whole, the failed one never
    // happened, and the failed transaction left no intent behind.
    {
        let database = Arc::new(WorkflowDatabase::open(&path)?);
        let port = StoreStatePort::new(database.clone());

        assert_eq!(
            port.checkpoint("run-committed")?,
            committed,
            "a committed checkpoint survives the reopen exactly"
        );
        assert_eq!(
            support::count(&database, "strategy_run_events", "run_id='run-committed'"),
            2,
            "the start event and the committed event are both on disk"
        );
        let start = support::event_body(&database, "run-committed", 1).expect("the start body");
        assert_eq!(
            serde_json::from_str::<ReducerEvent>(&start)?,
            support::start_event(),
            "the committed body is still whole after the reopen"
        );
        let pending = database.pending_notice_intents(8)?;
        assert_eq!(
            pending.len(),
            1,
            "the intent committed with its fact is still owed after the reopen"
        );
        assert_eq!(pending[0].run_id, "run-committed");
        assert_eq!(pending[0].sequence, committed.sequence);
        assert_eq!(pending[0].recipient, "owner-timeline");

        assert_eq!(
            port.checkpoint("run-failed")?,
            failed_head,
            "the failed transaction left the checkpoint exactly as it was"
        );
        assert_eq!(
            port.checkpoint("run-failed")?.commands[&failed_command_id].status,
            CommandStatus::Pending,
            "the command the failed transaction had touched is still pending"
        );
        assert_eq!(
            support::count(&database, "strategy_run_events", "run_id='run-failed'"),
            1,
            "no event of the failed transaction survived"
        );
        assert_eq!(
            support::count(&database, "workflow_notice_intents", "run_id='run-failed'"),
            0,
            "no intent of the failed transaction survived"
        );
    }

    // Reopen two: with the fault removed, the same transition commits on retry
    // and is still one notice for one fact.
    let retried_sequence;
    {
        let database = Arc::new(WorkflowDatabase::open(&path)?);
        database.write(|transaction, _| {
            transaction.execute_batch(DROP_INJECTED_FAULT)?;
            Ok(())
        })?;
        let port = StoreStatePort::new(database.clone());
        retried_sequence = port
            .commit_with_notices(
                "run-failed",
                failed_head.sequence,
                ReducerEvent::CancelRequested,
                &[notice("owner-timeline")],
            )?
            .snapshot
            .sequence;
        assert_eq!(retried_sequence, failed_head.sequence + 1);
    }
    {
        let database = Arc::new(WorkflowDatabase::open(&path)?);
        let port = StoreStatePort::new(database.clone());
        assert_eq!(
            port.checkpoint("run-failed")?.sequence,
            retried_sequence,
            "the retried transition survives its own reopen"
        );
        let owed: Vec<_> = database
            .pending_notice_intents(8)?
            .into_iter()
            .filter(|intent| intent.run_id == "run-failed")
            .collect();
        assert_eq!(
            owed.len(),
            1,
            "a retried fact still owes exactly one notice, not one per attempt"
        );
    }

    support::remove_database(&path);
    Ok(())
}
