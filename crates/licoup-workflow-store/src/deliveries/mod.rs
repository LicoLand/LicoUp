//! Durable delivery: the lanes a committed fact waits in, the subscriptions
//! that watch for it, and the pass that carries it to its owner.
//!
//! ```text
//!   commit ──► workflow_notice_intents (V7-S1: one row per owner, with the fact)
//!                        │
//!      assemble ─────────┤  workflow_notice_claims (this module: the lease a pass holds)
//!                        │  workflow_subscriptions (the same table the production store writes)
//!      reconcile ────────┘  claim by lane ─► sink (no write lock held) ─► close the intent
//! ```
//!
//! ## Interface, not a second queue
//!
//! The obligation to deliver a fact is committed with the fact itself, in the
//! same transaction that commits the transition, so a fact that exists with no
//! delivery owed is not representable. This module adds the *service* side of
//! that obligation and nothing else:
//!
//! * the lane is derived from the kind by a declared
//!   [`licoup_workflow_runtime::routing::LanePolicy`], so there is no second
//!   classification column to drift;
//! * the claim is a lease row keyed by the notice's own identity, so a second
//!   pass cannot hold the same notice and a crashed pass's lease expires into
//!   availability rather than into a lost delivery;
//! * acceptance stays where V7-S1 put it — one ledger row per notice, counting
//!   repeats — so a redelivery is recorded and does not become new work.
//!
//! ## What this does not claim
//!
//! One SQLite database still has one writer at a time. Nothing here introduces
//! per-graph parallel writes: a claim is one short write transaction through the
//! same [`WorkflowDatabase`] gate as every other write, and a reconcile pass
//! holds the write lock only while claiming and while closing — never while the
//! sink is being called, which is the same rule the write path already follows
//! for effects.
//!
//! ## Boot order: assemble, then reconcile
//!
//! [`DeliveryAssembly::assemble`] is the only way to reach a lane, a
//! subscription registry, or a reconcile pass, and reconcile is a method on
//! what it returns. So "assemble before reconcile" is not a sequence a caller
//! has to remember: a host that has not assembled its sinks and its durable
//! side has nothing to reconcile *with*. The port rule follows from the same
//! shape — a pass never claims a notice for an owner whose sink is not
//! assembled, so nothing is acknowledged on behalf of a port that is not up.

pub mod lanes;
pub mod router;
pub mod subscriptions;

use anyhow::{Result, anyhow};
use std::sync::Arc;

use crate::transactions::WorkflowDatabase;

pub use lanes::{NoticeLaneStats, NoticeLanes, NoticeLease};
pub use router::{NoticeRouter, ReconcileReport, RetryPolicy};
pub use subscriptions::{Subscription, SubscriptionRegistry};

/// The columns of the intent table this module reads.
///
/// Stated as a list rather than assumed: a file whose intent table is a
/// different shape cannot be served honestly, and failing at assembly is better
/// than failing in the middle of a claim that already holds the write lock.
/// Every column the statements below touch is listed, including the ones only
/// the claim and the close use, so no query of this module can discover a
/// missing column after the claim has been taken.
const INTENT_COLUMNS: [&str; 8] = [
    "notice_id",
    "run_id",
    "sequence",
    "recipient",
    "kind",
    "status",
    "created_at",
    "accepted_at",
];

/// The columns of the subscription table, matching the format the production
/// store writes.
///
/// This is the same table, not a second registry: a subscription registered
/// here is visible to the production store, and one it wrote is served here.
/// That is why the shape is checked rather than created blindly — a file whose
/// `workflow_subscriptions` holds some other set of columns is refused with its
/// own code instead of being written to through columns it does not have.
const SUBSCRIPTION_COLUMNS: [&str; 9] = [
    "subscription_id",
    "subscriber_id",
    "scope_json",
    "predicate_json",
    "activation_json",
    "durable_cursor",
    "is_control",
    "active",
    "created_at",
];

/// The tables and indexes this module owns, additive to the shared format.
///
/// The retired `workflow_notice_intents_lane_idx` served a probe keyed by kind
/// alone, which could not seek past a backlog queued for another owner; the
/// recipient index below replaces it, and the drop keeps one index per purpose
/// on this write-hot table.
const DELIVERY_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS workflow_notice_claims(
       notice_id TEXT PRIMARY KEY REFERENCES workflow_notice_intents(notice_id),
       lane TEXT NOT NULL CHECK(lane IN ('control', 'result', 'bulk')),
       claimant TEXT NOT NULL,
       lease_until INTEGER NOT NULL,
       attempts INTEGER NOT NULL,
       updated_at INTEGER NOT NULL
     );
     CREATE INDEX IF NOT EXISTS workflow_notice_claims_lease_idx
       ON workflow_notice_claims(lease_until);
     DROP INDEX IF EXISTS workflow_notice_intents_lane_idx;
     CREATE INDEX IF NOT EXISTS workflow_notice_intents_recipient_idx
       ON workflow_notice_intents(status, kind, recipient, created_at, run_id, sequence, notice_id);
     CREATE TABLE IF NOT EXISTS workflow_delivery_meta(
       key TEXT PRIMARY KEY, value INTEGER NOT NULL
     );
     CREATE TABLE IF NOT EXISTS workflow_subscriptions(
       subscription_id TEXT PRIMARY KEY,
       subscriber_id TEXT NOT NULL,
       scope_json TEXT NOT NULL,
       predicate_json TEXT NOT NULL,
       activation_json TEXT NOT NULL,
       durable_cursor INTEGER NOT NULL,
       is_control INTEGER NOT NULL,
       active INTEGER NOT NULL,
       created_at INTEGER NOT NULL
     );
     CREATE INDEX IF NOT EXISTS workflow_subscriptions_cursor_idx
       ON workflow_subscriptions(active, durable_cursor);";

/// The key the fair-service position is stored under.
pub(crate) const LANE_CLASS_KEY: &str = "lane_class";
/// The key the number of turns used in the current turn is stored under.
pub(crate) const LANE_SERVED_KEY: &str = "lane_served";

/// The durable delivery side, assembled.
///
/// Holding one of these is the proof that the tables exist and have the shape
/// this module serves. It is deliberately the only constructible route to
/// [`NoticeLanes`], [`SubscriptionRegistry`], and [`NoticeRouter`]: a host that
/// reconciles without assembling would be serving an obligation out of a table
/// it never validated.
pub struct DeliveryAssembly {
    database: Arc<WorkflowDatabase>,
}

impl DeliveryAssembly {
    /// Validate what this module reads, add what it owns, and return the handle.
    ///
    /// Additive and idempotent for the shared format. An existing file keeps
    /// every row it had: the statements either create something that does not
    /// exist yet, or retire an index this module itself created and superseded.
    /// The one thing that can fail is a table whose shape this module cannot
    /// serve, reported before anything is created.
    pub fn assemble(database: Arc<WorkflowDatabase>) -> Result<Self> {
        require_columns(&database, "workflow_notice_intents", &INTENT_COLUMNS)?;
        if !columns(&database, "workflow_subscriptions")?.is_empty() {
            require_columns(&database, "workflow_subscriptions", &SUBSCRIPTION_COLUMNS)?;
        }
        let (_, _) = database.write(|transaction, _| {
            transaction.execute_batch(DELIVERY_SCHEMA)?;
            Ok(())
        })?;
        // Read back what the statements above are supposed to have produced, so
        // the schema string and the expectation cannot disagree.
        require_columns(&database, "workflow_subscriptions", &SUBSCRIPTION_COLUMNS)?;
        Ok(Self { database })
    }

    pub fn database(&self) -> &Arc<WorkflowDatabase> {
        &self.database
    }

    /// The fair lanes a notice waits in, under one declared policy.
    pub fn lanes(&self, policy: licoup_workflow_runtime::routing::LanePolicy) -> NoticeLanes {
        NoticeLanes::new(self.database.clone(), policy)
    }

    /// The durable subscription registry.
    pub fn subscriptions(&self) -> SubscriptionRegistry {
        SubscriptionRegistry::new(self.database.clone())
    }

    /// A reconcile pass over the assembled lanes.
    pub fn router(
        &self,
        policy: licoup_workflow_runtime::routing::LanePolicy,
        retry: RetryPolicy,
    ) -> NoticeRouter {
        NoticeRouter::new(self.lanes(policy), retry)
    }
}

impl std::fmt::Debug for DeliveryAssembly {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DeliveryAssembly")
            .finish_non_exhaustive()
    }
}

/// The columns of one table, or an empty list when the table does not exist.
fn columns(database: &WorkflowDatabase, table: &str) -> Result<Vec<String>> {
    database.read(|connection| {
        let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
        let names = statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(names)
    })
}

fn require_columns(database: &WorkflowDatabase, table: &str, required: &[&str]) -> Result<()> {
    let present = columns(database, table)?;
    if present.is_empty() {
        return Err(anyhow!("workflow_deliveries_table_missing: {table}"));
    }
    for column in required {
        if !present.iter().any(|name| name == column) {
            return Err(anyhow!(
                "workflow_deliveries_column_missing: {table}.{column}"
            ));
        }
    }
    Ok(())
}

/// Fixtures for the delivery tests.
///
/// They run against a real file for the same reason the transaction tests do:
/// the lease, the lane position, and the claim live in the file, and an
/// in-memory database would let several of those go untested.
#[cfg(test)]
pub(crate) mod testing {
    use super::*;
    use rusqlite::params;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    pub fn scratch_path(label: &str) -> PathBuf {
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "licoup-deliveries-{label}-{}-{unique}.sqlite3",
            std::process::id()
        ))
    }

    pub fn remove_database(path: &Path) {
        for suffix in ["", "-wal", "-shm"] {
            let mut name = path.as_os_str().to_owned();
            name.push(suffix);
            let _ = std::fs::remove_file(PathBuf::from(name));
        }
    }

    /// An assembled delivery side over one scratch file.
    pub struct ScratchDelivery {
        path: PathBuf,
        database: Arc<WorkflowDatabase>,
        assembly: DeliveryAssembly,
    }

    impl ScratchDelivery {
        pub fn new(label: &str) -> Self {
            let path = scratch_path(label);
            remove_database(&path);
            let database = Arc::new(WorkflowDatabase::open(&path).expect("database opens"));
            let assembly =
                DeliveryAssembly::assemble(database.clone()).expect("the delivery side assembles");
            Self {
                path,
                database,
                assembly,
            }
        }

        pub fn database(&self) -> &Arc<WorkflowDatabase> {
            &self.database
        }

        pub fn assembly(&self) -> &DeliveryAssembly {
            &self.assembly
        }

        /// The file this fixture owns, for a test that reopens it as a fresh host.
        pub fn path(&self) -> &Path {
            &self.path
        }

        /// Commit one intent the way the write path commits it.
        ///
        /// The identity comes from [`notice_id`](crate::transactions::notice_id)
        /// rather than being written by hand, so a fixture cannot pass with an
        /// identity the real path would refuse.
        pub fn seed_intent(
            &self,
            run_id: &str,
            sequence: u64,
            recipient: &str,
            kind: &str,
            created_at_unix_ms: i64,
        ) -> String {
            let intent = crate::transactions::NoticeIntent::for_fact(
                run_id,
                sequence,
                &crate::transactions::NoticeRequest {
                    recipient: recipient.to_owned(),
                    kind: kind.to_owned(),
                },
                created_at_unix_ms,
            )
            .expect("the intent is storable");
            let (_, _) = self
                .database
                .write(|transaction, _| {
                    Ok(transaction.execute(
                        "INSERT INTO workflow_notice_intents(
                           notice_id, run_id, sequence, recipient, kind, status, created_at, accepted_at
                         ) VALUES (?1, ?2, ?3, ?4, ?5, 'pending', ?6, NULL)",
                        params![
                            intent.notice_id,
                            intent.run_id,
                            intent.sequence as i64,
                            intent.recipient,
                            intent.kind,
                            intent.created_at_unix_ms
                        ],
                    )?)
                })
                .expect("the intent commits");
            intent.notice_id
        }

        pub fn intent_status(&self, notice_id: &str) -> String {
            self.read_one(
                "SELECT status FROM workflow_notice_intents WHERE notice_id=?1",
                notice_id,
            )
            .expect("the intent exists")
        }

        pub fn acceptance_count(&self, notice_id: &str) -> Option<i64> {
            use rusqlite::OptionalExtension;
            self.database
                .read(|connection| {
                    Ok(connection
                        .query_row(
                            "SELECT accept_count FROM workflow_notice_acceptances WHERE notice_id=?1",
                            params![notice_id],
                            |row| row.get::<_, i64>(0),
                        )
                        .optional()?)
                })
                .expect("the acceptance ledger reads")
        }

        pub fn claim(&self, notice_id: &str) -> Option<(String, i64, i64)> {
            use rusqlite::OptionalExtension;
            self.database
                .read(|connection| {
                    Ok(connection
                        .query_row(
                            "SELECT claimant, lease_until, attempts FROM workflow_notice_claims
                             WHERE notice_id=?1",
                            params![notice_id],
                            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                        )
                        .optional()?)
                })
                .expect("the claim reads")
        }

        fn read_one(&self, sql: &str, notice_id: &str) -> Option<String> {
            use rusqlite::OptionalExtension;
            self.database
                .read(|connection| {
                    Ok(connection
                        .query_row(sql, params![notice_id], |row| row.get::<_, String>(0))
                        .optional()?)
                })
                .expect("the fixture query runs")
        }
    }

    impl Drop for ScratchDelivery {
        fn drop(&mut self) {
            remove_database(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{ScratchDelivery, remove_database, scratch_path};
    use super::*;

    #[test]
    fn assembly_adds_only_its_own_tables_and_can_be_repeated() {
        let path = scratch_path("assemble");
        remove_database(&path);
        let database = Arc::new(WorkflowDatabase::open(&path).expect("database opens"));
        let before = tables(&database);
        let assembly = DeliveryAssembly::assemble(database.clone()).expect("assembly");
        let added: Vec<String> = tables(&database)
            .into_iter()
            .filter(|table| !before.contains(table))
            .collect();
        assert_eq!(
            added,
            vec![
                "workflow_delivery_meta".to_owned(),
                "workflow_notice_claims".to_owned(),
                "workflow_subscriptions".to_owned(),
            ],
            "assembly adds its own tables and nothing else"
        );
        // Re-assembling is a no-op: the shape is validated, not re-created.
        let again = DeliveryAssembly::assemble(assembly.database().clone()).expect("assembly");
        assert_eq!(tables(again.database()), tables(&database));
        drop(again);
        drop(database);
        remove_database(&path);
    }

    #[test]
    fn a_subscription_table_of_another_shape_is_refused_before_anything_is_created() {
        let path = scratch_path("legacy-subscriptions");
        remove_database(&path);
        let database = WorkflowDatabase::open(&path).expect("database opens");
        database
            .write(|transaction, _| {
                Ok(transaction.execute_batch(
                    "CREATE TABLE workflow_subscriptions(
                       subscription_id TEXT PRIMARY KEY, cursor INTEGER NOT NULL
                     );",
                )?)
            })
            .expect("legacy table");
        let before = tables(&database);
        let error = DeliveryAssembly::assemble(Arc::new(database))
            .expect_err("a table this module cannot serve is refused");
        assert!(
            error
                .to_string()
                .starts_with("workflow_deliveries_column_missing: workflow_subscriptions."),
            "{error}"
        );
        let database = WorkflowDatabase::open(&path).expect("database reopens");
        assert_eq!(
            tables(&database),
            before,
            "a refused assembly creates nothing, so the file is left as it was"
        );
        drop(database);
        remove_database(&path);
    }

    #[test]
    fn assembly_retires_the_superseded_probe_index() {
        let path = scratch_path("retire-index");
        remove_database(&path);
        let database = WorkflowDatabase::open(&path).expect("database opens");
        database
            .write(|transaction, _| {
                Ok(transaction.execute_batch(
                    "CREATE INDEX IF NOT EXISTS workflow_notice_intents_lane_idx
                       ON workflow_notice_intents(status, kind, created_at, run_id, sequence, notice_id);",
                )?)
            })
            .expect("the superseded index exists");
        let assembly = DeliveryAssembly::assemble(Arc::new(database)).expect("assembly");

        let indexes = index_names(assembly.database());
        assert!(
            !indexes.contains(&"workflow_notice_intents_lane_idx".to_owned()),
            "the probe index that could not seek past another owner's backlog is retired: {indexes:?}"
        );
        assert!(
            indexes.contains(&"workflow_notice_intents_recipient_idx".to_owned()),
            "the recipient-keyed index the claim now seeks is present: {indexes:?}"
        );
        drop(assembly);
        remove_database(&path);
    }

    #[test]
    fn the_fixture_commits_intents_the_write_path_would_accept() {
        let delivery = ScratchDelivery::new("fixture-intent");
        let notice_id = delivery.seed_intent("run-1", 3, "timeline", "timeline-projection", 1);
        assert_eq!(delivery.intent_status(&notice_id), "pending");
        assert_eq!(
            notice_id,
            crate::transactions::notice_id("run-1", 3, "timeline", "timeline-projection"),
            "the fixture cannot invent an identity the real path would refuse"
        );
    }

    fn tables(database: &WorkflowDatabase) -> Vec<String> {
        database
            .read(|connection| {
                let mut statement = connection
                    .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")?;
                let names = statement
                    .query_map([], |row| row.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                Ok(names)
            })
            .expect("the schema reads")
    }

    fn index_names(database: &WorkflowDatabase) -> Vec<String> {
        database
            .read(|connection| {
                let mut statement = connection
                    .prepare("SELECT name FROM sqlite_master WHERE type='index' ORDER BY name")?;
                let names = statement
                    .query_map([], |row| row.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                Ok(names)
            })
            .expect("the schema reads")
    }
}
