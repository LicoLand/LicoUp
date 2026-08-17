use anyhow::{Result, anyhow, ensure};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};

use crate::platform::strategy_runtime::{
    RuntimeCatalog, StrategyEffectPermit, actor_fingerprint, admit_strategy_cwd, execute_actor,
    execute_script, predecessor_locator,
};

use super::{
    BindingCandidate, BindingKind, CommandKind, CommandStatus, FailureClass, ReducerEvent,
    StrategyPackageImporter, StrategyRunStatus, StrategyStore,
};

const MAX_PACKAGE_SOURCE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_DRIVE_EFFECTS_PER_CALL: usize = 512;

#[derive(Clone, Debug)]
pub struct StrategyService {
    store: StrategyStore,
    importer: StrategyPackageImporter,
    portable_root: PathBuf,
}

impl StrategyService {
    pub fn open(portable_root: &Path) -> Result<Self> {
        let service = Self {
            store: StrategyStore::open(portable_root)?,
            importer: StrategyPackageImporter::open(portable_root)?,
            portable_root: portable_root.to_path_buf(),
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
        }
    }

    pub fn store(&self) -> &StrategyStore {
        &self.store
    }

    /// Execute one bridge action. Errors are converted to bounded typed facts;
    /// raw paths, process output and adapter errors never cross this boundary.
    pub fn execute(&self, request: Value) -> Result<Value> {
        match self.execute_inner(request) {
            Ok(result) => Ok(json!({"ok": true, "result": result})),
            Err(error) => Ok(json!({"ok": false, "error": error_projection(&error.to_string())})),
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
                let _ = crate::domain::agent_usage::workflow_ledger::begin_strategy_run(&json!({
                    "stateRoot": self.portable_root,
                    "runId": snapshot.run_id,
                    "revisionDigest": revision,
                    "planRevision": 1,
                }));
                self.drive_run(&snapshot.run_id)?;
                Ok(serde_json::to_value(
                    self.store.projection_for_run(&snapshot.run_id)?,
                )?)
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
                let run_id = required_string(object, "runId")?;
                self.admit_run_identity(run_id)?;
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
                self.drive_run(run_id)?;
                Ok(serde_json::to_value(
                    self.store.projection_for_run(run_id)?,
                )?)
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
                Ok(serde_json::to_value(
                    self.store.projection_for_run(run_id)?,
                )?)
            }
            "strategy.run.retry" => {
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
                self.drive_run(run_id)?;
                Ok(serde_json::to_value(
                    self.store.projection_for_run(run_id)?,
                )?)
            }
            _ => Err(anyhow!("unsupported_action")),
        }
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
        self.store.definition_by_revision(revision)?;
        Ok(())
    }

    fn admit_run_identity(&self, run_id: &str) -> Result<()> {
        let snapshot = self.store.run(run_id)?;
        self.admit_revision_identity(&snapshot.definition_digest)
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

    fn drive_run(&self, run_id: &str) -> Result<()> {
        self.recover_expired_commands(run_id)?;
        let mut executed = 0usize;
        while executed < MAX_DRIVE_EFFECTS_PER_CALL {
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
                    now_ms().saturating_add(5 * 60 * 1000),
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
            let outcomes = std::thread::scope(|scope| -> Result<Vec<_>> {
                let (sender, receiver) = std::sync::mpsc::channel();
                let leases = commands
                    .iter()
                    .map(|(command, claimant)| (command.id.clone(), claimant.clone()))
                    .collect::<Vec<_>>();
                for (command, _) in commands {
                    let service = self.clone();
                    let run_id = run_id.to_owned();
                    let sender = sender.clone();
                    scope.spawn(move || {
                        let result = service.execute_command(&run_id, &command);
                        let _ = sender.send((command, result));
                    });
                }
                drop(sender);
                let mut outcomes = Vec::with_capacity(leases.len());
                while outcomes.len() < leases.len() {
                    match receiver.recv_timeout(std::time::Duration::from_secs(30)) {
                        Ok(outcome) => outcomes.push(outcome),
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            let lease_until = now_ms().saturating_add(5 * 60 * 1000);
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
            for (command, result) in outcomes {
                match result {
                    Ok(output) => {
                        self.store.apply_event(
                            run_id,
                            ReducerEvent::CommandSucceeded {
                                command_id: command.id.clone(),
                                attempt_token: command.attempt_token.clone(),
                                output: output.clone(),
                            },
                        )?;
                        let _ = self.project_membership_event(run_id, &command, &output);
                    }
                    Err(error) => {
                        let (class, code) = classify_effect_error(&error.to_string());
                        self.store.apply_event(
                            run_id,
                            ReducerEvent::CommandFailed {
                                command_id: command.id.clone(),
                                attempt_token: command.attempt_token.clone(),
                                class,
                                code: code.into(),
                            },
                        )?;
                        self.recover_failed_effect(run_id, &command, class, code)?;
                    }
                }
            }
        }
        Ok(())
    }

    fn recover_expired_commands(&self, run_id: &str) -> Result<()> {
        while self.store.recover_next_expired_command(run_id)? {}
        Ok(())
    }

    fn execute_command(&self, run_id: &str, command: &super::RunCommand) -> Result<Value> {
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
                let fingerprint = actor_fingerprint(
                    &binding.value_id,
                    &binding.model,
                    &binding.reasoning_effort,
                )?;
                self.store.authorize_effect(
                    run_id,
                    &command.id,
                    &command.attempt_token,
                    &authorization.authorization_digest,
                )?;
                let mut permit = StrategyEffectPermit::issue(
                    &command.id,
                    &authorization.authorization_digest,
                    &fingerprint,
                )?;
                execute_actor(
                    command,
                    &authorization.authorization_digest,
                    binding,
                    &mut permit,
                    snapshot.cwd.as_deref(),
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
            }
            CommandKind::Authorization => Err(anyhow!("authorization_required")),
        }
    }

    fn recover_failed_effect(
        &self,
        run_id: &str,
        command: &super::RunCommand,
        class: FailureClass,
        code: &str,
    ) -> Result<()> {
        if !matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem) {
            return Ok(());
        }
        let snapshot = self.store.run(run_id)?;
        let current = snapshot
            .commands
            .get(&command.id)
            .cloned()
            .ok_or_else(|| anyhow!("strategy_callback_stale"))?;
        if current.status == CommandStatus::Retryable && class == FailureClass::Transient {
            self.store.apply_event(
                run_id,
                ReducerEvent::RetryRequested {
                    command_id: current.id,
                },
            )?;
            return Ok(());
        }
        let Some(slot_id) = current.binding_id.as_deref() else {
            return Ok(());
        };
        let definition = self
            .store
            .definition_by_revision(&snapshot.definition_digest)?;
        let slot = definition
            .workflow
            .actor_slots
            .iter()
            .find(|slot| slot.id == slot_id);
        let quota = class == FailureClass::Permanent && code == "quota_exhausted";
        let transient_exhausted = class == FailureClass::Transient;
        let should_fallback =
            (quota && slot.is_some_and(|slot| slot.fallback.on_quota)) || transient_exhausted;
        if !should_fallback || current.status != CommandStatus::Failed {
            return Ok(());
        }
        let next_ordinal = current.binding_ordinal.saturating_add(1);
        let Some(next) = definition
            .bindings
            .iter()
            .find(|binding| binding.slot_id == slot_id && binding.ordinal == next_ordinal)
        else {
            return Ok(());
        };
        let previous = definition.bindings.iter().find(|binding| {
            binding.slot_id == slot_id && binding.ordinal == current.binding_ordinal
        });
        let mut facts = current.input.clone();
        if let Some(session) = current
            .resume_session_id
            .as_deref()
            .or_else(|| snapshot.actor_sessions.get(slot_id).map(String::as_str))
        {
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
                from_value_id: previous
                    .map(|binding| binding.value_id.clone())
                    .unwrap_or_default(),
                to_value_id: next.value_id.clone(),
                reason: if quota {
                    "quota".into()
                } else {
                    "transient-exhausted".into()
                },
                attempts: current.attempt,
            },
        )?;
        Ok(())
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
            membership.principal.agent_id.as_deref() == Some(binding.value_id.as_str())
                && membership.status == crate::domain::client_conversation::MembershipStatus::Active
        }) else {
            return Ok(());
        };
        let content = output
            .get("output")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| serde_json::to_string(output).unwrap_or_default());
        if content.trim().is_empty() {
            return Ok(());
        }
        store.append_event(
            conversation_id,
            Some(&membership.id),
            crate::domain::client_conversation::EventKind::Message,
            &[crate::domain::client_conversation::NewEventPart {
                id: String::new(),
                kind: crate::domain::client_conversation::EventPartKind::Text,
                content,
            }],
            None,
            Some(run_id),
            true,
        )?;
        Ok(())
    }
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
        "strategy.run.inspect"
        | "strategy.run.resume"
        | "strategy.run.cancel"
        | "strategy.run.retry" => &["action", "runId"],
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

fn error_projection(message: &str) -> Value {
    let (code, stage, component, retryable, recovery) = if message.contains("package_unavailable") {
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
}
