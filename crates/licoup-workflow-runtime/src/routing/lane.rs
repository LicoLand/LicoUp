//! Fair service across the notice lanes: control, result, and bulk.
//!
//! ## Why the classes are separate rather than prioritized in one queue
//!
//! One queue with a priority column still has one queue: a saturated bulk path
//! fills the table, and a cancel that arrives behind ten thousand bulk
//! deliveries waits for all of them, because the only thing that can move it
//! forward is the writer draining the same rows. Separate lanes make the
//! *order of service* a property of the class, not of how much bulk happened to
//! arrive first — which is the part of "控制/结果/bulk 分流" that can actually be
//! held.
//!
//! ## The reserve, stated precisely
//!
//! ```text
//!   weights: control=4, result=2, bulk=1
//!   service: C C C C R R B | C C C C R R B | ...
//! ```
//!
//! The weights are a *service reserve*: the classes that carry cancel and
//! settlement are guaranteed their share of the service turns, and bulk can
//! never take more than its own share no matter how far behind it is. Three
//! properties follow from the rule in [`LanePolicy::next`], and each is a test:
//!
//! 1. A lane with pending work is never skipped while it still has turns left in
//!    its own turn budget, so control cannot starve behind bulk.
//! 2. Once a lane's turn budget is used, the turn moves on, so a flood of
//!    control cannot starve result or bulk either.
//! 3. A lane with nothing to serve is skipped, and skipping does not bank its
//!    turns for the next cycle: an idle lane does not enlarge another class's
//!    share.
//!
//! A weight of zero is not a policy — it is a lane that is present and never
//! served — so [`LaneWeights::new`] refuses it. That is the reserve as a type:
//! there is no configuration in which cancel or settlement has no turn.
//!
//! ## Restart
//!
//! [`LanePosition`] is the whole arbiter state: the class currently being
//! served and how many of its turns are used. It is small enough to persist in
//! one row and to resume from, which is what makes fairness survive a restart
//! instead of every boot restarting at "serve control four times". The durable
//! store persists it in the same transaction that takes the claim, so a crashed
//! host does not replay a turn it already used.

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::num::NonZeroUsize;

/// The class of work a queued delivery belongs to.
///
/// The class decides the lane, and therefore the service order. It is a
/// property of the *delivery*, declared by whoever names the kinds, not
/// something inferred from arrival order or payload size.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum QueueClass {
    /// Cancel, stop, and pause: a request that changes what running work does.
    Control,
    /// A settled outcome travelling to its successor or its owner.
    Result,
    /// Everything that is carried at the rate the system can afford: history,
    /// projections, and batch payloads.
    Bulk,
}

impl QueueClass {
    /// Every class, in cycle order.
    pub const ALL: [Self; 3] = [Self::Control, Self::Result, Self::Bulk];

    /// The class as it is stored, so a durable row and this enum cannot drift.
    pub const fn wire(self) -> &'static str {
        match self {
            Self::Control => "control",
            Self::Result => "result",
            Self::Bulk => "bulk",
        }
    }

    /// The stored class. An unknown value is refused rather than defaulted:
    /// silently reading an unrecognised lane as bulk would move work into the
    /// lane that carries no reserve.
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "control" => Ok(Self::Control),
            "result" => Ok(Self::Result),
            "bulk" => Ok(Self::Bulk),
            other => {
                anyhow::bail!("routing_lane_class_invalid: {other}")
            }
        }
    }

    /// The position of this class in [`Self::ALL`], for storage in an integer
    /// column that a person can read back as a class.
    pub const fn ordinal(self) -> i64 {
        match self {
            Self::Control => 0,
            Self::Result => 1,
            Self::Bulk => 2,
        }
    }

    /// The class a stored ordinal names. An out-of-range value is refused for
    /// the same reason an unknown name is.
    pub fn from_ordinal(value: i64) -> Result<Self> {
        match value {
            0 => Ok(Self::Control),
            1 => Ok(Self::Result),
            2 => Ok(Self::Bulk),
            other => {
                anyhow::bail!("routing_lane_class_invalid: {other}")
            }
        }
    }

    /// The classes after this one in cycle order, ending with itself.
    ///
    /// The last entry is the class itself, so a caller scanning for the next
    /// class with work always terminates and always finds one when only this
    /// class has any.
    pub const fn successors(self) -> [Self; 3] {
        match self {
            Self::Control => [Self::Result, Self::Bulk, Self::Control],
            Self::Result => [Self::Bulk, Self::Control, Self::Result],
            Self::Bulk => [Self::Control, Self::Result, Self::Bulk],
        }
    }
}

/// How many consecutive services each class is guaranteed before the turn moves.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LaneWeights {
    control: NonZeroUsize,
    result: NonZeroUsize,
    bulk: NonZeroUsize,
}

impl LaneWeights {
    /// The weights of a policy.
    ///
    /// A zero weight is refused: it would name a lane that is never served, so
    /// a single misconfigured number could remove cancel and settlement from
    /// the schedule while still looking like a fair queue.
    pub fn new(control: usize, result: usize, bulk: usize) -> Result<Self> {
        Ok(Self {
            control: reserve("control", control)?,
            result: reserve("result", result)?,
            bulk: reserve("bulk", bulk)?,
        })
    }

    /// Every class served once per cycle, in cycle order.
    pub const fn equal() -> Self {
        Self {
            control: NonZeroUsize::MIN,
            result: NonZeroUsize::MIN,
            bulk: NonZeroUsize::MIN,
        }
    }

    /// The number of consecutive turns one class is served.
    pub const fn of(self, class: QueueClass) -> usize {
        match class {
            QueueClass::Control => self.control.get(),
            QueueClass::Result => self.result.get(),
            QueueClass::Bulk => self.bulk.get(),
        }
    }
}

/// How many deliveries are waiting in each lane.
///
/// Only *presence* decides the next lane, never the magnitude: a caller that
/// knows only whether a lane has work passes `1`, and a caller that counted
/// passes the count. Both schedule identically — which is what keeps the cost
/// of taking the next delivery a property of the pass rather than of the
/// backlog, since a scheduler that needed the count would have to count it.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LaneCounts {
    pub control: usize,
    pub result: usize,
    pub bulk: usize,
}

impl LaneCounts {
    pub const fn new(control: usize, result: usize, bulk: usize) -> Self {
        Self {
            control,
            result,
            bulk,
        }
    }

    pub const fn of(self, class: QueueClass) -> usize {
        match class {
            QueueClass::Control => self.control,
            QueueClass::Result => self.result,
            QueueClass::Bulk => self.bulk,
        }
    }

    pub const fn total(self) -> usize {
        self.control + self.result + self.bulk
    }

    pub const fn is_empty(self) -> bool {
        self.total() == 0
    }

    /// The same counts with one lane's value replaced.
    pub const fn with(self, class: QueueClass, count: usize) -> Self {
        match class {
            QueueClass::Control => Self {
                control: count,
                ..self
            },
            QueueClass::Result => Self {
                result: count,
                ..self
            },
            QueueClass::Bulk => Self {
                bulk: count,
                ..self
            },
        }
    }
}

/// Where the arbiter is in its cycle: the class being served and how many of
/// its turns are used.
///
/// This is the entire fairness state, which is why it can be persisted per
/// claim and resumed after a restart without a second scheduling decision to
/// reconstruct.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LanePosition {
    class: QueueClass,
    served_in_turn: u32,
}

impl LanePosition {
    /// A fresh position: control is served first.
    ///
    /// A cold start deliberately begins with the class that carries cancel and
    /// settlement, because that is the direction a system behind on bulk must
    /// not be able to change.
    pub const fn start() -> Self {
        Self {
            class: QueueClass::Control,
            served_in_turn: 0,
        }
    }

    /// A position restored from storage.
    pub fn restored(class: QueueClass, served_in_turn: u32) -> Self {
        Self {
            class,
            served_in_turn,
        }
    }

    pub const fn class(self) -> QueueClass {
        self.class
    }

    pub const fn served_in_turn(self) -> u32 {
        self.served_in_turn
    }
}

/// The lane to serve next, and the position to persist once it has been claimed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LaneStep {
    pub class: QueueClass,
    pub position: LanePosition,
}

/// Which kinds belong to which lane, and how the lanes share the service turns.
///
/// The classification is declared, not guessed. A kind is a name chosen by
/// whoever produces the delivery, and the only place that knows whether
/// `stop-requested` is control or history is that producer; a policy that tried
/// to infer it from a substring would put a cancel in the bulk lane on the day
/// someone renamed it. Everything not declared is bulk, so an undeclared kind
/// can never take the reserved turns — the failure mode of forgetting to
/// declare is "served later", not "cancel served ahead of everything".
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LanePolicy {
    control_kinds: BTreeSet<String>,
    result_kinds: BTreeSet<String>,
    weights: LaneWeights,
}

impl LanePolicy {
    /// Declare a policy from the kinds each reserved lane carries.
    pub fn new(
        control_kinds: impl IntoIterator<Item = String>,
        result_kinds: impl IntoIterator<Item = String>,
        weights: LaneWeights,
    ) -> Result<Self> {
        let control_kinds = classify_set("control", control_kinds)?;
        let result_kinds = classify_set("result", result_kinds)?;
        if let Some(shared) = control_kinds.intersection(&result_kinds).next() {
            anyhow::bail!("routing_lane_policy_ambiguous: {shared} is declared in two lanes");
        }
        Ok(Self {
            control_kinds,
            result_kinds,
            weights,
        })
    }

    /// The lane one kind is carried in.
    pub fn classify(&self, kind: &str) -> QueueClass {
        if self.control_kinds.contains(kind) {
            QueueClass::Control
        } else if self.result_kinds.contains(kind) {
            QueueClass::Result
        } else {
            QueueClass::Bulk
        }
    }

    /// Whether this policy declared a kind in a reserved lane.
    pub fn declares(&self, class: QueueClass, kind: &str) -> bool {
        match class {
            QueueClass::Control => self.control_kinds.contains(kind),
            QueueClass::Result => self.result_kinds.contains(kind),
            QueueClass::Bulk => self.classify(kind) == QueueClass::Bulk,
        }
    }

    /// The declared kinds of a reserved lane, in a stable order.
    pub fn kinds(&self, class: QueueClass) -> Vec<&str> {
        let kinds = match class {
            QueueClass::Control => &self.control_kinds,
            QueueClass::Result => &self.result_kinds,
            QueueClass::Bulk => return Vec::new(),
        };
        kinds.iter().map(String::as_str).collect()
    }

    pub const fn weights(&self) -> LaneWeights {
        self.weights
    }

    /// Whether the class at `position` may still be served within its turn.
    ///
    /// The budget conversion is the one [`Self::next`] performs, so a caller
    /// that wants to probe the arbiter's candidates lazily cannot disagree with
    /// the arbiter about whether a turn is over.
    pub fn turn_remains(&self, position: LanePosition) -> bool {
        let budget = u32::try_from(self.weights.of(position.class())).unwrap_or(u32::MAX);
        position.served_in_turn() < budget
    }

    /// Which lane to serve next from `pending`, continuing or starting a turn at
    /// `position`.
    ///
    /// `None` means there is nothing to serve. The returned [`LaneStep`] carries
    /// the position to persist, so a caller that stores it before serving the
    /// work resumes the same turn after a crash rather than replaying it.
    pub fn next(&self, pending: LaneCounts, position: LanePosition) -> Option<LaneStep> {
        if pending.is_empty() {
            return None;
        }
        let current = position.class;
        if pending.of(current) > 0 && self.turn_remains(position) {
            return Some(LaneStep {
                class: current,
                position: LanePosition::restored(current, position.served_in_turn + 1),
            });
        }
        for class in current.successors() {
            if pending.of(class) > 0 {
                return Some(LaneStep {
                    class,
                    position: LanePosition::restored(class, 1),
                });
            }
        }
        // Unreachable while `pending` is not empty and every class in the cycle
        // is visited, but returning `None` here would silently drop work, so the
        // caller gets the current class rather than an empty schedule.
        Some(LaneStep {
            class: current,
            position: LanePosition::restored(current, 1),
        })
    }
}

fn reserve(class: &str, weight: usize) -> Result<NonZeroUsize> {
    NonZeroUsize::new(weight).ok_or_else(|| {
        anyhow::anyhow!("routing_lane_weights_invalid: the {class} lane would never be served")
    })
}

fn classify_set(class: &str, kinds: impl IntoIterator<Item = String>) -> Result<BTreeSet<String>> {
    let mut declared = BTreeSet::new();
    for kind in kinds {
        ensure!(
            !kind.trim().is_empty() && kind == kind.trim() && !kind.chars().any(char::is_control),
            "routing_lane_kind_invalid: {class}"
        );
        declared.insert(kind);
    }
    Ok(declared)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn policy() -> LanePolicy {
        LanePolicy::new(
            ["cancel".to_owned(), "settlement".to_owned()],
            ["completion".to_owned()],
            LaneWeights::new(4, 2, 1).unwrap(),
        )
        .unwrap()
    }

    /// Serve `steps` turns under a fixed backlog and report the class sequence.
    fn schedule(policy: &LanePolicy, pending: LaneCounts, steps: usize) -> Vec<QueueClass> {
        let mut position = LanePosition::start();
        let mut served = Vec::new();
        for _ in 0..steps {
            let step = policy.next(pending, position).expect("work to serve");
            served.push(step.class);
            position = step.position;
        }
        served
    }

    #[test]
    fn a_bulk_backlog_cannot_take_the_control_turns() {
        let policy = policy();
        let served = schedule(&policy, LaneCounts::new(9, 9, 4000), 21);
        let control = served
            .iter()
            .filter(|class| **class == QueueClass::Control)
            .count();
        let bulk = served
            .iter()
            .filter(|class| **class == QueueClass::Bulk)
            .count();
        assert_eq!(
            control, 12,
            "four control turns per cycle of seven: {served:?}"
        );
        assert_eq!(bulk, 3, "one bulk turn per cycle of seven: {served:?}");
        assert_eq!(served[0], QueueClass::Control);
    }

    #[test]
    fn a_control_flood_cannot_starve_result_or_bulk() {
        let policy = policy();
        let served = schedule(&policy, LaneCounts::new(4000, 3, 3), 14);
        assert_eq!(
            served,
            vec![
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Result,
                QueueClass::Result,
                QueueClass::Bulk,
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Result,
                QueueClass::Result,
                QueueClass::Bulk,
            ],
            "the turn moves on after the budget is used"
        );
    }

    #[test]
    fn an_idle_lane_is_skipped_without_banking_its_turns() {
        let policy = policy();
        // Result has nothing to serve, so control and bulk alternate on their
        // own budgets rather than result's turns being handed to either.
        let served = schedule(&policy, LaneCounts::new(1, 0, 1), 7);
        assert_eq!(
            served,
            vec![
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Control,
                QueueClass::Bulk,
                QueueClass::Control,
                QueueClass::Control,
            ]
        );
    }

    #[test]
    fn an_empty_backlog_is_not_a_lane() {
        let policy = policy();
        assert_eq!(
            policy.next(LaneCounts::default(), LanePosition::start()),
            None
        );
    }

    #[test]
    fn a_persisted_position_resumes_the_turn_it_was_cut_off_in() {
        let policy = policy();
        let backlog = LaneCounts::new(9, 9, 9);
        // A host that restarts three turns into control's budget has one turn
        // left, not a fresh budget: without this, every restart would hand the
        // reserved lane another full turn.
        let mut position = LanePosition::restored(QueueClass::Control, 3);
        let mut served = Vec::new();
        for _ in 0..2 {
            let step = policy.next(backlog, position).expect("work to serve");
            served.push(step.class);
            position = step.position;
        }
        assert_eq!(served, vec![QueueClass::Control, QueueClass::Result]);
        assert_eq!(
            schedule(&policy, backlog, 2),
            vec![QueueClass::Control, QueueClass::Control],
            "a cold start is not the resumed schedule"
        );
    }

    #[test]
    fn a_turn_is_over_exactly_when_its_budget_is_used() {
        let policy = policy();
        assert!(policy.turn_remains(LanePosition::restored(QueueClass::Control, 3)));
        assert!(!policy.turn_remains(LanePosition::restored(QueueClass::Control, 4)));
        assert!(
            policy.turn_remains(LanePosition::restored(QueueClass::Bulk, 0)),
            "the bulk lane's own budget is read from the same rule"
        );
    }

    #[test]
    fn the_cycle_covers_every_class_and_terminates() {
        for class in QueueClass::ALL {
            let successors = class.successors();
            let distinct: BTreeSet<&str> = successors.iter().map(|c| c.wire()).collect();
            assert_eq!(successors.len(), 3);
            assert_eq!(distinct.len(), 3, "no class is dropped from the cycle");
            assert_eq!(successors[2], class, "the scan always reaches its own lane");
        }
    }

    #[test]
    fn a_lane_that_is_never_served_is_not_a_weights_value() {
        let error = LaneWeights::new(0, 1, 1).unwrap_err().to_string();
        assert!(error.starts_with("routing_lane_weights_invalid"), "{error}");
    }

    #[test]
    fn a_kind_declared_in_two_lanes_is_refused_rather_than_silently_preferred() {
        let error = LanePolicy::new(
            vec!["cancel".to_owned()],
            vec!["cancel".to_owned()],
            LaneWeights::equal(),
        )
        .unwrap_err()
        .to_string();
        assert!(
            error.starts_with("routing_lane_policy_ambiguous"),
            "{error}"
        );
    }

    #[test]
    fn an_undeclared_kind_is_bulk_and_never_climbs_into_a_reserved_lane() {
        let policy = policy();
        assert_eq!(policy.classify("cancel"), QueueClass::Control);
        assert_eq!(policy.classify("completion"), QueueClass::Result);
        assert_eq!(policy.classify("history-page"), QueueClass::Bulk);
        assert!(!policy.declares(QueueClass::Control, "history-page"));
        assert_eq!(
            policy.kinds(QueueClass::Control),
            vec!["cancel", "settlement"]
        );
    }

    #[test]
    fn a_stored_class_round_trips_and_an_unknown_one_is_refused() {
        for class in QueueClass::ALL {
            assert_eq!(QueueClass::parse(class.wire()).unwrap(), class);
        }
        assert!(QueueClass::parse("urgent").is_err());
    }
}
