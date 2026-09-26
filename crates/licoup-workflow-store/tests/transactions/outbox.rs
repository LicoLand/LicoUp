//! The bounded outbox: intent committed with its fact, read in bounded pages,
//! acknowledged once, and accepted durably exactly when it is accepted once.

use anyhow::Result;
use licoup_workflow::ReducerEvent;
use licoup_workflow_runtime::ports::{Notice, NoticeSink, StatePort};
use licoup_workflow_store::transactions::{
    DurableNoticeSink, MAX_OUTBOX_BATCH, NoticeIntent, NoticeRequest, StoreStatePort,
};

use crate::support;

fn request(recipient: &str) -> NoticeRequest {
    NoticeRequest {
        recipient: recipient.to_owned(),
        kind: "timeline".to_owned(),
    }
}

/// A started run, which is the state every intent in these tests is committed
/// from.
fn started(label: &str) -> Result<(support::ScratchDatabase, StoreStatePort)> {
    let scratch = support::ScratchDatabase::new(label)?;
    let port = scratch.port();
    support::started_run(&port);
    Ok((scratch, port))
}

fn notice_of(intent: &NoticeIntent) -> Notice {
    Notice {
        notice_id: intent.notice_id.clone(),
        run_id: intent.run_id.clone(),
        sequence: intent.sequence,
        recipient: intent.recipient.clone(),
        kind: intent.kind.clone(),
    }
}

#[test]
fn an_intent_is_committed_with_its_fact_and_reads_it_back_by_reference() {
    let (scratch, port) = started("intent-commit").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");
    let committed = port
        .commit_with_notices(
            "run-1",
            head.sequence,
            ReducerEvent::CancelRequested,
            &[request("owner-timeline"), request("owner-wake")],
        )
        .expect("the commit lands");

    let database = scratch.database();
    let pending = database
        .pending_notice_intents(MAX_OUTBOX_BATCH)
        .expect("pending intents read");
    assert_eq!(pending.len(), 2);
    assert!(
        pending
            .iter()
            .all(|intent| intent.sequence == committed.snapshot.sequence)
    );

    // The intent addresses the committed body instead of carrying a copy of it:
    // resolving the address finds the event that was committed with it.
    for intent in &pending {
        let body = support::event_body(database, &intent.run_id, intent.sequence)
            .expect("the referenced body is committed");
        let event: ReducerEvent =
            serde_json::from_str(&body).expect("the body is the committed event");
        assert_eq!(event, ReducerEvent::CancelRequested);
    }
    assert_eq!(
        support::count(database, "workflow_notice_intents", "status='pending'"),
        2
    );
}

#[test]
fn the_same_logical_notice_requested_twice_is_one_intent() {
    let (scratch, port) = started("intent-dedupe").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");
    port.commit_with_notices(
        "run-1",
        head.sequence,
        ReducerEvent::CancelRequested,
        &[request("owner-timeline"), request("owner-timeline")],
    )
    .expect("the commit lands");

    assert_eq!(
        support::count(scratch.database(), "workflow_notice_intents", "1=1"),
        1,
        "identity is the fact, so a repeated request is not a second piece of work"
    );
}

#[test]
fn a_page_is_bounded_and_refuses_to_pretend_a_larger_one_was_read() {
    let scratch = support::ScratchDatabase::new("intent-bound").expect("fixture");
    let database = scratch.database();
    // Three runs, each committing a full page of owners, so the outbox holds
    // more than one page. The outbox is the database's, not a run's.
    for index in 0..3 {
        let label = format!("run-bound-{index}");
        let port = support::graph(database, &label).expect("the run starts");
        let sequence = port.checkpoint(&label).expect("checkpoint reads").sequence;
        let owners: Vec<NoticeRequest> = (0..MAX_OUTBOX_BATCH)
            .map(|owner| request(&format!("owner-{owner}")))
            .collect();
        port.commit_with_notices(&label, sequence, ReducerEvent::CancelRequested, &owners)
            .expect("the commit lands");
    }
    let pending = support::count(database, "workflow_notice_intents", "status='pending'");
    assert_eq!(pending, 3 * MAX_OUTBOX_BATCH as i64);

    let page = database
        .pending_notice_intents(MAX_OUTBOX_BATCH)
        .expect("a full page reads");
    assert_eq!(
        page.len(),
        MAX_OUTBOX_BATCH,
        "a page is a page, not the table"
    );
    let small = database
        .pending_notice_intents(4)
        .expect("a small page reads");
    assert_eq!(small.len(), 4);
    assert_eq!(
        small,
        page[..4].to_vec(),
        "the oldest intents come first, so a drain makes progress"
    );
    let error = database
        .pending_notice_intents(MAX_OUTBOX_BATCH + 1)
        .expect_err("a request beyond the bound is refused")
        .to_string();
    assert!(
        error.starts_with("workflow_outbox_limit_invalid"),
        "unexpected: {error}"
    );
    assert!(
        database.pending_notice_intents(0).is_err(),
        "a page of nothing is not a way to ask for everything"
    );
}

#[test]
fn a_commit_cannot_write_more_intents_than_a_page_can_read() {
    let (_scratch, port) = started("intent-write-bound").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");
    let owners: Vec<NoticeRequest> = (0..=MAX_OUTBOX_BATCH)
        .map(|index| request(&format!("owner-{index}")))
        .collect();
    let error = port
        .commit_with_notices(
            "run-1",
            head.sequence,
            ReducerEvent::CancelRequested,
            &owners,
        )
        .expect_err("an unbounded commit is refused")
        .to_string();
    assert!(
        error.starts_with("workflow_outbox_limit_invalid"),
        "unexpected: {error}"
    );
}

#[test]
fn the_pending_query_is_an_index_scan_in_the_outbox_order() {
    let (scratch, _port) = started("intent-plan").expect("fixture");
    let plan = support::query_plan(
        scratch.database(),
        "SELECT notice_id FROM workflow_notice_intents
         WHERE status='pending'
         ORDER BY created_at ASC, run_id ASC, sequence ASC, notice_id ASC
         LIMIT 256",
    );
    let joined = plan.join(" | ");
    assert!(
        joined.contains("workflow_notice_intents_pending_idx"),
        "the pending query must use its own index: {joined}"
    );
    assert!(
        !joined.contains("TEMP B-TREE"),
        "sorting every pending row would make the page cost grow with the \
         backlog, which is what the bound exists to prevent: {joined}"
    );
}

#[test]
fn an_acknowledgement_closes_exactly_one_pending_intent() {
    let (scratch, port) = started("intent-ack").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");
    port.commit_with_notices(
        "run-1",
        head.sequence,
        ReducerEvent::CancelRequested,
        &[request("owner-timeline")],
    )
    .expect("the commit lands");
    let database = scratch.database();
    let intent = database
        .pending_notice_intents(1)
        .expect("pending intents read")
        .remove(0);

    database
        .acknowledge_notice(&intent.notice_id)
        .expect("the pending intent closes");
    assert_eq!(
        support::count(database, "workflow_notice_intents", "status='pending'"),
        0
    );
    let error = database
        .acknowledge_notice(&intent.notice_id)
        .expect_err("a second acknowledgement is refused")
        .to_string();
    assert!(
        error.starts_with("workflow_notice_intent_missing"),
        "an acknowledgement of something already acknowledged must not be \
         confirmed as if it had just happened: {error}"
    );
}

#[test]
fn accepting_a_notice_records_it_durably_and_recognises_the_repeat() {
    let (scratch, port) = started("intent-sink").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");
    port.commit_with_notices(
        "run-1",
        head.sequence,
        ReducerEvent::CancelRequested,
        &[request("owner-timeline")],
    )
    .expect("the commit lands");
    let database = scratch.database();
    let intent = database
        .pending_notice_intents(1)
        .expect("pending intents read")
        .remove(0);
    let notice = notice_of(&intent);

    let sink = DurableNoticeSink::new(database.clone());
    sink.accept(&notice).expect("the sink accepts the fact");
    assert_eq!(
        support::count(database, "workflow_notice_intents", "status='pending'"),
        0,
        "acceptance closes the intent it was owed for"
    );
    let first = database
        .accept_notice(&notice)
        .expect("a repeat is accepted");
    assert!(
        !first.first_acceptance,
        "the second acceptance is a repeat, not new work"
    );
    assert_eq!(first.accept_count, 2);
    assert_eq!(
        support::count(database, "workflow_notice_acceptances", "1=1"),
        1,
        "one fact, one accepted ledger row"
    );
}

#[test]
fn an_owner_name_at_its_full_length_still_gets_a_usable_identity() {
    // A notice identity is composed from three fields that may each be at their
    // limit, so the identity is longer than any of them and must still be
    // readable and acknowledgeable.
    let (scratch, port) = started("intent-long").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");
    let long_owner = "owner".repeat(32);
    assert_eq!(long_owner.len(), 160);
    port.commit_with_notices(
        "run-1",
        head.sequence,
        ReducerEvent::CancelRequested,
        &[NoticeRequest {
            recipient: long_owner.clone(),
            kind: "reliability".to_owned(),
        }],
    )
    .expect("the commit lands");
    let database = scratch.database();
    let intent = database
        .pending_notice_intents(1)
        .expect("pending intents read")
        .remove(0);
    assert!(intent.notice_id.len() > 160);
    database
        .acknowledge_notice(&intent.notice_id)
        .expect("an identity longer than one field is still acknowledgeable");
    assert_eq!(
        support::count(database, "workflow_notice_intents", "status='pending'"),
        0
    );
}

#[test]
fn a_notice_cannot_be_given_an_identity_of_its_own() {
    let (scratch, port) = started("intent-identity").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");
    let committed = port
        .commit_with_notices(
            "run-1",
            head.sequence,
            ReducerEvent::CancelRequested,
            &[request("owner-timeline")],
        )
        .expect("the commit lands");

    let mut notice = notice_of(
        &scratch
            .database()
            .pending_notice_intents(1)
            .expect("pending intents read")
            .remove(0),
    );
    notice.notice_id = format!("{}-again", notice.notice_id);
    let error = scratch
        .database()
        .accept_notice(&notice)
        .expect_err("a minted identity is refused")
        .to_string();
    assert!(
        error.starts_with("workflow_notice_identity_invalid"),
        "a caller must not be able to open a second equivalent round for a fact \
         it already sent: {error}"
    );
    assert_eq!(committed.snapshot.sequence, head.sequence + 1);
}

#[test]
fn two_owners_of_one_fact_are_confirmed_separately() {
    // A09 requires the timeline projection and the reliable wake to be
    // confirmed independently. They are two intents for one fact: accepting
    // one must not close the other, and each owner gets its own durable
    // acceptance.
    let (scratch, port) = started("intent-separate").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");
    port.commit_with_notices(
        "run-1",
        head.sequence,
        ReducerEvent::CancelRequested,
        &[
            request("owner-timeline"),
            NoticeRequest {
                recipient: "owner-wake".to_owned(),
                kind: "reliability".to_owned(),
            },
        ],
    )
    .expect("the commit lands");

    let database = scratch.database();
    let intents = database
        .pending_notice_intents(2)
        .expect("pending intents read");
    assert_eq!(intents.len(), 2);
    let timeline = intents
        .iter()
        .find(|intent| intent.kind == "timeline")
        .expect("the timeline intent")
        .clone();
    let wake = intents
        .iter()
        .find(|intent| intent.kind == "reliability")
        .expect("the wake intent")
        .clone();

    let sink = DurableNoticeSink::new(database.clone());
    sink.accept(&notice_of(&timeline))
        .expect("the timeline owner accepts");
    let still_pending = database
        .pending_notice_intents(2)
        .expect("pending intents read");
    assert_eq!(
        still_pending.len(),
        1,
        "accepting one owner's notice must not close the other's"
    );
    assert_eq!(still_pending[0].notice_id, wake.notice_id);

    sink.accept(&notice_of(&wake))
        .expect("the wake owner accepts");
    assert_eq!(
        support::count(database, "workflow_notice_intents", "status='pending'"),
        0
    );
    assert_eq!(
        support::count(database, "workflow_notice_acceptances", "1=1"),
        2,
        "each owner keeps its own acceptance ledger row"
    );
}
