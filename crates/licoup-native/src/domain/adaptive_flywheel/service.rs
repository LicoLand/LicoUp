use anyhow::{Result, anyhow, ensure};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use crate::platform::runtime_adapters::RuntimeAdapterError;
use crate::platform::strategy_runtime::{
    RuntimeCatalog, StrategyEffectPermit, actor_fingerprint, admit_strategy_cwd, execute_actor,
    execute_script, predecessor_locator,
};

use super::assistant::sha256_hex;
use super::reducer::{effect_input_for, fallback_reason};
use super::{
    ASSISTANT_TEMPORARY_DEFINITION_PREFIX, AssistantPreflight, BindingValue, PreflightDiagnostic,
    PreflightFailure, WorkflowDiagnosticCode, WorkflowDiagnosticRecovery, WorkflowDiagnosticStage,
    preflight_assistant_graph,
};
use super::{
    BindingCandidate, BindingKind, CommandKind, CommandStatus, CompiledWorkflow, FailureClass,
    GraphState, GraphStateKind, ReducerEvent, RunCommand, RunSnapshot, StrategyPackageImporter,
    StrategyRunStatus, StrategyStore, TransitionEvent, WorkflowValidationFailure,
    compile_persisted_workflow, compile_workflow_value,
};

const MAX_PACKAGE_SOURCE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_DRIVE_EFFECTS_PER_CALL: usize = 512;
const EFFECT_LEASE_DURATION_MS: i64 = 5 * 60 * 1000;

/// The Conversation-dispatch seam for one Conversation-bound actor command.
/// `open` registers the turn and returns its handle, `run` executes one
/// opened turn to its terminal state, and `abandon` settles one opened turn
/// that will never run. Composition happens where the persistent host
/// runtime exists; the strategy service treats the port as opaque.
pub struct ActorTurnPort {
    pub open: Arc<dyn Fn(&Value) -> std::result::Result<String, RuntimeAdapterError> + Send + Sync>,
    pub run:
        Arc<dyn Fn(&str, &Value) -> std::result::Result<Value, RuntimeAdapterError> + Send + Sync>,
    pub abandon: Arc<dyn Fn(&str) + Send + Sync>,
}

fn driving_runs() -> &'static Mutex<BTreeSet<String>> {
    static RUNS: OnceLock<Mutex<BTreeSet<String>>> = OnceLock::new();
    RUNS.get_or_init(|| Mutex::new(BTreeSet::new()))
}

#[derive(Clone)]
pub struct StrategyService {
    store: StrategyStore,
    importer: StrategyPackageImporter,
    portable_root: PathBuf,
    actor_port: Option<Arc<ActorTurnPort>>,
    profile_authority: crate::domain::client_conversation::SharedSnapshotAuthority,
}

impl std::fmt::Debug for StrategyService {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("StrategyService")
            .field("portable_root", &self.portable_root)
            .finish_non_exhaustive()
    }
}

impl StrategyService {
    pub fn open(portable_root: &Path) -> Result<Self> {
        let service = Self {
            store: StrategyStore::open(portable_root)?,
            importer: StrategyPackageImporter::open(portable_root)?,
            portable_root: portable_root.to_path_buf(),
            actor_port: None,
            profile_authority: crate::domain::client_conversation::production_snapshot_authority(),
        };
        service.refresh_runtime_bindings()?;
        Ok(service)
    }

    pub fn from_parts(
        portable_root: PathBuf,
        store: StrategyStore,
        importer: StrategyPackageImporter,
    ) -> Self {
        Self {
            store,
            importer,
            portable_root,
            actor_port: None,
            profile_authority: crate::domain::client_conversation::production_snapshot_authority(),
        }
    }

    pub fn with_actor_turn_port(mut self, actor_port: ActorTurnPort) -> Self {
        self.actor_port = Some(Arc::new(actor_port));
        self
    }

    pub fn with_profile_snapshot_authority(
        mut self,
        authority: crate::domain::client_conversation::SharedSnapshotAuthority,
    ) -> Self {
        self.profile_authority = authority;
        self
    }

    pub fn store(&self) -> &StrategyStore {
        &self.store
    }

    /// Execute one bridge action. Errors are converted to bounded typed facts;
    /// raw paths, process output and adapter errors never cross this boundary.
    pub fn execute(&self, request: Value) -> Result<Value> {
        match self.execute_inner(request) {
            Ok(result) => Ok(json!({"ok": true, "result": result})),
            Err(error) => {
                let projected = error_projection(&error);
                Ok(json!({"ok": false, "error": projected}))
            }
        }
    }

    fn execute_inner(&self, request: Value) -> Result<Value> {
        let object = request
            .as_object()
            .ok_or_else(|| anyhow!("invalid_request"))?;
        let action = required_string(object, "action")?;
        ensure_allowed_fields(action, object)?;
        match action {
            "strategy.package.prepare-import" => {
                validate_selection_token(required_string(object, "selectionToken")?)?;
                let source = Path::new(required_string(object, "sourcePath")?);
                let metadata =
                    fs::symlink_metadata(source).map_err(|_| anyhow!("package_unavailable"))?;
                ensure!(
                    metadata.is_file()
                        && !metadata.file_type().is_symlink()
                        && metadata.len() <= MAX_PACKAGE_SOURCE_BYTES,
                    "package_unavailable"
                );
                let bytes = fs::read(source).map_err(|_| anyhow!("package_unavailable"))?;
                let prepared = self.importer.prepare_bytes(&bytes)?;
                if let Err(error) = self.validate_import_identity(&prepared) {
                    let _ = self.importer.discard_preparation(&prepared.preparation_id);
                    return Err(error);
                }
                Ok(serde_json::to_value(prepared)?)
            }
            "strategy.package.commit-import" => {
                let prepared = self
                    .importer
                    .prepared(required_string(object, "preparationId")?)?;
                self.validate_import_identity(&prepared)?;
                let committed = self.importer.commit(
                    required_string(object, "preparationId")?,
                    required_string(object, "expectedRevisionDigest")?,
                )?;
                let definition = self.store.register_definition(
                    &committed.prepared.revision_digest,
                    &committed.prepared.semantics_digest,
                    &committed.workflow,
                    committed.prepared.asset_count,
                    committed.prepared.prepared_at_unix_ms,
                )?;
                self.bind_detected_runtimes(&definition.summary.revision_digest)?;
                Ok(serde_json::to_value(self.store.definition_by_revision(
                    &definition.summary.revision_digest,
                )?)?)
            }
            "strategy.definition.list" => Ok(serde_json::to_value(self.store.list_definitions()?)?),
            "strategy.definition.inspect" => {
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                self.bind_detected_runtimes(revision)?;
                let definition = self.store.definition_by_revision(revision)?;
                Ok(json!({
                    "projection": self.store.projection_for_definition(revision)?,
                    "workflow": definition.workflow,
                }))
            }
            "strategy.runtime.discover" | "strategy.runtime.list" => Ok(serde_json::to_value(
                RuntimeCatalog::discover().descriptors(),
            )?),
            "strategy.binding.update" => {
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                let slot = required_string(object, "slotId")?;
                let value = required_string(object, "valueId")?;
                self.validate_binding(revision, slot, value)?;
                Ok(serde_json::to_value(self.store.update_binding(
                    revision,
                    slot,
                    value,
                    optional_string(object, "model")?,
                    optional_string(object, "reasoningEffort")?,
                    object.get("expectedRevision").and_then(Value::as_u64),
                )?)?)
            }
            "strategy.binding.replace" => {
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                let slot = required_string(object, "slotId")?;
                let candidates = parse_binding_candidates(object)?;
                for candidate in &candidates {
                    self.validate_binding(revision, slot, &candidate.value_id)?;
                }
                Ok(serde_json::to_value(self.store.replace_slot_bindings(
                    revision,
                    slot,
                    &candidates,
                    object.get("expectedRevision").and_then(Value::as_u64),
                )?)?)
            }
            "strategy.binding.remove" => {
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                let slot = required_string(object, "slotId")?;
                let definition = self.store.definition_by_revision(revision)?;
                ensure!(
                    definition
                        .workflow
                        .actor_slots
                        .iter()
                        .any(|value| value.id == slot),
                    "strategy_binding_slot_unknown"
                );
                self.store.remove_binding(
                    revision,
                    slot,
                    object.get("expectedRevision").and_then(Value::as_u64),
                )?;
                Ok(json!({"removed": true}))
            }
            "strategy.authorization.preview" => {
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                Ok(serde_json::to_value(
                    self.store.authorization_preview(revision)?,
                )?)
            }
            "strategy.authorization.grant" => {
                ensure!(
                    object.get("confirmed").and_then(Value::as_bool) == Some(true),
                    "permit_denied"
                );
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                Ok(serde_json::to_value(self.store.grant_authorization(
                    revision,
                    required_string(object, "authorizationDigest")?,
                )?)?)
            }
            "strategy.authorization.revoke" => {
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                self.store.revoke_authorization(revision)?;
                Ok(json!({"revoked": true}))
            }
            "strategy.run.start" => {
                self.require_actor_port()?;
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                let conversation_id = optional_string(object, "conversationId")?;
                let cwd = optional_cwd(object)?;
                let snapshot = self.store.start_run(
                    revision,
                    object.get("input").cloned().unwrap_or_else(|| json!({})),
                    required_string(object, "idempotencyKey")?,
                    if conversation_id.is_empty() {
                        None
                    } else {
                        Some(conversation_id)
                    },
                    cwd,
                )?;
                self.record_graph_usage(&snapshot, None)?;
                let entry_turn = self.start_drive(&snapshot)?;
                let mut value =
                    serde_json::to_value(self.store.projection_for_run(&snapshot.run_id)?)?;
                if let Some(entry_turn) = entry_turn {
                    value["entryTurn"] = entry_turn;
                }
                Ok(value)
            }
            "strategy.run.inspect" => {
                let run_id = required_string(object, "runId")?;
                self.admit_run_identity(run_id)?;
                Ok(serde_json::to_value(
                    self.store.projection_for_run(run_id)?,
                )?)
            }
            "strategy.run.active" => {
                let revision = required_string(object, "revisionDigest")?;
                self.admit_revision_identity(revision)?;
                let conversation_id = required_string(object, "conversationId")?;
                match self
                    .store
                    .active_run_for_conversation(revision, conversation_id)?
                {
                    Some(snapshot) => Ok(serde_json::to_value(
                        self.store.projection_for_run(&snapshot.run_id)?,
                    )?),
                    None => Ok(json!({"runId": null})),
                }
            }
            "strategy.run.resume" => {
                self.require_actor_port()?;
                let run_id = required_string(object, "runId")?;
                self.admit_run_identity(run_id)?;
                let conversation_id = optional_string(object, "conversationId")?;
                if !conversation_id.is_empty() {
                    self.store
                        .bind_conversation_if_absent(run_id, conversation_id)?;
                }
                let snapshot = self.store.run(run_id)?;
                match snapshot.status {
                    StrategyRunStatus::AuthorizationRequired => {
                        let definition = self
                            .store
                            .definition_by_revision(&snapshot.definition_digest)?;
                        let authorization = definition
                            .authorization
                            .filter(|authorization| authorization.active)
                            .ok_or_else(|| anyhow!("authorization_required"))?;
                        if snapshot.commands.values().any(|command| {
                            command.kind == CommandKind::Authorization
                                && command.status == CommandStatus::Pending
                        }) {
                            self.store.apply_event(
                                run_id,
                                ReducerEvent::AuthorizationGranted {
                                    semantics_digest: authorization.semantics_digest,
                                },
                            )?;
                        } else {
                            let command = snapshot
                                .commands
                                .values()
                                .find(|command| {
                                    command.status == CommandStatus::Retryable
                                        && command.failure_class == Some(FailureClass::Authority)
                                })
                                .ok_or_else(|| anyhow!("run_not_retryable"))?;
                            self.store.apply_event(
                                run_id,
                                ReducerEvent::RetryRequested {
                                    command_id: command.id.clone(),
                                },
                            )?;
                        }
                    }
                    StrategyRunStatus::RuntimeMissing | StrategyRunStatus::Retryable => {
                        let command = snapshot
                            .commands
                            .values()
                            .find(|command| command.status == CommandStatus::Retryable)
                            .ok_or_else(|| anyhow!("run_not_retryable"))?;
                        self.store.apply_event(
                            run_id,
                            ReducerEvent::RetryRequested {
                                command_id: command.id.clone(),
                            },
                        )?;
                    }
                    StrategyRunStatus::Waiting | StrategyRunStatus::Running => {}
                    _ => return Err(anyhow!("run_not_retryable")),
                }
                let snapshot = self.store.run(run_id)?;
                let entry_turn = self.start_drive(&snapshot)?;
                let mut value = serde_json::to_value(self.store.projection_for_run(run_id)?)?;
                if let Some(entry_turn) = entry_turn {
                    value["entryTurn"] = entry_turn;
                }
                Ok(value)
            }
            "strategy.run.cancel" => {
                let run_id = required_string(object, "runId")?;
                self.admit_run_identity(run_id)?;
                let cancelled = self
                    .store
                    .apply_event(run_id, ReducerEvent::CancelRequested)?;
                for command in cancelled
                    .commands
                    .values()
                    .filter(|command| command.status == CommandStatus::CancelRequested)
                {
                    self.store.apply_event(
                        run_id,
                        ReducerEvent::CancellationUnknown {
                            command_id: command.id.clone(),
                            attempt_token: command.attempt_token.clone(),
                        },
                    )?;
                }
                let snapshot = self.store.run(run_id)?;
                self.record_graph_usage(&snapshot, None)?;
                Ok(serde_json::to_value(
                    self.store.projection_for_run(run_id)?,
                )?)
            }
            "strategy.run.retry" => {
                self.require_actor_port()?;
                let run_id = required_string(object, "runId")?;
                self.admit_run_identity(run_id)?;
                let snapshot = self.store.run(run_id)?;
                let command = snapshot
                    .commands
                    .values()
                    .find(|command| command.status == CommandStatus::Retryable)
                    .ok_or_else(|| anyhow!("run_not_retryable"))?;
                self.store.apply_event(
                    run_id,
                    ReducerEvent::RetryRequested {
                        command_id: command.id.clone(),
                    },
                )?;
                let snapshot = self.store.run(run_id)?;
                let entry_turn = self.start_drive(&snapshot)?;
                let mut value = serde_json::to_value(self.store.projection_for_run(run_id)?)?;
                if let Some(entry_turn) = entry_turn {
                    value["entryTurn"] = entry_turn;
                }
                Ok(value)
            }
            "strategy.assistant.workflow.execute" => {
                self.require_actor_port()?;
                let conversation_id = required_string(object, "conversationId")?;
                let membership_id = required_string(object, "membershipId")?;
                let idempotency_key = required_string(object, "idempotencyKey")?;
                let workflow = object
                    .get("workflow")
                    .cloned()
                    .ok_or_else(|| anyhow!("invalid_request"))?;
                let bindings: Vec<BindingValue> = serde_json::from_value(
                    object.get("bindings").cloned().unwrap_or_else(|| json!([])),
                )?;
                let filters: crate::domain::client_conversation::CandidateFilters =
                    serde_json::from_value(
                        object.get("filters").cloned().unwrap_or_else(|| json!({})),
                    )?;
                if let Some(run_id) = self.store.run_id_by_idempotency_key(idempotency_key)? {
                    return self.replay_assistant_workflow(
                        &run_id,
                        conversation_id,
                        membership_id,
                        &workflow,
                        &bindings,
                        object.get("input").cloned().unwrap_or_else(|| json!({})),
                    );
                }
                let admitted = match self.preflight_assistant_workflow(
                    conversation_id,
                    membership_id,
                    &workflow,
                    &bindings,
                    &filters,
                ) {
                    Ok(admitted) => admitted,
                    Err(failure) => {
                        return Ok(json!({"accepted": false, "error": failure}));
                    }
                };
                match self.revalidate_assistant_admission(conversation_id, membership_id, &admitted)
                {
                    Ok(()) => {}
                    Err(failure) => {
                        return Ok(json!({"accepted": false, "error": failure}));
                    }
                }
                let canonical = serde_json::to_vec(&admitted.definition)?;
                let semantics_digest = sha256_hex(&canonical);
                let revision_digest = admitted.receipt.workflow_digest.clone();
                let input = object.get("input").cloned().unwrap_or_else(|| json!({}));
                let (snapshot, _fresh) = self.store.admit_assistant_run(
                    &revision_digest,
                    &semantics_digest,
                    &admitted.definition,
                    &admitted.bindings,
                    input,
                    idempotency_key,
                    conversation_id,
                    membership_id,
                    admitted.receipt.route_receipt.clone(),
                )?;
                self.record_graph_usage(&snapshot, None)?;
                self.start_drive(&snapshot)?;
                self.wait_for_assistant_terminal(&snapshot.run_id, Some(&admitted.receipt))
            }
            "strategy.assistant.workflow.inspect" => {
                let run_id = required_string(object, "runId")?;
                let snapshot = self.admit_assistant_run_identity(run_id)?;
                let mut value = self.assistant_run_projection(&snapshot)?;
                if let Some(terminal) = terminal_projection(&value) {
                    value["terminal"] = terminal;
                }
                Ok(value)
            }
            "strategy.assistant.workflow.cancel" => {
                let run_id = required_string(object, "runId")?;
                self.admit_assistant_run_identity(run_id)?;
                let cancelled = self
                    .store
                    .apply_event(run_id, ReducerEvent::CancelRequested)?;
                for command in cancelled
                    .commands
                    .values()
                    .filter(|command| command.status == CommandStatus::CancelRequested)
                {
                    self.store.apply_event(
                        run_id,
                        ReducerEvent::CancellationUnknown {
                            command_id: command.id.clone(),
                            attempt_token: command.attempt_token.clone(),
                        },
                    )?;
                }
                let snapshot = self.store.run(run_id)?;
                self.record_graph_usage(&snapshot, None)?;
                let mut value = self.assistant_run_projection(&snapshot)?;
                if let Some(terminal) = terminal_projection(&value) {
                    value["terminal"] = terminal;
                }
                Ok(value)
            }
            _ => Err(anyhow!("unsupported_action")),
        }
    }

    fn preflight_assistant_workflow(
        &self,
        conversation_id: &str,
        assistant_membership_id: &str,
        workflow: &Value,
        bindings: &[BindingValue],
        filters: &crate::domain::client_conversation::CandidateFilters,
    ) -> std::result::Result<AssistantPreflight, PreflightFailure> {
        let store =
            crate::domain::client_conversation::ConversationStore::open(&self.portable_root)
                .map_err(|_| assistant_state_failure("conversation_state_unavailable", None))?;
        let conversation = store
            .get(conversation_id)
            .map_err(|_| assistant_state_failure("conversation_not_found", None))?;
        if conversation.assistant_membership_id.as_deref() != Some(assistant_membership_id)
            || !conversation.memberships.iter().any(|membership| {
                membership.id == assistant_membership_id
                    && membership.status
                        == crate::domain::client_conversation::MembershipStatus::Active
                    && membership.principal.kind
                        == crate::domain::client_conversation::PrincipalKind::Agent
            })
        {
            return Err(assistant_state_failure(
                "graph_assistant_designation_rejected",
                Some(assistant_membership_id),
            ));
        }
        let profiles = store
            .membership_profiles(conversation_id)
            .map_err(|_| assistant_state_failure("conversation_state_unavailable", None))?;
        let pairs = profiles
            .into_iter()
            .map(|(membership, intent)| {
                let designated = membership.id == assistant_membership_id;
                (membership, intent, designated)
            })
            .collect::<Vec<_>>();
        let snapshots = crate::domain::client_conversation::project_profile_snapshots(
            conversation_id,
            &pairs,
            &self.profile_authority,
        );
        preflight_assistant_graph(
            conversation_id,
            assistant_membership_id,
            workflow,
            bindings,
            &snapshots,
            filters,
        )
    }

    /// Revalidate only store-owned identity immediately before durable
    /// admission. Derived owners were already read once into the request-scoped
    /// route snapshot and must not be queried a second time in the same request.
    fn revalidate_assistant_admission(
        &self,
        conversation_id: &str,
        assistant_membership_id: &str,
        admitted: &AssistantPreflight,
    ) -> std::result::Result<(), PreflightFailure> {
        let store =
            crate::domain::client_conversation::ConversationStore::open(&self.portable_root)
                .map_err(|_| assistant_state_failure("conversation_state_unavailable", None))?;
        let conversation = store
            .get(conversation_id)
            .map_err(|_| assistant_state_failure("conversation_not_found", None))?;
        if conversation.assistant_membership_id.as_deref() != Some(assistant_membership_id) {
            return Err(assistant_state_failure(
                "graph_route_stale",
                Some(assistant_membership_id),
            ));
        }
        let profiles = store
            .membership_profiles(conversation_id)
            .map_err(|_| assistant_state_failure("conversation_state_unavailable", None))?
            .into_iter()
            .map(|(membership, profile)| (membership.id.clone(), (membership, profile)))
            .collect::<BTreeMap<_, _>>();
        for (membership_id, expected_revision) in &admitted.profile_revisions {
            let Some((membership, profile)) = profiles.get(membership_id) else {
                return Err(assistant_state_failure(
                    "graph_route_stale",
                    Some(membership_id),
                ));
            };
            if membership.status != crate::domain::client_conversation::MembershipStatus::Active
                || membership.principal.kind
                    != crate::domain::client_conversation::PrincipalKind::Agent
                || profile.revision != *expected_revision
            {
                return Err(assistant_state_failure(
                    "graph_route_stale",
                    Some(membership_id),
                ));
            }
        }
        Ok(())
    }

    fn replay_assistant_workflow(
        &self,
        run_id: &str,
        conversation_id: &str,
        assistant_membership_id: &str,
        workflow: &Value,
        bindings: &[BindingValue],
        input: Value,
    ) -> Result<Value> {
        let snapshot = self.admit_assistant_run_identity(run_id)?;
        ensure!(
            snapshot.conversation_id.as_deref() == Some(conversation_id)
                && snapshot.assistant_membership_id.as_deref() == Some(assistant_membership_id)
                && snapshot.input == input,
            "strategy_idempotency_conflict"
        );
        let submitted = compile_workflow_value(workflow)?.definition;
        let stored = self
            .store
            .definition_by_revision(&snapshot.definition_digest)?;
        ensure!(
            submitted == stored.workflow,
            "strategy_idempotency_conflict"
        );
        let mut submitted_bindings = bindings
            .iter()
            .map(|binding| {
                (
                    binding.slot_id.as_str(),
                    binding.ordinal,
                    binding.value_id.as_str(),
                    binding.model.as_str(),
                    binding.reasoning_effort.as_str(),
                )
            })
            .collect::<Vec<_>>();
        submitted_bindings.sort();
        let mut stored_bindings = stored
            .bindings
            .iter()
            .map(|binding| {
                (
                    binding.slot_id.as_str(),
                    binding.ordinal,
                    binding.value_id.as_str(),
                    binding.model.as_str(),
                    binding.reasoning_effort.as_str(),
                )
            })
            .collect::<Vec<_>>();
        stored_bindings.sort();
        ensure!(
            submitted_bindings.len() == stored_bindings.len()
                && submitted_bindings
                    .iter()
                    .zip(&stored_bindings)
                    .all(|(submitted, stored)| {
                        submitted.0 == stored.0
                            && submitted.1 == stored.1
                            && submitted.2 == stored.2
                            && (submitted.3.is_empty() || submitted.3 == stored.3)
                            && submitted.4 == stored.4
                    }),
            "strategy_idempotency_conflict"
        );
        if !assistant_run_terminal(snapshot.status) {
            self.start_drive(&snapshot)?;
        }
        self.wait_for_assistant_terminal(run_id, None)
    }

    fn wait_for_assistant_terminal(
        &self,
        run_id: &str,
        receipt: Option<&super::PreflightReceipt>,
    ) -> Result<Value> {
        loop {
            let snapshot = self.admit_assistant_run_identity(run_id)?;
            if assistant_run_terminal(snapshot.status) {
                self.record_graph_usage(&snapshot, None)?;
                let mut value = self.assistant_run_projection(&snapshot)?;
                if let Some(receipt) = receipt {
                    value["preflight"] = json!({"accepted": true, "receipt": receipt});
                }
                if let Some(terminal) = terminal_projection(&value) {
                    value["terminal"] = terminal;
                }
                return Ok(value);
            }
            if !DriveReservation::is_active(run_id) {
                self.start_drive(&snapshot)?;
            }
            std::thread::park_timeout(std::time::Duration::from_millis(20));
        }
    }

    /// Strict public projection for Assistant-temporary runs. Generic
    /// strategy projections may carry an entry session locator, definition
    /// labels, or generic control operations; none belong in the Assistant
    /// facade. This allowlist retains only opaque Graph/Membership identities,
    /// stable states, safe bindings, numeric history, and the frozen route
    /// receipt.
    fn assistant_run_projection(&self, snapshot: &RunSnapshot) -> Result<Value> {
        let generic = serde_json::to_value(self.store.projection_for_run(&snapshot.run_id)?)?;
        let mut value = json!({
            "schema": "licoup.assistant-workflow.run.v1",
            "runId": snapshot.run_id,
            "status": generic.get("status").cloned().unwrap_or(Value::Null),
            "currentStates": generic.get("currentStates").cloned().unwrap_or_else(|| json!([])),
            "neighborStates": generic.get("neighborStates").cloned().unwrap_or_else(|| json!([])),
            "bindings": generic.get("bindings").cloned().unwrap_or_else(|| json!([])),
            "historyCount": generic.get("historyCount").cloned().unwrap_or_else(|| json!(0)),
            "conversationId": snapshot.conversation_id,
            "assistantMembershipId": snapshot.assistant_membership_id,
            "routeReceipt": snapshot.route_receipt,
        });
        if let Some(code) = generic.pointer("/diagnostic/code").and_then(Value::as_str) {
            value["diagnostic"] = json!({
                "code": code,
                "stage": "assistant-workflow/runtime",
                "retryable": false,
                "recoveryClass": "assistant-direct-or-new-graph",
            });
        }
        Ok(value)
    }

    fn validate_import_identity(&self, prepared: &super::PreparedPackage) -> Result<()> {
        super::store::validate_import_identity(&prepared.definition_id, &prepared.name)
    }

    fn refresh_runtime_bindings(&self) -> Result<()> {
        for definition in self.store.list_definitions()? {
            self.bind_detected_runtimes(&definition.revision_digest)?;
        }
        Ok(())
    }

    fn bind_detected_runtimes(&self, revision: &str) -> Result<()> {
        let definition = self.store.definition_by_revision(revision)?;
        let catalog = RuntimeCatalog::discover();
        for slot in definition
            .workflow
            .actor_slots
            .iter()
            .filter(|slot| slot.kind == BindingKind::Runtime)
        {
            let requirement = definition
                .workflow
                .runtimes
                .iter()
                .find(|runtime| runtime.id == slot.id)
                .ok_or_else(|| anyhow!("runtime_unavailable"))?;
            let current = definition
                .bindings
                .iter()
                .find(|binding| binding.slot_id == slot.id);
            if let Some(runtime_id) =
                catalog.compatible_id(requirement.kind, &requirement.version_requirement)
            {
                if current.is_none_or(|binding| binding.value_id != runtime_id) {
                    self.store.update_binding(
                        revision,
                        &slot.id,
                        &runtime_id,
                        "",
                        "",
                        current.map(|binding| binding.revision),
                    )?;
                }
            } else if let Some(binding) = current {
                self.store
                    .remove_binding(revision, &slot.id, Some(binding.revision))?;
            }
        }
        Ok(())
    }

    fn admit_revision_identity(&self, revision: &str) -> Result<()> {
        let definition = self.store.definition_by_revision(revision)?;
        ensure!(
            !definition
                .summary
                .definition_id
                .starts_with(ASSISTANT_TEMPORARY_DEFINITION_PREFIX),
            "strategy_definition_not_found"
        );
        Ok(())
    }

    fn admit_run_identity(&self, run_id: &str) -> Result<()> {
        let snapshot = self.store.run(run_id)?;
        self.admit_revision_identity(&snapshot.definition_digest)
    }

    fn admit_assistant_run_identity(&self, run_id: &str) -> Result<RunSnapshot> {
        let snapshot = self.store.run(run_id)?;
        let definition = self
            .store
            .definition_by_revision(&snapshot.definition_digest)?;
        ensure!(
            definition
                .summary
                .definition_id
                .starts_with(ASSISTANT_TEMPORARY_DEFINITION_PREFIX)
                && snapshot.assistant_membership_id.is_some()
                && snapshot.route_receipt.is_some(),
            "strategy_run_not_found"
        );
        Ok(snapshot)
    }

    /// Run actions drive Agent work on background threads, so the service is
    /// fail closed without the persistent host runtime: a one-shot process
    /// must never orphan a run or open an unattached turn.
    fn require_actor_port(&self) -> Result<&Arc<ActorTurnPort>> {
        self.actor_port.as_ref().ok_or_else(|| {
            anyhow!(crate::domain::client_conversation::PERSISTENT_TRANSPORT_REQUIRED)
        })
    }

    /// Register the entry Membership turn before the drive thread starts. The
    /// entry command, binding, Membership, and prompt resolve through the same
    /// builder the drive uses, and the returned guard hands the handle to the
    /// drive. An entry command that legitimately waits on authorization is not
    /// emitted yet, so its input is computed deterministically from the entry
    /// state; the run status already projects that gate.
    fn register_entry_turn(&self, snapshot: &RunSnapshot) -> Result<Option<EntryTurnRegistration>> {
        let Some(port) = self.actor_port.as_ref() else {
            return Ok(None);
        };
        let conversation_id = snapshot
            .conversation_id
            .as_deref()
            .filter(|value| !value.is_empty());
        let Some(conversation_id) = conversation_id else {
            return Ok(None);
        };
        let definition = self
            .store
            .definition_by_revision(&snapshot.definition_digest)?;
        let Some(slot) = definition
            .workflow
            .actor_slots
            .iter()
            .find(|slot| slot.kind == BindingKind::Actor && slot.entry)
        else {
            return Ok(None);
        };
        let entry_command = snapshot.commands.values().find(|command| {
            matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem)
                && command.binding_id.as_deref() == Some(slot.id.as_str())
                && command.state_visit == 1
                && command.binding_ordinal == 0
        });
        let (input, resume_session_id) = match entry_command {
            Some(command) => {
                if command.status != CommandStatus::Pending {
                    // The entry command already belongs to a drive.
                    return Ok(None);
                }
                (command.input.clone(), command.resume_session_id.clone())
            }
            None => {
                let workflow = compile_persisted_workflow(definition.workflow.clone())?;
                let Some(state) = entry_state_for_start(&workflow, &slot.id) else {
                    return Ok(None);
                };
                (
                    effect_input_for(&workflow, &state.id, snapshot.input.clone())?,
                    None,
                )
            }
        };
        let Some(binding) = definition
            .bindings
            .iter()
            .find(|binding| binding.slot_id == slot.id && binding.ordinal == 0)
        else {
            return Ok(None);
        };
        let target = group_actor_target(conversation_id, &binding.value_id, &self.portable_root)
            .map_err(|_| anyhow!("strategy_actor_dispatch_failed"))?;
        let params = group_actor_params(
            conversation_id,
            &target.membership_id,
            &target.agent_id,
            binding,
            &input,
            &snapshot.run_id,
            resume_session_id.as_deref(),
            snapshot.cwd.as_deref(),
        )
        .map_err(|_| anyhow!("strategy_actor_dispatch_failed"))?;
        let handle = (port.open)(&params).map_err(|_| anyhow!("strategy_actor_dispatch_failed"))?;
        let projection = json!({
            "turnHandle": handle,
            "conversationId": conversation_id,
            "membershipId": target.membership_id,
            "agent": target.agent_id,
        });
        Ok(Some(EntryTurnRegistration {
            slot_id: slot.id.clone(),
            handle,
            params,
            projection,
            port: Arc::clone(port),
            armed: true,
        }))
    }

    fn validate_binding(&self, revision: &str, slot_id: &str, value_id: &str) -> Result<()> {
        let definition = self.store.definition_by_revision(revision)?;
        let slot = definition
            .workflow
            .actor_slots
            .iter()
            .find(|slot| slot.id == slot_id)
            .ok_or_else(|| anyhow!("binding_incomplete"))?;
        match slot.kind {
            BindingKind::Runtime => {
                let requirement = definition
                    .workflow
                    .runtimes
                    .iter()
                    .find(|runtime| runtime.id == slot.id)
                    .ok_or_else(|| anyhow!("runtime_unavailable"))?;
                RuntimeCatalog::discover().resolve(
                    value_id,
                    requirement.kind,
                    &requirement.version_requirement,
                )?;
            }
            BindingKind::Actor => {
                actor_fingerprint(value_id, "", "")?;
                let capabilities = crate::platform::dispatch_lane_operation(
                    "capabilities",
                    &json!({"agent": value_id}),
                )
                .map_err(|_| anyhow!("runtime_unavailable"))?;
                ensure!(
                    capabilities.get("ok").and_then(Value::as_bool) == Some(true),
                    "runtime_unavailable"
                );
            }
            BindingKind::Workspace => {
                ensure!(value_id.starts_with("workspace-"), "binding_incomplete");
            }
        }
        Ok(())
    }

    /// Mirror one durable reducer snapshot into the numeric-only Graph usage
    /// ledger. The projection is intentionally rebuilt from typed run,
    /// binding and command fields; input/output bodies never cross this seam.
    fn record_graph_usage(
        &self,
        snapshot: &RunSnapshot,
        settled: Option<(&RunCommand, &Value)>,
    ) -> Result<()> {
        let definition = self
            .store
            .definition_by_revision(&snapshot.definition_digest)?;
        let status = wire_enum(snapshot.status)?;
        crate::domain::agent_usage::workflow_ledger::begin_graph_run(&json!({
            "stateRoot": self.portable_root,
            "runId": snapshot.run_id,
            "revisionDigest": snapshot.definition_digest,
            "conversationId": snapshot.conversation_id,
            "assistantMembershipId": snapshot.assistant_membership_id,
            "status": status,
        }))
        .map_err(|error| anyhow!(error.code))?;
        for command in snapshot.commands.values() {
            let binding = command.binding_id.as_deref().and_then(|slot_id| {
                definition.bindings.iter().find(|binding| {
                    binding.slot_id == slot_id && binding.ordinal == command.binding_ordinal
                })
            });
            let (membership_id, agent_id) = match (
                snapshot.conversation_id.as_deref(),
                binding,
                matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem),
            ) {
                (Some(conversation_id), Some(binding), true) => {
                    let target = group_actor_target(
                        conversation_id,
                        &binding.value_id,
                        &self.portable_root,
                    )?;
                    (Some(target.membership_id), Some(target.agent_id))
                }
                (None, Some(binding), true) => (None, Some(binding.value_id.clone())),
                _ => (None, None),
            };
            let usage = settled
                .filter(|(settled_command, _)| settled_command.id == command.id)
                .and_then(|(_, output)| numeric_usage_projection(output));
            crate::domain::agent_usage::workflow_ledger::record_graph_command(&json!({
                "stateRoot": self.portable_root,
                "runId": snapshot.run_id,
                "commandId": command.id,
                "stateId": command.state_id,
                "membershipId": membership_id,
                "kind": wire_enum(command.kind)?,
                "status": wire_enum(command.status)?,
                "attempt": command.attempt,
                "agentId": agent_id,
                "model": binding.map(|binding| binding.model.as_str()).filter(|model| !model.is_empty()),
                "usage": usage,
            }))
            .map_err(|error| anyhow!(error.code))?;
        }
        Ok(())
    }

    fn start_drive(&self, snapshot: &RunSnapshot) -> Result<Option<Value>> {
        // Usage admission is local and deterministic, so it completes before
        // registering the first Membership turn or issuing any other effect.
        self.record_graph_usage(snapshot, None)?;
        let Some(reservation) = DriveReservation::acquire(&snapshot.run_id) else {
            return Ok(None);
        };
        let assistant_owned = snapshot.assistant_membership_id.is_some();
        let entry = match self.register_entry_turn(snapshot) {
            Ok(entry) => entry,
            Err(error) if assistant_owned => {
                self.settle_assistant_start_failure(snapshot, &error.to_string())?;
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        let projection = entry
            .as_ref()
            .map(|registration| registration.projection.clone());
        let run_id = snapshot.run_id.clone();
        let service = self.clone();
        let spawned = std::thread::Builder::new()
            .name("strategy-drive".to_owned())
            .spawn(move || {
                let _reservation = reservation;
                if service.drive_run(&run_id, entry).is_err() {
                    let _ = service.settle_assistant_drive_failure(&run_id);
                }
            });
        if spawned.is_err() {
            if assistant_owned {
                self.settle_assistant_start_failure(snapshot, "strategy_run_start_failed")?;
                return Ok(None);
            }
            return Err(anyhow!("strategy_run_start_failed"));
        }
        Ok(projection)
    }

    fn settle_assistant_start_failure(&self, snapshot: &RunSnapshot, message: &str) -> Result<()> {
        let Some(command) = snapshot.commands.values().find(|command| {
            matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem)
                && command.status == CommandStatus::Pending
        }) else {
            return self.settle_assistant_drive_failure(&snapshot.run_id);
        };
        let (class, code) = classify_effect_error(message);
        let updated = self.store.apply_event(
            &snapshot.run_id,
            ReducerEvent::AssistantEffectFailed {
                command_id: command.id.clone(),
                attempt_token: command.attempt_token.clone(),
                class,
                code: code.to_owned(),
            },
        )?;
        self.record_graph_usage(&updated, None)
    }

    fn drive_run(&self, run_id: &str, mut entry: Option<EntryTurnRegistration>) -> Result<()> {
        self.store.reclaim_abandoned_host_commands(run_id)?;
        self.recover_expired_commands(run_id)?;
        let assistant_owned = self.store.run(run_id)?.assistant_membership_id.is_some();
        let mut executed = 0usize;
        'drive: while executed < MAX_DRIVE_EFFECTS_PER_CALL {
            if !assistant_owned {
                self.recover_persisted_effects(run_id)?;
            }
            let snapshot = self.store.run(run_id)?;
            if snapshot.status == StrategyRunStatus::AuthorizationRequired {
                let definition = self
                    .store
                    .definition_by_revision(&snapshot.definition_digest)?;
                let Some(authorization) = definition
                    .authorization
                    .filter(|authorization| authorization.active)
                else {
                    break;
                };
                if snapshot.commands.values().any(|command| {
                    command.kind == CommandKind::Authorization
                        && command.status == CommandStatus::Pending
                }) {
                    self.store.apply_event(
                        run_id,
                        ReducerEvent::AuthorizationGranted {
                            semantics_digest: authorization.semantics_digest,
                        },
                    )?;
                } else if let Some(command) = snapshot.commands.values().find(|command| {
                    command.status == CommandStatus::Retryable
                        && command.failure_class == Some(FailureClass::Authority)
                }) {
                    self.store.apply_event(
                        run_id,
                        ReducerEvent::RetryRequested {
                            command_id: command.id.clone(),
                        },
                    )?;
                } else {
                    break;
                }
                executed = executed.saturating_add(1);
                continue;
            }
            let mut commands = Vec::new();
            let capacity =
                super::MAX_ACTIVE_EFFECTS.min(MAX_DRIVE_EFFECTS_PER_CALL.saturating_sub(executed));
            for index in 0..capacity {
                let claimant = format!(
                    "scheduler-{}-{index}",
                    &run_id.chars().take(24).collect::<String>()
                );
                let Some(command) = self.store.claim_next_command(
                    run_id,
                    &claimant,
                    now_ms().saturating_add(EFFECT_LEASE_DURATION_MS),
                )?
                else {
                    break;
                };
                self.store.apply_event(
                    run_id,
                    ReducerEvent::CommandStarted {
                        command_id: command.id.clone(),
                        attempt_token: command.attempt_token.clone(),
                    },
                )?;
                commands.push((command, claimant));
            }
            if commands.is_empty() {
                break;
            }
            let mut outcomes = std::thread::scope(|scope| -> Result<Vec<_>> {
                let (sender, receiver) = std::sync::mpsc::channel();
                let leases = commands
                    .iter()
                    .map(|(command, claimant)| (command.id.clone(), claimant.clone()))
                    .collect::<Vec<_>>();
                for (command, claimant) in commands {
                    let registration = if entry
                        .as_ref()
                        .is_some_and(|registration| registration.matches(&command))
                    {
                        entry.take()
                    } else {
                        None
                    };
                    let service = self.clone();
                    let run_id = run_id.to_owned();
                    let sender = sender.clone();
                    scope.spawn(move || {
                        let result =
                            service.execute_command(&run_id, &command, &claimant, registration);
                        let _ = sender.send((command, result));
                    });
                }
                drop(sender);
                let mut outcomes = Vec::with_capacity(leases.len());
                while outcomes.len() < leases.len() {
                    match receiver.recv_timeout(std::time::Duration::from_secs(30)) {
                        Ok(outcome) => outcomes.push(outcome),
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            let lease_until = now_ms().saturating_add(EFFECT_LEASE_DURATION_MS);
                            for (command_id, claimant) in &leases {
                                self.store.renew_command_lease(
                                    command_id,
                                    claimant,
                                    lease_until,
                                )?;
                            }
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                            return Err(anyhow!("strategy_effect_thread_failed"));
                        }
                    }
                }
                Ok(outcomes)
            })?;
            executed = executed.saturating_add(outcomes.len());
            outcomes.sort_by(|left, right| left.0.id.cmp(&right.0.id));
            let mut assistant_failures = Vec::new();
            for (command, result) in outcomes {
                match result {
                    Ok((output, group_streamed)) => {
                        if let Some((class, code)) = actor_output_failure(&command, &output) {
                            if assistant_owned {
                                assistant_failures.push((
                                    command,
                                    class,
                                    code.to_owned(),
                                    Some(output),
                                ));
                                continue;
                            }
                            let updated = self.store.apply_event(
                                run_id,
                                ReducerEvent::CommandFailed {
                                    command_id: command.id.clone(),
                                    attempt_token: command.attempt_token.clone(),
                                    class,
                                    code: code.into(),
                                },
                            )?;
                            self.record_graph_usage(&updated, None)?;
                            self.recover_failed_effect(run_id, &command.id)?;
                            continue;
                        }
                        let updated = self.store.apply_event(
                            run_id,
                            ReducerEvent::CommandSucceeded {
                                command_id: command.id.clone(),
                                attempt_token: command.attempt_token.clone(),
                                output: output.clone(),
                            },
                        )?;
                        self.record_graph_usage(&updated, Some((&command, &output)))?;
                        if !group_streamed {
                            let _ = self.project_membership_event(run_id, &command, &output);
                        }
                    }
                    Err(error) => {
                        let (class, code) = classify_effect_error(&error.to_string());
                        if assistant_owned {
                            assistant_failures.push((command, class, code.to_owned(), None));
                            continue;
                        }
                        let updated = self.store.apply_event(
                            run_id,
                            ReducerEvent::CommandFailed {
                                command_id: command.id.clone(),
                                attempt_token: command.attempt_token.clone(),
                                class,
                                code: code.into(),
                            },
                        )?;
                        self.record_graph_usage(&updated, None)?;
                        self.recover_failed_effect(run_id, &command.id)?;
                    }
                }
            }
            if !assistant_failures.is_empty() {
                for (command, class, code, output) in assistant_failures {
                    let updated = self.store.apply_event(
                        run_id,
                        ReducerEvent::AssistantEffectFailed {
                            command_id: command.id.clone(),
                            attempt_token: command.attempt_token.clone(),
                            class,
                            code,
                        },
                    )?;
                    self.record_graph_usage(
                        &updated,
                        output.as_ref().map(|output| (&command, output)),
                    )?;
                }
                break 'drive;
            }
        }
        Ok(())
    }

    fn settle_assistant_drive_failure(&self, run_id: &str) -> Result<()> {
        let snapshot = self.store.run(run_id)?;
        if snapshot.assistant_membership_id.is_none() || assistant_run_terminal(snapshot.status) {
            return Ok(());
        }
        let updated = self.store.apply_event(
            run_id,
            ReducerEvent::AssistantDriveFailed {
                code: "assistant_drive_outcome_unknown".to_owned(),
            },
        )?;
        self.record_graph_usage(&updated, None)
    }

    fn recover_expired_commands(&self, run_id: &str) -> Result<()> {
        while self.store.recover_next_expired_command(run_id)? {}
        Ok(())
    }

    fn recover_persisted_effects(&self, run_id: &str) -> Result<()> {
        loop {
            let snapshot = self.store.run(run_id)?;
            let definition = self
                .store
                .definition_by_revision(&snapshot.definition_digest)?;
            let workflow = compile_persisted_workflow(definition.workflow.clone())?;
            let candidate = snapshot.commands.values().find(|command| {
                matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem)
                    && ((command.status == CommandStatus::Retryable
                        && command.failure_class == Some(FailureClass::Transient))
                        || fallback_reason(&workflow, &snapshot, command).is_some())
            });
            let Some(command_id) = candidate.map(|command| command.id.clone()) else {
                return Ok(());
            };
            ensure!(
                self.recover_failed_effect(run_id, &command_id)?,
                "strategy_recovery_state_conflict"
            );
        }
    }

    fn execute_command(
        &self,
        run_id: &str,
        command: &super::RunCommand,
        claimant: &str,
        registration: Option<EntryTurnRegistration>,
    ) -> Result<(Value, bool)> {
        let snapshot = self.store.run(run_id)?;
        let definition = self
            .store
            .definition_by_revision(&snapshot.definition_digest)?;
        let authorization = definition
            .authorization
            .as_ref()
            .filter(|authorization| authorization.active)
            .ok_or_else(|| anyhow!("authorization_required"))?;
        match command.kind {
            CommandKind::Actor | CommandKind::WorksetItem => {
                let binding = binding_for(
                    &definition,
                    command
                        .binding_id
                        .as_deref()
                        .ok_or_else(|| anyhow!("binding_incomplete"))?,
                    command.binding_ordinal,
                )?;
                let fingerprint_value_id = match snapshot.conversation_id.as_deref() {
                    Some(conversation_id) if !conversation_id.is_empty() => {
                        group_actor_target(conversation_id, &binding.value_id, &self.portable_root)?
                            .agent_id
                    }
                    _ => binding.value_id.clone(),
                };
                let fingerprint = actor_fingerprint(
                    &fingerprint_value_id,
                    &binding.model,
                    &binding.reasoning_effort,
                )?;
                self.store.authorize_effect(
                    run_id,
                    &command.id,
                    &command.attempt_token,
                    &authorization.authorization_digest,
                    claimant,
                    now_ms().saturating_add(EFFECT_LEASE_DURATION_MS),
                )?;
                let mut permit = StrategyEffectPermit::issue(
                    &command.id,
                    &authorization.authorization_digest,
                    &fingerprint,
                )?;
                self.execute_actor_into_group(
                    run_id,
                    command,
                    &authorization.authorization_digest,
                    binding,
                    &mut permit,
                    snapshot.cwd.as_deref(),
                    snapshot.conversation_id.as_deref(),
                    registration,
                    &fingerprint,
                )
            }
            CommandKind::Script => {
                let requirement_id = command
                    .runtime_id
                    .as_deref()
                    .ok_or_else(|| anyhow!("runtime_unavailable"))?;
                let requirement = definition
                    .workflow
                    .runtimes
                    .iter()
                    .find(|requirement| requirement.id == requirement_id)
                    .ok_or_else(|| anyhow!("runtime_unavailable"))?;
                let runtime_id = &binding_for(&definition, requirement_id, 0)?.value_id;
                let runtime = RuntimeCatalog::discover().resolve(
                    runtime_id,
                    requirement.kind,
                    &requirement.version_requirement,
                )?;
                let revision_content = self.importer.verified_revision_content(
                    &definition.summary.revision_digest,
                    &definition.summary.semantics_digest,
                )?;
                self.store.authorize_effect(
                    run_id,
                    &command.id,
                    &command.attempt_token,
                    &authorization.authorization_digest,
                    claimant,
                    now_ms().saturating_add(EFFECT_LEASE_DURATION_MS),
                )?;
                let mut permit = StrategyEffectPermit::issue(
                    &command.id,
                    &authorization.authorization_digest,
                    runtime.fingerprint(),
                )?;
                let runtime_state = self
                    .portable_root
                    .join("client-state")
                    .join("adaptive-flywheel")
                    .join("runtime")
                    .join(run_id);
                execute_script(
                    command,
                    &authorization.authorization_digest,
                    &runtime,
                    &revision_content,
                    &runtime_state,
                    &mut permit,
                )
                .map(|value| (value, false))
            }
            CommandKind::Authorization => Err(anyhow!("authorization_required")),
        }
    }

    fn recover_failed_effect(&self, run_id: &str, command_id: &str) -> Result<bool> {
        let snapshot = self.store.run(run_id)?;
        let current = snapshot
            .commands
            .get(command_id)
            .cloned()
            .ok_or_else(|| anyhow!("strategy_callback_stale"))?;
        if !matches!(current.kind, CommandKind::Actor | CommandKind::WorksetItem) {
            return Ok(false);
        }
        if current.status == CommandStatus::Retryable
            && current.failure_class == Some(FailureClass::Transient)
        {
            self.store.apply_event(
                run_id,
                ReducerEvent::RetryRequested {
                    command_id: current.id,
                },
            )?;
            return Ok(true);
        }
        let Some(slot_id) = current.binding_id.as_deref() else {
            return Ok(false);
        };
        let definition = self
            .store
            .definition_by_revision(&snapshot.definition_digest)?;
        let workflow = compile_persisted_workflow(definition.workflow.clone())?;
        let Some(reason) = fallback_reason(&workflow, &snapshot, &current) else {
            return Ok(false);
        };
        let next_ordinal = current.binding_ordinal.saturating_add(1);
        let next = definition
            .bindings
            .iter()
            .find(|binding| binding.slot_id == slot_id && binding.ordinal == next_ordinal)
            .ok_or_else(|| anyhow!("binding_incomplete"))?;
        let previous = definition
            .bindings
            .iter()
            .find(|binding| {
                binding.slot_id == slot_id && binding.ordinal == current.binding_ordinal
            })
            .ok_or_else(|| anyhow!("binding_incomplete"))?;
        let mut facts = current.input.clone();
        if let Some(session) = current.resume_session_id.as_deref() {
            if let Value::Object(ref mut object) = facts {
                object
                    .entry("nativeSessionId")
                    .or_insert_with(|| Value::String(session.to_owned()));
            }
        }
        self.store.apply_event(
            run_id,
            ReducerEvent::FallbackIssued {
                failed_command_id: current.id,
                next_ordinal,
                locator: predecessor_locator(&facts),
                from_value_id: previous.value_id.clone(),
                to_value_id: next.value_id.clone(),
                reason: reason.into(),
                attempts: current.attempt,
            },
        )?;
        Ok(true)
    }

    fn execute_actor_into_group(
        &self,
        run_id: &str,
        command: &super::RunCommand,
        authorization_digest: &str,
        binding: &super::BindingValue,
        permit: &mut StrategyEffectPermit,
        cwd: Option<&str>,
        conversation_id: Option<&str>,
        registration: Option<EntryTurnRegistration>,
        expected_fingerprint: &str,
    ) -> Result<(Value, bool)> {
        let Some(conversation_id) = conversation_id.filter(|value| !value.is_empty()) else {
            return execute_actor(command, authorization_digest, binding, permit, cwd)
                .map(|value| (value, false));
        };
        // A Conversation-bound run must run a registered Membership
        // PersistentTurn. The entry command carries the pre-registered handle;
        // every later command opens and runs through the same port.
        let target = group_actor_target(conversation_id, &binding.value_id, &self.portable_root)?;
        let Some(port) = self.actor_port.as_ref() else {
            return Err(anyhow!("strategy_actor_dispatch_failed"));
        };
        let params = match registration.as_ref() {
            Some(registration) => registration.params.clone(),
            None => group_actor_params(
                conversation_id,
                &target.membership_id,
                &target.agent_id,
                binding,
                &command.input,
                run_id,
                command.resume_session_id.as_deref(),
                cwd,
            )?,
        };
        permit.consume(command, authorization_digest, expected_fingerprint)?;
        let registration = match registration {
            Some(registration) => registration,
            None => {
                let handle = (port.open)(&params)
                    .map_err(|error| anyhow!("strategy_actor_dispatch_failed:{error}"))?;
                EntryTurnRegistration::ad_hoc(handle, params.clone(), Arc::clone(port))
            }
        };
        let (handle, params) = registration.into_run();
        match (port.run)(&handle, &params) {
            Ok(value) => {
                if actor_output_failure(command, &value).is_some() {
                    return Err(anyhow!("strategy_actor_failed"));
                }
                Ok((value, true))
            }
            Err(error) => Err(anyhow!("strategy_actor_dispatch_failed:{error}")),
        }
    }

    fn project_membership_event(
        &self,
        run_id: &str,
        command: &super::RunCommand,
        output: &Value,
    ) -> Result<()> {
        if !matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem) {
            return Ok(());
        }
        let snapshot = self.store.run(run_id)?;
        let Some(conversation_id) = snapshot.conversation_id.as_deref() else {
            return Ok(());
        };
        let definition = self
            .store
            .definition_by_revision(&snapshot.definition_digest)?;
        let Some(slot_id) = command.binding_id.as_deref() else {
            return Ok(());
        };
        let Some(binding) = definition.bindings.iter().find(|binding| {
            binding.slot_id == slot_id && binding.ordinal == command.binding_ordinal
        }) else {
            return Ok(());
        };
        let store =
            crate::domain::client_conversation::ConversationStore::open(&self.portable_root)?;
        let conversation = store.get(conversation_id)?;
        let Some(membership) = conversation.memberships.iter().find(|membership| {
            membership.id == binding.value_id
                && membership.status == crate::domain::client_conversation::MembershipStatus::Active
        }) else {
            return Ok(());
        };
        let parts = group_actor_event_parts(output);
        if parts.is_empty() {
            return Ok(());
        }
        store.append_event(
            conversation_id,
            Some(&membership.id),
            crate::domain::client_conversation::EventKind::Message,
            &parts,
            None,
            Some(run_id),
            true,
        )?;
        Ok(())
    }
}

/// One atomic reservation for a run's background drive. Reserving before the
/// entry turn opens prevents concurrent idempotent starts from returning two
/// handles when only one drive can own the run.
struct DriveReservation {
    run_id: String,
}

impl DriveReservation {
    fn acquire(run_id: &str) -> Option<Self> {
        let mut driving = driving_runs()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        driving.insert(run_id.to_owned()).then(|| Self {
            run_id: run_id.to_owned(),
        })
    }

    fn is_active(run_id: &str) -> bool {
        driving_runs()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .contains(run_id)
    }
}

impl Drop for DriveReservation {
    fn drop(&mut self) {
        driving_runs()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .remove(&self.run_id);
    }
}

/// One registered entry turn whose settlement is owed to the drive that runs
/// it. Dropping an armed registration abandons the handle with a typed code,
/// so a drive that exits, fails to claim, or claims another command first can
/// never leave a phantom active turn keeping the pane busy.
struct EntryTurnRegistration {
    slot_id: String,
    handle: String,
    params: Value,
    projection: Value,
    port: Arc<ActorTurnPort>,
    armed: bool,
}

impl EntryTurnRegistration {
    /// A turn opened inline by the drive owns the same abandonment guarantee
    /// as a pre-registered entry turn.
    fn ad_hoc(handle: String, params: Value, port: Arc<ActorTurnPort>) -> Self {
        Self {
            slot_id: String::new(),
            handle,
            params,
            projection: Value::Null,
            port,
            armed: true,
        }
    }

    fn matches(&self, command: &RunCommand) -> bool {
        !self.slot_id.is_empty()
            && matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem)
            && command.binding_id.as_deref() == Some(self.slot_id.as_str())
            && command.state_visit == 1
            && command.binding_ordinal == 0
    }

    /// Hand the registered turn to the drive's run path. From this point the
    /// dispatch completion authority owns its settlement.
    fn into_run(mut self) -> (String, Value) {
        self.armed = false;
        (self.handle.clone(), self.params.clone())
    }
}

impl Drop for EntryTurnRegistration {
    fn drop(&mut self) {
        if self.armed {
            (self.port.abandon)(&self.handle);
        }
    }
}

/// The state that emits the first entry-slot command. When the initial state
/// is an authorization gate, the entry state is its deterministic success
/// target: the drive grants an active authorization before claiming anything.
fn entry_state_for_start<'a>(
    workflow: &'a CompiledWorkflow,
    slot_id: &str,
) -> Option<&'a GraphState> {
    let initial = workflow.state(&workflow.definition.initial)?;
    if initial.binding.as_deref() == Some(slot_id)
        && matches!(
            initial.kind,
            GraphStateKind::Actor | GraphStateKind::Workset
        )
    {
        return Some(initial);
    }
    if initial.kind == GraphStateKind::Authorization {
        let target = workflow
            .transitions(&initial.id, TransitionEvent::Success)
            .next()?;
        let state = workflow.state(&target.to)?;
        if state.binding.as_deref() == Some(slot_id)
            && matches!(state.kind, GraphStateKind::Actor | GraphStateKind::Workset)
        {
            return Some(state);
        }
    }
    None
}

/// Resolve the active Agent Membership one Conversation-bound command runs
/// against. Addressing is by Membership identity only.
struct GroupActorTarget {
    membership_id: String,
    agent_id: String,
}

fn group_actor_target(
    conversation_id: &str,
    binding_identity: &str,
    portable_root: &Path,
) -> Result<GroupActorTarget> {
    let store = crate::domain::client_conversation::ConversationStore::open(portable_root)
        .map_err(|_| anyhow!("strategy_actor_dispatch_failed"))?;
    let conversation = store
        .get(conversation_id)
        .map_err(|_| anyhow!("strategy_actor_dispatch_failed"))?;
    conversation
        .memberships
        .iter()
        .find(|membership| {
            membership.id == binding_identity
                && membership.status == crate::domain::client_conversation::MembershipStatus::Active
        })
        .and_then(|membership| {
            membership
                .principal
                .agent_id
                .as_ref()
                .map(|agent_id| GroupActorTarget {
                    membership_id: membership.id.clone(),
                    agent_id: agent_id.clone(),
                })
        })
        .ok_or_else(|| anyhow!("strategy_actor_dispatch_failed"))
}

/// The single parameter builder for one Conversation-bound actor turn, shared
/// by entry registration and the drive so a pre-registered handle always runs
/// the exact prompt and routing the emitted command carries.
fn group_actor_params(
    conversation_id: &str,
    membership_id: &str,
    agent_id: &str,
    binding: &super::BindingValue,
    input: &Value,
    run_id: &str,
    resume_session_id: Option<&str>,
    cwd: Option<&str>,
) -> Result<Value> {
    let prompt = group_actor_prompt(input);
    if prompt.trim().is_empty() {
        return Err(anyhow!("strategy_actor_dispatch_failed"));
    }
    let mut params = json!({
        "agent": agent_id,
        "agentId": agent_id,
        "text": prompt,
        "message": prompt,
        "streamEvents": true,
        "timeoutMs": 0,
        "conversationId": conversation_id,
        "membershipId": membership_id,
        "causationId": run_id,
    });
    if let Some(session_id) = resume_session_id.filter(|value| !value.trim().is_empty()) {
        params["sessionId"] = json!(session_id);
    }
    if !binding.model.is_empty() {
        params["model"] = json!(binding.model);
    }
    if !binding.reasoning_effort.is_empty() {
        params["reasoningEffort"] = json!(binding.reasoning_effort);
    }
    if let Some(cwd) = cwd {
        params["cwd"] = json!(cwd);
        params["workingDirectory"] = json!(cwd);
    }
    Ok(params)
}

fn json_string_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

/// Prompt sent on a Conversation-bound actor PersistentTurn.
///
/// Prefer the human Event text (`message` / `text` / `context.message`). Do
/// not fall back to a JSON dump of the command input: Codex treats that as
/// the user turn and often completes with `failed`.
fn group_actor_prompt(input: &Value) -> String {
    let context_message = input.get("context").and_then(|context| {
        json_string_field(context, "message").or_else(|| json_string_field(context, "text"))
    });
    let input_message =
        json_string_field(input, "message").or_else(|| json_string_field(input, "text"));
    let human = context_message.or(input_message);
    let prompt = json_string_field(input, "prompt");
    match (prompt, human) {
        (Some(prompt), Some(human)) if prompt.trim_start().starts_with('{') => human.to_owned(),
        (Some(prompt), Some(human)) if prompt.contains(human) => prompt.to_owned(),
        (Some(prompt), Some(human)) => format!("{prompt}\n\n{human}"),
        (Some(prompt), None) if prompt.trim_start().starts_with('{') => String::new(),
        (Some(prompt), None) => prompt.to_owned(),
        (None, Some(human)) => human.to_owned(),
        (None, None) => String::new(),
    }
}

fn group_actor_event_parts(
    output: &Value,
) -> Vec<crate::domain::client_conversation::NewEventPart> {
    use crate::domain::client_conversation::{EventPartKind, NewEventPart};

    let raw = output
        .get("output")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| serde_json::to_string(output).unwrap_or_default());
    if raw.trim().is_empty() {
        return Vec::new();
    }
    let parsed = output
        .get("output")
        .and_then(Value::as_str)
        .and_then(|value| serde_json::from_str::<Value>(value).ok())
        .or_else(|| match output {
            Value::Object(map)
                if map.contains_key("userreply")
                    || map.contains_key("userReply")
                    || map.contains_key("designGoal")
                    || map.contains_key("worksets") =>
            {
                Some(output.clone())
            }
            _ => serde_json::from_str(&raw).ok(),
        });
    if let Some(Value::Object(map)) = parsed {
        if let Some(reply) = user_facing_actor_reply(&map) {
            return vec![
                NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Text,
                    content: reply,
                },
                NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Metadata,
                    content: raw,
                },
            ];
        }
        if is_framework_contract(&map) || looks_like_wrapped_prompt(&raw) {
            return vec![NewEventPart {
                id: String::new(),
                kind: EventPartKind::Metadata,
                content: raw,
            }];
        }
    }
    if looks_like_wrapped_prompt(&raw) {
        return vec![NewEventPart {
            id: String::new(),
            kind: EventPartKind::Metadata,
            content: raw,
        }];
    }
    vec![NewEventPart {
        id: String::new(),
        kind: EventPartKind::Text,
        content: raw,
    }]
}

fn user_facing_actor_reply(map: &Map<String, Value>) -> Option<String> {
    for key in ["userreply", "userReply", "user_reply"] {
        if let Some(reply) = map
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return Some(reply.to_owned());
        }
    }
    None
}

fn is_framework_contract(map: &Map<String, Value>) -> bool {
    let has_goal = map.contains_key("designGoal") || map.contains_key("design_goal");
    let has_worksets = map.contains_key("worksets");
    let has_constraints = map.contains_key("constraints");
    let has_route = map.get("route").and_then(Value::as_str).is_some();
    (has_goal || has_worksets) && (has_constraints || has_route)
}

fn looks_like_wrapped_prompt(raw: &str) -> bool {
    raw.contains("Input JSON:") && raw.contains("State:")
}

fn binding_for<'a>(
    definition: &'a super::StrategyDefinition,
    slot: &str,
    ordinal: u8,
) -> Result<&'a super::BindingValue> {
    definition
        .bindings
        .iter()
        .find(|binding| binding.slot_id == slot && binding.ordinal == ordinal)
        .ok_or_else(|| anyhow!("binding_incomplete"))
}

fn ensure_allowed_fields(action: &str, object: &Map<String, Value>) -> Result<()> {
    let allowed: &[&str] = match action {
        "strategy.package.prepare-import" => &["action", "sourcePath", "selectionToken"],
        "strategy.package.commit-import" => &["action", "preparationId", "expectedRevisionDigest"],
        "strategy.definition.list" | "strategy.runtime.discover" | "strategy.runtime.list" => {
            &["action"]
        }
        "strategy.definition.inspect"
        | "strategy.authorization.preview"
        | "strategy.authorization.revoke" => &["action", "revisionDigest"],
        "strategy.binding.update" => &[
            "action",
            "revisionDigest",
            "slotId",
            "valueId",
            "model",
            "reasoningEffort",
            "expectedRevision",
        ],
        "strategy.binding.replace" => &[
            "action",
            "revisionDigest",
            "slotId",
            "candidates",
            "expectedRevision",
        ],
        "strategy.binding.remove" => &["action", "revisionDigest", "slotId", "expectedRevision"],
        "strategy.authorization.grant" => &[
            "action",
            "revisionDigest",
            "authorizationDigest",
            "confirmed",
        ],
        "strategy.run.start" => &[
            "action",
            "revisionDigest",
            "input",
            "idempotencyKey",
            "conversationId",
            "cwd",
        ],
        "strategy.run.active" => &["action", "revisionDigest", "conversationId"],
        "strategy.run.inspect" | "strategy.run.cancel" | "strategy.run.retry" => {
            &["action", "runId"]
        }
        "strategy.assistant.workflow.execute" => &[
            "action",
            "conversationId",
            "membershipId",
            "workflow",
            "bindings",
            "filters",
            "input",
            "idempotencyKey",
        ],
        "strategy.assistant.workflow.inspect" | "strategy.assistant.workflow.cancel" => {
            &["action", "runId"]
        }
        "strategy.run.resume" => &["action", "runId", "conversationId"],
        _ => return Err(anyhow!("unsupported_action")),
    };
    ensure!(
        object.keys().all(|key| allowed.contains(&key.as_str())),
        "invalid_request"
    );
    Ok(())
}

fn required_string<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| value == &value.trim() && !value.is_empty() && value.len() <= 4096)
        .ok_or_else(|| anyhow!("invalid_request"))
}

fn optional_string<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str> {
    match object.get(key) {
        None => Ok(""),
        Some(Value::String(value))
            if value == value.trim()
                && value.len() <= 160
                && !value.chars().any(char::is_control) =>
        {
            Ok(value)
        }
        _ => Err(anyhow!("invalid_request")),
    }
}

fn wire_enum(value: impl serde::Serialize) -> Result<String> {
    serde_json::to_value(value)?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("strategy_enum_invalid"))
}

/// Extract only checked numeric usage candidates from a runtime result. The
/// output body itself is never handed to the ledger or stored.
fn numeric_usage_projection(output: &Value) -> Option<Value> {
    let source = [
        output.pointer("/usage"),
        output.pointer("/result/usage"),
        output.pointer("/terminal/usage"),
        output.pointer("/payload/usage"),
        Some(output),
    ]
    .into_iter()
    .flatten()
    .find_map(Value::as_object)?;
    let number = |keys: &[&str]| {
        keys.iter()
            .find_map(|key| source.get(*key).and_then(Value::as_u64))
    };
    let prompt = number(&[
        "promptTokens",
        "prompt_tokens",
        "inputTokens",
        "input_tokens",
    ]);
    let cached = number(&[
        "cachedInputTokens",
        "cached_input_tokens",
        "cacheReadInputTokens",
        "cache_read_input_tokens",
    ]);
    let completion = number(&[
        "completionTokens",
        "completion_tokens",
        "outputTokens",
        "output_tokens",
    ]);
    if prompt.is_none() && cached.is_none() && completion.is_none() {
        return None;
    }
    let prompt = prompt.unwrap_or(0);
    let completion = completion.unwrap_or(0);
    let total = prompt.checked_add(completion)?;
    let accuracy = source
        .get("accuracy")
        .or_else(|| source.get("usageAccuracy"))
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "exact" | "estimated" | "unknown"))
        .unwrap_or("exact");
    Some(json!({
        "promptTokens": prompt,
        "cachedInputTokens": cached.unwrap_or(0),
        "completionTokens": completion,
        "totalTokens": total,
        "accuracy": accuracy,
    }))
}

fn optional_cwd(object: &Map<String, Value>) -> Result<Option<String>> {
    match object.get("cwd") {
        None => Ok(None),
        Some(Value::String(value)) if value.trim().is_empty() => Ok(None),
        Some(Value::String(value)) => {
            admit_strategy_cwd(value)?;
            Ok(Some(value.clone()))
        }
        _ => Err(anyhow!("invalid_request")),
    }
}

fn parse_binding_candidates(object: &Map<String, Value>) -> Result<Vec<BindingCandidate>> {
    let values = object
        .get("candidates")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("invalid_request"))?;
    ensure!(values.len() <= 16, "strategy_binding_limit");
    values
        .iter()
        .map(|value| {
            let candidate = value
                .as_object()
                .ok_or_else(|| anyhow!("invalid_request"))?;
            Ok(BindingCandidate {
                value_id: required_string(candidate, "valueId")?.to_owned(),
                model: optional_string(candidate, "model")?.to_owned(),
                reasoning_effort: optional_string(candidate, "reasoningEffort")?.to_owned(),
            })
        })
        .collect()
}

fn validate_selection_token(value: &str) -> Result<()> {
    ensure!(
        value.len() <= 96
            && value.chars().all(
                |character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_')
            ),
        "permit_denied"
    );
    Ok(())
}

fn classify_effect_error(message: &str) -> (FailureClass, &'static str) {
    if message.contains("runtime_unavailable") || message.contains("runtime_drifted") {
        (FailureClass::Runtime, "runtime_unavailable")
    } else if message.contains("sandbox") {
        (FailureClass::Sandbox, "sandbox_unavailable")
    } else if message.contains("authorization") || message.contains("permit") {
        (FailureClass::Authority, "authorization_required")
    } else if message.contains("quota_exhausted")
        || message.contains("strategy_actor_quota_exhausted")
    {
        (FailureClass::Permanent, "quota_exhausted")
    } else if message.contains("strategy_actor_failed") || message.contains("turn_not_completed") {
        // A PersistentTurn that finished with ok=false is a completed effect
        // failure. Do not classify it as dispatch_failed/transient or the
        // Graph will take the success edge and hand the chat to the next slot.
        (FailureClass::Permanent, "effect_failed")
    } else if message.contains("timed_out")
        || message.contains("timeout")
        || message.contains("dispatch_failed")
    {
        (FailureClass::Transient, "effect_temporarily_unavailable")
    } else if message.contains("outcome_unknown") {
        (FailureClass::InDoubt, "effect_outcome_unknown")
    } else {
        (FailureClass::Permanent, "effect_failed")
    }
}

/// Actor/workset JSON that the runtime returned as a value, not a transport Err.
///
/// A port run yields `Ok({ok:false,...})` when Codex pushes `turn/completed`
/// with `status != completed`. That is a failed effect, not CommandSucceeded.
fn actor_output_failure(
    command: &RunCommand,
    output: &Value,
) -> Option<(FailureClass, &'static str)> {
    if !matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem) {
        return None;
    }
    if output.get("ok").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let error = output.get("error").unwrap_or(output);
    let code = error.get("code").and_then(Value::as_str).unwrap_or("");
    let turn_status = error
        .get("turnStatus")
        .or_else(|| output.get("turnStatus"))
        .and_then(Value::as_str)
        .unwrap_or("");
    Some(classify_effect_error(&format!(
        "{code}\n{turn_status}\nstrategy_actor_failed"
    )))
}

fn error_projection(error: &anyhow::Error) -> Value {
    if let Some(failure) = error.downcast_ref::<WorkflowValidationFailure>() {
        return json!({
            "code": "workflow_invalid",
            "stage": "workflow/compile",
            "component": "strategy_graph",
            "retryable": false,
            "recovery": "correct_workflow_and_retry",
            "diagnostics": failure.diagnostics,
            "presentationArgs": {}
        });
    }
    let message = error.to_string();
    let (code, stage, component, retryable, recovery) =
        if message.contains(crate::domain::client_conversation::PERSISTENT_TRANSPORT_REQUIRED) {
            (
                crate::domain::client_conversation::PERSISTENT_TRANSPORT_REQUIRED,
                "run/dispatch",
                "strategy_runtime",
                true,
                "Open the client so the persistent runtime can drive the run, then retry.",
            )
        } else if message.contains("strategy_actor_dispatch_failed")
            || message.contains("strategy_run_start_failed")
        {
            (
                "strategy_run_start_failed",
                "strategy/start",
                "strategy_runtime",
                true,
                "Retry after the persistent Conversation runtime is available.",
            )
        } else if message.contains("package_unavailable") {
            (
                "package_unavailable",
                "package/read",
                "strategy_package",
                true,
                "Choose the ZIP package again.",
            )
        } else if message.contains("package_too_large") {
            (
                "package_too_large",
                "package/read",
                "strategy_package",
                false,
                "Use a package within the published size limit.",
            )
        } else if message.contains("package_duplicate") {
            (
                "package_duplicate_entry",
                "package/validate",
                "strategy_package",
                false,
                "Remove duplicate or case-colliding package entries.",
            )
        } else if message.contains("package_layout") {
            (
                "package_layout_invalid",
                "package/validate",
                "strategy_package",
                false,
                "Keep workflow.json at the root and helpers below scripts/.",
            )
        } else if message.contains("package_entry") {
            (
                "package_entry_invalid",
                "package/validate",
                "strategy_package",
                false,
                "Remove invalid or path-escaping package entries.",
            )
        } else if message.contains("package_resource") {
            (
                "package_resource_limit",
                "package/validate",
                "strategy_package",
                false,
                "Reduce package entries or extracted bytes.",
            )
        } else if message.contains("workflow") {
            (
                "workflow_invalid",
                "workflow/compile",
                "strategy_graph",
                false,
                "Correct the workflow Graph and import a new revision.",
            )
        } else if message.contains("definition_not_found") {
            (
                "definition_not_found",
                "definition/read",
                "strategy_store",
                false,
                "Select an available strategy definition.",
            )
        } else if message.contains("preparation_not_found") {
            (
                "preparation_not_found",
                "package/commit",
                "strategy_package",
                true,
                "Prepare the package again.",
            )
        } else if message.contains("revision_conflict") || message.contains("authorization_stale") {
            (
                "revision_conflict",
                "authority/revalidate",
                "strategy_authority",
                true,
                "Refresh the definition and authorize its current semantics.",
            )
        } else if message.contains("binding") {
            (
                "binding_incomplete",
                "binding/validate",
                "strategy_binding",
                true,
                "Bind every required actor and runtime slot.",
            )
        } else if message.contains("runtime") {
            (
                "runtime_unavailable",
                "runtime/discover",
                "strategy_runtime",
                true,
                "Install or bind a verified local runtime.",
            )
        } else if message.contains("sandbox") {
            (
                "sandbox_unavailable",
                "runtime/sandbox",
                "strategy_runtime",
                true,
                "Use a platform with the required reliable sandbox.",
            )
        } else if message.contains("authorization") || message.contains("permit") {
            (
                "authorization_required",
                "authority/check",
                "strategy_authority",
                true,
                "Review and authorize the current semantics.",
            )
        } else if message.contains("run_not_found") {
            (
                "run_not_found",
                "run/read",
                "strategy_store",
                false,
                "Select an existing run.",
            )
        } else if message.contains("not_retryable") {
            (
                "run_not_retryable",
                "run/retry",
                "strategy_reducer",
                false,
                "Inspect the run state before retrying.",
            )
        } else if message.contains("unsupported_action") {
            (
                "unsupported_action",
                "bridge/admission",
                "strategy_bridge",
                false,
                "Update the client and retry.",
            )
        } else if message.contains("invalid_request") {
            (
                "invalid_request",
                "bridge/admission",
                "strategy_bridge",
                false,
                "Correct the request fields.",
            )
        } else {
            (
                "strategy_operation_failed",
                "strategy/operation",
                "adaptive_flywheel",
                false,
                "Inspect the strategy diagnostics.",
            )
        };
    json!({
        "code": code,
        "stage": stage,
        "component": component,
        "retryable": retryable,
        "recovery": recovery,
        "presentationArgs": {}
    })
}

fn terminal_projection(value: &Value) -> Option<Value> {
    let status = value.get("status").and_then(Value::as_str)?;
    if !matches!(
        status,
        "authorization-required"
            | "runtime-missing"
            | "retryable"
            | "completed"
            | "failed"
            | "cancelled"
            | "blocked"
            | "cancel-in-doubt"
    ) {
        return None;
    }
    let code = value
        .pointer("/diagnostic/code")
        .and_then(Value::as_str)
        .filter(|code| !code.is_empty())
        .unwrap_or(match status {
            "completed" => "graph_completed",
            "cancelled" => "graph_cancelled",
            "cancel-in-doubt" => "cancellation_outcome_unknown",
            "authorization-required" => "authorization_required",
            "runtime-missing" => "runtime_unavailable",
            "retryable" => "runtime_retryable",
            "blocked" => "graph_blocked",
            _ => "graph_failed",
        });
    Some(json!({
        "code": code,
        "status": status,
        "stage": "assistant-workflow/terminal",
        "retryable": false,
        "recoveryClass": "assistant-direct-or-new-graph",
    }))
}

fn assistant_state_failure(code: &str, membership_id: Option<&str>) -> PreflightFailure {
    PreflightFailure::new(
        "graph_preflight_rejected",
        vec![PreflightDiagnostic {
            code: WorkflowDiagnosticCode::from_wire(code)
                .unwrap_or(WorkflowDiagnosticCode::WorkflowInvalid),
            stage: WorkflowDiagnosticStage::AssistantWorkflowRevalidate,
            path: membership_id.map(|_| "/membershipId".to_owned()),
            related_paths: Vec::new(),
            membership_id: membership_id.map(str::to_owned),
            actual: None,
            limit: None,
            expected: None,
            actual_kind: None,
            recovery: Some(WorkflowDiagnosticRecovery::RefreshConversationState),
            line: None,
            column: None,
        }],
    )
}

fn assistant_run_terminal(status: StrategyRunStatus) -> bool {
    matches!(
        status,
        StrategyRunStatus::AuthorizationRequired
            | StrategyRunStatus::RuntimeMissing
            | StrategyRunStatus::Retryable
            | StrategyRunStatus::Completed
            | StrategyRunStatus::Failed
            | StrategyRunStatus::Cancelled
            | StrategyRunStatus::Blocked
            | StrategyRunStatus::CancelInDoubt
    )
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lico-strategy-service-test-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn remove_root(path: PathBuf) {
        let mut stack = vec![path.clone()];
        while let Some(current) = stack.pop() {
            if let Ok(metadata) = fs::symlink_metadata(&current) {
                make_writable(&current, metadata.permissions());
                if metadata.is_dir()
                    && let Ok(entries) = fs::read_dir(&current)
                {
                    stack.extend(entries.flatten().map(|entry| entry.path()));
                }
            }
        }
        fs::remove_dir_all(path).unwrap();
    }

    fn make_writable(path: &Path, mut permissions: fs::Permissions) {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            permissions.set_mode(permissions.mode() | 0o200);
        }
        #[cfg(not(unix))]
        permissions.set_readonly(false);
        fs::set_permissions(path, permissions).unwrap();
    }

    #[test]
    fn catalog_starts_empty_until_a_package_is_imported() {
        let root = root();
        let service = StrategyService::open(&root).unwrap();
        let listed = service
            .execute(json!({"action": "strategy.definition.list"}))
            .unwrap();
        assert_eq!(listed["result"].as_array().unwrap().len(), 0);

        let zip_path = root.join("fixture.zip");
        fs::write(
            &zip_path,
            crate::domain::adaptive_flywheel::synthetic_fixture_package_bytes().unwrap(),
        )
        .unwrap();
        let prepared = service
            .execute(json!({
                "action": "strategy.package.prepare-import",
                "sourcePath": zip_path.to_string_lossy(),
                "selectionToken": "selection-test"
            }))
            .unwrap();
        assert_eq!(prepared["ok"], true);
        let commit = service
            .execute(json!({
                "action": "strategy.package.commit-import",
                "preparationId": prepared["result"]["preparationId"],
                "expectedRevisionDigest": prepared["result"]["revisionDigest"]
            }))
            .unwrap();
        assert_eq!(commit["ok"], true);
        assert_eq!(commit["result"]["definitionId"], "fixture-entry-worker");

        let reopened = StrategyService::open(&root).unwrap();
        let relisted = reopened
            .execute(json!({"action": "strategy.definition.list"}))
            .unwrap();
        assert_eq!(relisted["result"].as_array().unwrap().len(), 1);
        remove_root(root);
    }

    #[test]
    fn persisted_fallback_recovery_is_resumable_and_idempotent() {
        use crate::domain::adaptive_flywheel::{
            ActorSlot, GraphState, GraphStateKind, RetryPolicy, Transition, TransitionEvent,
            WorkflowDefinition, WorkflowLimits, WorkflowMetadata,
        };

        let root = root();
        let store = StrategyStore::open(&root).unwrap();
        let mut slot = ActorSlot::required_actor("worker", "Worker");
        slot.fallback.after_transient_attempts = 1;
        let workflow = WorkflowDefinition {
            schema: super::super::WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "fallback-recovery".into(),
                name: "Fallback recovery".into(),
                version: "1".into(),
                description: String::new(),
            },
            limits: WorkflowLimits {
                max_parallelism: 1,
                max_workset_items: 1,
                max_attempts: 2,
            },
            actor_slots: vec![slot],
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
                        max_attempts: 1,
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
                    id: "failed".into(),
                    kind: GraphStateKind::Fail,
                    label: "Failed".into(),
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
                    id: "succeeded".into(),
                    from: "work".into(),
                    to: "done".into(),
                    event: TransitionEvent::Success,
                    guard: None,
                },
                Transition {
                    id: "failed".into(),
                    from: "work".into(),
                    to: "failed".into(),
                    event: TransitionEvent::Failure,
                    guard: None,
                },
            ],
        };
        let revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        store
            .register_definition(revision, revision, &workflow, 1, 1)
            .unwrap();
        store
            .replace_slot_bindings(
                revision,
                "worker",
                &[
                    BindingCandidate {
                        value_id: "agent:primary".into(),
                        model: String::new(),
                        reasoning_effort: String::new(),
                    },
                    BindingCandidate {
                        value_id: "agent:fallback".into(),
                        model: String::new(),
                        reasoning_effort: String::new(),
                    },
                ],
                None,
            )
            .unwrap();
        let preview = store.authorization_preview(revision).unwrap();
        store
            .grant_authorization(revision, &preview.authorization_digest)
            .unwrap();
        let run = store
            .start_run(revision, json!({}), "fallback-recovery-run", None, None)
            .unwrap();
        let command = run.commands.values().next().unwrap().clone();
        let failed = store
            .apply_event(
                &run.run_id,
                ReducerEvent::CommandFailed {
                    command_id: command.id.clone(),
                    attempt_token: command.attempt_token,
                    class: FailureClass::Transient,
                    code: "effect_temporarily_unavailable".into(),
                },
            )
            .unwrap();
        assert_eq!(failed.status, StrategyRunStatus::Running);
        assert_eq!(failed.commands[&command.id].status, CommandStatus::Failed);

        let service = StrategyService::from_parts(
            root.clone(),
            store.clone(),
            StrategyPackageImporter::open(&root).unwrap(),
        );
        service.recover_persisted_effects(&run.run_id).unwrap();
        let recovered = store.run(&run.run_id).unwrap();
        assert_eq!(
            recovered.commands[&command.id].status,
            CommandStatus::Cancelled
        );
        assert_eq!(recovered.fallbacks.len(), 1);
        assert!(recovered.commands.values().any(|candidate| {
            candidate.binding_ordinal == 1 && candidate.status == CommandStatus::Pending
        }));
        service.recover_persisted_effects(&run.run_id).unwrap();
        assert_eq!(store.run(&run.run_id).unwrap(), recovered);
        remove_root(root);
    }

    #[test]
    fn actor_userreply_json_is_the_visible_group_text() {
        let parts = super::group_actor_event_parts(&json!({
            "output": "{\"userreply\":\"你好，我在。\",\"evidence\":{\"status\":\"done\"}}"
        }));
        let text: Vec<_> = parts
            .iter()
            .filter(|part| part.kind == crate::domain::client_conversation::EventPartKind::Text)
            .collect();
        assert_eq!(text.len(), 1);
        assert_eq!(text[0].content, "你好，我在。");
        assert!(parts.iter().any(|part| {
            part.kind == crate::domain::client_conversation::EventPartKind::Metadata
        }));
    }

    #[test]
    fn actor_design_contract_without_userreply_is_metadata_only() {
        let parts = super::group_actor_event_parts(&json!({
            "route": "ordinary",
            "intent": "greeting",
            "designGoal": "用简体中文友好地回应用户问候",
            "constraints": ["只回应问候"],
            "worksets": {"tasks": []}
        }));
        assert!(parts.iter().all(|part| {
            part.kind == crate::domain::client_conversation::EventPartKind::Metadata
        }));
        assert!(
            parts.iter().all(|part| {
                part.kind != crate::domain::client_conversation::EventPartKind::Text
            })
        );
    }

    #[test]
    fn group_actor_prompt_prefers_the_human_message_over_a_json_dump() {
        assert_eq!(super::group_actor_prompt(&json!({"message": "hi"})), "hi");
        assert_eq!(
            super::group_actor_prompt(&json!({
                "prompt": "{\"message\":\"hi\"}",
                "message": "hi"
            })),
            "hi"
        );
        assert_eq!(
            super::group_actor_prompt(&json!({
                "prompt": "Greet the user.",
                "context": {"message": "hi"}
            })),
            "Greet the user.\n\nhi"
        );
        let wrapped = "Greet the user.\n\nState: entry\nInput JSON:\n{\"message\":\"hi\"}";
        assert_eq!(
            super::group_actor_prompt(&json!({
                "prompt": wrapped,
                "context": {"message": "hi"}
            })),
            wrapped
        );
        assert!(super::group_actor_prompt(&json!({"prompt": "{\"unrelated\":true}"})).is_empty());
    }

    fn actor_command() -> RunCommand {
        serde_json::from_value(json!({
            "id": "command:test",
            "stateId": "schedule",
            "kind": "actor",
            "status": "running",
            "attempt": 1,
            "attemptToken": "token",
            "inputDigest": "digest"
        }))
        .unwrap()
    }

    #[test]
    fn failed_persistent_turn_is_a_permanent_effect_failure() {
        let command = actor_command();
        let failed = super::actor_output_failure(
            &command,
            &json!({
                "ok": false,
                "error": {
                    "code": "codex_turn_not_completed",
                    "turnStatus": "failed"
                }
            }),
        )
        .expect("failed turn must not settle as success");
        assert_eq!(failed, (FailureClass::Permanent, "effect_failed"));
        assert!(super::actor_output_failure(&command, &json!({"ok": true})).is_none());
        assert_eq!(
            super::classify_effect_error("strategy_actor_failed"),
            (FailureClass::Permanent, "effect_failed")
        );
        assert_eq!(
            super::classify_effect_error("strategy_actor_dispatch_failed"),
            (FailureClass::Transient, "effect_temporarily_unavailable")
        );
    }

    use crate::domain::client_conversation::{MembershipAccess, Principal, PrincipalKind};

    fn entry_workflow() -> crate::domain::adaptive_flywheel::WorkflowDefinition {
        use crate::domain::adaptive_flywheel::{
            ActorSlot, GraphState, GraphStateKind, RetryPolicy, Transition, TransitionEvent,
            WorkflowDefinition, WorkflowLimits, WorkflowMetadata,
        };
        let mut slot = ActorSlot::required_actor("entry", "Entry");
        slot.entry = true;
        WorkflowDefinition {
            schema: super::super::WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "entry-greeter".into(),
                name: "Entry greeter".into(),
                version: "1".into(),
                description: String::new(),
            },
            limits: WorkflowLimits {
                max_parallelism: 1,
                max_workset_items: 1,
                max_attempts: 2,
            },
            actor_slots: vec![slot],
            runtimes: vec![],
            worksets: vec![],
            initial: "greet".into(),
            states: vec![
                GraphState {
                    id: "greet".into(),
                    kind: GraphStateKind::Actor,
                    label: "Greet".into(),
                    instruction: String::new(),
                    binding: Some("entry".into()),
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
                    id: "failed".into(),
                    kind: GraphStateKind::Fail,
                    label: "Failed".into(),
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
                    id: "greeted".into(),
                    from: "greet".into(),
                    to: "done".into(),
                    event: TransitionEvent::Success,
                    guard: None,
                },
                Transition {
                    id: "greet-failed".into(),
                    from: "greet".into(),
                    to: "failed".into(),
                    event: TransitionEvent::Failure,
                    guard: None,
                },
            ],
        }
    }

    fn conversation_bound_fixture(
        root: &Path,
    ) -> (
        crate::domain::client_conversation::ConversationStore,
        String,
        String,
    ) {
        let conversation_store =
            crate::domain::client_conversation::ConversationStore::open(root).unwrap();
        let conversation = conversation_store
            .create_conversation(
                "Group",
                Principal {
                    id: "human:local".into(),
                    kind: PrincipalKind::Human,
                    display_name: "You".into(),
                    agent_id: None,
                    created_at_unix_ms: 1,
                },
            )
            .unwrap();
        let membership = conversation_store
            .add_member(
                &conversation.id,
                Principal {
                    id: "agent:entry".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "Entry".into(),
                    agent_id: Some("entry-agent".into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )
            .unwrap();
        let owner_membership_id = conversation
            .memberships
            .iter()
            .find(|candidate| candidate.principal.kind == PrincipalKind::Human)
            .unwrap()
            .id
            .clone();
        let revision = conversation_store.get(&conversation.id).unwrap().revision;
        conversation_store
            .set_conversation_assistant(
                &conversation.id,
                &owner_membership_id,
                revision,
                Some(&membership.id),
            )
            .unwrap();
        (conversation_store, conversation.id, membership.id)
    }

    struct FixtureProfileAuthority {
        readiness: &'static str,
        calls: Arc<Mutex<BTreeMap<&'static str, usize>>>,
    }

    impl crate::domain::client_conversation::ProfileSnapshotAuthority for FixtureProfileAuthority {
        fn target_facts(
            &mut self,
            _agent_id: &str,
        ) -> Option<crate::domain::client_conversation::TargetFacts> {
            *self.calls.lock().unwrap().entry("target").or_default() += 1;
            Some(crate::domain::client_conversation::TargetFacts {
                status: Some("available".to_owned()),
                model: Some("model-a".to_owned()),
                environment: Some("local".to_owned()),
                capabilities: vec!["conversationDriver:supported".to_owned()],
                readiness: Some(self.readiness.to_owned()),
                reliability_class: Some("verified".to_owned()),
                latency_class: Some(1),
            })
        }

        fn model_price_usd_per_million_tokens(
            &mut self,
            _model: &str,
        ) -> Option<crate::domain::client_conversation::PriceFacts> {
            *self.calls.lock().unwrap().entry("price").or_default() += 1;
            Some(crate::domain::client_conversation::PriceFacts {
                input: 1.0,
                output: 2.0,
            })
        }

        fn coding_score(&mut self, _agent_id: &str, _model: &str) -> Option<i64> {
            *self.calls.lock().unwrap().entry("score").or_default() += 1;
            Some(3)
        }

        fn skill_names(&mut self, _agent_id: &str) -> Vec<String> {
            *self.calls.lock().unwrap().entry("skills").or_default() += 1;
            vec![
                crate::domain::client_conversation::ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID
                    .to_owned(),
            ]
        }
    }

    fn fixture_profile_authority(
        readiness: &'static str,
        calls: Arc<Mutex<BTreeMap<&'static str, usize>>>,
    ) -> crate::domain::client_conversation::SharedSnapshotAuthority {
        Arc::new(Mutex::new(Box::new(FixtureProfileAuthority {
            readiness,
            calls,
        })))
    }

    struct MutatingProfileAuthority {
        store: crate::domain::client_conversation::ConversationStore,
        conversation_id: String,
        membership_id: String,
        owner_membership_id: String,
        calls: Arc<Mutex<BTreeMap<&'static str, usize>>>,
        mutated: bool,
    }

    impl crate::domain::client_conversation::ProfileSnapshotAuthority for MutatingProfileAuthority {
        fn target_facts(
            &mut self,
            _agent_id: &str,
        ) -> Option<crate::domain::client_conversation::TargetFacts> {
            *self.calls.lock().unwrap().entry("target").or_default() += 1;
            Some(crate::domain::client_conversation::TargetFacts {
                model: Some("model-a".to_owned()),
                environment: Some("local".to_owned()),
                capabilities: vec!["conversationDriver:supported".to_owned()],
                readiness: Some("ready".to_owned()),
                ..Default::default()
            })
        }

        fn model_price_usd_per_million_tokens(
            &mut self,
            _model: &str,
        ) -> Option<crate::domain::client_conversation::PriceFacts> {
            *self.calls.lock().unwrap().entry("price").or_default() += 1;
            Some(crate::domain::client_conversation::PriceFacts {
                input: 1.0,
                output: 2.0,
            })
        }

        fn coding_score(&mut self, _agent_id: &str, _model: &str) -> Option<i64> {
            *self.calls.lock().unwrap().entry("score").or_default() += 1;
            Some(3)
        }

        fn skill_names(&mut self, _agent_id: &str) -> Vec<String> {
            *self.calls.lock().unwrap().entry("skills").or_default() += 1;
            if !self.mutated {
                let revision = self
                    .store
                    .membership_profile(&self.membership_id)
                    .unwrap()
                    .unwrap()
                    .revision;
                self.store
                    .set_membership_profile(
                        &self.conversation_id,
                        &self.membership_id,
                        &self.owner_membership_id,
                        revision,
                        &crate::domain::client_conversation::ProfileIntentUpdate {
                            preferred_capabilities: vec!["changed-during-preflight".to_owned()],
                            ..Default::default()
                        },
                    )
                    .unwrap();
                self.mutated = true;
            }
            vec![
                crate::domain::client_conversation::ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID
                    .to_owned(),
            ]
        }
    }

    fn authorized_entry_store(root: &Path, membership_id: &str) -> (StrategyStore, String) {
        let store = StrategyStore::open(root).unwrap();
        let revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        store
            .register_definition(revision, revision, &entry_workflow(), 1, 1)
            .unwrap();
        store
            .replace_slot_bindings(
                revision,
                "entry",
                &[BindingCandidate {
                    value_id: membership_id.to_owned(),
                    model: String::new(),
                    reasoning_effort: String::new(),
                }],
                None,
            )
            .unwrap();
        let preview = store.authorization_preview(revision).unwrap();
        store
            .grant_authorization(revision, &preview.authorization_digest)
            .unwrap();
        (store, revision.to_owned())
    }

    fn recording_port(
        calls: Arc<Mutex<Vec<(String, Value)>>>,
        run: impl Fn(&str, &Value) -> std::result::Result<Value, RuntimeAdapterError>
        + Send
        + Sync
        + 'static,
    ) -> ActorTurnPort {
        let open_calls = Arc::clone(&calls);
        ActorTurnPort {
            open: Arc::new(move |params| {
                let mut recorded = open_calls.lock().unwrap();
                let handle = format!("dispatch:entry-{}", recorded.len() + 1);
                recorded.push(("open".to_owned(), params.clone()));
                Ok(handle)
            }),
            run: Arc::new(move |handle, params| {
                calls
                    .lock()
                    .unwrap()
                    .push((format!("run:{handle}"), params.clone()));
                run(handle, params)
            }),
            abandon: Arc::new(|_| {}),
        }
    }

    fn wait_for_terminal(store: &StrategyStore, run_id: &str) -> RunSnapshot {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let snapshot = store.run(run_id).unwrap();
            if matches!(
                snapshot.status,
                StrategyRunStatus::Completed
                    | StrategyRunStatus::Failed
                    | StrategyRunStatus::Blocked
                    | StrategyRunStatus::Cancelled
            ) {
                return snapshot;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "drive did not settle the run"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    /// A terminal snapshot is visible before the drive thread finishes its
    /// exit path, so root cleanup waits the drive out and retries the remove
    /// while SQLite drops its journal files.
    fn remove_drive_root(root: PathBuf, service: StrategyService) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !driving_runs()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .is_empty()
        {
            assert!(
                std::time::Instant::now() < deadline,
                "drive thread did not exit"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        drop(service);
        for attempt in 0..100 {
            let root = root.clone();
            if std::panic::catch_unwind(|| remove_root(root)).is_ok() {
                return;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "drive root cleanup did not settle"
            );
            std::thread::sleep(std::time::Duration::from_millis(20 + attempt.min(30)));
        }
    }

    #[test]
    fn run_actions_without_the_host_runtime_are_fail_closed() {
        let root = root();
        let service = StrategyService::open(&root).unwrap();
        for request in [
            json!({
                "action": "strategy.run.start",
                "revisionDigest": "rev",
                "idempotencyKey": "key-1"
            }),
            json!({"action": "strategy.run.resume", "runId": "run-1"}),
            json!({"action": "strategy.run.retry", "runId": "run-1"}),
        ] {
            let response = service.execute(request).unwrap();
            assert_eq!(response["ok"], false);
            assert_eq!(
                response["error"]["code"],
                crate::domain::client_conversation::PERSISTENT_TRANSPORT_REQUIRED
            );
        }
        let store = StrategyStore::open(&root).unwrap();
        assert!(
            store
                .active_run_for_conversation("rev", "conversation:none")
                .unwrap()
                .is_none(),
            "no run was persisted without the host runtime"
        );
        remove_root(root);
    }

    #[test]
    fn run_start_registers_the_entry_turn_before_the_drive_runs_it() {
        let root = root();
        let (_conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let (store, revision) = authorized_entry_store(&root, &membership_id);
        let calls = Arc::new(Mutex::new(Vec::<(String, Value)>::new()));
        let port = recording_port(Arc::clone(&calls), |_, _| {
            Ok(json!({"ok": true, "output": "done", "nativeSessionId": "session-1"}))
        });
        let service = StrategyService::from_parts(
            root.clone(),
            store.clone(),
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(port);

        let response = service
            .execute(json!({
                "action": "strategy.run.start",
                "revisionDigest": revision,
                "input": {"message": "hi"},
                "idempotencyKey": "start-1",
                "conversationId": conversation_id,
            }))
            .unwrap();
        assert_eq!(response["ok"], true);
        let run_id = response["result"]["runId"].as_str().unwrap().to_owned();
        assert_eq!(
            response["result"]["entryTurn"]["turnHandle"],
            "dispatch:entry-1"
        );
        assert_eq!(
            response["result"]["entryTurn"]["membershipId"],
            membership_id.as_str()
        );
        {
            let recorded = calls.lock().unwrap();
            assert!(!recorded.is_empty());
            assert_eq!(recorded[0].0, "open");
            assert_eq!(recorded[0].1["text"], "hi");
            assert_eq!(recorded[0].1["conversationId"], conversation_id.as_str());
            assert_eq!(recorded[0].1["membershipId"], membership_id.as_str());
            assert_eq!(recorded[0].1["agent"], "entry-agent");
            assert_eq!(recorded[0].1["causationId"], run_id.as_str());
        }

        let snapshot = wait_for_terminal(&store, &run_id);
        assert_eq!(snapshot.status, StrategyRunStatus::Completed);
        let recorded = calls.lock().unwrap();
        assert_eq!(recorded.len(), 2);
        assert_eq!(recorded[1].0, "run:dispatch:entry-1");
        drop(recorded);
        remove_drive_root(root, service);
    }

    fn assistant_workflow_json() -> Value {
        serde_json::json!({
            "schema": "licoup.adaptive-flywheel.workflow.v1",
            "metadata": {
                "id": "assistant-temporary",
                "name": "Assistant Temporary Graph",
                "version": "1"
            },
            "limits": {"maxParallelism": 2, "maxWorksetItems": 16, "maxAttempts": 2},
            "actorSlots": [
                {"id": "subagent-a", "kind": "actor", "label": "Subagent A", "required": true, "entry": true}
            ],
            "runtimes": [],
            "worksets": [],
            "initial": "running",
            "states": [
                {"id": "running", "kind": "actor", "label": "Running", "binding": "subagent-a"},
                {"id": "done", "kind": "succeed", "label": "Done"},
                {"id": "failed", "kind": "fail", "label": "Failed"}
            ],
            "transitions": [
                {"id": "succeeded", "from": "running", "event": "success", "to": "done"},
                {"id": "failed", "from": "running", "event": "failure", "to": "failed"}
            ]
        })
    }

    #[test]
    fn assistant_graph_start_preflights_and_replays_without_duplicate_effects() {
        let root = root();
        let (_conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let calls = Arc::new(Mutex::new(Vec::<(String, Value)>::new()));
        let port = recording_port(Arc::clone(&calls), |_, _| {
            Ok(json!({"ok": true, "output": "done", "nativeSessionId": "session-1"}))
        });
        let service = StrategyService::from_parts(
            root.clone(),
            StrategyStore::open(&root).unwrap(),
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(port);

        let workflow = assistant_workflow_json();
        let bindings = json!([{
            "slotId": "subagent-a",
            "ordinal": 0,
            "valueId": membership_id,
            "model": "model-a",
            "reasoningEffort": "",
            "revision": 1
        }]);
        let authority_calls = Arc::new(Mutex::new(BTreeMap::new()));
        let service = service.with_profile_snapshot_authority(fixture_profile_authority(
            "ready",
            Arc::clone(&authority_calls),
        ));
        let request = || {
            json!({
                "action": "strategy.assistant.workflow.execute",
                "conversationId": conversation_id,
                "membershipId": membership_id,
                "workflow": workflow,
                "bindings": bindings,
                "input": {"message": "hi"},
                "idempotencyKey": "assistant-start-1"
            })
        };
        let response = service.execute(request()).unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["preflight"]["accepted"], true);
        assert!(response["result"].get("entrySessionId").is_none());
        assert!(response["result"].get("definition").is_none());
        assert!(response["result"].get("allowedOperations").is_none());
        let run_id = response["result"]["runId"].as_str().unwrap().to_owned();
        assert_eq!(
            response["result"]["preflight"]["receipt"]["membershipIds"][0],
            membership_id.as_str()
        );

        let snapshot = wait_for_terminal(&service.store(), &run_id);
        assert_eq!(snapshot.status, StrategyRunStatus::Completed);
        {
            let recorded = calls.lock().unwrap();
            assert_eq!(recorded.len(), 2);
            assert_eq!(recorded[0].0, "open");
            assert_eq!(recorded[1].0, "run:dispatch:entry-1");
        }
        assert_eq!(
            authority_calls.lock().unwrap().clone(),
            BTreeMap::from([("price", 1), ("score", 1), ("skills", 1), ("target", 1),]),
            "derived owners are read once for one execute request"
        );

        let inspect = service
            .execute(json!({"action": "strategy.assistant.workflow.inspect", "runId": run_id}))
            .unwrap();
        assert_eq!(inspect["ok"], true);
        assert_eq!(inspect["result"]["terminal"]["status"], "completed");
        assert!(inspect["result"].get("entrySessionId").is_none());

        let replay = service.execute(request()).unwrap();
        assert_eq!(replay["ok"], true, "{replay}");
        assert_eq!(replay["result"]["runId"].as_str().unwrap(), run_id.as_str());
        {
            let recorded = calls.lock().unwrap();
            assert_eq!(
                recorded.len(),
                2,
                "idempotent replay must not open a turn or duplicate an effect"
            );
        }
        drop(service);
        remove_root(root);
    }

    #[test]
    fn assistant_runtime_failure_returns_once_without_retry_or_fallback() {
        let root = root();
        let (_conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let calls = Arc::new(Mutex::new(Vec::<(String, Value)>::new()));
        let port = recording_port(Arc::clone(&calls), |_, _| {
            Err(RuntimeAdapterError::ConversationDispatchFailed)
        });
        let authority_calls = Arc::new(Mutex::new(BTreeMap::new()));
        let service = StrategyService::from_parts(
            root.clone(),
            StrategyStore::open(&root).unwrap(),
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(port)
        .with_profile_snapshot_authority(fixture_profile_authority("ready", authority_calls));
        let request = || {
            json!({
                "action": "strategy.assistant.workflow.execute",
                "conversationId": conversation_id,
                "membershipId": membership_id,
                "workflow": assistant_workflow_json(),
                "bindings": [{
                    "slotId": "subagent-a",
                    "ordinal": 0,
                    "valueId": membership_id,
                    "model": "model-a",
                    "reasoningEffort": "",
                    "revision": 1
                }],
                "input": {"message": "hi"},
                "idempotencyKey": "assistant-runtime-failure"
            })
        };

        let response = service.execute(request()).unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["status"], "failed");
        assert_eq!(response["result"]["terminal"]["status"], "failed");
        assert_eq!(
            response["result"]["terminal"]["code"],
            "effect_temporarily_unavailable"
        );
        assert_eq!(response["result"]["terminal"]["retryable"], false);
        assert_eq!(
            response["result"]["terminal"]["recoveryClass"],
            "assistant-direct-or-new-graph"
        );
        let run_id = response["result"]["runId"].as_str().unwrap();
        let snapshot = service.store().run(run_id).unwrap();
        assert!(snapshot.fallbacks.is_empty());
        assert!(snapshot.commands.values().all(|command| {
            !matches!(
                command.status,
                CommandStatus::Pending | CommandStatus::Retryable
            )
        }));
        assert_eq!(calls.lock().unwrap().len(), 2, "one open and one effect");

        let replay = service.execute(request()).unwrap();
        assert_eq!(replay["result"]["runId"], response["result"]["runId"]);
        assert_eq!(
            calls.lock().unwrap().len(),
            2,
            "terminal replay must not duplicate the failed effect"
        );
        drop(service);
        remove_root(root);
    }

    #[test]
    fn assistant_entry_registration_failure_settles_the_admitted_graph_once() {
        let root = root();
        let (_conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let opens = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let recorded_opens = Arc::clone(&opens);
        let authority_calls = Arc::new(Mutex::new(BTreeMap::new()));
        let service = StrategyService::from_parts(
            root.clone(),
            StrategyStore::open(&root).unwrap(),
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(ActorTurnPort {
            open: Arc::new(move |_| {
                recorded_opens.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Err(RuntimeAdapterError::ConversationDispatchFailed)
            }),
            run: Arc::new(|_, _| panic!("a rejected registration has no effect to run")),
            abandon: Arc::new(|_| {}),
        })
        .with_profile_snapshot_authority(fixture_profile_authority("ready", authority_calls));
        let request = || {
            json!({
                "action": "strategy.assistant.workflow.execute",
                "conversationId": conversation_id,
                "membershipId": membership_id,
                "workflow": assistant_workflow_json(),
                "bindings": [{
                    "slotId": "subagent-a",
                    "ordinal": 0,
                    "valueId": membership_id,
                    "model": "model-a",
                    "reasoningEffort": "",
                    "revision": 1
                }],
                "input": {"message": "hi"},
                "idempotencyKey": "assistant-entry-registration-failure"
            })
        };

        let response = service.execute(request()).unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["status"], "failed");
        assert_eq!(response["result"]["terminal"]["status"], "failed");
        assert_eq!(opens.load(std::sync::atomic::Ordering::SeqCst), 1);
        let run_id = response["result"]["runId"].as_str().unwrap();
        let snapshot = service.store().run(run_id).unwrap();
        assert!(snapshot.commands.values().all(|command| {
            matches!(
                command.status,
                CommandStatus::Failed | CommandStatus::Cancelled
            )
        }));

        let replay = service.execute(request()).unwrap();
        assert_eq!(replay["result"]["runId"], response["result"]["runId"]);
        assert_eq!(
            opens.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "terminal replay must not attempt registration again"
        );
        drop(service);
        remove_root(root);
    }

    #[test]
    fn assistant_graph_preflight_rejects_before_any_actor_effect() {
        let root = root();
        let (_conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let calls = Arc::new(Mutex::new(Vec::<(String, Value)>::new()));
        let port = recording_port(Arc::clone(&calls), |_, _| {
            panic!("a rejected preflight must never reach the actor port")
        });
        let service = StrategyService::from_parts(
            root.clone(),
            StrategyStore::open(&root).unwrap(),
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(port);

        let authority_calls = Arc::new(Mutex::new(BTreeMap::new()));
        let service = service
            .with_profile_snapshot_authority(fixture_profile_authority("busy", authority_calls));
        let response = service
            .execute(json!({
                "action": "strategy.assistant.workflow.execute",
                "conversationId": conversation_id,
                "membershipId": membership_id,
                "workflow": assistant_workflow_json(),
                "bindings": [{
                    "slotId": "subagent-a",
                    "ordinal": 0,
                    "valueId": membership_id,
                    "model": "model-a",
                    "reasoningEffort": "",
                    "revision": 1
                }],
                "input": {"message": "hi"},
                "idempotencyKey": "assistant-start-rejected"
            }))
            .unwrap();
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["accepted"], false);
        assert_eq!(
            response["result"]["error"]["code"],
            "graph_preflight_rejected"
        );
        assert!(
            response["result"]["error"]["diagnostics"]
                .as_array()
                .unwrap()
                .iter()
                .any(|check| check["code"] == "graph_readiness_rejected")
        );
        {
            let recorded = calls.lock().unwrap();
            assert!(
                recorded.is_empty(),
                "zero actor effects are allowed before preflight admission"
            );
        }
        drop(service);
        remove_root(root);
    }

    #[test]
    fn assistant_graph_aggregates_compiler_profile_and_binding_failures_deterministically() {
        let root = root();
        let (_conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let calls = Arc::new(Mutex::new(Vec::<(String, Value)>::new()));
        let port = recording_port(Arc::clone(&calls), |_, _| {
            panic!("a rejected multi-pass preflight must never reach the actor port")
        });
        let strategy_store = StrategyStore::open(&root).unwrap();
        let service = StrategyService::from_parts(
            root.clone(),
            strategy_store.clone(),
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(port)
        .with_profile_snapshot_authority(fixture_profile_authority(
            "busy",
            Arc::new(Mutex::new(BTreeMap::new())),
        ));
        let mut workflow = assistant_workflow_json();
        workflow["metadata"]["id"] = json!("imported-workflow");
        workflow["metadata"]["name"] = json!(" private-workspace-sentinel ");
        workflow["limits"]["maxParallelism"] = json!(0);
        workflow["states"][0]["binding"] = json!("private-workspace-sentinel");
        workflow["transitions"][0]["to"] = json!("private-workspace-sentinel");
        let request = || {
            json!({
                "action": "strategy.assistant.workflow.execute",
                "conversationId": conversation_id,
                "membershipId": membership_id,
                "workflow": workflow,
                "bindings": [],
                "input": {"message": "hi"},
                "idempotencyKey": "assistant-multi-pass-rejected"
            })
        };

        let first = service.execute(request()).unwrap();
        let second = service.execute(request()).unwrap();
        assert_eq!(first, second);
        assert_eq!(first["ok"], true);
        assert_eq!(first["result"]["accepted"], false);
        assert_eq!(first["result"]["error"]["code"], "graph_preflight_rejected");
        let diagnostics = first["result"]["error"]["diagnostics"].as_array().unwrap();
        for code in [
            "workflow_metadata_name_invalid",
            "workflow_parallelism_invalid",
            "workflow_actor_binding_invalid",
            "workflow_transition_state_unknown",
            "graph_identity_not_assistant_temporary",
            "graph_readiness_rejected",
            "graph_binding_incomplete",
        ] {
            assert!(
                diagnostics
                    .iter()
                    .any(|diagnostic| diagnostic["code"] == code),
                "missing {code}: {diagnostics:?}"
            );
        }
        let serialized = serde_json::to_string(&first).unwrap();
        assert!(!serialized.contains("private-workspace-sentinel"));
        assert!(!serialized.contains("checks"));
        assert!(calls.lock().unwrap().is_empty());
        assert!(
            strategy_store
                .run_id_by_idempotency_key("assistant-multi-pass-rejected")
                .unwrap()
                .is_none()
        );
        drop(service);
        remove_root(root);
    }

    #[test]
    fn workflow_error_projection_keeps_the_exact_typed_list() {
        let source = json!({
            "schema": "licoup.adaptive-flywheel.workflow.v1",
            "metadata": {"id": "private-workspace-sentinel", "name": 3},
            "initial": false,
            "states": [],
            "transitions": []
        });
        let validation = compile_workflow_value(&source).unwrap_err();
        let expected = serde_json::to_value(&validation.diagnostics).unwrap();
        let error: anyhow::Error = validation.into();
        let projected = error_projection(&error);
        assert_eq!(projected["code"], "workflow_invalid");
        assert_eq!(projected["diagnostics"], expected);
        assert!(
            !serde_json::to_string(&projected)
                .unwrap()
                .contains("private-workspace-sentinel")
        );
    }

    #[test]
    fn assistant_route_revision_change_rejects_before_admission_or_effect() {
        let root = root();
        let (conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let owner_membership_id = conversation_store
            .get(&conversation_id)
            .unwrap()
            .memberships
            .into_iter()
            .find(|membership| membership.principal.kind == PrincipalKind::Human)
            .unwrap()
            .id;
        let authority_calls = Arc::new(Mutex::new(BTreeMap::new()));
        let authority: crate::domain::client_conversation::SharedSnapshotAuthority =
            Arc::new(Mutex::new(Box::new(MutatingProfileAuthority {
                store: conversation_store,
                conversation_id: conversation_id.clone(),
                membership_id: membership_id.clone(),
                owner_membership_id,
                calls: Arc::clone(&authority_calls),
                mutated: false,
            })));
        let strategy_store = StrategyStore::open(&root).unwrap();
        let service = StrategyService::from_parts(
            root.clone(),
            strategy_store.clone(),
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(ActorTurnPort {
            open: Arc::new(|_| panic!("a stale route must reject before registration")),
            run: Arc::new(|_, _| panic!("a stale route must reject before effects")),
            abandon: Arc::new(|_| {}),
        })
        .with_profile_snapshot_authority(authority);

        let response = service
            .execute(json!({
                "action": "strategy.assistant.workflow.execute",
                "conversationId": conversation_id,
                "membershipId": membership_id,
                "workflow": assistant_workflow_json(),
                "bindings": [{
                    "slotId": "subagent-a",
                    "ordinal": 0,
                    "valueId": membership_id,
                    "model": "model-a",
                    "reasoningEffort": "",
                    "revision": 1
                }],
                "input": {"message": "hi"},
                "idempotencyKey": "assistant-stale-route"
            }))
            .unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["accepted"], false);
        assert!(
            response["result"]["error"]["diagnostics"]
                .as_array()
                .unwrap()
                .iter()
                .any(|check| check["code"] == "graph_route_stale")
        );
        assert!(
            strategy_store
                .run_id_by_idempotency_key("assistant-stale-route")
                .unwrap()
                .is_none(),
            "the route revision check precedes durable admission"
        );
        assert_eq!(
            authority_calls.lock().unwrap().clone(),
            BTreeMap::from([("price", 1), ("score", 1), ("skills", 1), ("target", 1),]),
        );
        drop(service);
        remove_root(root);
    }

    #[test]
    fn entry_open_failure_is_a_real_typed_start_failure() {
        let root = root();
        let (_conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let (store, revision) = authorized_entry_store(&root, &membership_id);
        let service = StrategyService::from_parts(
            root.clone(),
            store,
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(ActorTurnPort {
            open: Arc::new(|_| Err(RuntimeAdapterError::ConversationDispatchFailed)),
            run: Arc::new(|_, _| panic!("a failed registration must not run")),
            abandon: Arc::new(|_| {}),
        });

        let response = service
            .execute(json!({
                "action": "strategy.run.start",
                "revisionDigest": revision,
                "input": {"message": "hi"},
                "idempotencyKey": "start-open-failure",
                "conversationId": conversation_id,
            }))
            .unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "strategy_run_start_failed");
        assert_eq!(response["error"]["stage"], "strategy/start");
        drop(service);
        remove_root(root);
    }

    #[test]
    fn drive_reservation_is_atomic_for_one_run() {
        let run_id = format!("run-reservation-{}", uuid::Uuid::new_v4());
        let first = DriveReservation::acquire(&run_id).expect("first reservation");
        assert!(DriveReservation::acquire(&run_id).is_none());
        drop(first);
        assert!(DriveReservation::acquire(&run_id).is_some());
    }

    #[test]
    fn drive_retry_opens_and_runs_a_fresh_turn_inline() {
        let root = root();
        let (_conversation_store, conversation_id, membership_id) =
            conversation_bound_fixture(&root);
        let (store, revision) = authorized_entry_store(&root, &membership_id);
        let calls = Arc::new(Mutex::new(Vec::<(String, Value)>::new()));
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let run_attempts = Arc::clone(&attempts);
        let port = recording_port(Arc::clone(&calls), move |_, _| {
            if run_attempts.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
                Err(RuntimeAdapterError::ConversationDispatchFailed)
            } else {
                Ok(json!({"ok": true, "output": "done"}))
            }
        });
        let service = StrategyService::from_parts(
            root.clone(),
            store.clone(),
            StrategyPackageImporter::open(&root).unwrap(),
        )
        .with_actor_turn_port(port);

        let response = service
            .execute(json!({
                "action": "strategy.run.start",
                "revisionDigest": revision,
                "input": {"message": "hi"},
                "idempotencyKey": "start-2",
                "conversationId": conversation_id,
            }))
            .unwrap();
        assert_eq!(response["ok"], true);
        let run_id = response["result"]["runId"].as_str().unwrap().to_owned();
        let snapshot = wait_for_terminal(&store, &run_id);
        assert_eq!(snapshot.status, StrategyRunStatus::Completed);
        let recorded = calls.lock().unwrap();
        let opens = recorded
            .iter()
            .filter(|(operation, _)| operation == "open")
            .count();
        let runs = recorded
            .iter()
            .filter(|(operation, _)| operation.starts_with("run:"))
            .count();
        assert_eq!(opens, 2, "the retried command opened a fresh turn inline");
        assert_eq!(runs, 2);
        drop(recorded);
        remove_drive_root(root, service);
    }

    #[test]
    fn entry_registration_guard_abandons_only_an_unrun_turn() {
        let abandoned = Arc::new(Mutex::new(Vec::<String>::new()));
        let abandon_calls = Arc::clone(&abandoned);
        let port = Arc::new(ActorTurnPort {
            open: Arc::new(|_| Ok("dispatch:entry".to_owned())),
            run: Arc::new(|_, _| Ok(json!({"ok": true}))),
            abandon: Arc::new(move |handle| {
                abandon_calls.lock().unwrap().push(handle.to_owned());
            }),
        });
        {
            let _guard = EntryTurnRegistration {
                slot_id: "entry".into(),
                handle: "dispatch:entry".into(),
                params: json!({}),
                projection: Value::Null,
                port: Arc::clone(&port),
                armed: true,
            };
        }
        assert_eq!(abandoned.lock().unwrap().as_slice(), ["dispatch:entry"]);
        let guard = EntryTurnRegistration {
            slot_id: "entry".into(),
            handle: "dispatch:entry-2".into(),
            params: json!({}),
            projection: Value::Null,
            port: Arc::clone(&port),
            armed: true,
        };
        let (handle, _) = guard.into_run();
        assert_eq!(handle, "dispatch:entry-2");
        assert_eq!(abandoned.lock().unwrap().len(), 1);
    }
}
