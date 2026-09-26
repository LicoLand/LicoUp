//! The durable lanes: which owed delivery is claimed next, under a lease.
//!
//! ## One obligation per row, one lease per obligation
//!
//! The obligation to deliver is V7-S1's intent row, committed with the fact. A
//! claim is a row of its own keyed by the notice's identity, and it carries a
//! lease rather than a lock: a pass that dies holding one leaves the lease to
//! expire into availability, which is what makes a crashed host a retry instead
//! of a lost delivery. The alternative — removing the row on claim — would make
//! a crash a silent loss, and "at-least-once" is the property the whole
//! acceptance ledger is built on.
//!
//! ## The lane is derived, the turn is persisted
//!
//! Which lane an intent belongs to is answered by the declared policy from its
//! kind, so there is no lane column that could disagree with the policy. The
//! *fairness state* is different: it is the position in the service cycle, and
//! it is persisted in the same write transaction that takes the claim, so a
//! restart resumes the cycle instead of handing the reserved lane a fresh turn
//! (see [`LanePosition`]).
//!
//! ## Bounded reads, and what each bound actually is
//!
//! A claim reads lazily and in the order the arbiter ranks the classes: a class
//! the arbiter cannot choose now is never probed, so a servable reserved turn
//! does not read the bulk lane at all.
//!
//! A reserved lane is probed once per declared kind *and* assembled owner,
//! behind an index on `(status, kind, recipient, created_at, ...)`. Those two
//! equalities let the index serve the filter and the ordering together, so the
//! probe stops at the first row of that pair no live lease holds: what it walks
//! past is the *leased* rows of that pair — bounded by how many passes are
//! working, not by how far behind the outbox has fallen. A hundred thousand
//! unleased rows for another owner or another kind cost it nothing.
//!
//! The bulk lane is the one read that cannot be a seek. "Not one of the declared
//! kinds" is not a value an index can be seeked to, and this module deliberately
//! keeps no lane column (that would be a second owner of the classification). So
//! the bulk probe walks pending rows in `created_at` order, rejecting by kind
//! and by owner as it goes, until it reaches a row no reserved lane declares and
//! an assembled owner owns; its cost is the number of pending rows older than
//! that row, and the whole pending set when there is no such row. Two properties
//! keep that honest rather than hidden: the walk happens only when the arbiter
//! actually reaches the bulk lane (with weights 4:2:1 that is one service turn
//! in seven, not every claim), and the row returned is still exactly one. A host
//! that needed the bulk probe itself to be constant-cost would need a durable
//! lane mark, which is a classification owner this module does not create; the
//! read side's per-pass bound, [`crate::transactions::MAX_OUTBOX_BATCH`], is a
//! different guarantee on a different path.
//!
//! The operator's [`NoticeLanes::stats`] count is deliberately not on the claim
//! path: it counts, which is what a report should do and what a claim must not.

use anyhow::{Result, ensure};
use licoup_workflow_runtime::routing::{LaneCounts, LanePolicy, LanePosition, QueueClass};
use rusqlite::types::Value;
use rusqlite::{OptionalExtension, StatementStatus, Transaction, params, params_from_iter};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use super::{LANE_CLASS_KEY, LANE_SERVED_KEY};
use crate::transactions::{NoticeIntent, WorkflowDatabase};

/// One claimed delivery, under a lease held by one claimant.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoticeLease {
    pub notice: NoticeIntent,
    /// The lane the arbiter chose for it.
    pub lane: QueueClass,
    pub claimant: String,
    pub lease_until_unix_ms: i64,
    /// How many times this notice has been claimed, including this claim.
    pub attempt: u32,
}

/// What the lanes hold: an operator-facing count, and where the cycle is.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NoticeLaneStats {
    pub pending: LaneCounts,
    pub position: LanePosition,
}

/// The fair lanes over one assembled delivery side.
///
/// Cloning shares the database; the policy is copied. Two lanes with different
/// policies over the same file would disagree about which class a kind belongs
/// to, so a host should hold one per policy.
#[derive(Clone)]
pub struct NoticeLanes {
    database: Arc<WorkflowDatabase>,
    policy: LanePolicy,
    /// Test-only: the VM work each class's probe actually did.
    ///
    /// Shared through an `Arc` so cloning the lanes (which shares the database)
    /// shares the record too. It holds no production state and is compiled out
    /// of every non-test build.
    #[cfg(test)]
    probe_work: Arc<std::sync::Mutex<Vec<(QueueClass, i64)>>>,
}

impl NoticeLanes {
    pub(crate) fn new(database: Arc<WorkflowDatabase>, policy: LanePolicy) -> Self {
        Self {
            database,
            policy,
            #[cfg(test)]
            probe_work: Arc::default(),
        }
    }

    /// Record what one lane's probes read, in VM steps.
    #[cfg(test)]
    fn record_probe_work(&self, class: QueueClass, steps: i64) {
        self.probe_work
            .lock()
            .expect("the probe-work lock")
            .push((class, steps));
    }

    #[cfg(not(test))]
    #[inline(always)]
    fn record_probe_work(&self, _class: QueueClass, _steps: i64) {}

    /// The VM work each lane probe has done since this instance was created.
    #[cfg(test)]
    pub(crate) fn probe_work(&self) -> Vec<(QueueClass, i64)> {
        self.probe_work.lock().expect("the probe-work lock").clone()
    }

    pub fn policy(&self) -> &LanePolicy {
        &self.policy
    }

    /// The file these lanes serve.
    pub fn database(&self) -> &Arc<WorkflowDatabase> {
        &self.database
    }

    /// Where the service cycle is.
    pub fn position(&self) -> Result<LanePosition> {
        self.database.read(|connection| {
            let mut statement = connection
                .prepare("SELECT key, value FROM workflow_delivery_meta WHERE key IN (?1, ?2)")?;
            let rows = statement.query_map(params![LANE_CLASS_KEY, LANE_SERVED_KEY], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })?;
            let mut class = LanePosition::start().class();
            let mut served = 0_u32;
            for row in rows {
                let (key, value) = row?;
                if key == LANE_CLASS_KEY {
                    class = QueueClass::from_ordinal(value)?;
                } else {
                    served = u32::try_from(value.max(0)).unwrap_or(u32::MAX);
                }
            }
            Ok(LanePosition::restored(class, served))
        })
    }

    /// How many deliveries are waiting in each lane.
    ///
    /// An operator query over the pending set, separate from the claim path:
    /// the claim path probes presence per lane and never counts, so a backlog
    /// cannot make a claim slower.
    pub fn stats(&self) -> Result<NoticeLaneStats> {
        let pending = self.database.read(|connection| {
            let mut counts = LaneCounts::default();
            for class in QueueClass::ALL {
                let (sql, values) = self.count_sql(class);
                let count: i64 =
                    connection
                        .query_row(&sql, params_from_iter(values.iter()), |row| row.get(0))?;
                counts = counts.with(class, count.max(0) as usize);
            }
            Ok(counts)
        })?;
        Ok(NoticeLaneStats {
            pending,
            position: self.position()?,
        })
    }

    /// Claim the next delivery owed to one of `assembled` owners.
    ///
    /// `assembled` is the set of owners whose sinks are up. An intent for any
    /// other owner is not claimed *and not acknowledged*: a pass that claimed it
    /// could only fail or, worse, report success for a port nobody is running.
    /// An empty set claims nothing.
    pub fn claim_next(
        &self,
        assembled: &[String],
        claimant: &str,
        now_unix_ms: i64,
        lease_until_unix_ms: i64,
    ) -> Result<Option<NoticeLease>> {
        validate_claimant(claimant)?;
        ensure!(
            lease_until_unix_ms > now_unix_ms,
            "workflow_notice_lease_invalid: the lease would already have expired"
        );
        if assembled.is_empty() {
            return Ok(None);
        }
        let (lease, _) = self.database.write(|transaction, _| {
            let position = read_position(transaction)?;
            let mut presence = LaneCounts::default();
            let mut candidates: [Option<NoticeIntent>; 3] = [None, None, None];
            // Probe lazily, in the order the arbiter ranks the classes: a class
            // the arbiter cannot choose now is never read, so a servable
            // reserved turn does not pay for the bulk lane. Each probe is fed to
            // the policy as it happens, so the choice is still the policy's and
            // not this loop's.
            for class in probe_order(&self.policy, position) {
                let candidate = self.probe(transaction, class, assembled, now_unix_ms)?;
                if candidate.is_some() {
                    presence = presence.with(class, 1);
                }
                candidates[class.ordinal() as usize] = candidate;
                let Some(step) = self.policy.next(presence, position) else {
                    continue;
                };
                if presence.of(step.class) == 0 {
                    continue;
                }
                let Some(notice) = candidates[step.class.ordinal() as usize].take() else {
                    continue;
                };
                let attempt = take_claim(
                    transaction,
                    &notice.notice_id,
                    step.class,
                    claimant,
                    now_unix_ms,
                    lease_until_unix_ms,
                )?;
                write_position(transaction, step.position)?;
                return Ok(Some(NoticeLease {
                    notice,
                    lane: step.class,
                    claimant: claimant.to_owned(),
                    lease_until_unix_ms,
                    attempt,
                }));
            }
            // Every class the arbiter could choose was probed and none had
            // work. A candidate left behind here would mean this loop's order
            // drifted from the policy's ranking, and dropping the work would be
            // worse than failing the claim.
            anyhow::ensure!(
                candidates.iter().all(Option::is_none),
                "workflow_notice_lane_choice_missing"
            );
            Ok(None)
        })?;
        Ok(lease)
    }

    /// Close one claimed delivery.
    ///
    /// One transaction: the obligation closes if it is still open, and the claim
    /// is released. An obligation already closed is not an error — a sink that
    /// records its own durable acceptance closes it as part of accepting, and
    /// the sink's success is the contract this pass acts on.
    pub fn acknowledge(&self, lease: &NoticeLease) -> Result<()> {
        let (_, _) = self.database.write(|transaction, _| {
            transaction.execute(
                "UPDATE workflow_notice_intents SET status='accepted', accepted_at=?2
                 WHERE notice_id=?1 AND status='pending'",
                params![lease.notice.notice_id, crate::transactions::now_unix_ms()],
            )?;
            release_claim(transaction, &lease.notice.notice_id, &lease.claimant)
        })?;
        Ok(())
    }

    /// Give a claimed delivery back, not before `next_attempt_at_unix_ms`.
    ///
    /// The obligation stays open and keeps its attempt count, so a sink that
    /// fails is retried on its own and a sink that succeeded is untouched: the
    /// two owners of one fact never share a retry.
    pub fn release(&self, lease: &NoticeLease, next_attempt_at_unix_ms: i64) -> Result<()> {
        let (_, _) = self.database.write(|transaction, _| {
            let changed = transaction.execute(
                "UPDATE workflow_notice_claims SET lease_until=?3, updated_at=?4
                 WHERE notice_id=?1 AND claimant=?2",
                params![
                    lease.notice.notice_id,
                    lease.claimant,
                    next_attempt_at_unix_ms,
                    crate::transactions::now_unix_ms()
                ],
            )?;
            ensure!(
                changed == 1,
                "workflow_notice_claim_lost: {} is no longer held by {}",
                lease.notice.notice_id,
                lease.claimant
            );
            Ok(())
        })?;
        Ok(())
    }

    /// Pending deliveries nobody can take yet, per owner.
    ///
    /// This is how a pass reports "the port is not assembled" as a number
    /// instead of treating the backlog as empty.
    pub fn blocked_recipients(&self, assembled: &[String]) -> Result<BTreeMap<String, usize>> {
        self.database.read(|connection| {
            let mut values: Vec<Value> = Vec::new();
            let predicate = recipient_filter(assembled, &mut values, true);
            let sql = format!(
                "SELECT i.recipient, COUNT(*) FROM workflow_notice_intents i
                 WHERE i.status='pending' AND {predicate}
                 GROUP BY i.recipient ORDER BY i.recipient ASC"
            );
            let mut statement = connection.prepare(&sql)?;
            let rows = statement.query_map(params_from_iter(values.iter()), |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })?;
            let mut blocked = BTreeMap::new();
            for row in rows {
                let (recipient, count) = row?;
                blocked.insert(recipient, count.max(0) as usize);
            }
            Ok(blocked)
        })
    }

    /// The oldest pending, claimable delivery in one lane, or `None`.
    ///
    /// A reserved lane is probed once per declared kind *and* assembled owner,
    /// and the oldest candidate wins. Both equalities matter: one `kind IN (…)`
    /// probe cannot use an index for its ordering, so the planner walks pending
    /// rows in `created_at` order and a control probe that finds nothing walks
    /// whatever else is pending — the coupling the separate lanes exist to
    /// remove. One `recipient = ?` is the other half: a backlog queued for a
    /// port that is not assembled must not lengthen the read of one that is.
    /// The bulk lane is the complement of the declared kinds and cannot be
    /// enumerated, so it is probed in `created_at` order and stops at its first
    /// row.
    fn probe(
        &self,
        transaction: &Transaction<'_>,
        class: QueueClass,
        assembled: &[String],
        now_unix_ms: i64,
    ) -> Result<Option<NoticeIntent>> {
        match class {
            QueueClass::Control | QueueClass::Result => {
                let mut oldest: Option<NoticeIntent> = None;
                let mut work = 0_i64;
                let recipients: BTreeSet<&str> = assembled.iter().map(String::as_str).collect();
                for kind in self.policy.kinds(class) {
                    for recipient in recipients.iter().copied() {
                        let (candidate, steps) =
                            probe_pair(transaction, kind, recipient, now_unix_ms)?;
                        work = work.saturating_add(steps);
                        let Some(candidate) = candidate else {
                            continue;
                        };
                        if oldest
                            .as_ref()
                            .map_or(true, |current| earlier(&candidate, current))
                        {
                            oldest = Some(candidate);
                        }
                    }
                }
                self.record_probe_work(class, work);
                Ok(oldest)
            }
            QueueClass::Bulk => {
                let (candidate, steps) =
                    probe_bulk(transaction, &self.policy, assembled, now_unix_ms)?;
                self.record_probe_work(class, steps);
                Ok(candidate)
            }
        }
    }

    fn count_sql(&self, class: QueueClass) -> (String, Vec<Value>) {
        let mut values: Vec<Value> = Vec::new();
        let lane = kind_filter(&self.policy, class, &mut values);
        (
            format!(
                "SELECT COUNT(*) FROM workflow_notice_intents i
                 WHERE i.status='pending' AND {lane}"
            ),
            values,
        )
    }
}

/// The classes the arbiter may choose, in the order it ranks them.
///
/// The current class leads only while its turn has budget left; the rest follow
/// in cycle order. Reading in this order and feeding the policy one result at a
/// time is what makes the read lazy without moving the fairness rule: the first
/// class the policy can choose is exactly the first class in this order that
/// has work.
fn probe_order(policy: &LanePolicy, position: LanePosition) -> Vec<QueueClass> {
    let mut order = Vec::with_capacity(3);
    if policy.turn_remains(position) {
        order.push(position.class());
    }
    for class in position.class().successors() {
        if !order.contains(&class) {
            order.push(class);
        }
    }
    order
}

/// The reserved-lane probe: one declared kind for one assembled owner.
///
/// Kept as one statement rather than a filter list so the two equalities can be
/// served by one index seek, and so the read-bound test measures the statement
/// the claim actually runs.
const PAIR_PROBE_SQL: &str =
    "SELECT i.notice_id, i.run_id, i.sequence, i.recipient, i.kind, i.created_at
     FROM workflow_notice_intents i
     WHERE i.status='pending'
       AND i.kind = ?
       AND i.recipient = ?
       AND NOT EXISTS(
         SELECT 1 FROM workflow_notice_claims c
         WHERE c.notice_id=i.notice_id AND c.lease_until > ?)
     ORDER BY i.created_at ASC, i.run_id ASC, i.sequence ASC, i.notice_id ASC
     LIMIT 1";

/// The oldest claimable pending row of one (kind, recipient) pair.
fn probe_pair(
    transaction: &Transaction<'_>,
    kind: &str,
    recipient: &str,
    now_unix_ms: i64,
) -> Result<(Option<NoticeIntent>, i64)> {
    read_candidate(
        transaction,
        PAIR_PROBE_SQL,
        &[
            Value::Text(kind.to_owned()),
            Value::Text(recipient.to_owned()),
            Value::Integer(now_unix_ms),
        ],
    )
}

/// The oldest claimable pending row outside the declared reserved kinds.
fn probe_bulk(
    transaction: &Transaction<'_>,
    policy: &LanePolicy,
    assembled: &[String],
    now_unix_ms: i64,
) -> Result<(Option<NoticeIntent>, i64)> {
    let mut values: Vec<Value> = Vec::new();
    let lane = kind_filter(policy, QueueClass::Bulk, &mut values);
    let recipients = recipient_filter(assembled, &mut values, false);
    values.push(Value::Integer(now_unix_ms));
    let sql = format!(
        "SELECT i.notice_id, i.run_id, i.sequence, i.recipient, i.kind, i.created_at
         FROM workflow_notice_intents i
         WHERE i.status='pending'
           AND {lane}
           AND {recipients}
           AND NOT EXISTS(
             SELECT 1 FROM workflow_notice_claims c
             WHERE c.notice_id=i.notice_id AND c.lease_until > ?)
         ORDER BY i.created_at ASC, i.run_id ASC, i.sequence ASC, i.notice_id ASC
         LIMIT 1"
    );
    read_candidate(transaction, &sql, &values)
}

fn read_candidate(
    transaction: &Transaction<'_>,
    sql: &str,
    values: &[Value],
) -> Result<(Option<NoticeIntent>, i64)> {
    let mut statement = transaction.prepare(sql)?;
    let found = statement
        .query_row(params_from_iter(values.iter()), |row| {
            Ok(NoticeIntent {
                notice_id: row.get(0)?,
                run_id: row.get(1)?,
                sequence: row.get::<_, i64>(2)?.max(0) as u64,
                recipient: row.get(3)?,
                kind: row.get(4)?,
                created_at_unix_ms: row.get(5)?,
            })
        })
        .optional()?;
    // What this probe actually did, in VM steps. The read-bound tests assert on
    // this number rather than on a wall clock, so they measure work instead of
    // machine speed.
    let steps = i64::from(statement.get_status(StatementStatus::VmStep));
    Ok((found, steps))
}

/// Whether `candidate` comes before `current` in the claim order.
///
/// The order is the one the probes use, so the winner of a multi-kind lane is
/// the same row the lane would have served if it were one kind.
fn earlier(candidate: &NoticeIntent, current: &NoticeIntent) -> bool {
    (
        candidate.created_at_unix_ms,
        &candidate.run_id,
        candidate.sequence,
        &candidate.notice_id,
    ) < (
        current.created_at_unix_ms,
        &current.run_id,
        current.sequence,
        &current.notice_id,
    )
}

/// Take the lease on one notice, or refuse if another pass holds it.
fn take_claim(
    transaction: &Transaction<'_>,
    notice_id: &str,
    lane: QueueClass,
    claimant: &str,
    now_unix_ms: i64,
    lease_until_unix_ms: i64,
) -> Result<u32> {
    let attempts: Option<i64> = transaction
        .query_row(
            "INSERT INTO workflow_notice_claims(
               notice_id, lane, claimant, lease_until, attempts, updated_at
             ) VALUES (?1, ?2, ?3, ?4, 1, ?5)
             ON CONFLICT(notice_id) DO UPDATE SET
               lane=excluded.lane,
               claimant=excluded.claimant,
               lease_until=excluded.lease_until,
               attempts=workflow_notice_claims.attempts + 1,
               updated_at=excluded.updated_at
             WHERE workflow_notice_claims.lease_until <= ?5
             RETURNING attempts",
            params![
                notice_id,
                lane.wire(),
                claimant,
                lease_until_unix_ms,
                now_unix_ms
            ],
            |row| row.get::<_, i64>(0),
        )
        .optional()?;
    let attempts = attempts.ok_or_else(|| {
        anyhow::anyhow!("workflow_notice_claim_not_taken: {notice_id} is still leased")
    })?;
    Ok(u32::try_from(attempts.max(0)).unwrap_or(u32::MAX))
}

/// Drop the claim row of one notice, for the claimant that holds it.
fn release_claim(transaction: &Transaction<'_>, notice_id: &str, claimant: &str) -> Result<()> {
    let changed = transaction.execute(
        "DELETE FROM workflow_notice_claims WHERE notice_id=?1 AND claimant=?2",
        params![notice_id, claimant],
    )?;
    ensure!(
        changed == 1,
        "workflow_notice_claim_lost: {notice_id} is no longer held by {claimant}"
    );
    Ok(())
}

fn read_position(transaction: &Transaction<'_>) -> Result<LanePosition> {
    let mut statement = transaction
        .prepare("SELECT key, value FROM workflow_delivery_meta WHERE key IN (?1, ?2)")?;
    let rows = statement.query_map(params![LANE_CLASS_KEY, LANE_SERVED_KEY], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    })?;
    let mut class = LanePosition::start().class();
    let mut served = 0_u32;
    for row in rows {
        let (key, value) = row?;
        if key == LANE_CLASS_KEY {
            class = QueueClass::from_ordinal(value)?;
        } else {
            served = u32::try_from(value.max(0)).unwrap_or(u32::MAX);
        }
    }
    Ok(LanePosition::restored(class, served))
}

fn write_position(transaction: &Transaction<'_>, position: LanePosition) -> Result<()> {
    for (key, value) in [
        (LANE_CLASS_KEY, position.class().ordinal()),
        (LANE_SERVED_KEY, i64::from(position.served_in_turn())),
    ] {
        transaction.execute(
            "INSERT INTO workflow_delivery_meta(key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![key, value],
        )?;
    }
    Ok(())
}

/// The lane filter for one class, with its kinds bound as parameters.
///
/// The kinds are bound rather than interpolated: they come from a policy the
/// composition root declares, and a policy is a value, not SQL.
fn kind_filter(policy: &LanePolicy, class: QueueClass, values: &mut Vec<Value>) -> String {
    let (kinds, negated) = match class {
        QueueClass::Control => (policy.kinds(QueueClass::Control), false),
        QueueClass::Result => (policy.kinds(QueueClass::Result), false),
        QueueClass::Bulk => (
            policy
                .kinds(QueueClass::Control)
                .into_iter()
                .chain(policy.kinds(QueueClass::Result))
                .collect::<Vec<_>>(),
            true,
        ),
    };
    if kinds.is_empty() {
        // Nothing can be in a lane with no declared kinds; the bulk lane, which
        // is defined as everything else, is everything.
        return if negated {
            "1".to_owned()
        } else {
            "0".to_owned()
        };
    }
    let placeholders = vec!["?"; kinds.len()].join(", ");
    values.extend(kinds.into_iter().map(|kind| Value::Text(kind.to_owned())));
    if negated {
        format!("i.kind NOT IN ({placeholders})")
    } else {
        format!("i.kind IN ({placeholders})")
    }
}

/// The owner filter, either as "one of the assembled owners" or as the
/// complement.
///
/// The complement is what a report of *unserved* work needs, and it is expressed
/// as SQL rather than as a subtraction in memory: "not what I can serve" must
/// count rows this process never read.
fn recipient_filter(assembled: &[String], values: &mut Vec<Value>, unassembled: bool) -> String {
    if assembled.is_empty() {
        // With no sink assembled, everything owed is blocked, and nothing is
        // claimable. The claim path returns before it builds this filter.
        return if unassembled { "1" } else { "0" }.to_owned();
    }
    let placeholders = vec!["?"; assembled.len()].join(", ");
    values.extend(
        assembled
            .iter()
            .map(|recipient| Value::Text(recipient.clone())),
    );
    if unassembled {
        format!("i.recipient NOT IN ({placeholders})")
    } else {
        format!("i.recipient IN ({placeholders})")
    }
}

fn validate_claimant(claimant: &str) -> Result<()> {
    ensure!(
        !claimant.trim().is_empty()
            && claimant == claimant.trim()
            && claimant.len() <= 160
            && !claimant.chars().any(char::is_control),
        "workflow_notice_claimant_invalid"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::testing::ScratchDelivery;
    use super::*;
    use licoup_workflow_runtime::routing::LaneWeights;

    fn policy() -> LanePolicy {
        LanePolicy::new(
            ["cancel".to_owned(), "settlement".to_owned()],
            ["completion".to_owned()],
            LaneWeights::new(2, 1, 1).unwrap(),
        )
        .unwrap()
    }

    fn owners(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn a_bulk_backlog_does_not_hold_back_a_cancel() {
        let delivery = ScratchDelivery::new("lanes-fairness");
        let lanes = delivery.assembly().lanes(policy());
        for index in 0..6 {
            delivery.seed_intent("run-bulk", index, "history", "history-page", index as i64);
        }
        let cancel = delivery.seed_intent("run-bulk", 9, "control", "cancel", 9);
        let assembled = owners(&["history", "control"]);

        let mut served = Vec::new();
        for step in 0..4 {
            let lease = lanes
                .claim_next(&assembled, "host-1", 100 + step, 200 + step)
                .expect("a claim")
                .expect("work is waiting");
            served.push(lease.lane);
            lanes.acknowledge(&lease).expect("the claim closes");
        }
        assert_eq!(
            served
                .iter()
                .filter(|lane| **lane == QueueClass::Control)
                .count(),
            1,
            "the cancel is served inside the first cycle: {served:?}"
        );
        assert_eq!(delivery.intent_status(&cancel), "accepted");
        assert_eq!(
            lanes.stats().expect("stats").pending.control,
            0,
            "the control lane is drained"
        );
    }

    #[test]
    fn a_reserved_lane_serves_the_oldest_of_its_kinds() {
        let delivery = ScratchDelivery::new("lanes-oldest-kind");
        let lanes = delivery.assembly().lanes(policy());
        // Two kinds of one lane, with the later-created one inserted first: the
        // lane's order is the fact's age, not the order the kinds are declared.
        let settlement = delivery.seed_intent("run-1", 2, "control", "settlement", 20);
        let cancel = delivery.seed_intent("run-1", 1, "control", "cancel", 10);
        let assembled = owners(&["control"]);

        let first = lanes
            .claim_next(&assembled, "host-1", 100, 200)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(
            first.notice.notice_id, cancel,
            "the oldest of the lane's kinds is served first"
        );
        lanes.acknowledge(&first).expect("the claim closes");
        let second = lanes
            .claim_next(&assembled, "host-1", 101, 201)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(second.notice.notice_id, settlement, "then the next one");
    }

    #[test]
    fn a_leased_candidate_does_not_hide_the_next_one_in_its_lane() {
        let delivery = ScratchDelivery::new("lanes-leased-kind");
        let lanes = delivery.assembly().lanes(policy());
        let cancel = delivery.seed_intent("run-1", 1, "control", "cancel", 10);
        let settlement = delivery.seed_intent("run-1", 2, "control", "settlement", 20);
        let assembled = owners(&["control"]);

        let held = lanes
            .claim_next(&assembled, "host-1", 100, 200)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(held.notice.notice_id, cancel);
        // The cancel is leased, so the probe of its kind finds nothing claimable;
        // the lane must still serve the settlement behind it rather than report
        // the lane empty.
        let next = lanes
            .claim_next(&assembled, "host-2", 110, 210)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(next.notice.notice_id, settlement);
        assert_eq!(next.attempt, 1, "it is its own claim, not a takeover");
    }

    /// Seed `count` pending intents of one (kind, recipient) in one transaction.
    fn seed_backlog(delivery: &ScratchDelivery, recipient: &str, kind: &str, count: i64) {
        delivery
            .database()
            .write(|transaction, _| {
                let mut statement = transaction.prepare(
                    "INSERT INTO workflow_notice_intents(
                       notice_id, run_id, sequence, recipient, kind, status, created_at, accepted_at
                     ) VALUES (?1, ?2, ?3, ?4, ?5, 'pending', ?6, NULL)",
                )?;
                for index in 0..count {
                    let sequence = index as u64;
                    statement.execute(params![
                        crate::transactions::notice_id("run-1", sequence, recipient, kind),
                        "run-1",
                        index,
                        recipient,
                        kind,
                        index
                    ])?;
                }
                Ok(())
            })
            .expect("the backlog commits");
    }

    #[test]
    fn a_foreign_recipient_backlog_does_not_lengthen_a_reserved_probe() {
        let delivery = ScratchDelivery::new("lanes-foreign-backlog");
        let lanes = delivery.assembly().lanes(policy());
        // One kind, two thousand rows queued for a port that is not assembled,
        // and the assembled owner's row behind all of them. A probe keyed by
        // kind alone would walk the whole foreign backlog to reach it.
        seed_backlog(&delivery, "stopped-port", "cancel", 2_000);
        let control = delivery.seed_intent("run-1", 2_000, "control", "cancel", 2_000);

        let lease = lanes
            .claim_next(&owners(&["control"]), "host-1", 100_000, 200_000)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(lease.notice.notice_id, control);

        let work = lanes.probe_work();
        let total: i64 = work.iter().map(|(_, steps)| *steps).sum();
        assert!(
            total < 1_000,
            "the pair is seeked, not walked through the foreign backlog: {work:?}"
        );
    }

    #[test]
    fn a_servable_control_turn_does_not_read_the_bulk_lane() {
        let delivery = ScratchDelivery::new("lanes-lazy-bulk");
        let lanes = delivery.assembly().lanes(policy());
        // Two thousand result rows and one control row, and no bulk work at
        // all: the old claim probed every lane, so the empty bulk lane cost a
        // walk of the whole reserved backlog on every claim.
        seed_backlog(&delivery, "timeline", "completion", 2_000);
        let control = delivery.seed_intent("run-1", 9_000, "control", "cancel", 9_000);

        let lease = lanes
            .claim_next(
                &owners(&["control", "timeline"]),
                "host-1",
                100_000,
                200_000,
            )
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(lease.notice.notice_id, control);

        let work = lanes.probe_work();
        assert!(
            work.iter().all(|(class, _)| *class != QueueClass::Bulk),
            "the bulk lane is read only when the arbiter reaches it: {work:?}"
        );
        let total: i64 = work.iter().map(|(_, steps)| *steps).sum();
        assert!(total < 1_000, "the claim stays a seek: {work:?}");
    }

    #[test]
    fn a_claimed_delivery_is_not_handed_to_a_second_pass() {
        let delivery = ScratchDelivery::new("lanes-lease");
        let lanes = delivery.assembly().lanes(policy());
        delivery.seed_intent("run-1", 1, "timeline", "timeline-projection", 1);
        let assembled = owners(&["timeline"]);

        let first = lanes
            .claim_next(&assembled, "host-1", 10, 50)
            .expect("a claim")
            .expect("work is waiting");
        let second = lanes
            .claim_next(&assembled, "host-2", 20, 60)
            .expect("a claim");
        assert_eq!(second, None, "a leased notice is not led out twice");
        // The lease expires into availability rather than into a lost delivery.
        let third = lanes
            .claim_next(&assembled, "host-2", 51, 90)
            .expect("a claim")
            .expect("the lease has expired");
        assert_eq!(third.notice, first.notice);
        assert_eq!(third.attempt, 2, "the attempt count follows the notice");
    }

    #[test]
    fn an_owner_whose_port_is_not_assembled_is_never_claimed() {
        let delivery = ScratchDelivery::new("lanes-unassembled");
        let lanes = delivery.assembly().lanes(policy());
        delivery.seed_intent("run-1", 1, "wake", "completion", 1);
        assert_eq!(
            lanes
                .claim_next(&owners(&["timeline"]), "host-1", 10, 50)
                .expect("a claim"),
            None,
            "nothing is claimable for an owner that is not assembled"
        );
        assert_eq!(
            lanes
                .blocked_recipients(&owners(&["timeline"]))
                .expect("the report"),
            BTreeMap::from([("wake".to_owned(), 1)]),
            "and the pass can say so instead of reporting an empty backlog"
        );
        assert_eq!(
            lanes.claim_next(&[], "host-1", 10, 50).expect("a claim"),
            None
        );
    }

    #[test]
    fn a_failed_pass_gives_the_delivery_back_without_closing_it() {
        let delivery = ScratchDelivery::new("lanes-release");
        let lanes = delivery.assembly().lanes(policy());
        let notice_id = delivery.seed_intent("run-1", 1, "wake", "completion", 1);
        let assembled = owners(&["wake"]);
        let lease = lanes
            .claim_next(&assembled, "host-1", 10, 50)
            .expect("a claim")
            .expect("work is waiting");
        lanes.release(&lease, 90).expect("the claim is released");
        assert_eq!(delivery.intent_status(&notice_id), "pending");
        assert_eq!(
            delivery.claim(&notice_id).map(|claim| claim.1),
            Some(90),
            "the lease is pushed to the retry time"
        );
        assert_eq!(
            lanes
                .claim_next(&assembled, "host-2", 60, 100)
                .expect("a claim"),
            None,
            "the retry time has not arrived"
        );
    }

    #[test]
    fn a_lease_cannot_be_closed_by_a_pass_that_does_not_hold_it() {
        let delivery = ScratchDelivery::new("lanes-claimant");
        let lanes = delivery.assembly().lanes(policy());
        delivery.seed_intent("run-1", 1, "timeline", "timeline-projection", 1);
        let assembled = owners(&["timeline"]);
        let mut lease = lanes
            .claim_next(&assembled, "host-1", 10, 50)
            .expect("a claim")
            .expect("work is waiting");
        lease.claimant = "host-2".to_owned();
        let error = lanes.acknowledge(&lease).unwrap_err().to_string();
        assert!(error.starts_with("workflow_notice_claim_lost"), "{error}");
    }

    #[test]
    fn the_service_turn_survives_a_restart() {
        let delivery = ScratchDelivery::new("lanes-restart");
        let equal = LanePolicy::new(
            vec!["cancel".to_owned()],
            vec!["completion".to_owned()],
            LaneWeights::equal(),
        )
        .unwrap();
        let lanes = delivery.assembly().lanes(equal.clone());
        delivery.seed_intent("run-1", 1, "control", "cancel", 1);
        delivery.seed_intent("run-1", 2, "owner", "completion", 2);
        delivery.seed_intent("run-1", 3, "history", "history-page", 3);
        let assembled = owners(&["control", "owner", "history"]);

        let first = lanes
            .claim_next(&assembled, "host-1", 100, 200)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(first.lane, QueueClass::Control);
        lanes.acknowledge(&first).expect("the claim closes");
        let position = lanes.position().expect("the position reads");
        assert_eq!(
            position,
            LanePosition::restored(QueueClass::Control, 1),
            "the turn is persisted with the claim"
        );

        // A second host over the same file continues the cycle: control's turn
        // for this cycle is used, so the next claim is the result lane. A host
        // that restarted its fairness state would serve control again.
        let resumed = delivery.assembly().lanes(equal);
        assert_eq!(resumed.position().expect("the position reads"), position);
        let next = resumed
            .claim_next(&assembled, "host-2", 300, 400)
            .expect("a claim")
            .expect("work is waiting");
        assert_eq!(next.lane, QueueClass::Result);
    }
}
