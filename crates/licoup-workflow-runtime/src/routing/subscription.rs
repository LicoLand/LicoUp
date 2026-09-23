//! Subscription scope and the lifecycle of a cursor.
//!
//! A subscription says "tell this subscriber about facts in *this* scope". Two
//! things make that sentence safe to keep for months:
//!
//! * The **scope is part of the subscription's identity.** A subscription whose
//!   scope changed is a different subscription, because the facts its cursor
//!   counts are different facts. Reusing the identity would make an old cursor
//!   mean "you have seen up to here" about a scope it never saw, so a cursor
//!   advance from another scope is refused rather than applied.
//! * The **cursor only moves forward.** Delivery is at-least-once, so an older
//!   fact can be offered again after a newer one has been delivered; applying
//!   it would rewind the cursor and re-announce everything between the two
//!   positions. [`SubscriptionCursor::advance`] therefore keeps the higher
//!   position and reports the stale one, and
//!   [`SubscriptionCursor::accepts_new_work`] answers what a redelivery is: not
//!   new logical work.
//!
//! ## Lifecycle
//!
//! ```text
//!   created   at the position the subscription starts from
//!   advanced  monotonically, by facts delivered in its own scope
//!   resumed   at the persisted position after a restart — never at zero
//! ```
//!
//! `resumed` is not `created` with a default. A cold start that began at zero
//! would re-deliver every fact in the scope's history to a subscriber that has
//! already been told, and "the host restarted" is not a reason to tell anyone
//! anything twice. The durable store reads the persisted row and resumes from
//! it; this type is where the rule lives so both a store and a test can state
//! it once.
//!
//! ## Scope and predicate: one vocabulary, not two
//!
//! [`SubscriptionScope`], [`SubscriptionPredicate`], and [`ActivationRule`] are
//! the shape a subscription is registered with. They live here, next to the
//! cursor, because the durable registry in `licoup-workflow-store::deliveries`
//! is the *implementation* of that vocabulary, not a second definition of it —
//! the same arrangement the production store already had, and the reason a row
//! written by one and read by the other decodes to the same value. The JSON
//! each variant produces is part of that contract and is asserted in the store's
//! tests, which is where the encoder lives.
//!
//! A subscription carries no authority. It says which facts a subscriber wants
//! to hear about; it does not say what the subscriber may do with them, and
//! nothing in this module or in the registry grants anything.

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

/// The longest scope address this vocabulary will carry.
///
/// A scope address is a canonical encoding of the scope, not a free-form label;
/// the bound exists so a corrupt or concatenated address is refused here rather
/// than after it has been written into a subscription row.
const MAX_SCOPE_ADDRESS_LEN: usize = 512;

/// What a subscription is scoped to.
///
/// A node scope is written as its graph plus the node, never as a bare node id:
/// node ids are unique inside a graph, not across graphs, so a bare id would
/// make two different nodes share a subscription.
///
/// The variant names are camelCase and the fields inside a variant keep their
/// Rust names, because that is the exact encoding the production store's rows
/// already hold: `{"node":{"graph_id":"…","node_id":"…"}}`. Renaming the fields
/// here would make every stored subscription undecodable, which is the opposite
/// of sharing one table.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SubscriptionScope {
    Graph(String),
    Node { graph_id: String, node_id: String },
}

impl SubscriptionScope {
    pub fn graph(graph_id: impl Into<String>) -> Result<Self> {
        let graph_id = graph_id.into();
        validate_name(&graph_id, "routing_subscription_graph_invalid")?;
        Ok(Self::Graph(graph_id))
    }

    pub fn node(graph_id: impl Into<String>, node_id: impl Into<String>) -> Result<Self> {
        let (graph_id, node_id) = (graph_id.into(), node_id.into());
        validate_name(&graph_id, "routing_subscription_graph_invalid")?;
        validate_name(&node_id, "routing_subscription_node_invalid")?;
        Ok(Self::Node { graph_id, node_id })
    }
}

/// When a subscription matches a committed transition.
///
/// Encoded as the production store encodes it: camelCase variant names, fields
/// as written. See [`SubscriptionScope`] for why the field names are not
/// renamed.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SubscriptionPredicate {
    /// A named lifecycle state, as the owner that publishes it names it. The
    /// name is validated as a token rather than as a member of an enum here:
    /// this crate does not own the lifecycle, and a second copy of that enum
    /// would be a second authority over what "running" means.
    OnLifecycleState(String),
    OnAnyTransition,
    OnExternalEvent {
        event_name: String,
    },
    OnCustom(String),
}

impl SubscriptionPredicate {
    pub fn on_lifecycle_state(state: impl Into<String>) -> Result<Self> {
        let state = state.into();
        validate_token(&state, "routing_subscription_state_invalid")?;
        Ok(Self::OnLifecycleState(state))
    }

    pub fn on_external_event(event_name: impl Into<String>) -> Result<Self> {
        let event_name = event_name.into();
        validate_name(&event_name, "routing_subscription_event_invalid")?;
        Ok(Self::OnExternalEvent { event_name })
    }
}

/// What a matched subscription is allowed to do.
///
/// [`ActivationRule::NotifyOnly`] is the one that cannot be mistaken for a
/// permission: the subscriber is told, and nothing is resumed on its behalf.
/// The other two are declared rules that the *owner* of the work applies — the
/// registry records them, and does not grant them.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivationRule {
    NotifyOnly,
    AutoResume,
    TriggerTransition { target_state: String },
}

impl ActivationRule {
    pub fn trigger_transition(target_state: impl Into<String>) -> Result<Self> {
        let target_state = target_state.into();
        validate_token(&target_state, "routing_subscription_target_invalid")?;
        Ok(Self::TriggerTransition { target_state })
    }
}

fn validate_name(value: &str, code: &'static str) -> Result<()> {
    ensure!(!value.trim().is_empty() && value == value.trim(), "{code}");
    ensure!(!value.chars().any(char::is_control), "{code}");
    Ok(())
}

fn validate_token(value: &str, code: &'static str) -> Result<()> {
    validate_name(value, code)?;
    ensure!(
        value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
        "{code}"
    );
    Ok(())
}

/// The scope a subscription is attached to, as a canonical address.
///
/// The address is opaque to this crate: the durable store knows which scope
/// shape it encodes, and comparing two addresses is exactly "same scope". That
/// keeps the encoding with the owner of the scope and keeps the one rule that
/// matters here — the address travels with the cursor — independent of it.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct ScopeAddress(String);

impl ScopeAddress {
    pub fn new(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        ensure!(
            !value.trim().is_empty()
                && value == value.trim()
                && value.len() <= MAX_SCOPE_ADDRESS_LEN
                && !value.chars().any(char::is_control),
            "routing_subscription_scope_invalid"
        );
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// What one cursor advance did.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdvanceOutcome {
    /// The cursor moved forward.
    Advanced { from: u64, to: u64 },
    /// The offered position is the one already reached: no movement, no
    /// duplicate announcement.
    Unchanged { at: u64 },
    /// The offered position is behind the cursor. The cursor is kept where it
    /// is; the caller learns that what it was handed is older than what this
    /// subscriber has already seen.
    Stale { current: u64, proposed: u64 },
}

impl AdvanceOutcome {
    /// The cursor position after this advance.
    pub fn position(self) -> u64 {
        match self {
            Self::Advanced { to, .. } => to,
            Self::Unchanged { at } => at,
            Self::Stale { current, .. } => current,
        }
    }
}

/// One subscriber's position in one scope.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SubscriptionCursor {
    scope: ScopeAddress,
    position: u64,
}

impl SubscriptionCursor {
    /// A cursor for a subscription created at the scope position it starts from.
    ///
    /// The starting position is the caller's decision — for a subscription that
    /// should see only what happens next, that is the scope's current position;
    /// for one that should catch up, it is where the catch-up starts. What this
    /// constructor refuses to do is pick a position on its own: a subscription
    /// that silently started at zero would announce a whole history nobody
    /// asked for.
    pub fn created(scope: ScopeAddress, position: u64) -> Self {
        Self { scope, position }
    }

    /// A cursor restored from the position a subscriber last reached.
    ///
    /// This is the restart path, and it is the same position the subscriber was
    /// at, not a fresh one.
    pub fn resumed(scope: ScopeAddress, persisted_position: u64) -> Self {
        Self::created(scope, persisted_position)
    }

    pub fn scope(&self) -> &ScopeAddress {
        &self.scope
    }

    pub fn position(&self) -> u64 {
        self.position
    }

    /// Whether a fact delivered at `delivered_at` is work this subscriber has
    /// not been told about yet.
    pub fn accepts_new_work(&self, delivered_at: u64) -> bool {
        delivered_at > self.position
    }

    /// Move the cursor for a fact delivered in `scope`.
    ///
    /// Refuses a fact from another scope: the cursor counts facts in one scope,
    /// and an advance from elsewhere would either skip facts of this scope or
    /// count facts that were never in it. A delivery behind the cursor is
    /// reported as [`AdvanceOutcome::Stale`] and leaves the position alone.
    pub fn advance_in_scope(
        &mut self,
        scope: &ScopeAddress,
        delivered_at: u64,
    ) -> Result<AdvanceOutcome> {
        ensure!(
            &self.scope == scope,
            "routing_subscription_scope_mismatch: cursor is for {} and the delivery is for {}",
            self.scope.as_str(),
            scope.as_str()
        );
        Ok(self.advance(delivered_at))
    }

    /// Move the cursor forward within its own scope.
    pub fn advance(&mut self, proposed: u64) -> AdvanceOutcome {
        if proposed > self.position {
            let from = self.position;
            self.position = proposed;
            AdvanceOutcome::Advanced { from, to: proposed }
        } else if proposed == self.position {
            AdvanceOutcome::Unchanged { at: proposed }
        } else {
            AdvanceOutcome::Stale {
                current: self.position,
                proposed,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope() -> ScopeAddress {
        ScopeAddress::new("{\"graph\":\"graph-1\"}").unwrap()
    }

    #[test]
    fn a_cursor_only_moves_forward_and_reports_the_older_fact() {
        let mut cursor = SubscriptionCursor::created(scope(), 10);
        assert_eq!(
            cursor.advance(14),
            AdvanceOutcome::Advanced { from: 10, to: 14 }
        );
        assert_eq!(cursor.advance(14), AdvanceOutcome::Unchanged { at: 14 });
        assert_eq!(
            cursor.advance(11),
            AdvanceOutcome::Stale {
                current: 14,
                proposed: 11
            }
        );
        assert_eq!(cursor.position(), 14, "a redelivery does not rewind");
        assert!(!cursor.accepts_new_work(11));
        assert!(cursor.accepts_new_work(15));
    }

    #[test]
    fn a_restart_resumes_where_the_subscriber_stopped() {
        let mut cursor = SubscriptionCursor::created(scope(), 4);
        cursor.advance(9);
        let resumed = SubscriptionCursor::resumed(scope(), cursor.position());
        assert_eq!(resumed.position(), 9);
        assert!(
            !resumed.accepts_new_work(9),
            "the fact the subscriber already saw is not new work after a restart"
        );
        assert!(resumed.accepts_new_work(10));
    }

    #[test]
    fn a_fact_from_another_scope_is_refused_rather_than_advanced() {
        let mut cursor = SubscriptionCursor::created(scope(), 4);
        let other = ScopeAddress::new("{\"graph\":\"graph-2\"}").unwrap();
        let error = cursor.advance_in_scope(&other, 20).unwrap_err().to_string();
        assert!(
            error.starts_with("routing_subscription_scope_mismatch"),
            "{error}"
        );
        assert_eq!(cursor.position(), 4);
    }

    #[test]
    fn a_node_scope_always_carries_its_graph() {
        let node = SubscriptionScope::node("graph-1", "node-1").unwrap();
        assert_eq!(
            node,
            SubscriptionScope::Node {
                graph_id: "graph-1".into(),
                node_id: "node-1".into()
            }
        );
        assert!(SubscriptionScope::node("graph-1", "  ").is_err());
        assert!(SubscriptionScope::node("", "node-1").is_err());
    }

    #[test]
    fn a_predicate_name_is_a_token_not_a_sentence() {
        assert!(SubscriptionPredicate::on_lifecycle_state("stopRequested").is_ok());
        assert!(SubscriptionPredicate::on_lifecycle_state("stop requested").is_err());
        assert!(SubscriptionPredicate::on_lifecycle_state("").is_err());
        assert!(ActivationRule::trigger_transition("running").is_ok());
        assert!(ActivationRule::trigger_transition("run\nning").is_err());
        assert_eq!(ActivationRule::NotifyOnly, ActivationRule::NotifyOnly);
    }

    #[test]
    fn an_empty_or_padded_scope_address_is_not_a_scope() {
        assert!(ScopeAddress::new("   ").is_err());
        assert!(ScopeAddress::new(" graph-1").is_err());
        assert!(ScopeAddress::new("graph\u{0}1").is_err());
        assert!(ScopeAddress::new("g".repeat(MAX_SCOPE_ADDRESS_LEN + 1)).is_err());
    }
}
