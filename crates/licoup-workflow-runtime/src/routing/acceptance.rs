//! What one committed fact still owes, and when it is settled.
//!
//! ## Two acceptances, not one
//!
//! C03 accounts a timeline projection and a reliable wake *separately*, each
//! retryable on its own, with the final ack being the intersection of what the
//! required downstream owners have durably accepted. That is not a stylistic
//! preference. If one acceptance covered both, then a projection that landed
//! while a wake did not would either be re-projected (visible duplicate) or
//! count as delivered (silent lost wake); there is no third outcome, because
//! one bit cannot describe two facts.
//!
//! ```text
//!   required owners: {timeline, wake}
//!   accepted:        {timeline}
//!   disposition:      pending, retryable = [wake], unassembled = []
//!   accepted:        {timeline, wake}
//!   disposition:      acknowledged
//! ```
//!
//! [`NoticeAcceptance`] is that ledger for one fact. It records a *durable*
//! outcome per owner and reports the intersection; it never invents progress
//! for an owner that has not accepted.
//!
//! ## Physical delivery is not logical creation
//!
//! A sink may be handed the same notice more than once — a lease can expire, a
//! host can die between accepting and acknowledging, a queue can redeliver.
//! [`NoticeAcceptance::accept`] therefore answers [`AcceptanceOutcome::Repeat`]
//! for an owner that has already accepted, and the count rises while the
//! *logical* creation does not happen twice. Any owner that performs paid or
//! externally visible work on a repeat has misread its own input, which is why
//! the distinction is in the return type rather than in a comment.
//!
//! ## Assembly is a property of the host, requirement is a property of the fact
//!
//! A sink that is not assembled cannot accept: accepting on behalf of a port
//! that is not up is exactly the "acked but nobody has it" state the contract
//! exists to prevent, so [`NoticeAcceptance::accept`] refuses an unassembled
//! owner and [`NoticeAcceptance::disposition`] reports it separately from
//! "owed and retryable" — an operator needs to know the difference between "the
//! owner said no" and "the owner is not running". A *durable* acceptance read
//! back at boot is a different thing from a live one: it outlives the process
//! that made it, so [`NoticeAcceptance::restore`] records it without pretending
//! a sink is up.

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// The owners one fact must be durably accepted by.
///
/// The set is fixed when the fact is committed, not decided at delivery time: a
/// requirement that could be edited later would make "already acknowledged" mean
/// whatever the last writer wanted it to mean.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcceptancePlan {
    required: BTreeSet<String>,
}

impl AcceptancePlan {
    /// The plan for one fact. A fact with no required owner is refused: it would
    /// be acknowledged the moment it existed, which is a way of losing it while
    /// looking healthy.
    pub fn new(owners: impl IntoIterator<Item = String>) -> Result<Self> {
        let required = owners.into_iter().collect::<BTreeSet<_>>();
        ensure!(
            !required.is_empty(),
            "routing_acceptance_plan_empty: a fact must be owed to at least one owner"
        );
        for owner in &required {
            ensure!(
                !owner.trim().is_empty()
                    && owner == owner.trim()
                    && !owner.chars().any(char::is_control),
                "routing_acceptance_owner_invalid"
            );
        }
        Ok(Self { required })
    }

    pub fn required(&self) -> &BTreeSet<String> {
        &self.required
    }

    pub fn requires(&self, owner: &str) -> bool {
        self.required.contains(owner)
    }
}

/// What one owner's acceptance of one notice did.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AcceptanceOutcome {
    /// This owner had not accepted this notice before: the logical creation.
    First,
    /// The same logical notice arrived again. Recorded as a repeat, and not a
    /// second piece of work.
    Repeat,
}

/// Which required acceptances are still owed for one fact.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingAcceptances {
    /// Owed, and their owner is up: each of these may be retried on its own.
    pub retryable: Vec<String>,
    /// Owed, and their owner is not assembled: nothing may be attempted, and
    /// nothing may be acknowledged.
    pub unassembled: Vec<String>,
}

impl PendingAcceptances {
    /// Whether anything is still owed.
    pub fn is_owed(&self) -> bool {
        !self.retryable.is_empty() || !self.unassembled.is_empty()
    }
}

/// Whether one fact is settled.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NoticeDisposition {
    /// Not settled, with the owners still owed, split by whether they can be
    /// retried now.
    Pending(PendingAcceptances),
    /// Every required owner has durably accepted.
    Acknowledged,
}

impl NoticeDisposition {
    pub fn is_acknowledged(&self) -> bool {
        matches!(self, Self::Acknowledged)
    }

    pub fn pending(&self) -> Option<&PendingAcceptances> {
        match self {
            Self::Pending(owed) => Some(owed),
            Self::Acknowledged => None,
        }
    }
}

/// The acceptances of one committed fact.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoticeAcceptance {
    plan: AcceptancePlan,
    assembled: BTreeSet<String>,
    accepted: BTreeMap<String, u64>,
}

impl NoticeAcceptance {
    pub fn new(plan: AcceptancePlan) -> Self {
        Self {
            plan,
            assembled: BTreeSet::new(),
            accepted: BTreeMap::new(),
        }
    }

    /// Note that one owner's sink is up.
    ///
    /// Assembling an owner the fact does not require is allowed: assembly
    /// describes the host, and one host serves many facts. What it does not do
    /// is make that owner part of this fact's intersection.
    pub fn assemble(&mut self, owner: &str) {
        self.assembled.insert(owner.to_owned());
    }

    /// Record a **new** acceptance by an owner whose sink is up.
    ///
    /// Refuses an owner the fact does not require (that acceptance would not be
    /// part of any intersection) and an owner whose sink is not assembled (the
    /// acceptance would be a claim about a port that is not running).
    pub fn accept(&mut self, owner: &str) -> Result<AcceptanceOutcome> {
        ensure!(
            self.plan.requires(owner),
            "routing_acceptance_owner_unexpected: {owner} is not owed this fact"
        );
        ensure!(
            self.assembled.contains(owner),
            "routing_acceptance_owner_unassembled: {owner}"
        );
        Ok(self.record(owner))
    }

    /// Record an acceptance that is **already durable** — read back at boot from
    /// the owner's own ledger.
    ///
    /// This is the one path that records an acceptance without assembly, because
    /// the fact being recorded is that the owner accepted *when it was running*.
    /// It is not a way around [`Self::accept`]: it takes a count the caller read
    /// from storage, so a caller that wants to claim a fresh acceptance has
    /// nothing to pass.
    pub fn restore(&mut self, owner: &str, accept_count: u64) -> Result<()> {
        ensure!(
            self.plan.requires(owner),
            "routing_acceptance_owner_unexpected: {owner} is not owed this fact"
        );
        ensure!(
            accept_count > 0,
            "routing_acceptance_count_invalid: {owner} restored with no acceptance"
        );
        self.accepted.insert(owner.to_owned(), accept_count);
        Ok(())
    }

    /// The owners that have durably accepted, in a stable order.
    pub fn accepted(&self) -> Vec<String> {
        self.accepted.keys().cloned().collect()
    }

    /// How many times one owner has accepted, or zero.
    pub fn accept_count(&self, owner: &str) -> u64 {
        self.accepted.get(owner).copied().unwrap_or(0)
    }

    /// Whether one fact is settled: the intersection of what every required
    /// owner has durably accepted.
    pub fn disposition(&self) -> NoticeDisposition {
        let mut owed = PendingAcceptances {
            retryable: Vec::new(),
            unassembled: Vec::new(),
        };
        for owner in self.plan.required() {
            if self.accepted.contains_key(owner) {
                continue;
            }
            if self.assembled.contains(owner) {
                owed.retryable.push(owner.clone());
            } else {
                owed.unassembled.push(owner.clone());
            }
        }
        if owed.is_owed() {
            NoticeDisposition::Pending(owed)
        } else {
            NoticeDisposition::Acknowledged
        }
    }

    fn record(&mut self, owner: &str) -> AcceptanceOutcome {
        match self.accepted.get_mut(owner) {
            Some(count) => {
                *count = count.saturating_add(1);
                AcceptanceOutcome::Repeat
            }
            None => {
                self.accepted.insert(owner.to_owned(), 1);
                AcceptanceOutcome::First
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan() -> AcceptancePlan {
        AcceptancePlan::new(["timeline".to_owned(), "wake".to_owned()]).unwrap()
    }

    #[test]
    fn one_acceptance_is_not_a_settlement_of_two_owners() {
        let mut acceptance = NoticeAcceptance::new(plan());
        acceptance.assemble("timeline");
        acceptance.assemble("wake");
        assert_eq!(
            acceptance.accept("timeline").unwrap(),
            AcceptanceOutcome::First
        );
        let disposition = acceptance.disposition();
        assert!(!disposition.is_acknowledged());
        assert_eq!(
            disposition.pending().unwrap().retryable,
            vec!["wake".to_owned()],
            "the wake is still owed and retryable on its own"
        );
        assert_eq!(acceptance.accept("wake").unwrap(), AcceptanceOutcome::First);
        assert_eq!(acceptance.disposition(), NoticeDisposition::Acknowledged);
    }

    #[test]
    fn a_redelivery_is_a_repeat_and_not_a_second_logical_creation() {
        let mut acceptance = NoticeAcceptance::new(plan());
        acceptance.assemble("timeline");
        assert_eq!(
            acceptance.accept("timeline").unwrap(),
            AcceptanceOutcome::First
        );
        assert_eq!(
            acceptance.accept("timeline").unwrap(),
            AcceptanceOutcome::Repeat
        );
        assert_eq!(acceptance.accept_count("timeline"), 2);
        assert_eq!(acceptance.accepted(), vec!["timeline".to_owned()]);
    }

    #[test]
    fn a_failed_owner_does_not_disturb_the_one_that_accepted() {
        let mut acceptance = NoticeAcceptance::new(plan());
        acceptance.assemble("timeline");
        acceptance.assemble("wake");
        acceptance.accept("timeline").unwrap();
        // The wake owner fails; nothing is recorded for it and nothing is
        // taken away from the owner that already accepted.
        let disposition = acceptance.disposition();
        assert_eq!(disposition.pending().unwrap().retryable, vec!["wake"]);
        assert_eq!(acceptance.accept_count("timeline"), 1);
        assert_eq!(acceptance.accepted(), vec!["timeline".to_owned()]);
    }

    #[test]
    fn an_unassembled_owner_is_not_the_same_as_an_owner_that_has_not_answered() {
        let mut acceptance = NoticeAcceptance::new(plan());
        acceptance.assemble("timeline");
        let disposition = acceptance.disposition();
        let owed = disposition.pending().expect("still owed");
        assert_eq!(owed.retryable, vec!["timeline".to_owned()]);
        assert_eq!(owed.unassembled, vec!["wake".to_owned()]);
        let error = acceptance.accept("wake").unwrap_err().to_string();
        assert!(
            error.starts_with("routing_acceptance_owner_unassembled"),
            "{error}"
        );
    }

    #[test]
    fn a_durable_acceptance_outlives_the_sink_that_made_it() {
        let mut acceptance = NoticeAcceptance::new(plan());
        acceptance.assemble("wake");
        acceptance.restore("timeline", 3).unwrap();
        acceptance.accept("wake").unwrap();
        assert_eq!(acceptance.disposition(), NoticeDisposition::Acknowledged);
        assert_eq!(acceptance.accept_count("timeline"), 3);
    }

    #[test]
    fn an_acceptance_nobody_required_cannot_join_the_intersection() {
        let mut acceptance = NoticeAcceptance::new(plan());
        acceptance.assemble("metrics");
        let error = acceptance.accept("metrics").unwrap_err().to_string();
        assert!(
            error.starts_with("routing_acceptance_owner_unexpected"),
            "{error}"
        );
        assert!(acceptance.restore("metrics", 1).is_err());
        assert!(acceptance.disposition().pending().is_some());
    }

    #[test]
    fn a_fact_owed_to_nobody_is_refused() {
        let error = AcceptancePlan::new(Vec::new()).unwrap_err().to_string();
        assert!(
            error.starts_with("routing_acceptance_plan_empty"),
            "{error}"
        );
    }
}
