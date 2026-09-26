//! The durable subscription registry, over the table the production store writes.
//!
//! ## Same table, same rows, not a second registry
//!
//! `workflow_subscriptions` is the format the production store already owns,
//! and this module serves it in place: a subscription registered here is visible
//! to that store, and one it wrote is served here. That is why
//! [`super::DeliveryAssembly::assemble`] validates the columns instead of
//! creating whatever it likes — writing a different set of columns into a shared
//! table is how two owners of one fact start disagreeing, and the failure would
//! show up as a subscription whose cursor means nothing.
//!
//! ## Semantics kept from the existing implementation
//!
//! * **Registering is idempotent for the same identity and payload, and a
//!   conflict otherwise.** A changed scope, predicate, or activation rule must
//!   use a new identity, because the stored cursor counts facts that matched the
//!   *old* meaning; reusing it would silently reinterpret history. The check is
//!   on every field of the registered subscription, not just the id.
//! * **The cursor only moves forward.** A delivering pass may offer a fact at or
//!   below the cursor — at-least-once delivery makes that normal — and the rule
//!   lives in [`licoup_workflow_runtime::routing::SubscriptionCursor`], so the
//!   stored row and the rule cannot disagree.
//! * **A restart resumes; it does not replay.** Registering an old cursor over
//!   an existing subscription does not rewind it, and
//!   [`SubscriptionRegistry::resume_cursor`] answers with the persisted position
//!   rather than a fresh zero.
//!
//! ## Nothing here grants anything
//!
//! A subscription is a request to be told about committed facts in a scope. The
//! registry records that request and counts what has been delivered. It does not
//! authorize the subscriber to do anything with a fact, and
//! [`licoup_workflow_runtime::routing::ActivationRule`] is a declaration the
//! owner of the work applies, not a permission this table confers.

use anyhow::{Result, ensure};
use licoup_workflow_runtime::routing::{
    ActivationRule, AdvanceOutcome, ScopeAddress, SubscriptionCursor, SubscriptionPredicate,
    SubscriptionScope,
};
use rusqlite::{OptionalExtension, params};
use std::sync::Arc;

use crate::transactions::WorkflowDatabase;

/// One registered subscription.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Subscription {
    pub subscription_id: String,
    pub subscriber_id: String,
    pub scope: SubscriptionScope,
    pub predicate: SubscriptionPredicate,
    pub activation_rule: ActivationRule,
    /// The highest position in the scope this subscription has been told about.
    pub durable_cursor: u64,
    /// Whether this subscription watches work that carries control: the owner
    /// uses it to keep control off the result path, which is a routing decision
    /// the subscriber declares and the registry records.
    pub is_control: bool,
    pub active: bool,
}

impl Subscription {
    /// The scope as the address the cursor travels with.
    ///
    /// The canonical encoding is the stored `scope_json`, so the address and the
    /// row cannot describe different scopes: changing the encoding would change
    /// what a stored cursor means, and this is the one place that decides.
    pub fn scope_address(&self) -> Result<ScopeAddress> {
        ScopeAddress::new(serde_json::to_string(&self.scope)?)
    }
}

/// The durable registry over one assembled delivery side.
#[derive(Clone)]
pub struct SubscriptionRegistry {
    database: Arc<WorkflowDatabase>,
}

impl SubscriptionRegistry {
    pub(crate) fn new(database: Arc<WorkflowDatabase>) -> Self {
        Self { database }
    }

    /// Register one subscription.
    ///
    /// `true` when it was registered, `false` when an identical subscription was
    /// already there. A subscription with the same identity but a different
    /// scope, predicate, activation rule, control flag, or active flag is
    /// refused: its cursor counts facts that matched the old meaning.
    pub fn subscribe(&self, subscription: &Subscription) -> Result<bool> {
        validate_id(
            &subscription.subscription_id,
            "workflow_subscription_id_invalid",
        )?;
        validate_id(
            &subscription.subscriber_id,
            "workflow_subscription_subscriber_invalid",
        )?;
        ensure!(
            subscription.durable_cursor <= i64::MAX as u64,
            "workflow_subscription_cursor_invalid"
        );
        let scope_json = serde_json::to_string(&subscription.scope)?;
        let predicate_json = serde_json::to_string(&subscription.predicate)?;
        let activation_json = serde_json::to_string(&subscription.activation_rule)?;
        let (registered, _) = self.database.write(|transaction, _| {
            let existing: Option<(String, String, String, String, i64, i64)> = transaction
                .query_row(
                    "SELECT subscriber_id, scope_json, predicate_json, activation_json,
                            is_control, active
                     FROM workflow_subscriptions WHERE subscription_id=?1",
                    params![subscription.subscription_id],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get(2)?,
                            row.get(3)?,
                            row.get(4)?,
                            row.get(5)?,
                        ))
                    },
                )
                .optional()?;
            if let Some((subscriber, scope, predicate, activation, is_control, active)) = existing {
                ensure!(
                    subscriber == subscription.subscriber_id
                        && scope == scope_json
                        && predicate == predicate_json
                        && activation == activation_json
                        && is_control == i64::from(subscription.is_control)
                        && active == i64::from(subscription.active),
                    "workflow_subscription_conflict: {subscription_id} is registered with a different meaning",
                    subscription_id = subscription.subscription_id
                );
                return Ok(false);
            }
            transaction.execute(
                "INSERT INTO workflow_subscriptions(
                   subscription_id, subscriber_id, scope_json, predicate_json,
                   activation_json, durable_cursor, is_control, active, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    subscription.subscription_id,
                    subscription.subscriber_id,
                    scope_json,
                    predicate_json,
                    activation_json,
                    subscription.durable_cursor as i64,
                    i64::from(subscription.is_control),
                    i64::from(subscription.active),
                    crate::transactions::now_unix_ms(),
                ],
            )?;
            Ok(true)
        })?;
        Ok(registered)
    }

    /// Forget one subscription and its cursor. `false` when it was not there.
    pub fn unsubscribe(&self, subscription_id: &str) -> Result<bool> {
        validate_id(subscription_id, "workflow_subscription_id_invalid")?;
        let (removed, _) = self.database.write(|transaction, _| {
            Ok(transaction.execute(
                "DELETE FROM workflow_subscriptions WHERE subscription_id=?1",
                params![subscription_id],
            )?)
        })?;
        Ok(removed == 1)
    }

    pub fn get(&self, subscription_id: &str) -> Result<Option<Subscription>> {
        validate_id(subscription_id, "workflow_subscription_id_invalid")?;
        self.database.read(|connection| {
            connection
                .query_row(
                    "SELECT subscription_id, subscriber_id, scope_json, predicate_json,
                            activation_json, durable_cursor, is_control, active
                     FROM workflow_subscriptions WHERE subscription_id=?1",
                    params![subscription_id],
                    subscription_row,
                )
                .optional()?
                .map(decode)
                .transpose()
        })
    }

    pub fn list(&self) -> Result<Vec<Subscription>> {
        self.database.read(|connection| {
            let mut statement = connection.prepare(
                "SELECT subscription_id, subscriber_id, scope_json, predicate_json,
                        activation_json, durable_cursor, is_control, active
                 FROM workflow_subscriptions ORDER BY subscription_id ASC",
            )?;
            let rows = statement.query_map([], subscription_row)?;
            let mut subscriptions = Vec::new();
            for row in rows {
                subscriptions.push(decode(row?)?);
            }
            Ok(subscriptions)
        })
    }

    /// Deliver one fact of `scope` at `delivered_at`.
    ///
    /// Refuses a fact from another scope: the cursor counts facts in one scope,
    /// and an advance from elsewhere would either skip facts of this scope or
    /// count facts that were never in it. A fact at or below the cursor is
    /// reported as already seen, and the stored cursor does not move.
    pub fn deliver(
        &self,
        subscription_id: &str,
        scope: &SubscriptionScope,
        delivered_at: u64,
    ) -> Result<AdvanceOutcome> {
        validate_id(subscription_id, "workflow_subscription_id_invalid")?;
        let (outcome, _) = self.database.write(|transaction, _| {
            let (scope_json, cursor) = transaction
                .query_row(
                    "SELECT scope_json, durable_cursor FROM workflow_subscriptions
                     WHERE subscription_id=?1",
                    params![subscription_id],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
                )
                .optional()?
                .ok_or_else(|| {
                    anyhow::anyhow!("workflow_subscription_missing: {subscription_id}")
                })?;
            let registered = serde_json::from_str::<SubscriptionScope>(&scope_json)
                .map_err(|_| anyhow::anyhow!("workflow_subscription_scope_invalid"))?;
            let stored_scope = ScopeAddress::new(serde_json::to_string(&registered)?)?;
            let delivered_scope = ScopeAddress::new(serde_json::to_string(scope)?)?;
            let mut cursor = SubscriptionCursor::resumed(stored_scope, cursor.max(0) as u64);
            let outcome = cursor.advance_in_scope(&delivered_scope, delivered_at)?;
            if let AdvanceOutcome::Advanced { to, .. } = outcome {
                let changed = transaction.execute(
                    "UPDATE workflow_subscriptions SET durable_cursor=MAX(durable_cursor, ?2)
                     WHERE subscription_id=?1",
                    params![subscription_id, to as i64],
                )?;
                ensure!(
                    changed == 1,
                    "workflow_subscription_missing: {subscription_id}"
                );
            }
            Ok(outcome)
        })?;
        Ok(outcome)
    }

    /// The cursor one subscription resumes from after a restart.
    ///
    /// The persisted position, not zero: a host that restarted has not un-told
    /// its subscribers anything, and resuming from zero would re-announce a
    /// history they have already seen.
    pub fn resume_cursor(&self, subscription_id: &str) -> Result<Option<SubscriptionCursor>> {
        let Some(subscription) = self.get(subscription_id)? else {
            return Ok(None);
        };
        let address = subscription.scope_address()?;
        Ok(Some(SubscriptionCursor::resumed(
            address,
            subscription.durable_cursor,
        )))
    }
}

type SubscriptionRow = (String, String, String, String, String, i64, i64, i64);

fn subscription_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SubscriptionRow> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        row.get(6)?,
        row.get(7)?,
    ))
}

fn decode(row: SubscriptionRow) -> Result<Subscription> {
    let scope = serde_json::from_str::<SubscriptionScope>(&row.2)
        .map_err(|_| anyhow::anyhow!("workflow_subscription_scope_invalid"))?;
    let predicate = serde_json::from_str::<SubscriptionPredicate>(&row.3)
        .map_err(|_| anyhow::anyhow!("workflow_subscription_predicate_invalid"))?;
    let activation_rule = serde_json::from_str::<ActivationRule>(&row.4)
        .map_err(|_| anyhow::anyhow!("workflow_subscription_activation_invalid"))?;
    Ok(Subscription {
        subscription_id: row.0,
        subscriber_id: row.1,
        scope,
        predicate,
        activation_rule,
        durable_cursor: row.5.max(0) as u64,
        is_control: row.6 != 0,
        active: row.7 != 0,
    })
}

fn validate_id(value: &str, code: &'static str) -> Result<()> {
    ensure!(
        !value.trim().is_empty()
            && value == value.trim()
            && value.len() <= 160
            && !value.chars().any(char::is_control),
        "{code}"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::testing::ScratchDelivery;
    use super::*;

    fn subscription(id: &str, cursor: u64) -> Subscription {
        Subscription {
            subscription_id: id.to_owned(),
            subscriber_id: "assistant-1".to_owned(),
            scope: SubscriptionScope::graph("graph-1").unwrap(),
            predicate: SubscriptionPredicate::OnAnyTransition,
            activation_rule: ActivationRule::NotifyOnly,
            durable_cursor: cursor,
            is_control: false,
            active: true,
        }
    }

    #[test]
    fn a_registered_subscription_keeps_its_cursor_across_a_reopen() {
        let delivery = ScratchDelivery::new("subscriptions-reopen");
        let path = delivery.path().to_path_buf();
        let registry = delivery.assembly().subscriptions();
        assert!(
            registry
                .subscribe(&subscription("subscription-1", 7))
                .unwrap()
        );
        assert!(
            !registry
                .subscribe(&subscription("subscription-1", 1))
                .unwrap(),
            "the same subscription re-registered is the same subscription, not a rewind"
        );
        let scope = SubscriptionScope::graph("graph-1").unwrap();
        assert_eq!(
            registry.deliver("subscription-1", &scope, 11).unwrap(),
            AdvanceOutcome::Advanced { from: 7, to: 11 }
        );
        drop(registry);

        // A fresh host over the same file resumes where the subscriber stopped.
        // The fixture that owns the file stays alive: dropping it would delete
        // the file this test is about.
        let database = Arc::new(WorkflowDatabase::open(&path).expect("the file reopens"));
        let assembly =
            super::super::DeliveryAssembly::assemble(database.clone()).expect("assembly");
        let registry = assembly.subscriptions();
        let listed = registry.list().expect("the registry lists");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].durable_cursor, 11);
        let resumed = registry
            .resume_cursor("subscription-1")
            .expect("the cursor reads")
            .expect("the subscription exists");
        assert_eq!(resumed.position(), 11);
        assert!(
            !resumed.accepts_new_work(11),
            "the restart does not re-deliver what the subscriber already saw"
        );
        assert_eq!(
            registry.deliver("subscription-1", &scope, 11).unwrap(),
            AdvanceOutcome::Unchanged { at: 11 },
            "a redelivery of the same fact is not new work"
        );
        assert_eq!(
            registry.deliver("subscription-1", &scope, 9).unwrap(),
            AdvanceOutcome::Stale {
                current: 11,
                proposed: 9
            }
        );
        drop(registry);
        drop(assembly);
        drop(database);
        drop(delivery);
    }

    #[test]
    fn a_redelivered_fact_is_not_a_second_delivery_but_a_new_one_advances() {
        let delivery = ScratchDelivery::new("subscriptions-cursor");
        let registry = delivery.assembly().subscriptions();
        registry
            .subscribe(&subscription("subscription-1", 0))
            .unwrap();
        let scope = SubscriptionScope::graph("graph-1").unwrap();
        assert_eq!(
            registry
                .deliver("subscription-1", &scope, 4)
                .unwrap()
                .position(),
            4
        );
        assert_eq!(
            registry.deliver("subscription-1", &scope, 4).unwrap(),
            AdvanceOutcome::Unchanged { at: 4 }
        );
        assert_eq!(
            registry.deliver("subscription-1", &scope, 12).unwrap(),
            AdvanceOutcome::Advanced { from: 4, to: 12 }
        );
        assert_eq!(
            registry
                .get("subscription-1")
                .expect("the subscription reads")
                .expect("it exists")
                .durable_cursor,
            12
        );
    }

    #[test]
    fn a_subscription_whose_meaning_changed_is_refused_rather_than_reinterpreted() {
        let delivery = ScratchDelivery::new("subscriptions-conflict");
        let registry = delivery.assembly().subscriptions();
        registry
            .subscribe(&subscription("subscription-1", 3))
            .unwrap();

        let mut changed_scope = subscription("subscription-1", 3);
        changed_scope.scope = SubscriptionScope::node("graph-1", "node-1").unwrap();
        assert!(
            registry
                .subscribe(&changed_scope)
                .unwrap_err()
                .to_string()
                .starts_with("workflow_subscription_conflict"),
            "a new scope needs a new identity"
        );

        let mut changed_predicate = subscription("subscription-1", 3);
        changed_predicate.predicate = SubscriptionPredicate::on_lifecycle_state("running").unwrap();
        assert!(registry.subscribe(&changed_predicate).is_err());

        let mut changed_active = subscription("subscription-1", 3);
        changed_active.active = false;
        assert!(registry.subscribe(&changed_active).is_err());
        assert_eq!(
            registry.get("subscription-1").unwrap().unwrap(),
            subscription("subscription-1", 3),
            "the refused registrations changed nothing"
        );

        assert!(registry.unsubscribe("subscription-1").unwrap());
        assert!(!registry.unsubscribe("subscription-1").unwrap());
        assert_eq!(registry.list().unwrap(), Vec::new());
    }

    #[test]
    fn a_fact_from_another_scope_is_refused_and_moves_nothing() {
        let delivery = ScratchDelivery::new("subscriptions-scope");
        let registry = delivery.assembly().subscriptions();
        registry
            .subscribe(&subscription("subscription-1", 5))
            .unwrap();
        let other = SubscriptionScope::graph("graph-2").unwrap();
        let error = registry.deliver("subscription-1", &other, 40).unwrap_err();
        assert!(
            error
                .to_string()
                .starts_with("routing_subscription_scope_mismatch"),
            "{error}"
        );
        assert_eq!(
            registry
                .get("subscription-1")
                .unwrap()
                .unwrap()
                .durable_cursor,
            5
        );
    }

    #[test]
    fn a_row_written_by_the_production_store_decodes_here() {
        let delivery = ScratchDelivery::new("subscriptions-wire");
        let registry = delivery.assembly().subscriptions();
        // The JSON the production store writes for a node-scoped subscription
        // with a lifecycle predicate and a resume rule: camelCase variant names,
        // fields as the Rust types spell them.
        delivery
            .database()
            .write(|transaction, _| {
                Ok(transaction.execute(
                    "INSERT INTO workflow_subscriptions(
                       subscription_id, subscriber_id, scope_json, predicate_json,
                       activation_json, durable_cursor, is_control, active, created_at
                     ) VALUES ('subscription-1', 'assistant-1',
                       '{\"node\":{\"graph_id\":\"graph-1\",\"node_id\":\"node-1\"}}',
                       '{\"onLifecycleState\":\"running\"}',
                       '{\"triggerTransition\":{\"target_state\":\"waiting\"}}',
                       4, 1, 1, 1)",
                    [],
                )?)
            })
            .expect("the row of the production writer is stored");

        let read = registry
            .get("subscription-1")
            .expect("it reads")
            .expect("it exists");
        assert_eq!(
            read.scope,
            SubscriptionScope::node("graph-1", "node-1").unwrap()
        );
        assert_eq!(
            read.predicate,
            SubscriptionPredicate::on_lifecycle_state("running").unwrap()
        );
        assert_eq!(
            read.activation_rule,
            ActivationRule::trigger_transition("waiting").unwrap()
        );
        assert_eq!(read.durable_cursor, 4);
        assert!(read.is_control);

        // And what this crate writes is the same shape, so the row is the same
        // row in both directions.
        assert_eq!(
            serde_json::to_string(&read.scope).expect("a scope encodes"),
            "{\"node\":{\"graph_id\":\"graph-1\",\"node_id\":\"node-1\"}}"
        );
        assert_eq!(
            serde_json::to_string(&read.predicate).expect("a predicate encodes"),
            "{\"onLifecycleState\":\"running\"}"
        );
        assert_eq!(
            serde_json::to_string(&read.activation_rule).expect("a rule encodes"),
            "{\"triggerTransition\":{\"target_state\":\"waiting\"}}"
        );
        assert_eq!(
            serde_json::to_string(&SubscriptionPredicate::OnAnyTransition)
                .expect("a unit variant encodes"),
            "\"onAnyTransition\""
        );
        assert_eq!(
            serde_json::to_string(&ActivationRule::NotifyOnly).expect("a unit variant encodes"),
            "\"notifyOnly\""
        );
        assert_eq!(
            serde_json::to_string(&SubscriptionScope::Graph("graph-1".to_owned()))
                .expect("a scope encodes"),
            "{\"graph\":\"graph-1\"}"
        );
        assert_eq!(
            serde_json::to_string(&SubscriptionPredicate::OnExternalEvent {
                event_name: "peer-joined".to_owned()
            })
            .expect("a predicate encodes"),
            "{\"onExternalEvent\":{\"event_name\":\"peer-joined\"}}"
        );
    }
}
