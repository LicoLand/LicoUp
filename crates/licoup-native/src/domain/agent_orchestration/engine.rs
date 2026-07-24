//! Active durable workflow authority used by every local control plane.
use super::reducer::reduce_workflow_event;
use super::store::DurableWorkflowStore;
use super::*;

pub struct ControlPlaneConnection;

pub struct PersistentWorkflowEngine {
    store: DurableWorkflowStore,
    dispatch: Arc<dyn DispatchPort>,
    clock: Arc<dyn Clock>,
    crash: Arc<dyn CrashBoundaryInjector>,
    limits: EngineLimits,
}

impl PersistentWorkflowEngine {
    pub fn open_active(
        store: DurableWorkflowStore,
        dispatch: Arc<dyn DispatchPort>,
        clock: Arc<dyn Clock>,
        crash: Arc<dyn CrashBoundaryInjector>,
        limits: EngineLimits,
    ) -> Result<Self, EngineErrorCode> {
        Ok(Self {
            store,
            dispatch,
            clock,
            crash,
            limits,
        })
    }

    pub fn owner_fence(&self) -> u64 {
        self.store.owner_fence()
    }
    pub fn connect_control_plane(
        &self,
        _: &str,
    ) -> Result<ControlPlaneConnection, EngineErrorCode> {
        Ok(ControlPlaneConnection)
    }

    pub fn register_policy(&self, policy: PolicyDocument) -> Result<String, EngineErrorCode> {
        let compiled = CompiledPolicy::compile(policy).map_err(|_| EngineErrorCode::Compile)?;
        let revision = compiled.revision_digest().to_owned();
        let encoded = serde_json::to_string(compiled.source_policy())?;
        self.store.register_policy(&revision, &encoded)?;
        Ok(revision)
    }

    pub fn activate_policy(&self, revision: &str) -> Result<bool, EngineErrorCode> {
        self.store.activate_policy(revision)
    }

    pub fn registered_policy(
        &self,
        revision: &str,
    ) -> Result<Option<PolicyDocument>, EngineErrorCode> {
        self.store
            .registered_policy(revision)?
            .map(|encoded| serde_json::from_str(&encoded).map_err(Into::into))
            .transpose()
    }

    pub fn policy_is_active(&self, revision: &str) -> Result<bool, EngineErrorCode> {
        self.store.policy_is_active(revision)
    }

    pub fn control_receipt(&self, key: &str) -> Result<Option<(String, String)>, EngineErrorCode> {
        self.store.control_receipt(key)
    }

    pub fn save_control_receipt(
        &self,
        key: &str,
        request_digest: &str,
        receipt: &str,
    ) -> Result<(), EngineErrorCode> {
        self.store
            .save_control_receipt(key, request_digest, receipt)
    }

    pub fn handle(&self, command: WorkflowCommand) -> Result<WorkflowReceipt, EngineErrorCode> {
        if let Some(receipt) = self.store.receipt(command.key())? {
            return Ok(receipt);
        }
        match command {
            WorkflowCommand::Submit {
                idempotency_key,
                workflow_id,
                policy,
                input_artifact,
            } => {
                if self.store.load_snapshot(&workflow_id)?.is_some() {
                    return Err(EngineErrorCode::InvalidCommand);
                }
                if !valid_submit_artifact(&input_artifact) {
                    return Err(EngineErrorCode::InvalidCommand);
                }
                let compiled =
                    CompiledPolicy::compile(policy).map_err(|_| EngineErrorCode::Compile)?;
                let initial = WorkflowSnapshot::initial(&workflow_id, &compiled);
                let events = [WorkflowEvent::Admitted { input_artifact }];
                let admitted = fold(&initial, &events)?;
                let policy_json = serde_json::to_string(compiled.source_policy())?;
                self.store.commit(
                    &workflow_id,
                    &idempotency_key,
                    Some(&policy_json),
                    &initial,
                    &events,
                    &admitted,
                    Some(self.crash.as_ref()),
                )
            }
            WorkflowCommand::Approve {
                idempotency_key,
                workflow_id,
                step_id,
            } => {
                let before = self.workflow(&workflow_id)?;
                if before.state.is_terminal() {
                    return Err(EngineErrorCode::TerminalState);
                }
                let events = [WorkflowEvent::StepApproved { step_id }];
                let after = fold(&before, &events)?;
                self.store.commit(
                    &workflow_id,
                    &idempotency_key,
                    None,
                    &before,
                    &events,
                    &after,
                    None,
                )
            }
            WorkflowCommand::Cancel {
                idempotency_key,
                workflow_id,
            } => {
                let before = self.workflow(&workflow_id)?;
                if before.state.is_terminal() {
                    return Err(EngineErrorCode::TerminalState);
                }
                let events = [WorkflowEvent::WorkflowCancelled {
                    reason_code: "cancelled".into(),
                }];
                let after = fold(&before, &events)?;
                self.store.commit(
                    &workflow_id,
                    &idempotency_key,
                    None,
                    &before,
                    &events,
                    &after,
                    None,
                )
            }
            WorkflowCommand::Tick {
                idempotency_key,
                workflow_id,
            } => {
                let before = self.workflow(&workflow_id)?;
                if before.state.is_terminal() {
                    return Err(EngineErrorCode::TerminalState);
                }
                let expired = before
                    .steps
                    .iter()
                    .find(|s| {
                        s.state.is_active()
                            && s.deadline_ms.is_some_and(|d| d <= self.clock.now_ms())
                    })
                    .map(|s| s.id.clone());
                let Some(step_id) = expired else {
                    return Err(EngineErrorCode::InvalidCommand);
                };
                let events = [
                    WorkflowEvent::StepFailed {
                        step_id,
                        reason_code: "step_timeout".into(),
                    },
                    WorkflowEvent::WorkflowFailed {
                        reason_code: "step_timeout".into(),
                    },
                ];
                let after = fold(&before, &events)?;
                self.store.commit(
                    &workflow_id,
                    &idempotency_key,
                    None,
                    &before,
                    &events,
                    &after,
                    None,
                )
            }
        }
    }

    pub fn drive(
        &self,
        workflow_id: &str,
        idempotency_key: &str,
    ) -> Result<WorkflowReceipt, EngineErrorCode> {
        match self.prepare_external_drive_step(workflow_id, idempotency_key)? {
            ExternalDriveStep::Quiescent(receipt) | ExternalDriveStep::Progressed(receipt) => {
                Ok(receipt)
            }
            ExternalDriveStep::Ready(prepared) => {
                let compiled = self.compiled_policy(workflow_id)?;
                let step = compiled
                    .ordered_steps()
                    .iter()
                    .find(|step| step.id == prepared.step_id)
                    .ok_or(EngineErrorCode::NotFound)?;
                let mut attempt = 1;
                let outcome = loop {
                    let out = self.dispatch.dispatch(prepared.request.clone());
                    if matches!(
                        out,
                        DispatchOutcome::KnownFailure {
                            retryable: true,
                            ..
                        }
                    ) && attempt < prepared.max_attempts
                    {
                        attempt += 1;
                        continue;
                    }
                    break out;
                };
                if self
                    .crash
                    .should_crash(CrashBoundary::AfterExternalDispatchBeforeProof)
                {
                    let before = self.workflow(workflow_id)?;
                    let events = [
                        WorkflowEvent::StepUnknown {
                            step_id: prepared.step_id.clone(),
                            reason_code: "external_outcome_unproven".into(),
                        },
                        WorkflowEvent::WorkflowUnknown {
                            reason_code: "external_outcome_unproven".into(),
                        },
                    ];
                    let after = fold(&before, &events)?;
                    let _ = self.store.commit(
                        workflow_id,
                        idempotency_key,
                        None,
                        &before,
                        &events,
                        &after,
                        None,
                    )?;
                    return Err(EngineErrorCode::CrashInjected);
                }
                self.finish_outcome(
                    workflow_id,
                    idempotency_key,
                    step,
                    &self.workflow(workflow_id)?,
                    outcome,
                )
            }
        }
    }

    /// Advance durable state until an external dispatch is prepared, the
    /// workflow quiesces, or a non-dispatch progress event is committed.
    /// Never calls [`DispatchPort`]; callers must dispatch out of any service
    /// lock and then prove the outcome with [`Self::record_dispatch_outcome`].
    pub fn prepare_external_drive_step(
        &self,
        workflow_id: &str,
        idempotency_key: &str,
    ) -> Result<ExternalDriveStep, EngineErrorCode> {
        if let Some(receipt) = self.store.receipt(idempotency_key)? {
            return Ok(ExternalDriveStep::Quiescent(receipt));
        }
        let before = self.workflow(workflow_id)?;
        if before.state.is_terminal() {
            return Err(EngineErrorCode::TerminalState);
        }
        let compiled = self.compiled_policy(workflow_id)?;
        let Some((position, step_state)) = before
            .steps
            .iter()
            .enumerate()
            .find(|(_, s)| !s.state.is_terminal())
        else {
            let events = [WorkflowEvent::WorkflowCompleted];
            let after = fold(&before, &events)?;
            let receipt = self.store.commit(
                workflow_id,
                idempotency_key,
                None,
                &before,
                &events,
                &after,
                None,
            )?;
            return Ok(ExternalDriveStep::Quiescent(receipt));
        };
        let step = &compiled.ordered_steps()[position];
        if step_state.state == StepState::AwaitingApproval {
            return Err(EngineErrorCode::InvalidCommand);
        }
        if matches!(step.approval, ApprovalRule::Required) && !step_state.approved {
            let events = [WorkflowEvent::ApprovalRequested {
                step_id: step.id.clone(),
            }];
            let after = fold(&before, &events)?;
            let receipt = self.store.commit(
                workflow_id,
                idempotency_key,
                None,
                &before,
                &events,
                &after,
                None,
            )?;
            return Ok(ExternalDriveStep::Quiescent(receipt));
        }
        let matched = matches!(step.condition, Condition::Always);
        if !matched {
            let mut events = vec![WorkflowEvent::ConditionEvaluated {
                step_id: step.id.clone(),
                matched: false,
            }];
            let mut after = fold(&before, &events)?;
            if after.steps.iter().all(|s| s.state.is_terminal()) {
                events.push(WorkflowEvent::WorkflowCompleted);
                after = fold(&before, &events)?;
                let receipt = self.store.commit(
                    workflow_id,
                    idempotency_key,
                    None,
                    &before,
                    &events,
                    &after,
                    None,
                )?;
                return Ok(ExternalDriveStep::Quiescent(receipt));
            }
            let receipt = self.store.commit(
                workflow_id,
                idempotency_key,
                None,
                &before,
                &events,
                &after,
                None,
            )?;
            return Ok(ExternalDriveStep::Progressed(receipt));
        }
        if self
            .crash
            .should_crash(CrashBoundary::BeforeExternalDispatch)
        {
            return Err(EngineErrorCode::CrashInjected);
        }
        let mut dispatch_state = before.clone();
        let condition = WorkflowEvent::ConditionEvaluated {
            step_id: step.id.clone(),
            matched: true,
        };
        dispatch_state = reduce_workflow_event(&dispatch_state, &condition)?;
        let owner_fence = self.owner_fence();
        let started = WorkflowEvent::DispatchStarted {
            step_id: step.id.clone(),
            attempt: step_state.attempts + 1,
            owner_fence,
            absolute_deadline_ms: self.clock.now_ms().saturating_add(step.timeout_ms),
        };
        dispatch_state = reduce_workflow_event(&dispatch_state, &started)?;
        self.store.commit(
            workflow_id,
            &format!("__dispatch__{idempotency_key}"),
            None,
            &before,
            &[condition, started],
            &dispatch_state,
            None,
        )?;
        Ok(ExternalDriveStep::Ready(PreparedExternalDispatch {
            request: self.request(workflow_id, step, &before),
            step_id: step.id.clone(),
            owner_fence,
            max_attempts: step.max_attempts.max(1),
        }))
    }

    pub fn begin_dispatch(
        &self,
        workflow_id: &str,
        idempotency_key: &str,
    ) -> Result<WorkflowReceipt, EngineErrorCode> {
        if let Some(r) = self.store.receipt(idempotency_key)? {
            return Ok(r);
        }
        let before = self.workflow(workflow_id)?;
        let policy = self.compiled_policy(workflow_id)?;
        let (position, state) = before
            .steps
            .iter()
            .enumerate()
            .find(|(_, s)| s.state == StepState::Pending)
            .ok_or(EngineErrorCode::InvalidCommand)?;
        let step = &policy.ordered_steps()[position];
        let events = [
            WorkflowEvent::ConditionEvaluated {
                step_id: step.id.clone(),
                matched: true,
            },
            WorkflowEvent::DispatchStarted {
                step_id: step.id.clone(),
                attempt: state.attempts + 1,
                owner_fence: self.owner_fence(),
                absolute_deadline_ms: self.clock.now_ms() + step.timeout_ms,
            },
        ];
        let after = fold(&before, &events)?;
        self.store.commit(
            workflow_id,
            idempotency_key,
            None,
            &before,
            &events,
            &after,
            None,
        )
    }
    pub fn record_dispatch_outcome(
        &self,
        workflow_id: &str,
        step_id: &str,
        owner_fence: u64,
        outcome: DispatchOutcome,
    ) -> Result<WorkflowReceipt, EngineErrorCode> {
        if owner_fence != self.owner_fence() {
            return Err(EngineErrorCode::StaleFence);
        }
        let before = self.workflow(workflow_id)?;
        let policy = self.compiled_policy(workflow_id)?;
        let step = policy
            .ordered_steps()
            .iter()
            .find(|s| s.id == step_id)
            .ok_or(EngineErrorCode::NotFound)?;
        self.finish_outcome(
            workflow_id,
            &format!("outcome-{step_id}-{owner_fence}"),
            step,
            &before,
            outcome,
        )
    }
    fn finish_outcome(
        &self,
        workflow_id: &str,
        key: &str,
        step: &PolicyStep,
        before: &WorkflowSnapshot,
        outcome: DispatchOutcome,
    ) -> Result<WorkflowReceipt, EngineErrorCode> {
        let mut events = Vec::new();
        match outcome {
            DispatchOutcome::Succeeded { digest, .. }
            | DispatchOutcome::ValidationPassed { digest, .. } => {
                events.push(WorkflowEvent::DispatchProvenSucceeded {
                    step_id: step.id.clone(),
                    artifact_handle: artifact_handle(workflow_id, &step.id, &digest),
                    digest,
                })
            }
            DispatchOutcome::ValidationFailed { reason_code } => {
                events.push(WorkflowEvent::StepFailed {
                    step_id: step.id.clone(),
                    reason_code: reason_code.clone(),
                });
                events.push(WorkflowEvent::WorkflowFailed { reason_code });
            }
            DispatchOutcome::KnownFailure { reason_code, .. } => {
                events.push(WorkflowEvent::StepFailed {
                    step_id: step.id.clone(),
                    reason_code: reason_code.clone(),
                });
                if step.failure_action == FailureAction::Stop {
                    events.push(WorkflowEvent::WorkflowFailed { reason_code });
                }
            }
            DispatchOutcome::Unknown { reason_code } => {
                events.push(WorkflowEvent::StepUnknown {
                    step_id: step.id.clone(),
                    reason_code: reason_code.clone(),
                });
                events.push(WorkflowEvent::WorkflowUnknown { reason_code });
            }
        }
        let mut after = fold(before, &events)?;
        if after.steps.iter().all(|s| s.state.is_terminal()) && !after.state.is_terminal() {
            events.push(WorkflowEvent::WorkflowCompleted);
            after = fold(before, &events)?;
        }
        self.store
            .commit(workflow_id, key, None, before, &events, &after, None)
    }
    fn request(
        &self,
        workflow_id: &str,
        step: &PolicyStep,
        snapshot: &WorkflowSnapshot,
    ) -> DispatchRequest {
        let artifacts = step
            .context_step_ids
            .iter()
            .filter_map(|id| snapshot.step(id).and_then(|s| s.artifact.clone()))
            .collect();
        DispatchRequest {
            workflow_id: workflow_id.into(),
            step_id: step.id.clone(),
            role_id: step.role_id.clone(),
            agent_id: step.agent_id.clone(),
            model_id: step.model_id.clone(),
            reasoning_level: step.reasoning_level,
            purpose: step.purpose,
            validation: step.validation.clone(),
            input_artifact: snapshot.submit_input.clone(),
            predecessor_artifacts: artifacts,
        }
    }
    pub fn workflow(&self, id: &str) -> Result<WorkflowSnapshot, EngineErrorCode> {
        self.store
            .load_snapshot(id)?
            .ok_or(EngineErrorCode::NotFound)
    }
    pub fn compiled_policy(&self, id: &str) -> Result<CompiledPolicy, EngineErrorCode> {
        let json = self
            .store
            .load_policy(id)?
            .ok_or(EngineErrorCode::NotFound)?;
        CompiledPolicy::compile(serde_json::from_str(&json)?).map_err(|_| EngineErrorCode::Compile)
    }
    pub fn persisted_events(&self, id: &str) -> Result<Vec<WorkflowEvent>, EngineErrorCode> {
        self.store.events(id)
    }
    pub fn recover_all(&self) -> Result<Vec<WorkflowSnapshot>, EngineErrorCode> {
        self.store.all_snapshots()
    }
    pub fn terminalize_unproven_active(
        &self,
        workflow_id: &str,
        idempotency_key: &str,
    ) -> Result<Option<WorkflowReceipt>, EngineErrorCode> {
        let before = self.workflow(workflow_id)?;
        let Some(step_id) = before
            .steps
            .iter()
            .find(|step| {
                matches!(
                    step.state,
                    StepState::Dispatching | StepState::Running | StepState::Validating
                )
            })
            .map(|step| step.id.clone())
        else {
            return Ok(None);
        };
        let events = [
            WorkflowEvent::StepUnknown {
                step_id,
                reason_code: "external_outcome_unproven".into(),
            },
            WorkflowEvent::WorkflowUnknown {
                reason_code: "external_outcome_unproven".into(),
            },
        ];
        let after = fold(&before, &events)?;
        self.store
            .commit(
                workflow_id,
                idempotency_key,
                None,
                &before,
                &events,
                &after,
                None,
            )
            .map(Some)
    }
    pub fn recover(&self) -> Result<WorkflowSnapshot, EngineErrorCode> {
        let all = self.recover_all()?;
        if all.len() != 1 {
            return Err(EngineErrorCode::InvalidCommand);
        }
        Ok(all.into_iter().next().unwrap())
    }
    pub fn receipt_for_idempotency_key(
        &self,
        key: &str,
    ) -> Result<Option<WorkflowReceipt>, EngineErrorCode> {
        self.store.receipt(key)
    }
    pub fn events(
        &self,
        id: &str,
        after: u64,
        requested: usize,
    ) -> Result<EventPage, EngineErrorCode> {
        let rows =
            self.store
                .event_rows(id, after, requested.min(self.limits.max_events_per_page))?;
        let next = rows.last().map(|r| r.0).unwrap_or(after);
        Ok(EventPage {
            events: rows
                .into_iter()
                .map(|(cursor, event)| EventRecord { cursor, event })
                .collect(),
            next_cursor: next,
        })
    }
}
fn fold(
    initial: &WorkflowSnapshot,
    events: &[WorkflowEvent],
) -> Result<WorkflowSnapshot, EngineErrorCode> {
    events.iter().try_fold(initial.clone(), |state, event| {
        reduce_workflow_event(&state, event)
    })
}
fn artifact_handle(workflow: &str, step: &str, digest: &str) -> String {
    let bytes = Sha256::digest(format!("{workflow}:{step}:{digest}"));
    format!("artifact-{:x}", bytes)
}
fn valid_submit_artifact(artifact: &ArtifactRef) -> bool {
    valid_opaque_handle(&artifact.opaque_handle) && valid_content_digest(&artifact.digest)
}
fn valid_opaque_handle(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !value.contains('/')
        && !value.contains('\\')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}
fn valid_content_digest(value: &str) -> bool {
    let hex = value.strip_prefix("sha256:").unwrap_or(value);
    hex.len() == 64 && hex.bytes().all(|byte| byte.is_ascii_hexdigit())
}
