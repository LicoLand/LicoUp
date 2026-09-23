//! Consumer-owned ports for graph execution.
//!
//! A port is named in the consumer's vocabulary and implemented by whoever
//! owns the underlying fact. That is what fixes this crate's place in the
//! dependency direction:
//!
//! ```text
//!   licoup-workflow-store  ──►  licoup-workflow-runtime::ports  ──►  licoup-workflow
//!      (implements)                   (declares)                      (pure machine)
//! ```
//!
//! Nothing in this module may name a storage type. If a port needed one, the
//! direction would have to be reversed, and the compile-fail fixtures under
//! `tests/ui/` exist to make that reversal a build error rather than a
//! convention.
//!
//! The port surface is deliberately small. Each trait here is grounded in an
//! operation the production store already performs; ports for the effect,
//! budget, and usage sides arrive with the leaves that own those facts
//! (V7-C1, V7-S1, V7-R1), not before.

use anyhow::Result;
use licoup_workflow::{ReducerEvent, RunCommand, RunSnapshot};
use serde::{Deserialize, Serialize};

/// The durable run state a drive reads and advances.
///
/// Every method states what a *late* caller must see, because the interesting
/// failures in this system come from a second host acting on a stale view.
pub trait StatePort: Send + Sync {
    /// The active checkpoint for a run.
    fn checkpoint(&self, run_id: &str) -> Result<RunSnapshot>;

    /// Commit one reducer event against the sequence the caller read.
    ///
    /// A stale `expected_sequence` must fail instead of silently rebasing: a
    /// caller that decided something from an old view must not have that
    /// decision applied to a newer one.
    fn commit(
        &self,
        run_id: &str,
        expected_sequence: u64,
        event: ReducerEvent,
    ) -> Result<RunSnapshot>;

    /// Atomically take the next dispatchable command under a lease.
    ///
    /// Returns `None` when nothing is dispatchable, which is not an error.
    fn claim_next(
        &self,
        run_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<Option<RunCommand>>;

    /// Extend a held lease. Fails when the lease was lost, so a caller cannot
    /// keep working on a claim it no longer owns.
    fn renew_lease(&self, command_id: &str, claimant: &str, lease_until_unix_ms: i64)
    -> Result<()>;

    /// Commit the possible-effect marker, **before** the effect is invoked.
    ///
    /// This is the boundary the whole recovery contract rests on: a command
    /// carrying this marker may already have had its effect happen, so recovery
    /// must treat it as in-doubt rather than retryable. Callers must not invoke
    /// an effect on a command whose marker is not yet durable.
    fn mark_started(
        &self,
        run_id: &str,
        command_id: &str,
        attempt_token: &str,
    ) -> Result<RunSnapshot>;

    /// Read back the recorded result reference for a command, if its outcome
    /// was recorded. `None` means "no recorded outcome", which is exactly the
    /// fact a reconciliation must not confuse with failure.
    fn result_ref(&self, run_id: &str, command_id: &str) -> Result<Option<String>>;
}

/// A resolved authorization reference.
///
/// Identifier-only: the port answers *which* grant is in force, never the
/// content of a principal or a credential.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorizationRef {
    /// Digest of the grant in force for the requested revision.
    pub authorization_digest: String,
    /// Digest of the semantics the grant was issued against.
    pub semantics_digest: String,
}

/// One recheck of a command against the authority that admitted it.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorityRecheck {
    pub run_id: String,
    pub command_id: String,
    /// The grant the caller believes admitted this command.
    pub expected_authorization_digest: String,
    /// The semantics the caller believes it is acting under.
    pub expected_semantics_digest: String,
}

/// Resolving authorization references in the trusted session domain.
///
/// A grant is *resolved*, never granted, through this port: issuing a grant is
/// a user decision that stays with its own owner.
pub trait AuthorityPort: Send + Sync {
    /// The active grant for a definition revision, if any.
    fn active_authorization(&self, revision_digest: &str) -> Result<Option<AuthorizationRef>>;

    /// Recheck one command at the admission boundary.
    ///
    /// Returns `Ok(false)` for a refusal rather than an error: "this command is
    /// no longer covered" is an answer, not a failure.
    fn recheck(&self, request: &AuthorityRecheck) -> Result<bool>;
}

/// Durable downstream acceptance of a committed fact.
///
/// The contract here is deliberately not "delivered". A sink reports success
/// only once the downstream owner has it durably, so a caller may treat a
/// successful sink call as a fact it no longer has to repeat, and a failed one
/// as work still owed.
pub trait NoticeSink: Send + Sync {
    /// Hand one committed fact to its downstream owner.
    fn accept(&self, notice: &Notice) -> Result<()>;
}

/// One committed fact addressed to one downstream owner.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Notice {
    /// Stable identity: the same fact carried twice keeps the same id, so a
    /// retry is recognisable as a repeat rather than as new work.
    pub notice_id: String,
    pub run_id: String,
    /// The run sequence this fact was committed at.
    pub sequence: u64,
    /// The owner expected to accept it.
    pub recipient: String,
    pub kind: String,
}
