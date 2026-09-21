//! Node-visit lifecycle: what one owner knows about one dispatch while it runs.
//!
//! The driver owns *dispatch*; this module owns the bookkeeping that makes a
//! dispatch observable and refuses the transitions that would make the account
//! false. Two rules are enforced here rather than left to convention:
//!
//! * One work unit has at most one effect in flight. A work unit is a node
//!   visit, or one workset item of a visit: a workset visit schedules several
//!   items at once, each with its own command and its own result, so treating
//!   the visit alone as the unit would refuse the second item and stop a run
//!   that is behaving correctly. A second claim of a unit that is still running
//!   is refused instead of quietly tracked twice, so "commit A's outcome, then
//!   admit A's successors" cannot decay into "start a successor of a unit that
//!   has not settled".
//! * A lifecycle step is only legal from the step before it. An effect that was
//!   never claimed cannot start, and a second start of the same effect is
//!   refused. The durable marker is committed before the invocation (that order
//!   is what recovery rests on); this ledger is the in-memory mirror of the same
//!   order, so a double start shows up here as well as in the store.
//!
//! The work unit is this module's own key and does not leave it: C02's identity
//! is the parent state and visit, and that is what traces, results and control
//! name. An attempt is not part of the unit either — a retry of one item is the
//! same unit under a new command, which is why the retry is refused while the
//! first command is still live and admitted once it has settled.
//!
//! Nothing here is durable, and nothing here decides readiness: which command is
//! dispatchable is the store's answer through `StatePort::claim_next`. The
//! ledger records what *this owner* has in flight, so a control request can name
//! the recipients it froze and a capacity bound can be counted.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::{Display, Formatter};

use licoup_workflow::{FailureClass, RunCommand};
use serde::{Deserialize, Serialize};

/// Identity of one visit of one node in one run.
///
/// A visit, not a node: a node that is entered twice has two visits with two
/// independent effects, and a result belongs to one of them.
#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeVisitKey {
    pub state_id: String,
    pub state_visit: u64,
}

impl NodeVisitKey {
    pub fn new(state_id: impl Into<String>, state_visit: u64) -> Self {
        Self {
            state_id: state_id.into(),
            state_visit,
        }
    }

    /// The visit a claimed command belongs to.
    pub fn from_command(command: &RunCommand) -> Self {
        Self::new(command.state_id.clone(), command.state_visit)
    }
}

impl Display for NodeVisitKey {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}@{}", self.state_id, self.state_visit)
    }
}

/// Where one dispatched effect is in its own lifecycle.
///
/// This is the driver's view of C03's effect states: `Claimed` is a claim taken
/// under a lease, `Started` is a claim whose possible-effect marker is durable,
/// and `Settled` is an effect whose outcome has been committed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NodePhase {
    Claimed,
    Started,
    Settled,
}

impl Display for NodePhase {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            Self::Claimed => "claimed",
            Self::Started => "started",
            Self::Settled => "settled",
        };
        formatter.write_str(name)
    }
}

/// What a settled effect settled as.
///
/// The vocabulary is C03's, and it keeps the two facts a single "success" would
/// erase apart: an effect that was cancelled is not an effect that failed, and
/// an effect whose position is unknown is neither of those and is never retried
/// as if it were.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NodeOutcome {
    Succeeded,
    Failed { class: FailureClass, code: String },
    Cancelled,
    Unknown,
}

impl NodeOutcome {
    /// The outcome's name, without its payload.
    pub fn kind(&self) -> NodeOutcomeKind {
        match self {
            Self::Succeeded => NodeOutcomeKind::Succeeded,
            Self::Failed { .. } => NodeOutcomeKind::Failed,
            Self::Cancelled => NodeOutcomeKind::Cancelled,
            Self::Unknown => NodeOutcomeKind::Unknown,
        }
    }
}

/// The name of an outcome, for records that must not carry the payload.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NodeOutcomeKind {
    Succeeded,
    Failed,
    Cancelled,
    Unknown,
}

impl Display for NodeOutcomeKind {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Unknown => "unknown",
        };
        formatter.write_str(name)
    }
}

/// One effect this owner has in flight.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NodeEffect {
    key: NodeVisitKey,
    command_id: String,
    attempt_token: String,
    phase: NodePhase,
    cancel_requested: bool,
}

impl NodeEffect {
    pub fn key(&self) -> &NodeVisitKey {
        &self.key
    }

    pub fn command_id(&self) -> &str {
        &self.command_id
    }

    pub fn attempt_token(&self) -> &str {
        &self.attempt_token
    }

    pub fn phase(&self) -> NodePhase {
        self.phase
    }

    /// Whether a control request asked this effect to stop.
    pub fn cancel_requested(&self) -> bool {
        self.cancel_requested
    }
}

/// One effect that settled, with the facts the drive needs to report it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NodeSettlement {
    pub key: NodeVisitKey,
    pub command_id: String,
    pub attempt_token: String,
    pub outcome: NodeOutcome,
    /// Whether a cancellation had been requested for this effect before it
    /// settled. A late result is reported, never re-read as a cancellation.
    pub cancel_requested: bool,
}

/// Which recipients a control request addresses.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "scope")]
pub enum ControlTarget {
    /// The whole run: every effect it has in flight.
    Run,
    /// One node visit: its effect, if it has one in flight.
    Node(NodeVisitKey),
}

/// The recipients a control request froze when it was handled.
///
/// C03's rule is that a node-set instruction acts on its frozen recipients: the
/// set is taken once, at handling time, and an effect admitted afterwards is not
/// a recipient of a request that predates it.
///
/// `commands` names every frozen effect, one per effect. `visits` names the
/// visits those effects belong to, each visit once: a workset visit can have
/// several effects in flight, and the parent visit is one recipient however many
/// of its items are running.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct FrozenRecipients {
    pub commands: Vec<String>,
    pub visits: Vec<NodeVisitKey>,
}

impl FrozenRecipients {
    pub fn is_empty(&self) -> bool {
        self.commands.is_empty()
    }

    pub fn len(&self) -> usize {
        self.commands.len()
    }
}

/// Why a lifecycle transition was refused.
///
/// Every variant is a refusal of an *account*, not of an I/O operation: the
/// driver's own record would have become untrue if the transition had been
/// allowed, so it is returned instead of being absorbed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NodeLifecycleError {
    /// A live effect already exists for this visit.
    VisitAlreadyInFlight {
        key: NodeVisitKey,
        command_id: String,
    },
    /// A live effect already exists for this workset item of this visit.
    ///
    /// Distinct from [`Self::VisitAlreadyInFlight`] because the item, not the
    /// visit, is what collided: the rest of the visit's items are allowed to be
    /// in flight at the same time.
    ItemAlreadyInFlight {
        key: NodeVisitKey,
        item_id: String,
        command_id: String,
    },
    /// This command is already being tracked.
    CommandAlreadyLive { command_id: String },
    /// No live effect carries this command id.
    UnknownCommand { command_id: String },
    /// The token presented does not belong to the claim being advanced.
    AttemptTokenMismatch { command_id: String },
    /// The step is not reachable from the phase the effect is in.
    IllegalTransition {
        command_id: String,
        from: NodePhase,
        to: NodePhase,
    },
}

impl Display for NodeLifecycleError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::VisitAlreadyInFlight { key, command_id } => write!(
                formatter,
                "node_visit_already_in_flight: {key} has {command_id} in flight"
            ),
            Self::ItemAlreadyInFlight {
                key,
                item_id,
                command_id,
            } => write!(
                formatter,
                "workset_item_already_in_flight: {key} item {item_id} has {command_id} in flight"
            ),
            Self::CommandAlreadyLive { command_id } => {
                write!(formatter, "node_command_already_live: {command_id}")
            }
            Self::UnknownCommand { command_id } => {
                write!(formatter, "node_command_unknown: {command_id}")
            }
            Self::AttemptTokenMismatch { command_id } => {
                write!(formatter, "node_attempt_token_mismatch: {command_id}")
            }
            Self::IllegalTransition {
                command_id,
                from,
                to,
            } => write!(
                formatter,
                "node_illegal_transition: {command_id} {from} -> {to}"
            ),
        }
    }
}

impl std::error::Error for NodeLifecycleError {}

/// The work one ledger slot accounts for: a visit, and the workset item it is
/// running when the machine named one.
///
/// This is the ledger's own key. It never reaches a caller: what a caller reads
/// is [`NodeEffect::key`], the parent visit, which is C02's identity.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct NodeWorkUnit {
    visit: NodeVisitKey,
    /// The workset item this command is for, as the machine emitted it
    /// (`RunCommand::item_id`); `None` when the visit itself is the unit.
    item_id: Option<String>,
}

impl NodeWorkUnit {
    fn from_command(command: &RunCommand) -> Self {
        Self {
            visit: NodeVisitKey::from_command(command),
            item_id: command.item_id.clone(),
        }
    }
}

/// The effects one owner has in flight, keyed by work unit: a visit, or one
/// workset item of a visit.
#[derive(Debug, Default)]
pub struct NodeLedger {
    live: BTreeMap<NodeWorkUnit, NodeEffect>,
    by_command: BTreeMap<String, NodeWorkUnit>,
    settled: usize,
}

impl NodeLedger {
    pub fn new() -> Self {
        Self::default()
    }

    /// Track a command as claimed.
    ///
    /// The caller has already taken the claim and committed the possible-effect
    /// marker, so a refusal here means the drive's own view disagrees with what
    /// it just committed — the drive stops rather than continuing on an account
    /// it cannot keep true.
    pub fn record_claim(
        &mut self,
        command: &RunCommand,
    ) -> Result<NodeVisitKey, NodeLifecycleError> {
        let unit = NodeWorkUnit::from_command(command);
        if self.by_command.contains_key(&command.id) {
            return Err(NodeLifecycleError::CommandAlreadyLive {
                command_id: command.id.clone(),
            });
        }
        if let Some(existing) = self.live.get(&unit) {
            return Err(match &unit.item_id {
                Some(item_id) => NodeLifecycleError::ItemAlreadyInFlight {
                    key: unit.visit.clone(),
                    item_id: item_id.clone(),
                    command_id: existing.command_id.clone(),
                },
                None => NodeLifecycleError::VisitAlreadyInFlight {
                    key: unit.visit.clone(),
                    command_id: existing.command_id.clone(),
                },
            });
        }
        self.by_command.insert(command.id.clone(), unit.clone());
        self.live.insert(
            unit.clone(),
            NodeEffect {
                key: unit.visit.clone(),
                command_id: command.id.clone(),
                attempt_token: command.attempt_token.clone(),
                phase: NodePhase::Claimed,
                cancel_requested: false,
            },
        );
        Ok(unit.visit)
    }

    /// Move a claimed effect to started, once its marker is durable.
    pub fn record_started(
        &mut self,
        command_id: &str,
        attempt_token: &str,
    ) -> Result<(), NodeLifecycleError> {
        let key = self.key_of(command_id)?.clone();
        let effect = self
            .live
            .get_mut(&key)
            .ok_or_else(|| NodeLifecycleError::UnknownCommand {
                command_id: command_id.to_owned(),
            })?;
        if effect.attempt_token != attempt_token {
            return Err(NodeLifecycleError::AttemptTokenMismatch {
                command_id: command_id.to_owned(),
            });
        }
        if effect.phase != NodePhase::Claimed {
            return Err(NodeLifecycleError::IllegalTransition {
                command_id: command_id.to_owned(),
                from: effect.phase,
                to: NodePhase::Started,
            });
        }
        effect.phase = NodePhase::Started;
        Ok(())
    }

    /// Settle one effect and take it out of the live set.
    ///
    /// An effect settles from `Claimed` as well as from `Started`: a claim whose
    /// dispatch never happened still owes the run an outcome (in doubt, or a
    /// refusal), and leaving it live would make the drive wait forever for a
    /// completion nobody is going to produce.
    pub fn settle(
        &mut self,
        command_id: &str,
        outcome: NodeOutcome,
    ) -> Result<NodeSettlement, NodeLifecycleError> {
        let unit = self.key_of(command_id)?.clone();
        let effect = self
            .live
            .remove(&unit)
            .ok_or_else(|| NodeLifecycleError::UnknownCommand {
                command_id: command_id.to_owned(),
            })?;
        if effect.phase == NodePhase::Settled {
            return Err(NodeLifecycleError::IllegalTransition {
                command_id: command_id.to_owned(),
                from: effect.phase,
                to: NodePhase::Settled,
            });
        }
        self.by_command.remove(command_id);
        self.settled = self.settled.saturating_add(1);
        Ok(NodeSettlement {
            key: effect.key,
            command_id: effect.command_id,
            attempt_token: effect.attempt_token,
            outcome,
            cancel_requested: effect.cancel_requested,
        })
    }

    /// The recipients a control request would act on right now.
    ///
    /// Every live effect addressed by the target is named in `commands`; each
    /// parent visit it belongs to appears in `visits` once, however many of the
    /// visit's workset items are running.
    pub fn freeze(&self, target: &ControlTarget) -> FrozenRecipients {
        let mut frozen = FrozenRecipients::default();
        let mut visits = BTreeSet::new();
        for (unit, effect) in &self.live {
            let addressed = match target {
                ControlTarget::Run => true,
                ControlTarget::Node(key) => unit.visit == *key,
            };
            if addressed {
                frozen.commands.push(effect.command_id.clone());
                if visits.insert(unit.visit.clone()) {
                    frozen.visits.push(unit.visit.clone());
                }
            }
        }
        frozen
    }

    /// Mark one frozen recipient as asked to stop. Returns whether it was live.
    pub fn mark_cancel_requested(&mut self, command_id: &str) -> bool {
        let Some(key) = self.by_command.get(command_id).cloned() else {
            return false;
        };
        match self.live.get_mut(&key) {
            Some(effect) => {
                effect.cancel_requested = true;
                true
            }
            None => false,
        }
    }

    pub fn is_cancel_requested(&self, command_id: &str) -> bool {
        self.effect(command_id)
            .is_some_and(NodeEffect::cancel_requested)
    }

    pub fn effect(&self, command_id: &str) -> Option<&NodeEffect> {
        let key = self.by_command.get(command_id)?;
        self.live.get(key)
    }

    pub fn live_effects(&self) -> impl Iterator<Item = &NodeEffect> {
        self.live.values()
    }

    /// How many effects are in flight.
    pub fn in_flight(&self) -> usize {
        self.live.len()
    }

    /// The commands that are in flight, in work-unit order (visit, then item).
    pub fn in_flight_commands(&self) -> Vec<String> {
        self.live
            .values()
            .map(|effect| effect.command_id.clone())
            .collect()
    }

    pub fn settled_count(&self) -> usize {
        self.settled
    }

    fn key_of(&self, command_id: &str) -> Result<&NodeWorkUnit, NodeLifecycleError> {
        self.by_command
            .get(command_id)
            .ok_or_else(|| NodeLifecycleError::UnknownCommand {
                command_id: command_id.to_owned(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use licoup_workflow::{CommandKind, CommandStatus, RunSnapshot};

    fn command(id: &str, token: &str, state_id: &str, visit: u64) -> RunCommand {
        // The crate has no JSON dependency, so the fixture takes its JSON value
        // from the machine's own default rather than naming a JSON type here.
        let input = RunSnapshot::empty("fixture", "fixture", "fixture").input;
        RunCommand {
            id: id.to_owned(),
            state_id: state_id.to_owned(),
            state_visit: visit,
            kind: CommandKind::Actor,
            status: CommandStatus::Claimed,
            attempt: 1,
            attempt_token: token.to_owned(),
            binding_id: None,
            runtime_id: None,
            entry: None,
            item_id: None,
            session_policy: Default::default(),
            binding_ordinal: 0,
            resume_session_id: None,
            input_digest: "digest".to_owned(),
            input,
            output_digest: None,
            failure_class: None,
            failure_code: None,
        }
    }

    /// A workset item command: the machine emits several of these for one visit,
    /// each with its own item id and its own command id.
    fn workset_item(id: &str, token: &str, state_id: &str, visit: u64, item: &str) -> RunCommand {
        RunCommand {
            kind: CommandKind::WorksetItem,
            item_id: Some(item.to_owned()),
            ..command(id, token, state_id, visit)
        }
    }

    #[test]
    fn a_visit_carries_one_effect_at_a_time() {
        let mut ledger = NodeLedger::new();
        ledger
            .record_claim(&command("c1", "t1", "a", 1))
            .expect("claim");
        let refusal = ledger
            .record_claim(&command("c2", "t2", "a", 1))
            .expect_err("a second effect for a live visit must be refused");
        assert!(matches!(
            refusal,
            NodeLifecycleError::VisitAlreadyInFlight { .. }
        ));
        // A different visit of the same node is a different effect.
        ledger
            .record_claim(&command("c3", "t3", "a", 2))
            .expect("second visit");
        assert_eq!(ledger.in_flight(), 2);
    }

    #[test]
    fn one_workset_visit_carries_its_items_side_by_side() {
        let mut ledger = NodeLedger::new();
        ledger
            .record_claim(&workset_item("c-a", "t-a", "tasks", 1, "a"))
            .expect("item a");
        ledger
            .record_claim(&workset_item("c-b", "t-b", "tasks", 1, "b"))
            .expect("item b of the same visit is a different work unit");
        assert_eq!(ledger.in_flight(), 2);
        // The same item of the same visit is still one unit: a second live
        // command for it is refused, naming the item rather than the visit.
        let refusal = ledger
            .record_claim(&workset_item("c-a2", "t-a2", "tasks", 1, "a"))
            .expect_err("a second attempt at a live item must be refused");
        assert!(matches!(
            refusal,
            NodeLifecycleError::ItemAlreadyInFlight { .. }
        ));
        // A retry is the same unit under a new command, so it is admitted once
        // the first command has settled and not before.
        let settlement = ledger
            .settle("c-a", NodeOutcome::Succeeded)
            .expect("settle a");
        assert_eq!(settlement.key, NodeVisitKey::new("tasks", 1));
        ledger
            .record_claim(&workset_item("c-a-retry", "t-a3", "tasks", 1, "a"))
            .expect("the retry is admitted once the first command settled");
        assert_eq!(ledger.in_flight(), 2);
    }

    #[test]
    fn freeze_names_each_frozen_visit_once_and_every_frozen_effect() {
        let mut ledger = NodeLedger::new();
        ledger
            .record_claim(&workset_item("c-a", "t-a", "tasks", 1, "a"))
            .expect("item a");
        ledger
            .record_claim(&workset_item("c-b", "t-b", "tasks", 1, "b"))
            .expect("item b");
        let frozen = ledger.freeze(&ControlTarget::Run);
        assert_eq!(
            frozen.commands,
            vec!["c-a".to_owned(), "c-b".to_owned()],
            "every frozen effect is named"
        );
        assert_eq!(
            frozen.visits,
            vec![NodeVisitKey::new("tasks", 1)],
            "the parent visit is named once, however many of its items are live"
        );
        // A node-scoped instruction addresses the visit, so it freezes all of
        // the visit's live items.
        let frozen = ledger.freeze(&ControlTarget::Node(NodeVisitKey::new("tasks", 1)));
        assert_eq!(frozen.commands.len(), 2);
        assert_eq!(frozen.visits.len(), 1);
    }

    #[test]
    fn lifecycle_steps_are_only_legal_from_the_step_before() {
        let mut ledger = NodeLedger::new();
        let command = command("c1", "t1", "a", 1);
        ledger.record_claim(&command).expect("claim");
        ledger.record_started("c1", "t1").expect("start");
        let refusal = ledger
            .record_started("c1", "t1")
            .expect_err("a duplicate start must be refused");
        assert!(matches!(
            refusal,
            NodeLifecycleError::IllegalTransition { .. }
        ));
        ledger.settle("c1", NodeOutcome::Succeeded).expect("settle");
        let refusal = ledger
            .settle("c1", NodeOutcome::Succeeded)
            .expect_err("settling twice must be refused");
        assert!(matches!(refusal, NodeLifecycleError::UnknownCommand { .. }));
        assert_eq!(ledger.in_flight(), 0);
        assert_eq!(ledger.settled_count(), 1);
    }

    #[test]
    fn freeze_names_only_the_effects_in_flight_when_it_is_taken() {
        let mut ledger = NodeLedger::new();
        ledger
            .record_claim(&command("c1", "t1", "a", 1))
            .expect("claim");
        let frozen = ledger.freeze(&ControlTarget::Run);
        assert_eq!(frozen.commands, vec!["c1".to_owned()]);
        assert_eq!(frozen.visits, vec![NodeVisitKey::new("a", 1)]);
        // An effect admitted after the freeze is not a recipient of it.
        ledger
            .record_claim(&command("c2", "t2", "b", 1))
            .expect("claim");
        assert_eq!(frozen.len(), 1);
        assert_eq!(
            ledger
                .freeze(&ControlTarget::Node(NodeVisitKey::new("b", 1)))
                .len(),
            1
        );
        assert!(
            ledger
                .freeze(&ControlTarget::Node(NodeVisitKey::new("z", 9)))
                .is_empty()
        );
    }
}
