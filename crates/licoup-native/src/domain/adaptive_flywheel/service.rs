use anyhow::{Result, anyhow, ensure};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};

use crate::platform::strategy_runtime::{
    RuntimeCatalog, StrategyEffectPermit, actor_fingerprint, execute_actor, execute_script,
};

use super::{
    BindingKind, CommandKind, CommandStatus, FailureClass, ReducerEvent, StrategyPackageImporter,
    StrategyRunStatus, StrategyStore, builtin_strategy_identity, builtin_strategy_package_bytes,
};

const MAX_PACKAGE_SOURCE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_DRIVE_EFFECTS_PER_CALL: usize = 512;
const BUILTIN_STRATEGY_ID: &str = "licoup-basic";

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
        service.ensure_builtin_strategy()?;
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
            "strategy.definition.list" => {
                let identity = builtin_strategy_identity()?;
                let definitions = self
                    .store
                    .list_definitions()?
                    .into_iter()
                    .filter(|definition| {
                        (definition.definition_id != identity.definition_id
                            && definition.name != identity.name)
                            || definition.revision_digest == identity.revision_digest
                    })
                    .collect::<Vec<_>>();
                Ok(serde_json::to_value(definitions)?)
            }
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
                let snapshot = self.store.start_run(
                    revision,
                    object.get("input").cloned().unwrap_or_else(|| json!({})),
                    required_string(object, "idempotencyKey")?,
                )?;
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

    fn ensure_builtin_strategy(&self) -> Result<()> {
        let identity = builtin_strategy_identity()?;
        ensure!(
            identity.definition_id == BUILTIN_STRATEGY_ID,
            "builtin_strategy_identity_invalid"
        );
        if self
            .store
            .definition_by_revision(&identity.revision_digest)
            .is_ok_and(|definition| {
                definition.summary.definition_id == identity.definition_id
                    && definition.summary.name == identity.name
                    && definition.summary.version == identity.version
                    && definition.summary.semantics_digest == identity.semantics_digest
            })
        {
            return Ok(());
        }
        let bytes = builtin_strategy_package_bytes()?;
        let prepared = self.importer.prepare_bytes(&bytes)?;
        ensure!(
            prepared.definition_id == identity.definition_id
                && prepared.name == identity.name
                && prepared.version == identity.version
                && prepared.revision_digest == identity.revision_digest
                && prepared.semantics_digest == identity.semantics_digest,
            "builtin_strategy_identity_invalid"
        );
        let committed = self
            .importer
            .commit(&prepared.preparation_id, &prepared.revision_digest)?;
        self.store.register_definition(
            &committed.prepared.revision_digest,
            &committed.prepared.semantics_digest,
            &committed.workflow,
            committed.prepared.asset_count,
            committed.prepared.prepared_at_unix_ms,
        )?;
        Ok(())
    }

    fn validate_import_identity(&self, prepared: &super::PreparedPackage) -> Result<()> {
        let identity = builtin_strategy_identity()?;
        if prepared.definition_id == identity.definition_id || prepared.name == identity.name {
            ensure!(
                prepared.definition_id == identity.definition_id
                    && prepared.name == identity.name
                    && prepared.version == identity.version
                    && prepared.revision_digest == identity.revision_digest
                    && prepared.semantics_digest == identity.semantics_digest,
                "workflow_builtin_identity_reserved"
            );
        }
        Ok(())
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
        let identity = builtin_strategy_identity()?;
        if definition.summary.definition_id == identity.definition_id
            || definition.summary.name == identity.name
        {
            ensure!(
                definition.summary.definition_id == identity.definition_id
                    && definition.summary.name == identity.name
                    && definition.summary.version == identity.version
                    && definition.summary.revision_digest == identity.revision_digest
                    && definition.summary.semantics_digest == identity.semantics_digest,
                "workflow_builtin_identity_reserved"
            );
        }
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
                                command_id: command.id,
                                attempt_token: command.attempt_token,
                                output,
                            },
                        )?;
                    }
                    Err(error) => {
                        let (class, code) = classify_effect_error(&error.to_string());
                        self.store.apply_event(
                            run_id,
                            ReducerEvent::CommandFailed {
                                command_id: command.id,
                                attempt_token: command.attempt_token,
                                class,
                                code: code.into(),
                            },
                        )?;
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
                let runtime_id = &binding_for(&definition, requirement_id)?.value_id;
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
}

fn binding_for<'a>(
    definition: &'a super::StrategyDefinition,
    slot: &str,
) -> Result<&'a super::BindingValue> {
    definition
        .bindings
        .iter()
        .find(|binding| binding.slot_id == slot)
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
        "strategy.binding.remove" => &["action", "revisionDigest", "slotId", "expectedRevision"],
        "strategy.authorization.grant" => &[
            "action",
            "revisionDigest",
            "authorizationDigest",
            "confirmed",
        ],
        "strategy.run.start" => &["action", "revisionDigest", "input", "idempotencyKey"],
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
    } else if message.contains("timed_out") || message.contains("dispatch_failed") {
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
    use std::sync::atomic::{AtomicU64, Ordering};

    fn root() -> PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "lico-strategy-service-test-{}",
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn basic_strategy_is_available_when_the_service_opens() {
        let root = root();
        let service = StrategyService::open(&root).unwrap();
        let listed = service
            .execute(json!({"action": "strategy.definition.list"}))
            .unwrap();
        let definitions = listed["result"].as_array().unwrap();
        assert_eq!(definitions.len(), 1);
        assert_eq!(definitions[0]["definitionId"], "licoup-basic");

        let reopened = StrategyService::open(&root).unwrap();
        let relisted = reopened
            .execute(json!({"action": "strategy.definition.list"}))
            .unwrap();
        assert_eq!(relisted["result"].as_array().unwrap().len(), 1);

        let identity = builtin_strategy_identity().unwrap();
        let forged = super::super::PreparedPackage {
            preparation_id: "preparation-forged".into(),
            definition_id: identity.definition_id,
            revision_digest: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
                .into(),
            semantics_digest: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
                .into(),
            name: identity.name,
            version: identity.version,
            asset_count: 1,
            prepared_at_unix_ms: 1,
        };
        assert!(reopened.validate_import_identity(&forged).is_err());

        let _ = fs::remove_dir_all(root);
    }
}
