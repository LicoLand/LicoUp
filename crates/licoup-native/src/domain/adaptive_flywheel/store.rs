use anyhow::{Result, anyhow, ensure};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

use super::{
    BindingCandidate, BindingValue, ReducerEvent, RunCommand, RunSnapshot, STRATEGY_SCHEMA_VERSION,
    StrategyAuthorization, StrategyDefinition, StrategyDefinitionSummary, StrategyDiagnostic,
    StrategyProjection, StrategyRunStatus, WorkflowDefinition, compile_persisted_workflow,
    compile_workflow, reduce,
};

const DATABASE_FILE: &str = "strategies.sqlite3";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LeaseRecovery {
    Standard,
    AbandonedHost,
}

#[derive(Clone, Debug)]
pub struct StrategyStore {
    db_path: PathBuf,
    package_revisions_root: Option<PathBuf>,
}

impl StrategyStore {
    pub fn open(portable_root: &Path) -> Result<Self> {
        let root = portable_root.join("client-state").join("adaptive-flywheel");
        crate::platform::file_security::ensure_private_dir(&root)?;
        let db_path = root.join(DATABASE_FILE);
        let existed = db_path.exists();
        let store = Self {
            db_path,
            package_revisions_root: Some(root.join("strategy-packages").join("revisions")),
        };
        let retired = store.with_connection(|connection| {
            if existed {
                validate_current_schema(connection).map(|()| Vec::new())
            } else {
                initialize_schema(connection)
            }
        })?;
        crate::platform::file_security::harden_private_path(&store.db_path)?;
        store.remove_retired_revision_trees(&retired);
        Ok(store)
    }

    pub(crate) fn open_for_migration(portable_root: &Path) -> Result<Self> {
        let root = portable_root.join("client-state").join("adaptive-flywheel");
        crate::platform::file_security::ensure_private_dir(&root)?;
        let store = Self {
            db_path: root.join(DATABASE_FILE),
            package_revisions_root: Some(root.join("strategy-packages").join("revisions")),
        };
        let retired = store.with_connection(initialize_schema)?;
        crate::platform::file_security::harden_private_path(&store.db_path)?;
        store.remove_retired_revision_trees(&retired);
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self> {
        let path =
            std::env::temp_dir().join(format!("lico-adaptive-flywheel-{}.sqlite3", Uuid::new_v4()));
        let store = Self {
            db_path: path,
            package_revisions_root: None,
        };
        store.with_connection(initialize_schema)?;
        Ok(store)
    }

    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    fn with_connection<T>(
        &self,
        operation: impl FnOnce(&mut Connection) -> Result<T>,
    ) -> Result<T> {
        let mut connection = Connection::open(&self.db_path)
            .map_err(|_| anyhow!("strategy_database_open_failed"))?;
        configure_connection(&connection)?;
        operation(&mut connection)
    }

    pub(crate) fn register_definition(
        &self,
        revision_digest: &str,
        semantics_digest: &str,
        workflow: &WorkflowDefinition,
        asset_count: usize,
        imported_at_unix_ms: i64,
    ) -> Result<StrategyDefinition> {
        let compiled = compile_workflow(workflow.clone())?;
        let workflow_json = serde_json::to_string(&compiled.definition)?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute(
                "INSERT INTO strategy_definitions(
                   definition_id, revision_digest, semantics_digest, name, version,
                   workflow_json, asset_count, imported_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(revision_digest) DO NOTHING",
                params![
                    compiled.definition.metadata.id,
                    revision_digest,
                    semantics_digest,
                    compiled.definition.metadata.name,
                    compiled.definition.metadata.version,
                    workflow_json,
                    asset_count as i64,
                    imported_at_unix_ms,
                ],
            )?;
            let existing: Option<(String, String)> = transaction
                .query_row(
                    "SELECT definition_id, semantics_digest FROM strategy_definitions
                     WHERE revision_digest=?1",
                    params![revision_digest],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            ensure!(
                existing
                    == Some((
                        compiled.definition.metadata.id.clone(),
                        semantics_digest.to_owned()
                    )),
                "strategy_revision_conflict"
            );
            transaction.commit()?;
            self.definition_by_revision(revision_digest)
        })
    }

    pub fn list_definitions(&self) -> Result<Vec<StrategyDefinitionSummary>> {
        self.with_connection(|connection| {
            let mut statement = connection.prepare(
                "SELECT definition_id, revision_digest, semantics_digest, name, version, imported_at,
                        EXISTS(
                          SELECT 1 FROM strategy_authorizations
                          WHERE revision_digest=strategy_definitions.revision_digest AND active=1
                        )
                 FROM strategy_definitions
                 WHERE definition_id NOT LIKE 'assistant-temporary%'
                 ORDER BY imported_at DESC, revision_digest ASC",
            )?;
            let rows = statement.query_map([], summary_from_row)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
                .map_err(Into::into)
        })
    }

    pub fn definition_by_revision(&self, revision_digest: &str) -> Result<StrategyDefinition> {
        self.with_connection(|connection| definition_by_revision(connection, revision_digest))
    }

    pub fn latest_definition(&self, definition_id: &str) -> Result<StrategyDefinition> {
        self.with_connection(|connection| {
            let revision: Option<String> = connection
                .query_row(
                    "SELECT revision_digest FROM strategy_definitions
                     WHERE definition_id=?1 ORDER BY imported_at DESC, revision_digest ASC LIMIT 1",
                    params![definition_id],
                    |row| row.get(0),
                )
                .optional()?;
            definition_by_revision(
                connection,
                revision
                    .as_deref()
                    .ok_or_else(|| anyhow!("strategy_definition_not_found"))?,
            )
        })
    }

    pub fn update_binding(
        &self,
        revision_digest: &str,
        slot_id: &str,
        value_id: &str,
        model: &str,
        reasoning_effort: &str,
        expected_revision: Option<u64>,
    ) -> Result<BindingValue> {
        self.replace_slot_bindings(
            revision_digest,
            slot_id,
            &[BindingCandidate {
                value_id: value_id.to_owned(),
                model: model.to_owned(),
                reasoning_effort: reasoning_effort.to_owned(),
            }],
            expected_revision,
        )?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("strategy_binding_incomplete"))
    }

    pub fn replace_slot_bindings(
        &self,
        revision_digest: &str,
        slot_id: &str,
        candidates: &[BindingCandidate],
        expected_revision: Option<u64>,
    ) -> Result<Vec<BindingValue>> {
        validate_opaque_id(slot_id, "strategy_binding_slot_invalid")?;
        ensure!(candidates.len() <= 16, "strategy_binding_limit");
        for candidate in candidates {
            validate_opaque_id(&candidate.value_id, "strategy_binding_value_invalid")?;
            validate_optional_text(&candidate.model, "strategy_binding_model_invalid")?;
            validate_optional_text(
                &candidate.reasoning_effort,
                "strategy_binding_reasoning_effort_invalid",
            )?;
        }
        let definition = self.definition_by_revision(revision_digest)?;
        ensure!(
            definition
                .workflow
                .actor_slots
                .iter()
                .any(|slot| slot.id == slot_id),
            "strategy_binding_slot_unknown"
        );
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let current: Option<u64> = transaction
                .query_row(
                    "SELECT MAX(revision) FROM strategy_bindings
                     WHERE revision_digest=?1 AND slot_id=?2",
                    params![revision_digest, slot_id],
                    |row| row.get::<_, Option<i64>>(0),
                )
                .optional()?
                .flatten()
                .map(|value| value as u64);
            if let Some(expected) = expected_revision {
                ensure!(current.unwrap_or(0) == expected, "strategy_revision_conflict");
            }
            let revision = current.unwrap_or(0) + 1;
            transaction.execute(
                "DELETE FROM strategy_bindings WHERE revision_digest=?1 AND slot_id=?2",
                params![revision_digest, slot_id],
            )?;
            let mut values = Vec::with_capacity(candidates.len());
            for (ordinal, candidate) in candidates.iter().enumerate() {
                let ordinal = u8::try_from(ordinal).map_err(|_| anyhow!("strategy_binding_limit"))?;
                transaction.execute(
                    "INSERT INTO strategy_bindings(
                       revision_digest, slot_id, ordinal, value_id, model, reasoning_effort, revision
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        revision_digest,
                        slot_id,
                        ordinal as i64,
                        candidate.value_id,
                        candidate.model,
                        candidate.reasoning_effort,
                        revision as i64
                    ],
                )?;
                values.push(BindingValue {
                    slot_id: slot_id.to_owned(),
                    ordinal,
                    value_id: candidate.value_id.clone(),
                    model: candidate.model.clone(),
                    reasoning_effort: candidate.reasoning_effort.clone(),
                    revision,
                });
            }
            transaction.execute(
                "UPDATE strategy_authorizations SET active=0 WHERE revision_digest=?1 AND active=1",
                params![revision_digest],
            )?;
            transaction.commit()?;
            Ok(values)
        })
    }

    pub fn remove_binding(
        &self,
        revision_digest: &str,
        slot_id: &str,
        expected_revision: Option<u64>,
    ) -> Result<()> {
        validate_opaque_id(slot_id, "strategy_binding_slot_invalid")?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let current: Option<u64> = transaction
                .query_row(
                    "SELECT MAX(revision) FROM strategy_bindings
                     WHERE revision_digest=?1 AND slot_id=?2",
                    params![revision_digest, slot_id],
                    |row| row.get::<_, Option<i64>>(0),
                )
                .optional()?
                .flatten()
                .map(|value| value as u64);
            if let Some(expected) = expected_revision {
                ensure!(
                    current.unwrap_or(0) == expected,
                    "strategy_revision_conflict"
                );
            }
            transaction.execute(
                "DELETE FROM strategy_bindings WHERE revision_digest=?1 AND slot_id=?2",
                params![revision_digest, slot_id],
            )?;
            transaction.execute(
                "UPDATE strategy_authorizations SET active=0
                 WHERE revision_digest=?1 AND active=1",
                params![revision_digest],
            )?;
            transaction.commit()?;
            Ok(())
        })
    }

    pub fn authorization_preview(&self, revision_digest: &str) -> Result<StrategyAuthorization> {
        let definition = self.definition_by_revision(revision_digest)?;
        ensure!(
            bindings_complete(&definition),
            "strategy_binding_incomplete"
        );
        let binding_digest = binding_digest(&definition.bindings)?;
        let next_revision = definition
            .authorization
            .as_ref()
            .map_or(1, |authorization| authorization.revision + 1);
        let authorization_digest = authorization_digest(
            revision_digest,
            &definition.summary.semantics_digest,
            &binding_digest,
            next_revision,
        );
        Ok(StrategyAuthorization {
            definition_digest: revision_digest.to_owned(),
            semantics_digest: definition.summary.semantics_digest,
            binding_digest,
            authorization_digest,
            revision: next_revision,
            active: false,
        })
    }

    pub fn grant_authorization(
        &self,
        revision_digest: &str,
        expected_authorization_digest: &str,
    ) -> Result<StrategyAuthorization> {
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let definition = definition_by_revision(&transaction, revision_digest)?;
            ensure!(
                bindings_complete(&definition),
                "strategy_binding_incomplete"
            );
            let binding_digest = binding_digest(&definition.bindings)?;
            let next_revision = definition
                .authorization
                .as_ref()
                .map_or(1, |authorization| authorization.revision + 1);
            let authorization_digest = authorization_digest(
                revision_digest,
                &definition.summary.semantics_digest,
                &binding_digest,
                next_revision,
            );
            ensure!(
                authorization_digest == expected_authorization_digest,
                "strategy_authorization_stale"
            );
            transaction.execute(
                "UPDATE strategy_authorizations SET active=0 WHERE revision_digest=?1 AND active=1",
                params![revision_digest],
            )?;
            transaction.execute(
                "INSERT INTO strategy_authorizations(
                   revision_digest, revision, semantics_digest, binding_digest,
                   authorization_digest, active, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6)",
                params![
                    revision_digest,
                    next_revision as i64,
                    definition.summary.semantics_digest,
                    binding_digest,
                    authorization_digest,
                    now_ms(),
                ],
            )?;
            transaction.commit()?;
            Ok(StrategyAuthorization {
                definition_digest: revision_digest.to_owned(),
                semantics_digest: definition.summary.semantics_digest,
                binding_digest,
                authorization_digest,
                revision: next_revision,
                active: true,
            })
        })
    }

    pub fn revoke_authorization(&self, revision_digest: &str) -> Result<()> {
        self.with_connection(|connection| {
            connection.execute(
                "UPDATE strategy_authorizations SET active=0 WHERE revision_digest=?1 AND active=1",
                params![revision_digest],
            )?;
            Ok(())
        })
    }

    pub fn start_run(
        &self,
        revision_digest: &str,
        input: Value,
        idempotency_key: &str,
        conversation_id: Option<&str>,
        cwd: Option<String>,
    ) -> Result<RunSnapshot> {
        self.start_run_with_assistant_context(
            revision_digest,
            input,
            idempotency_key,
            conversation_id,
            cwd,
            None,
            None,
        )
    }

    pub(crate) fn start_run_with_assistant_context(
        &self,
        revision_digest: &str,
        input: Value,
        idempotency_key: &str,
        conversation_id: Option<&str>,
        cwd: Option<String>,
        assistant_membership_id: Option<&str>,
        route_receipt: Option<Value>,
    ) -> Result<RunSnapshot> {
        validate_opaque_id(idempotency_key, "strategy_idempotency_key_invalid")?;
        if let Some(conversation_id) = conversation_id {
            validate_opaque_id(conversation_id, "strategy_conversation_id_invalid")?;
        }
        if let Some(membership_id) = assistant_membership_id {
            validate_opaque_id(membership_id, "strategy_membership_id_invalid")?;
        }
        let input_bytes = serde_json::to_vec(&input)?;
        let mut digest_source = Vec::from(revision_digest.as_bytes());
        digest_source.push(0);
        digest_source.extend_from_slice(&input_bytes);
        digest_source.push(0);
        digest_source.extend_from_slice(conversation_id.unwrap_or("").as_bytes());
        digest_source.push(0);
        digest_source.extend_from_slice(cwd.as_deref().unwrap_or("").as_bytes());
        digest_source.push(0);
        digest_source.extend_from_slice(assistant_membership_id.unwrap_or("").as_bytes());
        digest_source.push(0);
        digest_source.extend_from_slice(&serde_json::to_vec(&route_receipt)?);
        let request_digest = sha256_hex(&digest_source);
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let existing: Option<(String, String)> = transaction
                .query_row(
                    "SELECT run_id, request_digest FROM strategy_runs WHERE idempotency_key=?1",
                    params![idempotency_key],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            if let Some((run_id, existing_digest)) = existing {
                ensure!(
                    existing_digest == request_digest,
                    "strategy_idempotency_conflict"
                );
                let snapshot = load_run(&transaction, &run_id)?;
                transaction.commit()?;
                return Ok(snapshot);
            }

            // Authorization, exact bindings, reduction, and insertion share
            // one write transaction. A concurrent revoke or binding update
            // therefore happens wholly before or wholly after this admission.
            let definition = definition_by_revision(&transaction, revision_digest)?;
            ensure!(
                bindings_complete(&definition),
                "strategy_binding_incomplete"
            );
            let authorization = current_authorization(&definition)?;
            ensure!(
                authorization.binding_digest == binding_digest(&definition.bindings)?,
                "strategy_authorization_stale"
            );
            let slot_candidate_counts = slot_candidate_counts(&definition.bindings);
            let semantics_digest = definition.summary.semantics_digest.clone();
            let compiled = compile_persisted_workflow(definition.workflow)?;
            let run_id = format!("run-{}", Uuid::new_v4());
            let empty = RunSnapshot::empty(&run_id, revision_digest, &semantics_digest);
            let event = ReducerEvent::Start { input };
            let output = reduce(&compiled, &empty, event.clone())?;
            let mut snapshot = output.snapshot;
            snapshot.conversation_id = conversation_id.map(str::to_owned);
            snapshot.assistant_membership_id = assistant_membership_id.map(str::to_owned);
            snapshot.route_receipt = route_receipt;
            snapshot.cwd = cwd;
            snapshot.slot_candidate_counts = slot_candidate_counts;
            let now = now_ms();
            transaction.execute(
                "INSERT INTO strategy_runs(
                   run_id, revision_digest, semantics_digest, idempotency_key,
                   request_digest, snapshot_json, conversation_id, terminal,
                   created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)",
                params![
                    run_id,
                    revision_digest,
                    semantics_digest,
                    idempotency_key,
                    request_digest,
                    serde_json::to_string(&snapshot)?,
                    snapshot.conversation_id,
                    i64::from(run_is_terminal(snapshot.status)),
                    now,
                ],
            )?;
            persist_event_and_commands(
                &transaction,
                &snapshot,
                &event,
                &output.emitted_commands,
                now,
            )?;
            transaction.commit()?;
            Ok(snapshot)
        })
    }

    /// Atomically freezes one Assistant-temporary definition, exact
    /// Membership bindings, authorization and run snapshot. The definition
    /// digest already commits to the route receipt; existing rows must be
    /// byte-for-byte equivalent and can never be rebound.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn admit_assistant_run(
        &self,
        revision_digest: &str,
        semantics_digest: &str,
        workflow: &WorkflowDefinition,
        bindings: &[BindingValue],
        input: Value,
        idempotency_key: &str,
        conversation_id: &str,
        assistant_membership_id: &str,
        route_receipt: Value,
    ) -> Result<(RunSnapshot, bool)> {
        validate_opaque_id(idempotency_key, "strategy_idempotency_key_invalid")?;
        validate_opaque_id(conversation_id, "strategy_conversation_id_invalid")?;
        validate_opaque_id(assistant_membership_id, "strategy_membership_id_invalid")?;
        ensure!(
            workflow
                .metadata
                .id
                .starts_with(super::ASSISTANT_TEMPORARY_DEFINITION_PREFIX),
            "graph_identity_rejected"
        );
        let compiled = compile_workflow(workflow.clone())?;
        let workflow_json = serde_json::to_string(&compiled.definition)?;
        let mut expected_bindings = bindings.to_vec();
        expected_bindings.sort_by(|left, right| {
            left.slot_id
                .cmp(&right.slot_id)
                .then_with(|| left.ordinal.cmp(&right.ordinal))
        });
        for binding in &expected_bindings {
            validate_opaque_id(&binding.slot_id, "strategy_binding_slot_invalid")?;
            validate_opaque_id(&binding.value_id, "strategy_binding_value_invalid")?;
            ensure!(binding.ordinal < 16, "strategy_binding_limit");
            validate_optional_text(&binding.model, "strategy_binding_model_invalid")?;
            validate_optional_text(
                &binding.reasoning_effort,
                "strategy_binding_reasoning_effort_invalid",
            )?;
        }
        let mut request_source = Vec::from(revision_digest.as_bytes());
        request_source.push(0);
        request_source.extend_from_slice(&serde_json::to_vec(&input)?);
        request_source.push(0);
        request_source.extend_from_slice(conversation_id.as_bytes());
        request_source.push(0);
        request_source.extend_from_slice(assistant_membership_id.as_bytes());
        request_source.push(0);
        request_source.extend_from_slice(&serde_json::to_vec(&route_receipt)?);
        let request_digest = sha256_hex(&request_source);
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let existing: Option<(String, String)> = transaction
                .query_row(
                    "SELECT run_id, request_digest FROM strategy_runs WHERE idempotency_key=?1",
                    params![idempotency_key],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            if let Some((run_id, existing_digest)) = existing {
                ensure!(
                    existing_digest == request_digest,
                    "strategy_idempotency_conflict"
                );
                let snapshot = load_run(&transaction, &run_id)?;
                transaction.commit()?;
                return Ok((snapshot, false));
            }

            transaction.execute(
                "INSERT INTO strategy_definitions(
                   definition_id, revision_digest, semantics_digest, name, version,
                   workflow_json, asset_count, imported_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)
                 ON CONFLICT(revision_digest) DO NOTHING",
                params![
                    compiled.definition.metadata.id,
                    revision_digest,
                    semantics_digest,
                    compiled.definition.metadata.name,
                    compiled.definition.metadata.version,
                    workflow_json,
                    now_ms(),
                ],
            )?;
            let stored_identity: (String, String, String) = transaction.query_row(
                "SELECT definition_id, semantics_digest, workflow_json
                 FROM strategy_definitions WHERE revision_digest=?1",
                params![revision_digest],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
            ensure!(
                stored_identity
                    == (
                        compiled.definition.metadata.id.clone(),
                        semantics_digest.to_owned(),
                        serde_json::to_string(&compiled.definition)?,
                    ),
                "strategy_revision_conflict"
            );
            for binding in &expected_bindings {
                transaction.execute(
                    "INSERT OR IGNORE INTO strategy_bindings(
                       revision_digest, slot_id, ordinal, value_id, model,
                       reasoning_effort, revision
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1)",
                    params![
                        revision_digest,
                        binding.slot_id,
                        binding.ordinal as i64,
                        binding.value_id,
                        binding.model,
                        binding.reasoning_effort,
                    ],
                )?;
            }
            let definition = definition_by_revision(&transaction, revision_digest)?;
            let mut stored_bindings = definition.bindings.clone();
            stored_bindings.sort_by(|left, right| {
                left.slot_id
                    .cmp(&right.slot_id)
                    .then_with(|| left.ordinal.cmp(&right.ordinal))
            });
            ensure!(
                stored_bindings.len() == expected_bindings.len()
                    && stored_bindings
                        .iter()
                        .zip(&expected_bindings)
                        .all(|(stored, expected)| {
                            stored.slot_id == expected.slot_id
                                && stored.ordinal == expected.ordinal
                                && stored.value_id == expected.value_id
                                && stored.model == expected.model
                                && stored.reasoning_effort == expected.reasoning_effort
                        })
                    && bindings_complete(&definition),
                "strategy_revision_conflict"
            );
            let frozen_binding_digest = binding_digest(&stored_bindings)?;
            let frozen_authorization_digest =
                authorization_digest(revision_digest, semantics_digest, &frozen_binding_digest, 1);
            transaction.execute(
                "INSERT OR IGNORE INTO strategy_authorizations(
                   revision_digest, revision, semantics_digest, binding_digest,
                   authorization_digest, active, created_at
                 ) VALUES (?1, 1, ?2, ?3, ?4, 1, ?5)",
                params![
                    revision_digest,
                    semantics_digest,
                    frozen_binding_digest,
                    frozen_authorization_digest,
                    now_ms(),
                ],
            )?;
            let authorization = load_authorization(&transaction, revision_digest)?
                .ok_or_else(|| anyhow!("strategy_authorization_stale"))?;
            ensure!(
                authorization.active
                    && authorization.revision == 1
                    && authorization.semantics_digest == semantics_digest
                    && authorization.binding_digest == frozen_binding_digest
                    && authorization.authorization_digest == frozen_authorization_digest,
                "strategy_authorization_stale"
            );

            let slot_candidate_counts = slot_candidate_counts(&stored_bindings);
            let run_id = format!("run-{}", Uuid::new_v4());
            let empty = RunSnapshot::empty(&run_id, revision_digest, semantics_digest);
            let event = ReducerEvent::Start { input };
            let output = reduce(&compiled, &empty, event.clone())?;
            let mut snapshot = output.snapshot;
            snapshot.conversation_id = Some(conversation_id.to_owned());
            snapshot.assistant_membership_id = Some(assistant_membership_id.to_owned());
            snapshot.route_receipt = Some(route_receipt);
            snapshot.slot_candidate_counts = slot_candidate_counts;
            let now = now_ms();
            transaction.execute(
                "INSERT INTO strategy_runs(
                   run_id, revision_digest, semantics_digest, idempotency_key,
                   request_digest, snapshot_json, conversation_id, terminal,
                   created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)",
                params![
                    run_id,
                    revision_digest,
                    semantics_digest,
                    idempotency_key,
                    request_digest,
                    serde_json::to_string(&snapshot)?,
                    conversation_id,
                    i64::from(run_is_terminal(snapshot.status)),
                    now,
                ],
            )?;
            persist_event_and_commands(
                &transaction,
                &snapshot,
                &event,
                &output.emitted_commands,
                now,
            )?;
            transaction.commit()?;
            Ok((snapshot, true))
        })
    }

    pub(crate) fn run_id_by_idempotency_key(
        &self,
        idempotency_key: &str,
    ) -> Result<Option<String>> {
        validate_opaque_id(idempotency_key, "strategy_idempotency_key_invalid")?;
        self.with_connection(|connection| {
            connection
                .query_row(
                    "SELECT run_id FROM strategy_runs WHERE idempotency_key=?1",
                    params![idempotency_key],
                    |row| row.get(0),
                )
                .optional()
                .map_err(Into::into)
        })
    }

    pub fn run(&self, run_id: &str) -> Result<RunSnapshot> {
        self.with_connection(|connection| load_run(connection, run_id))
    }

    pub fn apply_event(&self, run_id: &str, event: ReducerEvent) -> Result<RunSnapshot> {
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let previous = load_run(&transaction, run_id)?;
            let workflow = workflow_for_revision(&transaction, &previous.definition_digest)?;
            let compiled = compile_persisted_workflow(workflow)?;
            let output = reduce(&compiled, &previous, event.clone())?;
            if output.applied {
                let now = now_ms();
                persist_event_and_commands(
                    &transaction,
                    &output.snapshot,
                    &event,
                    &output.emitted_commands,
                    now,
                )?;
                transaction.execute(
                    "UPDATE strategy_runs SET snapshot_json=?2, conversation_id=?3,
                     terminal=?4, updated_at=?5 WHERE run_id=?1",
                    params![
                        run_id,
                        serde_json::to_string(&output.snapshot)?,
                        output.snapshot.conversation_id,
                        i64::from(run_is_terminal(output.snapshot.status)),
                        now
                    ],
                )?;
            }
            transaction.commit()?;
            Ok(output.snapshot)
        })
    }

    pub(crate) fn claim_next_command(
        &self,
        run_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<Option<RunCommand>> {
        validate_opaque_id(claimant, "strategy_claimant_invalid")?;
        let now = now_ms();
        ensure!(lease_until_unix_ms > now, "strategy_lease_invalid");
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let active: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM strategy_commands
                 WHERE status IN ('claimed', 'running') AND lease_until>?1",
                params![now],
                |row| row.get(0),
            )?;
            if active >= super::MAX_ACTIVE_EFFECTS as i64 {
                transaction.commit()?;
                return Ok(None);
            }
            let previous = load_run(&transaction, run_id)?;
            if !matches!(
                previous.status,
                StrategyRunStatus::Running
                    | StrategyRunStatus::Waiting
                    | StrategyRunStatus::Retryable
            ) {
                transaction.commit()?;
                return Ok(None);
            }
            let workflow = workflow_for_revision(&transaction, &previous.definition_digest)?;
            let compiled = compile_persisted_workflow(workflow)?;
            let run_active: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM strategy_commands
                 WHERE run_id=?1 AND status IN ('claimed', 'running') AND lease_until>?2",
                params![run_id, now],
                |row| row.get(0),
            )?;
            if run_active >= compiled.definition.limits.max_parallelism as i64 {
                transaction.commit()?;
                return Ok(None);
            }
            let value: Option<String> = transaction
                .query_row(
                    "SELECT command_json FROM strategy_commands
                     WHERE run_id=?1 AND status='pending' AND kind!='authorization'
                     ORDER BY command_id ASC LIMIT 1",
                    params![run_id],
                    |row| row.get(0),
                )
                .optional()?;
            let Some(value) = value else {
                transaction.commit()?;
                return Ok(None);
            };
            let command: RunCommand = serde_json::from_str(&value)?;
            let event = ReducerEvent::CommandClaimed {
                command_id: command.id.clone(),
                attempt_token: command.attempt_token.clone(),
            };
            let output = reduce(&compiled, &previous, event.clone())?;
            ensure!(output.applied, "strategy_command_not_claimable");
            persist_event_and_commands(
                &transaction,
                &output.snapshot,
                &event,
                &output.emitted_commands,
                now,
            )?;
            transaction.execute(
                "UPDATE strategy_runs SET snapshot_json=?2, conversation_id=?3,
                 terminal=?4, updated_at=?5 WHERE run_id=?1",
                params![
                    run_id,
                    serde_json::to_string(&output.snapshot)?,
                    output.snapshot.conversation_id,
                    i64::from(run_is_terminal(output.snapshot.status)),
                    now
                ],
            )?;
            transaction.execute(
                "UPDATE strategy_commands SET status='claimed', lease_owner=?2,
                 lease_until=?3, command_json=?4, updated_at=?5 WHERE command_id=?1",
                params![
                    command.id,
                    claimant,
                    lease_until_unix_ms,
                    serde_json::to_string(&output.snapshot.commands[&command.id])?,
                    now,
                ],
            )?;
            let claimed = output.snapshot.commands.get(&command.id).cloned();
            transaction.commit()?;
            Ok(claimed)
        })
    }

    pub(crate) fn renew_command_lease(
        &self,
        command_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<()> {
        validate_opaque_id(claimant, "strategy_claimant_invalid")?;
        ensure!(lease_until_unix_ms > now_ms(), "strategy_lease_invalid");
        self.with_connection(|connection| {
            let changed = connection.execute(
                "UPDATE strategy_commands SET lease_until=?3, updated_at=?4
                 WHERE command_id=?1 AND lease_owner=?2
                   AND status IN ('claimed', 'running')",
                params![command_id, claimant, lease_until_unix_ms, now_ms()],
            )?;
            ensure!(changed == 1, "strategy_lease_lost");
            Ok(())
        })
    }

    /// Revalidate the exact command and authorization immediately before an
    /// effect permit is issued. The write lock serializes this admission with
    /// binding updates and authorization revocation; a later revoke does not
    /// retroactively invalidate the already-issued one-shot permit.
    pub(crate) fn authorize_effect(
        &self,
        run_id: &str,
        command_id: &str,
        attempt_token: &str,
        expected_authorization_digest: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<()> {
        validate_opaque_id(claimant, "strategy_claimant_invalid")?;
        let now = now_ms();
        ensure!(lease_until_unix_ms > now, "strategy_lease_invalid");
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let lease: Option<(String, String, Option<String>, Option<i64>)> = transaction
                .query_row(
                    "SELECT status, attempt_token, lease_owner, lease_until
                     FROM strategy_commands WHERE command_id=?1 AND run_id=?2",
                    params![command_id, run_id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )
                .optional()?;
            ensure!(
                lease.is_some_and(|(status, token, owner, lease_until)| {
                    status == "running"
                        && token == attempt_token
                        && owner.as_deref() == Some(claimant)
                        && lease_until.is_some_and(|value| value > now)
                }),
                "strategy_lease_lost"
            );
            let snapshot = load_run(&transaction, run_id)?;
            let command = snapshot
                .commands
                .get(command_id)
                .filter(|command| {
                    command.status == super::CommandStatus::Running
                        && command.attempt_token == attempt_token
                })
                .ok_or_else(|| anyhow!("strategy_callback_stale"))?;
            ensure!(command.id == command_id, "strategy_callback_stale");
            let definition = definition_by_revision(&transaction, &snapshot.definition_digest)?;
            ensure!(
                definition.summary.semantics_digest == snapshot.semantics_digest,
                "strategy_authorization_stale"
            );
            ensure!(
                bindings_complete(&definition),
                "strategy_binding_incomplete"
            );
            let authorization = current_authorization(&definition)?;
            ensure!(
                authorization.binding_digest == binding_digest(&definition.bindings)?
                    && authorization.authorization_digest == expected_authorization_digest,
                "strategy_authorization_stale"
            );
            let renewed = transaction.execute(
                "UPDATE strategy_commands SET lease_until=?4, updated_at=?5
                 WHERE command_id=?1 AND run_id=?2 AND lease_owner=?3
                   AND status='running' AND lease_until>?5",
                params![command_id, run_id, claimant, lease_until_unix_ms, now],
            )?;
            ensure!(renewed == 1, "strategy_lease_lost");
            transaction.commit()?;
            Ok(())
        })
    }

    /// Atomically fence and recover one expired command.
    ///
    /// Lease renewal and this recovery both require the same SQLite write
    /// lock. The winner observes and commits one state transition; the loser
    /// cannot act on a stale pre-lock observation. Claimed-before-start work
    /// is retried in the same transaction, while expired running work is
    /// retained as in-doubt and is never blindly retried.
    pub(crate) fn recover_next_expired_command(&self, run_id: &str) -> Result<bool> {
        let Some(command_id) = self.next_expired_leased_command_id(run_id)? else {
            return Ok(false);
        };
        self.recover_leased_command(run_id, &command_id, LeaseRecovery::Standard)?;
        Ok(true)
    }

    /// Drop still-valid leases left by a previous host process and retry the
    /// commands. Expired-running recovery stays InDoubt; only this path treats
    /// a running effect as Transient `host_runtime_lost`.
    pub(crate) fn reclaim_abandoned_host_commands(&self, run_id: &str) -> Result<()> {
        let command_ids = self.release_live_host_leases(run_id)?;
        for command_id in command_ids {
            self.recover_leased_command(run_id, &command_id, LeaseRecovery::AbandonedHost)?;
        }
        Ok(())
    }

    fn next_expired_leased_command_id(&self, run_id: &str) -> Result<Option<String>> {
        self.with_connection(|connection| {
            connection
                .query_row(
                    "SELECT command_id FROM strategy_commands
                     WHERE run_id=?1 AND status IN ('claimed', 'running')
                       AND lease_until IS NOT NULL AND lease_until<=?2
                     ORDER BY command_id ASC LIMIT 1",
                    params![run_id, now_ms()],
                    |row| row.get(0),
                )
                .optional()
                .map_err(Into::into)
        })
    }

    fn release_live_host_leases(&self, run_id: &str) -> Result<Vec<String>> {
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let command_ids = {
                let mut statement = transaction.prepare(
                    "SELECT command_id FROM strategy_commands
                     WHERE run_id=?1 AND status IN ('claimed', 'running')
                       AND lease_until IS NOT NULL AND lease_until>?2
                     ORDER BY command_id ASC",
                )?;
                let command_ids = statement
                    .query_map(params![run_id, now_ms()], |row| row.get(0))?
                    .collect::<rusqlite::Result<Vec<String>>>()?;
                command_ids
            };
            for command_id in &command_ids {
                transaction.execute(
                    "UPDATE strategy_commands SET lease_until=0 WHERE command_id=?1",
                    params![command_id],
                )?;
            }
            transaction.commit()?;
            Ok(command_ids)
        })
    }

    fn recover_leased_command(
        &self,
        run_id: &str,
        command_id: &str,
        recovery: LeaseRecovery,
    ) -> Result<()> {
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let value: Option<(String, String)> = transaction
                .query_row(
                    "SELECT command_json, status FROM strategy_commands
                     WHERE run_id=?1 AND command_id=?2 AND status IN ('claimed', 'running')",
                    params![run_id, command_id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let Some((command_json, persisted_status)) = value else {
                transaction.commit()?;
                return Ok(());
            };
            let command: RunCommand = serde_json::from_str(&command_json)?;
            let expected_status = enum_wire(command.status)?;
            ensure!(
                expected_status == persisted_status
                    && matches!(
                        command.status,
                        super::CommandStatus::Claimed | super::CommandStatus::Running
                    ),
                "strategy_recovery_state_conflict"
            );
            let previous = load_run(&transaction, run_id)?;
            ensure!(
                previous.commands.get(&command.id).is_some_and(|current| {
                    current.status == command.status
                        && current.attempt_token == command.attempt_token
                }),
                "strategy_recovery_state_conflict"
            );
            let workflow = workflow_for_revision(&transaction, &previous.definition_digest)?;
            let compiled = compile_persisted_workflow(workflow)?;
            let (class, code) = match (command.status, recovery) {
                (super::CommandStatus::Claimed, _) => {
                    (super::FailureClass::Transient, "lease_expired_before_start")
                }
                (super::CommandStatus::Running, LeaseRecovery::AbandonedHost) => {
                    (super::FailureClass::Transient, "host_runtime_lost")
                }
                _ => (super::FailureClass::InDoubt, "effect_outcome_unknown"),
            };
            let failure_event = ReducerEvent::CommandFailed {
                command_id: command.id.clone(),
                attempt_token: command.attempt_token.clone(),
                class,
                code: code.to_owned(),
            };
            let failure = reduce(&compiled, &previous, failure_event.clone())?;
            let now = now_ms();
            persist_event_and_commands(
                &transaction,
                &failure.snapshot,
                &failure_event,
                &failure.emitted_commands,
                now,
            )?;
            let final_snapshot = if failure
                .snapshot
                .commands
                .get(&command.id)
                .is_some_and(|current| current.status == super::CommandStatus::Retryable)
            {
                let retry_event = ReducerEvent::RetryRequested {
                    command_id: command.id.clone(),
                };
                let retry = reduce(&compiled, &failure.snapshot, retry_event.clone())?;
                persist_event_and_commands(
                    &transaction,
                    &retry.snapshot,
                    &retry_event,
                    &retry.emitted_commands,
                    now,
                )?;
                retry.snapshot
            } else {
                failure.snapshot
            };
            transaction.execute(
                "UPDATE strategy_runs SET snapshot_json=?2, conversation_id=?3,
                 terminal=?4, updated_at=?5 WHERE run_id=?1",
                params![
                    run_id,
                    serde_json::to_string(&final_snapshot)?,
                    final_snapshot.conversation_id,
                    i64::from(run_is_terminal(final_snapshot.status)),
                    now
                ],
            )?;
            transaction.execute(
                "UPDATE strategy_commands SET lease_owner=NULL, lease_until=NULL
                 WHERE command_id=?1",
                params![&command.id],
            )?;
            transaction.commit()?;
            Ok(())
        })
    }

    pub fn projection_for_definition(&self, revision_digest: &str) -> Result<StrategyProjection> {
        let definition = self.definition_by_revision(revision_digest)?;
        let complete = bindings_complete(&definition);
        let mut allowed = BTreeSet::from([
            "strategy.definition.inspect".into(),
            "strategy.binding.update".into(),
            "strategy.binding.replace".into(),
            "strategy.authorization.preview".into(),
        ]);
        let status = if complete {
            if definition
                .authorization
                .as_ref()
                .is_some_and(|value| value.active)
            {
                allowed.extend([
                    "strategy.authorization.revoke".into(),
                    "strategy.run.start".into(),
                ]);
                StrategyRunStatus::Pending
            } else {
                allowed.insert("strategy.authorization.grant".into());
                StrategyRunStatus::AuthorizationRequired
            }
        } else {
            StrategyRunStatus::Pending
        };
        Ok(StrategyProjection {
            schema: STRATEGY_SCHEMA_VERSION.into(),
            definition: definition.summary,
            run_id: None,
            status,
            current_states: BTreeSet::new(),
            neighbor_states: BTreeSet::new(),
            allowed_operations: allowed,
            bindings: definition.bindings,
            diagnostic: if complete {
                None
            } else {
                Some(StrategyDiagnostic {
                    code: "binding_incomplete".into(),
                    component: "strategy_binding".into(),
                    retryable: true,
                    recovery: "Bind every required actor and runtime slot.".into(),
                    arguments: BTreeMap::new(),
                })
            },
            history_count: 0,
            fallbacks: Vec::new(),
            pending_callbacks: Vec::new(),
            needs_human_input: false,
            entry_session_id: None,
        })
    }

    pub fn projection_for_run(&self, run_id: &str) -> Result<StrategyProjection> {
        let snapshot = self.run(run_id)?;
        let definition = self.definition_by_revision(&snapshot.definition_digest)?;
        let compiled = compile_persisted_workflow(definition.workflow.clone())?;
        let neighbors = snapshot
            .active_states
            .iter()
            .flat_map(|state| {
                compiled
                    .outgoing(state)
                    .map(|transition| transition.to.clone())
            })
            .collect();
        let mut allowed = BTreeSet::from(["strategy.run.inspect".into()]);
        match snapshot.status {
            StrategyRunStatus::AuthorizationRequired
            | StrategyRunStatus::RuntimeMissing
            | StrategyRunStatus::Waiting => {
                allowed.insert("strategy.run.resume".into());
                allowed.insert("strategy.run.cancel".into());
            }
            StrategyRunStatus::Running => {
                allowed.insert("strategy.run.resume".into());
                allowed.insert("strategy.run.cancel".into());
            }
            StrategyRunStatus::Retryable => {
                allowed.insert("strategy.run.retry".into());
                allowed.insert("strategy.run.cancel".into());
            }
            StrategyRunStatus::CancelRequested => {
                allowed.insert("strategy.run.inspect".into());
            }
            _ => {}
        }
        let history_count = self.with_connection(|connection| {
            connection
                .query_row(
                    "SELECT COUNT(*) FROM strategy_run_events WHERE run_id=?1",
                    params![run_id],
                    |row| row.get::<_, i64>(0).map(|value| value as u64),
                )
                .map_err(Into::into)
        })?;
        let pending_callbacks = snapshot.pending_callbacks.clone();
        Ok(StrategyProjection {
            schema: STRATEGY_SCHEMA_VERSION.into(),
            definition: definition.summary,
            run_id: Some(run_id.to_owned()),
            status: snapshot.status,
            current_states: snapshot.active_states,
            neighbor_states: neighbors,
            allowed_operations: allowed,
            bindings: definition.bindings,
            diagnostic: snapshot.diagnostic_code.map(|code| StrategyDiagnostic {
                component: "strategy_runtime".into(),
                retryable: matches!(
                    snapshot.status,
                    StrategyRunStatus::Retryable
                        | StrategyRunStatus::RuntimeMissing
                        | StrategyRunStatus::AuthorizationRequired
                ),
                recovery: recovery_for_status(snapshot.status).into(),
                code,
                arguments: BTreeMap::new(),
            }),
            history_count,
            fallbacks: snapshot.fallbacks,
            pending_callbacks: pending_callbacks.clone(),
            needs_human_input: !pending_callbacks.is_empty()
                || matches!(
                    snapshot.status,
                    StrategyRunStatus::AuthorizationRequired
                        | StrategyRunStatus::RuntimeMissing
                        | StrategyRunStatus::Waiting
                        | StrategyRunStatus::Retryable
                ),
            entry_session_id: definition
                .workflow
                .actor_slots
                .iter()
                .find(|slot| {
                    slot.kind == crate::domain::adaptive_flywheel::BindingKind::Actor && slot.entry
                })
                .and_then(|slot| {
                    let prefix = format!("{}\0", slot.id);
                    snapshot
                        .actor_sessions
                        .iter()
                        .filter(|(key, _)| key.starts_with(&prefix))
                        .filter_map(|(key, session)| {
                            snapshot
                                .merge_sources
                                .get(&format!("session\0{key}"))
                                .map(|source| (source, key, session))
                        })
                        .max_by(|left, right| left.0.cmp(right.0).then(left.1.cmp(right.1)))
                        .map(|(_, _, session)| session.clone())
                }),
        })
    }

    pub fn active_run_for_conversation(
        &self,
        revision_digest: &str,
        conversation_id: &str,
    ) -> Result<Option<RunSnapshot>> {
        validate_opaque_id(conversation_id, "strategy_conversation_id_invalid")?;
        self.with_connection(|connection| {
            connection
                .query_row(
                    "SELECT snapshot_json FROM strategy_runs
                     WHERE revision_digest=?1 AND conversation_id=?2 AND terminal=0
                     ORDER BY updated_at DESC LIMIT 1",
                    params![revision_digest, conversation_id],
                    |row| row.get::<_, String>(0),
                )
                .optional()?
                .map(|snapshot_json| serde_json::from_str(&snapshot_json).map_err(Into::into))
                .transpose()
        })
    }

    pub(crate) fn bind_conversation_if_absent(
        &self,
        run_id: &str,
        conversation_id: &str,
    ) -> Result<()> {
        validate_opaque_id(conversation_id, "strategy_conversation_id_invalid")?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let mut snapshot = load_run(&transaction, run_id)?;
            if snapshot
                .conversation_id
                .as_deref()
                .is_some_and(|value| !value.is_empty())
            {
                transaction.commit()?;
                return Ok(());
            }
            snapshot.conversation_id = Some(conversation_id.to_owned());
            transaction.execute(
                "UPDATE strategy_runs SET snapshot_json=?2, conversation_id=?3, updated_at=?4
                 WHERE run_id=?1",
                params![
                    run_id,
                    serde_json::to_string(&snapshot)?,
                    snapshot.conversation_id,
                    now_ms()
                ],
            )?;
            transaction.commit()?;
            Ok(())
        })
    }

    /// Remove the on-disk package trees of definitions the typed migration
    /// deleted. Only runs for digests the migration actually returned.
    fn remove_retired_revision_trees(&self, digests: &[String]) {
        for digest in digests {
            let Some(root) = &self.package_revisions_root else {
                return;
            };
            if digest.len() != 64
                || !digest
                    .chars()
                    .all(|character| character.is_ascii_hexdigit())
            {
                continue;
            }
            let path = root.join(digest);
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                continue;
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            remove_directory_tree(&path);
        }
    }
}

fn initialize_schema(connection: &mut Connection) -> Result<Vec<String>> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS strategy_meta(
           key TEXT PRIMARY KEY, value TEXT NOT NULL
         );
         INSERT INTO strategy_meta(key, value) VALUES ('version', '2')
           ON CONFLICT(key) DO NOTHING;
         CREATE TABLE IF NOT EXISTS strategy_definitions(
           definition_id TEXT NOT NULL,
           revision_digest TEXT PRIMARY KEY,
           semantics_digest TEXT NOT NULL,
           name TEXT NOT NULL,
           version TEXT NOT NULL,
           workflow_json TEXT NOT NULL,
           asset_count INTEGER NOT NULL,
           imported_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS strategy_definitions_id_idx
           ON strategy_definitions(definition_id, imported_at DESC);
         CREATE TABLE IF NOT EXISTS strategy_bindings(
           revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
           slot_id TEXT NOT NULL,
           ordinal INTEGER NOT NULL DEFAULT 0,
           value_id TEXT NOT NULL,
           model TEXT NOT NULL DEFAULT '',
           reasoning_effort TEXT NOT NULL DEFAULT '',
           revision INTEGER NOT NULL,
           PRIMARY KEY(revision_digest, slot_id, ordinal)
         );
         CREATE TABLE IF NOT EXISTS strategy_authorizations(
           revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
           revision INTEGER NOT NULL,
           semantics_digest TEXT NOT NULL,
           binding_digest TEXT NOT NULL,
           authorization_digest TEXT NOT NULL,
           active INTEGER NOT NULL,
           created_at INTEGER NOT NULL,
           PRIMARY KEY(revision_digest, revision)
         );
         CREATE UNIQUE INDEX IF NOT EXISTS strategy_authorization_active_idx
           ON strategy_authorizations(revision_digest) WHERE active=1;
         CREATE TABLE IF NOT EXISTS strategy_runs(
           run_id TEXT PRIMARY KEY,
           revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest),
           semantics_digest TEXT NOT NULL,
           idempotency_key TEXT NOT NULL UNIQUE,
           request_digest TEXT NOT NULL,
           snapshot_json TEXT NOT NULL,
           conversation_id TEXT,
           terminal INTEGER NOT NULL,
           created_at INTEGER NOT NULL,
           updated_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS strategy_runs_revision_idx
           ON strategy_runs(revision_digest, updated_at DESC);
         CREATE TABLE IF NOT EXISTS strategy_run_events(
           run_id TEXT NOT NULL REFERENCES strategy_runs(run_id) ON DELETE CASCADE,
           sequence INTEGER NOT NULL,
           event_type TEXT NOT NULL,
           event_json TEXT NOT NULL,
           created_at INTEGER NOT NULL,
           PRIMARY KEY(run_id, sequence)
         );
         CREATE TABLE IF NOT EXISTS strategy_commands(
           command_id TEXT PRIMARY KEY,
           run_id TEXT NOT NULL REFERENCES strategy_runs(run_id) ON DELETE CASCADE,
           state_id TEXT NOT NULL,
           kind TEXT NOT NULL,
           status TEXT NOT NULL,
           attempt INTEGER NOT NULL,
           attempt_token TEXT NOT NULL,
           command_json TEXT NOT NULL,
           lease_owner TEXT,
           lease_until INTEGER,
           updated_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS strategy_commands_ready_idx
           ON strategy_commands(status, command_id);
         CREATE INDEX IF NOT EXISTS strategy_commands_lease_idx
           ON strategy_commands(lease_until) WHERE status IN ('claimed', 'running');",
    )?;
    ensure_column(
        connection,
        "strategy_bindings",
        "model",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    ensure_column(
        connection,
        "strategy_bindings",
        "reasoning_effort",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    ensure_column(connection, "strategy_runs", "conversation_id", "TEXT")?;
    ensure_column(connection, "strategy_runs", "terminal", "INTEGER")?;
    let retired = migrate_retired_builtin_definition(connection)?;
    backfill_run_query_columns(connection)?;
    connection.execute_batch(
        "CREATE INDEX IF NOT EXISTS strategy_runs_active_conversation_idx
           ON strategy_runs(revision_digest, conversation_id, terminal, updated_at DESC);",
    )?;
    migrate_bindings_ordinal_primary_key(connection)?;
    connection.execute("UPDATE strategy_meta SET value='2' WHERE key='version'", [])?;
    Ok(retired)
}

/// Typed one-time migration for the retired built-in strategy: databases from
/// before the retirement still hold its definition rows (and runs), and the
/// removal lives here — at migration, with no runtime compatibility path.
/// Returns the deleted revision digests so the caller can drop the orphaned
/// package trees.
fn migrate_retired_builtin_definition(connection: &mut Connection) -> Result<Vec<String>> {
    const RETIRED_DEFINITION_ID: &str = "licoup-basic";
    const RETIRED_DEFINITION_NAME: &str = "LicoUp Basic Strategy";
    let mut statement = connection.prepare(
        "SELECT revision_digest FROM strategy_definitions
         WHERE definition_id=?1 OR name=?2",
    )?;
    let digests = statement
        .query_map(
            params![RETIRED_DEFINITION_ID, RETIRED_DEFINITION_NAME],
            |row| row.get::<_, String>(0),
        )?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(statement);
    for digest in &digests {
        connection.execute(
            "DELETE FROM strategy_runs WHERE revision_digest=?1",
            params![digest],
        )?;
        connection.execute(
            "DELETE FROM strategy_definitions WHERE revision_digest=?1",
            params![digest],
        )?;
    }
    Ok(digests)
}

fn validate_current_schema(connection: &mut Connection) -> Result<()> {
    configure_connection(connection)?;
    let version: String = connection.query_row(
        "SELECT value FROM strategy_meta WHERE key='version'",
        [],
        |row| row.get(0),
    )?;
    ensure!(version == "2", "strategy_schema_migration_required");
    Ok(())
}

fn backfill_run_query_columns(connection: &mut Connection) -> Result<()> {
    let mut statement = connection
        .prepare("SELECT run_id, snapshot_json FROM strategy_runs WHERE terminal IS NULL")?;
    let runs = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(statement);
    for (run_id, snapshot_json) in runs {
        let snapshot: RunSnapshot = serde_json::from_str(&snapshot_json)?;
        connection.execute(
            "UPDATE strategy_runs SET conversation_id=?2, terminal=?3 WHERE run_id=?1",
            params![
                run_id,
                snapshot.conversation_id,
                i64::from(run_is_terminal(snapshot.status))
            ],
        )?;
    }
    Ok(())
}

fn run_is_terminal(status: StrategyRunStatus) -> bool {
    matches!(
        status,
        StrategyRunStatus::Completed
            | StrategyRunStatus::Failed
            | StrategyRunStatus::Cancelled
            | StrategyRunStatus::Blocked
            | StrategyRunStatus::CancelInDoubt
    )
}

fn migrate_bindings_ordinal_primary_key(connection: &mut Connection) -> Result<()> {
    let mut statement = connection.prepare("PRAGMA table_info(strategy_bindings)")?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if columns.iter().any(|column| column == "ordinal") {
        return Ok(());
    }
    connection.execute_batch(
        "CREATE TABLE strategy_bindings_v2 (
           revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
           slot_id TEXT NOT NULL,
           ordinal INTEGER NOT NULL,
           value_id TEXT NOT NULL,
           model TEXT NOT NULL DEFAULT '',
           reasoning_effort TEXT NOT NULL DEFAULT '',
           revision INTEGER NOT NULL,
           PRIMARY KEY(revision_digest, slot_id, ordinal)
         );
         INSERT INTO strategy_bindings_v2(
           revision_digest, slot_id, ordinal, value_id, model, reasoning_effort, revision
         )
         SELECT revision_digest, slot_id, 0, value_id, model, reasoning_effort, revision
           FROM strategy_bindings;
         DROP TABLE strategy_bindings;
         ALTER TABLE strategy_bindings_v2 RENAME TO strategy_bindings;
         UPDATE strategy_authorizations SET active=0 WHERE active=1;
         UPDATE strategy_meta SET value='2' WHERE key='version';",
    )?;
    Ok(())
}

fn configure_connection(connection: &Connection) -> Result<()> {
    connection.execute_batch(
        "PRAGMA foreign_keys=ON;
         PRAGMA journal_mode=WAL;
         PRAGMA synchronous=FULL;
         PRAGMA busy_timeout=5000;",
    )?;
    Ok(())
}

fn definition_by_revision(connection: &Connection, revision: &str) -> Result<StrategyDefinition> {
    let base: Option<(String, String, String, String, String, String, i64, i64)> = connection
        .query_row(
            "SELECT definition_id, revision_digest, semantics_digest, name, version,
             workflow_json, asset_count, imported_at FROM strategy_definitions
             WHERE revision_digest=?1",
            params![revision],
            |row| {
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
            },
        )
        .optional()?;
    let Some((
        definition_id,
        revision_digest,
        semantics_digest,
        name,
        version,
        workflow_json,
        asset_count,
        imported_at,
    )) = base
    else {
        return Err(anyhow!("strategy_definition_not_found"));
    };
    let workflow: WorkflowDefinition = serde_json::from_str(&workflow_json)?;
    let bindings = load_bindings(connection, &revision_digest)?;
    let authorization = load_authorization(connection, &revision_digest)?;
    Ok(StrategyDefinition {
        summary: StrategyDefinitionSummary {
            definition_id,
            revision_digest,
            semantics_digest,
            name,
            version,
            imported_at_unix_ms: imported_at,
            authorized: authorization.as_ref().is_some_and(|value| value.active),
        },
        workflow,
        asset_count: asset_count as usize,
        bindings,
        authorization,
    })
}

fn summary_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StrategyDefinitionSummary> {
    Ok(StrategyDefinitionSummary {
        definition_id: row.get(0)?,
        revision_digest: row.get(1)?,
        semantics_digest: row.get(2)?,
        name: row.get(3)?,
        version: row.get(4)?,
        imported_at_unix_ms: row.get(5)?,
        authorized: row
            .get::<_, i64>(6)
            .map(|value| value != 0)
            .unwrap_or(false),
    })
}

fn load_bindings(connection: &Connection, revision: &str) -> Result<Vec<BindingValue>> {
    let mut statement = connection.prepare(
        "SELECT slot_id, ordinal, value_id, model, reasoning_effort, revision
         FROM strategy_bindings
         WHERE revision_digest=?1 ORDER BY slot_id ASC, ordinal ASC",
    )?;
    let rows = statement.query_map(params![revision], |row| {
        Ok(BindingValue {
            slot_id: row.get(0)?,
            ordinal: row.get::<_, i64>(1)? as u8,
            value_id: row.get(2)?,
            model: row.get(3)?,
            reasoning_effort: row.get(4)?,
            revision: row.get::<_, i64>(5)? as u64,
        })
    })?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(Into::into)
}

fn load_authorization(
    connection: &Connection,
    revision: &str,
) -> Result<Option<StrategyAuthorization>> {
    connection
        .query_row(
            "SELECT revision, semantics_digest, binding_digest, authorization_digest, active
             FROM strategy_authorizations WHERE revision_digest=?1
             ORDER BY revision DESC LIMIT 1",
            params![revision],
            |row| {
                Ok(StrategyAuthorization {
                    definition_digest: revision.to_owned(),
                    revision: row.get::<_, i64>(0)? as u64,
                    semantics_digest: row.get(1)?,
                    binding_digest: row.get(2)?,
                    authorization_digest: row.get(3)?,
                    active: row.get::<_, i64>(4)? != 0,
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn current_authorization(definition: &StrategyDefinition) -> Result<&StrategyAuthorization> {
    definition
        .authorization
        .as_ref()
        .filter(|authorization| {
            authorization.active
                && authorization.definition_digest == definition.summary.revision_digest
                && authorization.semantics_digest == definition.summary.semantics_digest
        })
        .ok_or_else(|| anyhow!("strategy_authorization_required"))
}

fn bindings_complete(definition: &StrategyDefinition) -> bool {
    let bound = definition
        .bindings
        .iter()
        .filter(|binding| binding.ordinal == 0)
        .map(|binding| binding.slot_id.as_str())
        .collect::<BTreeSet<_>>();
    definition
        .workflow
        .actor_slots
        .iter()
        .filter(|slot| slot.required)
        .all(|slot| bound.contains(slot.id.as_str()))
}

fn binding_digest(bindings: &[BindingValue]) -> Result<String> {
    let mut sorted = bindings.to_vec();
    sorted.sort_by(|left, right| {
        left.slot_id
            .cmp(&right.slot_id)
            .then(left.ordinal.cmp(&right.ordinal))
    });
    Ok(sha256_hex(&serde_json::to_vec(&sorted)?))
}

fn slot_candidate_counts(bindings: &[BindingValue]) -> BTreeMap<String, u8> {
    let mut counts = BTreeMap::new();
    for binding in bindings {
        let entry = counts.entry(binding.slot_id.clone()).or_insert(0);
        *entry = (*entry).max(binding.ordinal.saturating_add(1));
    }
    counts
}

fn authorization_digest(
    revision: &str,
    semantics: &str,
    bindings: &str,
    authorization_revision: u64,
) -> String {
    sha256_hex(
        format!(
            "licoup-strategy-authorization-v1\0{revision}\0{semantics}\0{bindings}\0{authorization_revision}"
        )
        .as_bytes(),
    )
}

fn workflow_for_revision(connection: &Connection, revision: &str) -> Result<WorkflowDefinition> {
    let value: String = connection
        .query_row(
            "SELECT workflow_json FROM strategy_definitions WHERE revision_digest=?1",
            params![revision],
            |row| row.get(0),
        )
        .optional()?
        .ok_or_else(|| anyhow!("strategy_definition_not_found"))?;
    serde_json::from_str(&value).map_err(Into::into)
}

fn load_run(connection: &Connection, run_id: &str) -> Result<RunSnapshot> {
    let value: Option<String> = connection
        .query_row(
            "SELECT snapshot_json FROM strategy_runs WHERE run_id=?1",
            params![run_id],
            |row| row.get(0),
        )
        .optional()?;
    serde_json::from_str(
        value
            .as_deref()
            .ok_or_else(|| anyhow!("strategy_run_not_found"))?,
    )
    .map_err(Into::into)
}

fn persist_event_and_commands(
    transaction: &Transaction<'_>,
    snapshot: &RunSnapshot,
    event: &ReducerEvent,
    emitted: &[RunCommand],
    now: i64,
) -> Result<()> {
    let event_json = serde_json::to_string(event)?;
    let event_type = event_json.split('"').nth(3).unwrap_or("event").to_owned();
    transaction.execute(
        "INSERT INTO strategy_run_events(run_id, sequence, event_type, event_json, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            snapshot.run_id,
            snapshot.sequence as i64,
            event_type,
            event_json,
            now
        ],
    )?;
    for command in emitted {
        transaction.execute(
            "INSERT INTO strategy_commands(
               command_id, run_id, state_id, kind, status, attempt,
               attempt_token, command_json, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                command.id,
                snapshot.run_id,
                command.state_id,
                enum_wire(command.kind)?,
                enum_wire(command.status)?,
                command.attempt as i64,
                command.attempt_token,
                serde_json::to_string(command)?,
                now,
            ],
        )?;
    }
    for command in snapshot.commands.values() {
        transaction.execute(
            "UPDATE strategy_commands SET status=?2, command_json=?3, updated_at=?4
             WHERE command_id=?1",
            params![
                command.id,
                enum_wire(command.status)?,
                serde_json::to_string(command)?,
                now,
            ],
        )?;
    }
    Ok(())
}

fn enum_wire(value: impl serde::Serialize) -> Result<String> {
    serde_json::to_value(value)?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("strategy_enum_invalid"))
}

fn validate_opaque_id(value: &str, code: &'static str) -> Result<()> {
    ensure!(
        value == value.trim()
            && !value.is_empty()
            && value.len() <= 160
            && !value.chars().any(char::is_control),
        code
    );
    Ok(())
}

fn validate_optional_text(value: &str, code: &'static str) -> Result<()> {
    ensure!(
        value == value.trim() && value.len() <= 160 && !value.chars().any(char::is_control),
        code
    );
    Ok(())
}

fn ensure_column(
    connection: &Connection,
    table: &str,
    column: &str,
    declaration: &str,
) -> Result<()> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let existing = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !existing.iter().any(|value| value == column) {
        connection.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {declaration}"
        ))?;
    }
    Ok(())
}

fn recovery_for_status(status: StrategyRunStatus) -> &'static str {
    match status {
        StrategyRunStatus::AuthorizationRequired => "Review and authorize the current semantics.",
        StrategyRunStatus::RuntimeMissing => "Bind an available verified local runtime.",
        StrategyRunStatus::Retryable => "Retry the failed command.",
        StrategyRunStatus::CancelInDoubt => "Inspect the external effect before continuing.",
        _ => "Inspect the run history.",
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn remove_directory_tree(path: &Path) {
    let mut stack = vec![path.to_path_buf()];
    while let Some(current) = stack.pop() {
        if let Ok(metadata) = fs::symlink_metadata(&current) {
            make_path_writable(&current, metadata.permissions());
            if metadata.is_dir()
                && let Ok(entries) = fs::read_dir(&current)
            {
                stack.extend(entries.flatten().map(|entry| entry.path()));
            }
        }
    }
    let _ = fs::remove_dir_all(path);
}

fn make_path_writable(path: &Path, mut permissions: fs::Permissions) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        permissions.set_mode(permissions.mode() | 0o200);
    }
    #[cfg(not(unix))]
    permissions.set_readonly(false);
    let _ = fs::set_permissions(path, permissions);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::adaptive_flywheel::{
        ActorSlot, BindingCandidate, GraphState, GraphStateKind, RetryPolicy, Transition,
        TransitionEvent, TransitionMode, WorkflowLimits, WorkflowMetadata,
    };
    use serde_json::json;

    fn workflow() -> WorkflowDefinition {
        WorkflowDefinition {
            schema: super::super::WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "test".into(),
                name: "Test".into(),
                version: "1".into(),
                description: String::new(),
            },
            limits: WorkflowLimits::default(),
            actor_slots: vec![ActorSlot::required_actor("worker", "Worker")],
            runtimes: vec![],
            worksets: vec![],
            initial: "work".into(),
            states: vec![
                GraphState {
                    id: "work".into(),
                    kind: GraphStateKind::Actor,
                    label: "Work".into(),
                    instruction: String::new(),
                    binding: Some("worker".into()),
                    runtime: None,
                    entry: None,
                    workset: None,
                    retry: RetryPolicy {
                        max_attempts: 2,
                        transient_only: true,
                    },
                },
                GraphState {
                    id: "done".into(),
                    kind: GraphStateKind::Succeed,
                    label: "Done".into(),
                    instruction: String::new(),
                    binding: None,
                    runtime: None,
                    entry: None,
                    workset: None,
                    retry: RetryPolicy::default(),
                },
                GraphState {
                    id: "fail".into(),
                    kind: GraphStateKind::Fail,
                    label: "Fail".into(),
                    instruction: String::new(),
                    binding: None,
                    runtime: None,
                    entry: None,
                    workset: None,
                    retry: RetryPolicy::default(),
                },
            ],
            transitions: vec![
                Transition {
                    id: "done".into(),
                    from: "work".into(),
                    to: "done".into(),
                    event: TransitionEvent::Success,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "failed".into(),
                    from: "work".into(),
                    to: "fail".into(),
                    event: TransitionEvent::Failure,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
            ],
        }
    }

    #[test]
    fn binding_ordinal_migration_invalidates_existing_authorizations() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO strategy_meta(key, value) VALUES ('version', '1');
                 CREATE TABLE strategy_definitions(
                   definition_id TEXT NOT NULL,
                   revision_digest TEXT PRIMARY KEY,
                   semantics_digest TEXT NOT NULL,
                   name TEXT NOT NULL,
                   version TEXT NOT NULL,
                   workflow_json TEXT NOT NULL,
                   asset_count INTEGER NOT NULL,
                   imported_at INTEGER NOT NULL
                 );
                 CREATE TABLE strategy_bindings(
                   revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
                   slot_id TEXT NOT NULL,
                   value_id TEXT NOT NULL,
                   model TEXT NOT NULL DEFAULT '',
                   reasoning_effort TEXT NOT NULL DEFAULT '',
                   revision INTEGER NOT NULL,
                   PRIMARY KEY(revision_digest, slot_id)
                 );
                 CREATE TABLE strategy_authorizations(
                   revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
                   revision INTEGER NOT NULL,
                   semantics_digest TEXT NOT NULL,
                   binding_digest TEXT NOT NULL,
                   authorization_digest TEXT NOT NULL,
                   active INTEGER NOT NULL,
                   created_at INTEGER NOT NULL,
                   PRIMARY KEY(revision_digest, revision)
                 );
                 INSERT INTO strategy_definitions VALUES (
                   'strategy', 'revision', 'semantics', 'Strategy', '1', '{}', 0, 1
                 );
                 INSERT INTO strategy_bindings VALUES (
                   'revision', 'worker', 'agent:test', '', '', 1
                 );
                 INSERT INTO strategy_authorizations VALUES (
                   'revision', 1, 'semantics', 'old-bindings', 'authorization', 1, 1
                 );",
            )
            .unwrap();

        let retired = initialize_schema(&mut connection).unwrap();
        assert!(retired.is_empty());

        let (ordinal, active, version): (i64, i64, String) = connection
            .query_row(
                "SELECT b.ordinal, a.active, m.value
                   FROM strategy_bindings b
                   JOIN strategy_authorizations a USING (revision_digest)
                   JOIN strategy_meta m ON m.key='version'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(ordinal, 0);
        assert_eq!(active, 0);
        assert_eq!(version, "2");
    }

    #[test]
    fn ordinary_open_rejects_a_legacy_strategy_schema() {
        let root = std::env::temp_dir().join(format!("lico-strategy-legacy-{}", Uuid::new_v4()));
        let database = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
        fs::create_dir_all(database.parent().unwrap()).unwrap();
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO strategy_meta(key, value) VALUES ('version', '1');",
            )
            .unwrap();
        drop(connection);
        assert!(StrategyStore::open(&root).is_err());
        StrategyStore::open_for_migration(&root).unwrap();
        StrategyStore::open(&root).unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn event_snapshot_and_outbox_commit_together() {
        let store = StrategyStore::open_in_memory().unwrap();
        store
            .register_definition(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                &workflow(),
                1,
                1,
            )
            .unwrap();
        let binding = store
            .update_binding(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "worker",
                "agent:test",
                "gpt-5",
                "high",
                None,
            )
            .unwrap();
        assert_eq!(binding.model, "gpt-5");
        assert_eq!(binding.reasoning_effort, "high");
        let persisted = store
            .definition_by_revision(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            )
            .unwrap();
        assert_eq!(persisted.bindings[0].ordinal, 0);
        assert_eq!(persisted.bindings[0].model, "gpt-5");
        assert_eq!(persisted.bindings[0].reasoning_effort, "high");
        let chain = store
            .replace_slot_bindings(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "worker",
                &[
                    BindingCandidate {
                        value_id: "agent:primary".into(),
                        model: "model-a".into(),
                        reasoning_effort: "high".into(),
                    },
                    BindingCandidate {
                        value_id: "agent:fallback".into(),
                        model: "model-b".into(),
                        reasoning_effort: String::new(),
                    },
                ],
                Some(binding.revision),
            )
            .unwrap();
        assert_eq!(chain.len(), 2);
        assert_eq!(chain[0].ordinal, 0);
        assert_eq!(chain[1].ordinal, 1);
        assert_eq!(chain[1].value_id, "agent:fallback");
        let preview = store
            .authorization_preview(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            )
            .unwrap();
        store
            .grant_authorization(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                &preview.authorization_digest,
            )
            .unwrap();
        let run = store
            .start_run(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                json!({}),
                "idempotency-test",
                Some("conversation:test"),
                None,
            )
            .unwrap();
        assert_eq!(run.commands.len(), 1);
        assert_eq!(
            store
                .active_run_for_conversation(
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "conversation:test",
                )
                .unwrap()
                .map(|snapshot| snapshot.run_id),
            Some(run.run_id.clone())
        );
        let indexed: (String, i64) = store
            .with_connection(|connection| {
                connection
                    .query_row(
                        "SELECT conversation_id, terminal FROM strategy_runs WHERE run_id=?1",
                        params![run.run_id],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .map_err(Into::into)
            })
            .unwrap();
        assert_eq!(indexed, ("conversation:test".to_owned(), 0));
        let replay = store
            .start_run(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                json!({}),
                "idempotency-test",
                Some("conversation:test"),
                None,
            )
            .unwrap();
        assert_eq!(run, replay);
    }

    #[test]
    fn effect_authorization_revalidates_digest_owner_and_live_lease() {
        let store = StrategyStore::open_in_memory().unwrap();
        let revision = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
        store
            .register_definition(revision, revision, &workflow(), 1, 1)
            .unwrap();
        store
            .update_binding(revision, "worker", "agent:test", "", "", None)
            .unwrap();
        let preview = store.authorization_preview(revision).unwrap();
        let authorization = store
            .grant_authorization(revision, &preview.authorization_digest)
            .unwrap();
        let run = store
            .start_run(revision, json!({}), "authorization-fence", None, None)
            .unwrap();
        let command = store
            .claim_next_command(&run.run_id, "claimant", now_ms() + 60_000)
            .unwrap()
            .unwrap();
        store
            .apply_event(
                &run.run_id,
                ReducerEvent::CommandStarted {
                    command_id: command.id.clone(),
                    attempt_token: command.attempt_token.clone(),
                },
            )
            .unwrap();
        store
            .authorize_effect(
                &run.run_id,
                &command.id,
                &command.attempt_token,
                &authorization.authorization_digest,
                "claimant",
                now_ms() + 60_000,
            )
            .unwrap();
        assert!(
            store
                .authorize_effect(
                    &run.run_id,
                    &command.id,
                    &command.attempt_token,
                    &authorization.authorization_digest,
                    "other-claimant",
                    now_ms() + 60_000,
                )
                .is_err()
        );
        store.revoke_authorization(revision).unwrap();
        assert!(
            store
                .authorize_effect(
                    &run.run_id,
                    &command.id,
                    &command.attempt_token,
                    &authorization.authorization_digest,
                    "claimant",
                    now_ms() + 60_000,
                )
                .is_err()
        );
        let next = store.authorization_preview(revision).unwrap();
        let next = store
            .grant_authorization(revision, &next.authorization_digest)
            .unwrap();
        assert!(
            store
                .authorize_effect(
                    &run.run_id,
                    &command.id,
                    &command.attempt_token,
                    &authorization.authorization_digest,
                    "claimant",
                    now_ms() + 60_000,
                )
                .is_err()
        );
        store
            .authorize_effect(
                &run.run_id,
                &command.id,
                &command.attempt_token,
                &next.authorization_digest,
                "claimant",
                now_ms() + 60_000,
            )
            .unwrap();
        let connection = Connection::open(store.db_path()).unwrap();
        connection
            .execute(
                "UPDATE strategy_commands SET lease_until=0 WHERE command_id=?1",
                params![&command.id],
            )
            .unwrap();
        assert!(
            store
                .authorize_effect(
                    &run.run_id,
                    &command.id,
                    &command.attempt_token,
                    &next.authorization_digest,
                    "claimant",
                    now_ms() + 60_000,
                )
                .is_err(),
            "an expired running lease must never issue an effect permit"
        );
    }

    #[test]
    fn expired_claim_recovery_is_atomic_and_retries_before_start() {
        let store = StrategyStore::open_in_memory().unwrap();
        let revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        store
            .register_definition(
                revision,
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                &workflow(),
                1,
                1,
            )
            .unwrap();
        store
            .update_binding(revision, "worker", "agent:test", "", "", None)
            .unwrap();
        let preview = store.authorization_preview(revision).unwrap();
        store
            .grant_authorization(revision, &preview.authorization_digest)
            .unwrap();
        let run = store
            .start_run(revision, json!({}), "recovery-test", None, None)
            .unwrap();
        let claimed = store
            .claim_next_command(&run.run_id, "claimant", now_ms() + 60_000)
            .unwrap()
            .unwrap();
        let connection = Connection::open(store.db_path()).unwrap();
        connection
            .execute(
                "UPDATE strategy_commands SET lease_until=0 WHERE command_id=?1",
                params![claimed.id],
            )
            .unwrap();

        assert!(store.recover_next_expired_command(&run.run_id).unwrap());
        assert!(!store.recover_next_expired_command(&run.run_id).unwrap());
        assert!(
            store
                .renew_command_lease(&claimed.id, "claimant", now_ms() + 60_000)
                .is_err()
        );
        let recovered = store.run(&run.run_id).unwrap();
        assert_eq!(
            recovered.commands[&claimed.id].status,
            super::super::CommandStatus::Cancelled
        );
        assert!(recovered.commands.values().any(|command| {
            command.attempt == 2 && command.status == super::super::CommandStatus::Pending
        }));
    }

    #[test]
    fn expired_running_effect_is_fenced_in_doubt_without_retry() {
        let store = StrategyStore::open_in_memory().unwrap();
        let revision = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        store
            .register_definition(
                revision,
                "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                &workflow(),
                1,
                1,
            )
            .unwrap();
        store
            .update_binding(revision, "worker", "agent:test", "", "", None)
            .unwrap();
        let preview = store.authorization_preview(revision).unwrap();
        store
            .grant_authorization(revision, &preview.authorization_digest)
            .unwrap();
        let run = store
            .start_run(revision, json!({}), "running-recovery-test", None, None)
            .unwrap();
        let claimed = store
            .claim_next_command(&run.run_id, "claimant", now_ms() + 60_000)
            .unwrap()
            .unwrap();
        store
            .apply_event(
                &run.run_id,
                ReducerEvent::CommandStarted {
                    command_id: claimed.id.clone(),
                    attempt_token: claimed.attempt_token.clone(),
                },
            )
            .unwrap();
        let connection = Connection::open(store.db_path()).unwrap();
        connection
            .execute(
                "UPDATE strategy_commands SET lease_until=0 WHERE command_id=?1",
                params![claimed.id],
            )
            .unwrap();

        assert!(store.recover_next_expired_command(&run.run_id).unwrap());
        let recovered = store.run(&run.run_id).unwrap();
        assert_eq!(recovered.status, StrategyRunStatus::CancelInDoubt);
        assert_eq!(
            recovered.commands[&claimed.id].status,
            super::super::CommandStatus::InDoubt
        );
        assert!(
            !recovered
                .commands
                .values()
                .any(|command| command.attempt == 2)
        );
    }

    #[test]
    fn abandoned_running_effect_is_retried_when_this_host_becomes_driver() {
        let store = StrategyStore::open_in_memory().unwrap();
        let revision = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
        store
            .register_definition(
                revision,
                "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                &workflow(),
                1,
                1,
            )
            .unwrap();
        store
            .update_binding(revision, "worker", "agent:test", "", "", None)
            .unwrap();
        let preview = store.authorization_preview(revision).unwrap();
        store
            .grant_authorization(revision, &preview.authorization_digest)
            .unwrap();
        let run = store
            .start_run(revision, json!({}), "abandoned-host-recovery", None, None)
            .unwrap();
        let claimed = store
            .claim_next_command(&run.run_id, "claimant", now_ms() + 60_000)
            .unwrap()
            .unwrap();
        store
            .apply_event(
                &run.run_id,
                ReducerEvent::CommandStarted {
                    command_id: claimed.id.clone(),
                    attempt_token: claimed.attempt_token.clone(),
                },
            )
            .unwrap();

        store.reclaim_abandoned_host_commands(&run.run_id).unwrap();
        let recovered = store.run(&run.run_id).unwrap();
        assert_eq!(
            recovered.commands[&claimed.id].status,
            super::super::CommandStatus::Cancelled
        );
        assert_eq!(
            recovered.commands[&claimed.id].failure_code.as_deref(),
            Some("host_runtime_lost")
        );
        assert!(
            recovered
                .commands
                .values()
                .any(|command| command.attempt == 2
                    && command.status == super::super::CommandStatus::Pending)
        );
        assert_eq!(recovered.status, StrategyRunStatus::Running);
    }

    #[test]
    fn bind_conversation_if_absent_fills_an_unbound_run() {
        let store = StrategyStore::open_in_memory().unwrap();
        let revision = "1111111111111111111111111111111111111111111111111111111111111111";
        store
            .register_definition(
                revision,
                "2222222222222222222222222222222222222222222222222222222222222222",
                &workflow(),
                1,
                1,
            )
            .unwrap();
        store
            .update_binding(revision, "worker", "agent:test", "", "", None)
            .unwrap();
        let preview = store.authorization_preview(revision).unwrap();
        store
            .grant_authorization(revision, &preview.authorization_digest)
            .unwrap();
        let run = store
            .start_run(revision, json!({}), "bind-conversation", None, None)
            .unwrap();
        assert!(run.conversation_id.is_none());
        store
            .bind_conversation_if_absent(&run.run_id, "conversation:group")
            .unwrap();
        store
            .bind_conversation_if_absent(&run.run_id, "conversation:other")
            .unwrap();
        let bound = store.run(&run.run_id).unwrap();
        assert_eq!(bound.conversation_id.as_deref(), Some("conversation:group"));
    }

    fn digest(fill: char) -> String {
        fill.to_string().repeat(64)
    }

    #[test]
    fn retired_builtin_definition_is_deleted_by_the_typed_migration() {
        let root =
            std::env::temp_dir().join(format!("lico-adaptive-flywheel-retire-{}", Uuid::new_v4()));
        let database = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
        fs::create_dir_all(database.parent().unwrap()).unwrap();
        let retired_id_digest = digest('a');
        let retired_name_digest = digest('b');
        let kept_digest = digest('c');
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO strategy_meta(key, value) VALUES ('version', '1');
                 CREATE TABLE strategy_definitions(
                   definition_id TEXT NOT NULL,
                   revision_digest TEXT PRIMARY KEY,
                   semantics_digest TEXT NOT NULL,
                   name TEXT NOT NULL,
                   version TEXT NOT NULL,
                   workflow_json TEXT NOT NULL,
                   asset_count INTEGER NOT NULL,
                   imported_at INTEGER NOT NULL
                 );
                 CREATE TABLE strategy_runs(
                   run_id TEXT PRIMARY KEY,
                   revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest),
                   semantics_digest TEXT NOT NULL,
                   idempotency_key TEXT NOT NULL UNIQUE,
                   request_digest TEXT NOT NULL,
                   snapshot_json TEXT NOT NULL,
                   created_at INTEGER NOT NULL,
                   updated_at INTEGER NOT NULL
                 );",
            )
            .unwrap();
        let workflow_json = serde_json::to_string(&workflow()).unwrap();
        for (definition_id, revision, name) in [
            (
                "licoup-basic",
                retired_id_digest.clone(),
                "LicoUp Basic Strategy",
            ),
            (
                "other-id",
                retired_name_digest.clone(),
                "LicoUp Basic Strategy",
            ),
            ("imported-graph", kept_digest.clone(), "Imported Graph"),
        ] {
            connection
                .execute(
                    "INSERT INTO strategy_definitions(
                       definition_id, revision_digest, semantics_digest, name, version,
                       workflow_json, asset_count, imported_at
                     ) VALUES (?1, ?2, ?3, ?4, '1', ?5, 1, 1)",
                    params![definition_id, revision, digest('d'), name, workflow_json],
                )
                .unwrap();
        }
        let snapshot_json = serde_json::to_string(&RunSnapshot::empty(
            "run-retired",
            &retired_id_digest,
            "semantics",
        ))
        .unwrap();
        connection
            .execute(
                "INSERT INTO strategy_runs(
                   run_id, revision_digest, semantics_digest, idempotency_key,
                   request_digest, snapshot_json, created_at, updated_at
                 ) VALUES ('run-retired', ?1, 'semantics', 'key-retired', 'request', ?2, 1, 1)",
                params![retired_id_digest, snapshot_json],
            )
            .unwrap();
        drop(connection);
        let revisions = root
            .join("client-state")
            .join("adaptive-flywheel")
            .join("strategy-packages")
            .join("revisions");
        let retired_tree = revisions.join(&retired_id_digest);
        fs::create_dir_all(retired_tree.join("content")).unwrap();
        fs::write(retired_tree.join("content").join("marker.txt"), "retired").unwrap();
        let kept_tree = revisions.join(&kept_digest);
        fs::create_dir_all(kept_tree.join("content")).unwrap();
        fs::write(kept_tree.join("content").join("marker.txt"), "kept").unwrap();

        assert!(
            StrategyStore::open(&root).is_err(),
            "a legacy schema must pass through the migration path first"
        );
        StrategyStore::open_for_migration(&root).unwrap();

        let store = StrategyStore::open(&root).unwrap();
        let listed = store.list_definitions().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].definition_id, "imported-graph");
        assert_eq!(listed[0].name, "Imported Graph");
        assert_eq!(listed[0].revision_digest, kept_digest);
        assert!(store.definition_by_revision(&retired_id_digest).is_err());
        assert!(store.definition_by_revision(&retired_name_digest).is_err());
        assert!(!retired_tree.exists());
        assert!(kept_tree.join("content").join("marker.txt").exists());
        remove_directory_tree(&root);
    }
}
