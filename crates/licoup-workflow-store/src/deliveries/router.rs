//! The reconcile pass: claim by lane, hand the fact to its owner, close it.
//!
//! ## The order inside one pass
//!
//! ```text
//!   claim   (one short write transaction)   ─┐
//!   accept  (the sink, no write lock held)  ─┤ the same rule the write path
//!   close   (one short write transaction)   ─┘ already follows for effects
//!   retry   (the claim is released, the obligation stays open)
//! ```
//!
//! A sink call is never made inside a write transaction: it may reach another
//! database, another process, or the network, and holding the single SQLite
//! writer across it would put every graph behind whatever the sink is waiting
//! for. So the claim and the close are two short writes, and the interesting
//! state in between — a lease held by a pass that has not finished — is exactly
//! what a lease is for.
//!
//! ## What the port's success means, and what is done with it
//!
//! [`NoticeSink::accept`] returns `Ok` only once the owner has the fact durably
//! (C01). This pass acts on exactly that: `Ok` closes the obligation, `Err`
//! leaves it open and pushes the claim to a retry time. It does **not** look
//! behind the sink to check for itself, because a second opinion about "is it
//! durable" would be a second authority over the same question.
//!
//! ## Acceptances are accounted separately, and the ack is their intersection
//!
//! One fact owed to two owners is two obligations, so a failure of one leaves
//! the other's acceptance untouched and retries only its own. The final
//! acknowledgement of the *fact* is
//! [`NoticeRouter::notice_disposition`], which reads the durable rows and asks
//! [`licoup_workflow_runtime::routing::NoticeAcceptance`] for the intersection —
//! the same rule the owners' ledgers are measured against, so no participant can
//! settle a fact the others have not.
//!
//! ## A port that is not assembled cannot ack
//!
//! The pass claims nothing for an owner whose sink is not registered
//! ([`crate::deliveries::lanes::NoticeLanes::claim_next`]), and reports what it
//! left alone in [`ReconcileReport::blocked_recipients`]. That is the whole of
//! the rule: there is no code path in which an obligation for an unassembled
//! port is closed, because there is no code path in which it is claimed.

use anyhow::{Result, ensure};
use licoup_workflow_runtime::ports::{Notice, NoticeSink};
use licoup_workflow_runtime::routing::{AcceptancePlan, NoticeAcceptance, NoticeDisposition};
use std::collections::BTreeMap;
use std::sync::Arc;

use super::lanes::NoticeLanes;

/// The most obligations one pass may take.
///
/// A bound is the point: a pass that can ask for "everything" eventually does.
/// A pass claims up to this many, closes them, and comes back for the rest, so
/// its cost is a property of the pass rather than of the backlog. A caller
/// asking for more is refused rather than quietly given a shorter pass.
pub const MAX_RECONCILE_BATCH: usize = 256;

/// How long a failed obligation waits before it is claimable again.
///
/// Doubling from `base_delay_ms` and capped at `max_delay_ms`, computed from the
/// notice's own attempt count, so a sink that is down is retried less and less
/// often while a sink that recovers is picked up on the next pass that finds its
/// lease elapsed. The delay is a claim's lease, not a sleep: no pass ever waits.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryPolicy {
    pub base_delay_ms: i64,
    pub max_delay_ms: i64,
}

impl RetryPolicy {
    pub fn new(base_delay_ms: i64, max_delay_ms: i64) -> Result<Self> {
        ensure!(
            base_delay_ms >= 1 && max_delay_ms >= base_delay_ms,
            "workflow_notice_retry_policy_invalid: base {base_delay_ms}, max {max_delay_ms}"
        );
        Ok(Self {
            base_delay_ms,
            max_delay_ms,
        })
    }

    /// The delay before the `attempt`-th retry, saturating at the cap.
    pub fn delay_ms(&self, attempt: u32) -> i64 {
        let shift = attempt.saturating_sub(1).min(16);
        let delay = self.base_delay_ms.saturating_mul(1_i64 << shift);
        delay.min(self.max_delay_ms)
    }
}

/// What one pass did, and what it could not do.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ReconcileReport {
    /// Obligations the pass took under a lease.
    pub claimed: usize,
    /// Obligations whose owner accepted them, and which are now closed.
    pub accepted: usize,
    /// Obligations whose owner refused or failed; each is retryable on its own.
    pub failed: usize,
    /// Pending obligations nobody could take, per unassembled owner.
    pub blocked_recipients: BTreeMap<String, usize>,
}

impl ReconcileReport {
    /// Whether the pass found nothing left to take for the owners it has.
    pub fn is_drained(&self) -> bool {
        self.claimed == 0 && self.blocked_recipients.is_empty()
    }
}

/// The assembled sinks and the lanes they are served from.
pub struct NoticeRouter {
    lanes: NoticeLanes,
    retry: RetryPolicy,
    sinks: BTreeMap<String, Arc<dyn NoticeSink>>,
}

impl NoticeRouter {
    pub(crate) fn new(lanes: NoticeLanes, retry: RetryPolicy) -> Self {
        Self {
            lanes,
            retry,
            sinks: BTreeMap::new(),
        }
    }

    /// Assemble one owner's sink.
    ///
    /// An owner is registered once. Registering it twice is refused rather than
    /// replacing the sink: a pass that swapped an owner's port halfway through a
    /// boot would be choosing, silently, which implementation accepted a fact.
    pub fn register_sink(
        &mut self,
        owner: impl Into<String>,
        sink: Arc<dyn NoticeSink>,
    ) -> Result<()> {
        let owner = owner.into();
        ensure!(
            !owner.trim().is_empty()
                && owner == owner.trim()
                && !owner.chars().any(char::is_control),
            "workflow_notice_owner_invalid"
        );
        ensure!(
            !self.sinks.contains_key(&owner),
            "workflow_notice_sink_duplicate: {owner}"
        );
        self.sinks.insert(owner, sink);
        Ok(())
    }

    /// The owners whose sinks are assembled, in a stable order.
    pub fn owners(&self) -> Vec<String> {
        self.sinks.keys().cloned().collect()
    }

    pub fn retry(&self) -> RetryPolicy {
        self.retry
    }

    pub fn lanes(&self) -> &NoticeLanes {
        &self.lanes
    }

    /// Take up to `budget` obligations and carry each to its owner.
    ///
    /// `lease_ms` is how long a claim is held before another pass may take it;
    /// it bounds how long a crash can hold an obligation off, not how long this
    /// call runs.
    pub fn reconcile(
        &self,
        claimant: &str,
        now_unix_ms: i64,
        lease_ms: i64,
        budget: usize,
    ) -> Result<ReconcileReport> {
        ensure!(
            budget > 0 && budget <= MAX_RECONCILE_BATCH,
            "workflow_notice_reconcile_budget_invalid: 1..={MAX_RECONCILE_BATCH}, requested {budget}"
        );
        ensure!(lease_ms > 0, "workflow_notice_lease_invalid: {lease_ms}");
        let owners = self.owners();
        let mut report = ReconcileReport::default();
        for _ in 0..budget {
            let Some(lease) = self.lanes.claim_next(
                &owners,
                claimant,
                now_unix_ms,
                now_unix_ms.saturating_add(lease_ms),
            )?
            else {
                break;
            };
            report.claimed += 1;
            let Some(sink) = self.sinks.get(&lease.notice.recipient) else {
                anyhow::bail!(
                    "workflow_notice_sink_missing: {} was claimed without an assembled sink",
                    lease.notice.recipient
                );
            };
            let notice = Notice {
                notice_id: lease.notice.notice_id.clone(),
                run_id: lease.notice.run_id.clone(),
                sequence: lease.notice.sequence,
                recipient: lease.notice.recipient.clone(),
                kind: lease.notice.kind.clone(),
            };
            match sink.accept(&notice) {
                Ok(()) => {
                    self.lanes.acknowledge(&lease)?;
                    report.accepted += 1;
                }
                Err(_) => {
                    let delay = self.retry.delay_ms(lease.attempt);
                    self.lanes
                        .release(&lease, now_unix_ms.saturating_add(delay))?;
                    report.failed += 1;
                }
            }
        }
        report.blocked_recipients = self.lanes.blocked_recipients(&owners)?;
        Ok(report)
    }

    /// Whether one committed fact is settled: the intersection of what its
    /// required owners have durably accepted.
    ///
    /// Read from the durable rows rather than from this process's memory, so a
    /// fact accepted by a host that has since exited is still settled, and a
    /// fact whose owner is not running here is still owed.
    pub fn notice_disposition(
        &self,
        run_id: &str,
        sequence: u64,
        kind: &str,
    ) -> Result<NoticeDisposition> {
        let rows = self.database_rows(run_id, sequence, kind)?;
        ensure!(
            !rows.is_empty(),
            "workflow_notice_fact_unknown: {run_id}:{sequence}:{kind} owes nothing and cannot be settled"
        );
        let plan = AcceptancePlan::new(rows.keys().cloned())?;
        let mut acceptance = NoticeAcceptance::new(plan);
        for owner in self.sinks.keys() {
            acceptance.assemble(owner);
        }
        for (owner, accepted) in rows {
            if accepted == 0 {
                continue;
            }
            acceptance.restore(&owner, accepted)?;
        }
        Ok(acceptance.disposition())
    }

    /// One row per required owner of one fact: how many times it has accepted.
    ///
    /// A closed obligation counts as accepted even when the owner's own ledger
    /// has no row for it: closing happens only after a sink returned `Ok`, and
    /// the port contract defines that as durable acceptance. The ledger, when it
    /// has a row, is the count of how many times.
    fn database_rows(
        &self,
        run_id: &str,
        sequence: u64,
        kind: &str,
    ) -> Result<BTreeMap<String, u64>> {
        use rusqlite::params;
        self.lanes.database().read(|connection| {
            let mut statement = connection.prepare(
                "SELECT i.recipient, i.status, COALESCE(a.accept_count, 0)
                 FROM workflow_notice_intents i
                 LEFT JOIN workflow_notice_acceptances a ON a.notice_id = i.notice_id
                 WHERE i.run_id=?1 AND i.sequence=?2 AND i.kind=?3
                 ORDER BY i.recipient ASC",
            )?;
            let rows = statement.query_map(params![run_id, sequence as i64, kind], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?;
            let mut owners = BTreeMap::new();
            for row in rows {
                let (owner, status, ledger) = row?;
                let ledger = u64::try_from(ledger.max(0)).unwrap_or(u64::MAX);
                let accepted = if status == "accepted" {
                    ledger.max(1)
                } else {
                    ledger
                };
                owners.insert(owner, accepted);
            }
            Ok(owners)
        })
    }
}

impl std::fmt::Debug for NoticeRouter {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("NoticeRouter")
            .field("owners", &self.sinks.keys().collect::<Vec<_>>())
            .field("retry", &self.retry)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::super::testing::ScratchDelivery;
    use super::*;
    use licoup_workflow_runtime::routing::{LanePolicy, LaneWeights, QueueClass};
    use rusqlite::params;
    use std::sync::Mutex;

    fn policy() -> LanePolicy {
        LanePolicy::new(
            vec!["cancel".to_owned()],
            vec!["completion".to_owned()],
            LaneWeights::equal(),
        )
        .unwrap()
    }

    /// A sink that records what it was handed and can be told to fail.
    #[derive(Default)]
    struct RecordingSink {
        accepted: Mutex<Vec<String>>,
        fail: bool,
    }

    impl RecordingSink {
        fn failing() -> Self {
            Self {
                fail: true,
                ..Self::default()
            }
        }

        fn accepted(&self) -> Vec<String> {
            self.accepted.lock().expect("the sink lock").clone()
        }
    }

    impl NoticeSink for RecordingSink {
        fn accept(&self, notice: &Notice) -> Result<()> {
            if self.fail {
                anyhow::bail!("sink down");
            }
            self.accepted
                .lock()
                .expect("the sink lock")
                .push(notice.notice_id.clone());
            Ok(())
        }
    }

    /// A sink that accepts durably through the ledger the real one uses, and
    /// records what each acceptance was: a first acceptance or a repeat.
    #[derive(Default)]
    struct DurableSink {
        database: Option<Arc<crate::transactions::WorkflowDatabase>>,
        seen: Mutex<Vec<(String, bool)>>,
    }

    impl DurableSink {
        fn new(database: Arc<crate::transactions::WorkflowDatabase>) -> Self {
            Self {
                database: Some(database),
                seen: Mutex::new(Vec::new()),
            }
        }

        fn seen(&self) -> Vec<(String, bool)> {
            self.seen.lock().expect("the sink lock").clone()
        }
    }

    impl NoticeSink for DurableSink {
        fn accept(&self, notice: &Notice) -> Result<()> {
            let database = self
                .database
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("the fixture has no database"))?;
            let acceptance = database.accept_notice(notice)?;
            self.seen
                .lock()
                .expect("the sink lock")
                .push((notice.notice_id.clone(), acceptance.first_acceptance));
            Ok(())
        }
    }

    fn retry() -> RetryPolicy {
        RetryPolicy::new(100, 1_000).unwrap()
    }

    #[test]
    fn a_pass_claims_in_lane_order_and_closes_what_it_accepted() {
        let delivery = ScratchDelivery::new("router-pass");
        let mut router = delivery.assembly().router(policy(), retry());
        let timeline = Arc::new(RecordingSink::default());
        router
            .register_sink("timeline", timeline.clone())
            .expect("the sink registers");
        for index in 0..3 {
            delivery.seed_intent("run-1", index, "timeline", "history-page", index as i64);
        }
        let cancel = delivery.seed_intent("run-1", 9, "timeline", "cancel", 9);

        let report = router
            .reconcile("host-1", 1_000, 5_000, 2)
            .expect("the pass runs");
        assert_eq!(report.claimed, 2);
        assert_eq!(report.accepted, 2);
        assert_eq!(report.failed, 0);
        assert_eq!(report.blocked_recipients, BTreeMap::new());
        assert!(
            timeline.accepted().contains(&cancel),
            "the cancel is in the first pass: a bulk backlog cannot hold it"
        );
        assert_eq!(delivery.intent_status(&cancel), "accepted");
    }

    #[test]
    fn a_budget_larger_than_a_pass_is_refused_rather_than_truncated() {
        let delivery = ScratchDelivery::new("router-budget");
        let router = delivery.assembly().router(policy(), retry());
        for budget in [0, MAX_RECONCILE_BATCH + 1] {
            let error = router
                .reconcile("host-1", 1_000, 5_000, budget)
                .expect_err("a budget outside the bound is refused");
            assert!(
                error
                    .to_string()
                    .starts_with("workflow_notice_reconcile_budget_invalid"),
                "{error}"
            );
        }
    }

    #[test]
    fn a_failing_owner_is_retried_alone_and_the_other_owner_is_untouched() {
        let delivery = ScratchDelivery::new("router-separate");
        let mut router = delivery.assembly().router(policy(), retry());
        let timeline = Arc::new(RecordingSink::default());
        let wake = Arc::new(RecordingSink::failing());
        router
            .register_sink("timeline", timeline.clone())
            .expect("the sink registers");
        router
            .register_sink("wake", wake.clone())
            .expect("the sink registers");
        // One fact owed to two owners: a projection and a wake.
        let projected = delivery.seed_intent("run-1", 1, "timeline", "completion", 1);
        let wake_notice = delivery.seed_intent("run-1", 1, "wake", "completion", 2);

        let report = router
            .reconcile("host-1", 1_000, 5_000, 4)
            .expect("the pass runs");
        assert_eq!(report.accepted, 1, "the projection was accepted");
        assert_eq!(report.failed, 1, "the wake owner failed on its own");
        assert_eq!(delivery.intent_status(&projected), "accepted");
        assert_eq!(delivery.intent_status(&wake_notice), "pending");

        // The fact is not settled: one of its two owners has not accepted.
        let disposition = router
            .notice_disposition("run-1", 1, "completion")
            .expect("the disposition reads");
        let owed = disposition.pending().expect("still owed");
        assert_eq!(owed.retryable, vec!["wake".to_owned()]);
        assert!(owed.unassembled.is_empty());

        // Its retry is its own: the lease moved, and the accepted projection
        // holds no claim at all.
        let claim = delivery.claim(&wake_notice).expect("the claim is held");
        assert_eq!(claim.2, 1, "one attempt so far");
        assert_eq!(claim.1, 1_100, "the retry waits for the policy");
        assert_eq!(delivery.claim(&projected), None);
    }

    #[test]
    fn a_restart_redelivers_physically_and_creates_the_logical_work_once() {
        let delivery = ScratchDelivery::new("router-restart");
        let mut router = delivery.assembly().router(policy(), retry());
        let sink = Arc::new(DurableSink::new(delivery.database().clone()));
        router
            .register_sink("timeline", sink.clone())
            .expect("the sink registers");
        let notice_id = delivery.seed_intent("run-1", 1, "timeline", "completion", 1);

        let first = router
            .reconcile("host-1", 1_000, 5_000, 4)
            .expect("the pass runs");
        assert_eq!(first.accepted, 1);
        assert_eq!(sink.seen(), vec![(notice_id.clone(), true)]);
        assert_eq!(delivery.acceptance_count(&notice_id), Some(1));

        // The host restarts: a new assembly and a new pass, and the same fact is
        // physically redelivered because the obligation was still open when the
        // first host went down.
        let assembly = super::super::DeliveryAssembly::assemble(delivery.database().clone())
            .expect("reassembly");
        let mut restarted = assembly.router(policy(), retry());
        restarted
            .register_sink("timeline", sink.clone())
            .expect("the sink registers");
        delivery
            .database()
            .write(|transaction, _| {
                Ok(transaction.execute(
                    "UPDATE workflow_notice_intents SET status='pending', accepted_at=NULL
                     WHERE notice_id=?1",
                    params![notice_id],
                )?)
            })
            .expect("the fixture reopens the obligation");

        let second = restarted
            .reconcile("host-2", 2_000, 5_000, 4)
            .expect("the pass runs");
        assert_eq!(
            second.accepted, 1,
            "the obligation is taken again: at-least-once delivery"
        );
        assert_eq!(
            sink.seen(),
            vec![(notice_id.clone(), true), (notice_id.clone(), false)],
            "the second physical delivery is a repeat, not a second logical creation"
        );
        assert_eq!(
            delivery.acceptance_count(&notice_id),
            Some(2),
            "and the ledger counts the repeat"
        );
        assert_eq!(delivery.intent_status(&notice_id), "accepted");
        assert_eq!(
            restarted
                .reconcile("host-2", 3_000, 5_000, 4)
                .expect("the pass runs")
                .accepted,
            0,
            "the closed obligation is not taken again"
        );
    }

    #[test]
    fn a_claim_that_crashed_before_accepting_is_redelivered_after_its_lease() {
        let delivery = ScratchDelivery::new("router-crash-before-accept");
        let lanes = delivery.assembly().lanes(policy());
        let sink = Arc::new(RecordingSink::default());
        let notice_id = delivery.seed_intent("run-1", 1, "timeline", "completion", 1);
        // Host 1 takes the claim and dies before its sink ever sees the fact.
        let lease = lanes
            .claim_next(&["timeline".to_owned()], "host-1", 1_000, 2_000)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(lease.notice.notice_id, notice_id);

        // A second host over the same file cannot take it while the lease holds,
        // and takes the same fact once it has expired: nothing was lost.
        let mut restarted = delivery.assembly().router(policy(), retry());
        restarted
            .register_sink("timeline", sink.clone())
            .expect("the sink registers");
        assert_eq!(
            restarted
                .reconcile("host-2", 1_500, 5_000, 4)
                .expect("the pass runs")
                .claimed,
            0,
            "the lease still holds the fact off"
        );
        let report = restarted
            .reconcile("host-2", 2_500, 5_000, 4)
            .expect("the pass runs");
        assert_eq!(report.accepted, 1);
        assert_eq!(sink.accepted(), vec![notice_id.clone()]);
        assert_eq!(delivery.intent_status(&notice_id), "accepted");
    }

    #[test]
    fn a_claim_that_crashed_after_the_sink_accepted_is_not_redelivered() {
        let delivery = ScratchDelivery::new("router-crash-after-accept");
        let lanes = delivery.assembly().lanes(policy());
        let sink = Arc::new(DurableSink::new(delivery.database().clone()));
        let notice_id = delivery.seed_intent("run-1", 1, "timeline", "completion", 1);
        let lease = lanes
            .claim_next(&["timeline".to_owned()], "host-1", 1_000, 2_000)
            .expect("a claim")
            .expect("work is waiting");
        // The sink's durable acceptance is the contract, and the real sink closes
        // the obligation as part of accepting. The host then dies before its pass
        // can acknowledge.
        sink.accept(&Notice {
            notice_id: lease.notice.notice_id.clone(),
            run_id: lease.notice.run_id.clone(),
            sequence: lease.notice.sequence,
            recipient: lease.notice.recipient.clone(),
            kind: lease.notice.kind.clone(),
        })
        .expect("the sink accepts durably");

        let mut restarted = delivery.assembly().router(policy(), retry());
        restarted
            .register_sink("timeline", sink.clone())
            .expect("the sink registers");
        let report = restarted
            .reconcile("host-2", 2_500, 5_000, 4)
            .expect("the pass runs");
        assert_eq!(
            report.claimed, 0,
            "an obligation the sink already accepted is not carried again"
        );
        assert_eq!(
            sink.seen(),
            vec![(notice_id.clone(), true)],
            "one physical acceptance, and it was the first"
        );
        assert_eq!(delivery.acceptance_count(&notice_id), Some(1));
        assert_eq!(delivery.intent_status(&notice_id), "accepted");
    }

    #[test]
    fn a_durable_owner_keeps_its_acceptance_when_this_host_has_no_sink_for_it() {
        let delivery = ScratchDelivery::new("router-durable-owner");
        let mut first = delivery.assembly().router(policy(), retry());
        first
            .register_sink(
                "timeline",
                Arc::new(DurableSink::new(delivery.database().clone())),
            )
            .expect("the sink registers");
        delivery.seed_intent("run-1", 1, "timeline", "completion", 1);
        first
            .reconcile("host-1", 1_000, 5_000, 4)
            .expect("the pass runs");

        // A later host serves a different owner: the projection is still settled
        // because the acceptance is durable, and the fact is acknowledged.
        let mut second = delivery.assembly().router(policy(), retry());
        second
            .register_sink("metrics", Arc::new(RecordingSink::default()))
            .expect("the sink registers");
        assert_eq!(
            second
                .notice_disposition("run-1", 1, "completion")
                .expect("the disposition reads"),
            NoticeDisposition::Acknowledged
        );
    }

    #[test]
    fn an_owner_with_no_assembled_port_is_reported_and_never_settled() {
        let delivery = ScratchDelivery::new("router-unassembled");
        let router = delivery.assembly().router(policy(), retry());
        let wake = delivery.seed_intent("run-1", 1, "wake", "completion", 1);
        let report = router
            .reconcile("host-1", 1_000, 5_000, 4)
            .expect("the pass runs");
        assert_eq!(report.claimed, 0);
        assert_eq!(
            report.blocked_recipients,
            BTreeMap::from([("wake".to_owned(), 1)]),
            "the pass says what it could not serve instead of reporting an empty queue"
        );
        assert!(!report.is_drained());
        assert_eq!(delivery.intent_status(&wake), "pending");
        let disposition = router
            .notice_disposition("run-1", 1, "completion")
            .expect("the disposition reads");
        assert!(!disposition.is_acknowledged());
    }

    #[test]
    fn a_fact_that_owes_nothing_cannot_be_settled() {
        let delivery = ScratchDelivery::new("router-unknown-fact");
        let router = delivery.assembly().router(policy(), retry());
        let error = router
            .notice_disposition("run-absent", 1, "completion")
            .expect_err("a fact with no obligation is not a settled fact");
        assert!(
            error
                .to_string()
                .starts_with("workflow_notice_fact_unknown"),
            "{error}"
        );
    }

    #[test]
    fn an_owner_cannot_be_assembled_twice() {
        let delivery = ScratchDelivery::new("router-duplicate-owner");
        let mut router = delivery.assembly().router(policy(), retry());
        router
            .register_sink("timeline", Arc::new(RecordingSink::default()))
            .expect("the sink registers");
        let error = router
            .register_sink("timeline", Arc::new(RecordingSink::default()))
            .expect_err("a second sink for one owner is refused");
        assert!(
            error
                .to_string()
                .starts_with("workflow_notice_sink_duplicate"),
            "{error}"
        );
        assert_eq!(router.owners(), vec!["timeline".to_owned()]);
    }

    #[test]
    fn the_retry_delay_grows_and_stops_at_its_cap() {
        let policy = RetryPolicy::new(100, 1_000).unwrap();
        assert_eq!(policy.delay_ms(1), 100);
        assert_eq!(policy.delay_ms(2), 200);
        assert_eq!(policy.delay_ms(5), 1_000);
        assert_eq!(policy.delay_ms(40), 1_000);
        assert!(RetryPolicy::new(0, 1_000).is_err());
        assert!(RetryPolicy::new(1_000, 100).is_err());
    }

    #[test]
    fn a_pass_claims_the_lane_the_policy_puts_the_kind_in() {
        let delivery = ScratchDelivery::new("router-lane-policy");
        let mut router = delivery.assembly().router(policy(), retry());
        router
            .register_sink("timeline", Arc::new(RecordingSink::default()))
            .expect("the sink registers");
        delivery.seed_intent("run-1", 1, "timeline", "unclassified", 1);
        let lease = router
            .lanes()
            .claim_next(&router.owners(), "host-1", 1_000, 5_000)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(
            lease.lane,
            QueueClass::Bulk,
            "a kind nobody declared is bulk and takes no reserved turn"
        );
    }
}
