use anyhow::{Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

use super::{
    CompiledWorkflow, FailureClass, GraphStateKind, MAX_WORKSET_ITEMS, SessionPolicy,
    StrategyRunStatus,
};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CommandKind {
    Authorization,
    Actor,
    Script,
    WorksetItem,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CommandStatus {
    Pending,
    Claimed,
    Running,
    Succeeded,
    Failed,
    Retryable,
    CancelRequested,
    Cancelled,
    InDoubt,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunCommand {
    pub id: String,
    pub state_id: String,
    #[serde(default = "default_state_visit")]
    pub state_visit: u64,
    pub kind: CommandKind,
    pub status: CommandStatus,
    pub attempt: u8,
    pub attempt_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binding_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    #[serde(default)]
    pub session_policy: SessionPolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_session_id: Option<String>,
    pub input_digest: String,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub input: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_digest: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_class: Option<FailureClass>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_code: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunSnapshot {
    pub run_id: String,
    pub definition_digest: String,
    pub semantics_digest: String,
    pub status: StrategyRunStatus,
    pub sequence: u64,
    pub input: Value,
    pub active_states: BTreeSet<String>,
    pub completed_states: BTreeSet<String>,
    pub state_visits: BTreeMap<String, u64>,
    pub join_arrivals: BTreeMap<String, BTreeSet<String>>,
    #[serde(default)]
    pub actor_sessions: BTreeMap<String, String>,
    pub commands: BTreeMap<String, RunCommand>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diagnostic_code: Option<String>,
}

impl RunSnapshot {
    pub fn empty(
        run_id: impl Into<String>,
        definition_digest: impl Into<String>,
        semantics_digest: impl Into<String>,
    ) -> Self {
        Self {
            run_id: run_id.into(),
            definition_digest: definition_digest.into(),
            semantics_digest: semantics_digest.into(),
            status: StrategyRunStatus::Pending,
            sequence: 0,
            input: Value::Object(Default::default()),
            active_states: BTreeSet::new(),
            completed_states: BTreeSet::new(),
            state_visits: BTreeMap::new(),
            join_arrivals: BTreeMap::new(),
            actor_sessions: BTreeMap::new(),
            commands: BTreeMap::new(),
            diagnostic_code: None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ReducerEvent {
    Start {
        input: Value,
    },
    AuthorizationGranted {
        semantics_digest: String,
    },
    AuthorizationDenied,
    AuthorizationRevoked,
    CommandClaimed {
        command_id: String,
        attempt_token: String,
    },
    CommandStarted {
        command_id: String,
        attempt_token: String,
    },
    CommandSucceeded {
        command_id: String,
        attempt_token: String,
        output: Value,
    },
    CommandFailed {
        command_id: String,
        attempt_token: String,
        class: FailureClass,
        code: String,
    },
    RetryRequested {
        command_id: String,
    },
    CancelRequested,
    CancellationAcknowledged {
        command_id: String,
        attempt_token: String,
    },
    CancellationUnknown {
        command_id: String,
        attempt_token: String,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct ReducerOutput {
    pub snapshot: RunSnapshot,
    pub emitted_commands: Vec<RunCommand>,
    pub applied: bool,
}

pub fn reduce(
    workflow: &CompiledWorkflow,
    previous: &RunSnapshot,
    event: ReducerEvent,
) -> Result<ReducerOutput> {
    let mut machine = Machine {
        workflow,
        snapshot: previous.clone(),
        emitted: Vec::new(),
        automatic: VecDeque::new(),
        applied: true,
    };
    machine.snapshot.sequence = machine
        .snapshot
        .sequence
        .checked_add(1)
        .ok_or_else(|| anyhow!("strategy_event_sequence_overflow"))?;
    match event {
        ReducerEvent::Start { input } => {
            ensure!(
                previous.status == StrategyRunStatus::Pending && previous.sequence == 0,
                "strategy_run_already_started"
            );
            ensure!(
                serde_json::to_vec(&input)?.len() <= 1024 * 1024,
                "strategy_run_input_too_large"
            );
            machine.snapshot.input = input;
            machine.snapshot.status = StrategyRunStatus::Running;
            machine.enter(&workflow.definition.initial, None)?;
        }
        ReducerEvent::AuthorizationGranted { semantics_digest } => {
            ensure!(
                semantics_digest == previous.semantics_digest,
                "strategy_authorization_stale"
            );
            let command_id = machine
                .snapshot
                .commands
                .values()
                .find(|command| {
                    command.kind == CommandKind::Authorization
                        && command.status == CommandStatus::Pending
                })
                .map(|command| command.id.clone())
                .ok_or_else(|| anyhow!("strategy_authorization_not_pending"))?;
            machine.settle_success(&command_id, None, json!({"authorized": true}))?;
        }
        ReducerEvent::AuthorizationDenied => {
            let command_id = pending_authorization(&machine.snapshot)?;
            machine.settle_failure(
                &command_id,
                None,
                FailureClass::Authority,
                "authorization_denied",
            )?;
        }
        ReducerEvent::AuthorizationRevoked => {
            if matches!(
                machine.snapshot.status,
                StrategyRunStatus::Completed
                    | StrategyRunStatus::Cancelled
                    | StrategyRunStatus::Failed
                    | StrategyRunStatus::Blocked
                    | StrategyRunStatus::CancelInDoubt
            ) {
                machine.applied = false;
            } else {
                machine.snapshot.status = StrategyRunStatus::AuthorizationRequired;
                machine.snapshot.diagnostic_code = Some("authorization_revoked".into());
            }
        }
        ReducerEvent::CommandClaimed {
            command_id,
            attempt_token,
        } => machine.transition_command(
            &command_id,
            &attempt_token,
            CommandStatus::Pending,
            CommandStatus::Claimed,
        )?,
        ReducerEvent::CommandStarted {
            command_id,
            attempt_token,
        } => {
            let current = machine
                .snapshot
                .commands
                .get(&command_id)
                .ok_or_else(|| anyhow!("strategy_callback_stale"))?
                .status;
            ensure!(
                matches!(current, CommandStatus::Pending | CommandStatus::Claimed),
                "strategy_callback_conflict"
            );
            machine.transition_command(
                &command_id,
                &attempt_token,
                current,
                CommandStatus::Running,
            )?;
        }
        ReducerEvent::CommandSucceeded {
            command_id,
            attempt_token,
            output,
        } => machine.settle_success(&command_id, Some(&attempt_token), output)?,
        ReducerEvent::CommandFailed {
            command_id,
            attempt_token,
            class,
            code,
        } => machine.settle_failure(&command_id, Some(&attempt_token), class, &code)?,
        ReducerEvent::RetryRequested { command_id } => machine.retry(&command_id)?,
        ReducerEvent::CancelRequested => machine.cancel()?,
        ReducerEvent::CancellationAcknowledged {
            command_id,
            attempt_token,
        } => machine.cancel_acknowledged(&command_id, &attempt_token)?,
        ReducerEvent::CancellationUnknown {
            command_id,
            attempt_token,
        } => machine.cancel_unknown(&command_id, &attempt_token)?,
    }
    machine.drain_automatic()?;
    if !machine.applied {
        machine.snapshot.sequence = previous.sequence;
    }
    Ok(ReducerOutput {
        snapshot: machine.snapshot,
        emitted_commands: machine.emitted,
        applied: machine.applied,
    })
}

struct Machine<'a> {
    workflow: &'a CompiledWorkflow,
    snapshot: RunSnapshot,
    emitted: Vec<RunCommand>,
    automatic: VecDeque<(String, Value)>,
    applied: bool,
}

impl Machine<'_> {
    fn enter(&mut self, state_id: &str, predecessor: Option<&str>) -> Result<()> {
        let state = self
            .workflow
            .state(state_id)
            .ok_or_else(|| anyhow!("strategy_state_unknown"))?
            .clone();
        if state.kind == GraphStateKind::Join {
            if let Some(predecessor) = predecessor {
                self.snapshot
                    .join_arrivals
                    .entry(state.id.clone())
                    .or_default()
                    .insert(predecessor.to_owned());
            }
            if self.snapshot.join_arrivals.get(&state.id)
                != Some(self.workflow.predecessors(&state.id))
            {
                self.snapshot.status = StrategyRunStatus::Waiting;
                return Ok(());
            }
            self.snapshot.join_arrivals.remove(&state.id);
        }
        self.snapshot.completed_states.remove(&state.id);
        self.snapshot.active_states.insert(state.id.clone());
        *self
            .snapshot
            .state_visits
            .entry(state.id.clone())
            .or_default() += 1;
        self.snapshot.status = StrategyRunStatus::Running;
        self.snapshot.diagnostic_code = None;
        match state.kind {
            GraphStateKind::Pass | GraphStateKind::Choice | GraphStateKind::Join => {
                self.automatic
                    .push_back((state.id, self.snapshot.input.clone()));
            }
            GraphStateKind::Fork => self.complete_fork(&state.id)?,
            GraphStateKind::Authorization => {
                self.emit_command(&state.id, CommandKind::Authorization, None, Value::Null)?;
                self.snapshot.status = StrategyRunStatus::AuthorizationRequired;
            }
            GraphStateKind::Actor => {
                let input = self.effect_input(&state.id, self.snapshot.input.clone())?;
                self.emit_command(&state.id, CommandKind::Actor, None, input)?;
            }
            GraphStateKind::Script => {
                self.emit_command(
                    &state.id,
                    CommandKind::Script,
                    None,
                    self.snapshot.input.clone(),
                )?;
            }
            GraphStateKind::Workset => {
                if self.schedule_workset(&state.id)? {
                    self.automatic.push_back((state.id, json!({"empty": true})));
                }
            }
            GraphStateKind::Succeed => {
                self.snapshot.active_states.remove(&state.id);
                self.snapshot.completed_states.insert(state.id);
                self.snapshot.status = StrategyRunStatus::Completed;
            }
            GraphStateKind::Fail => {
                self.snapshot.active_states.remove(&state.id);
                self.snapshot.status = StrategyRunStatus::Failed;
            }
            GraphStateKind::Blocked => {
                self.snapshot.active_states.remove(&state.id);
                self.snapshot.status = StrategyRunStatus::Blocked;
            }
        }
        Ok(())
    }

    fn drain_automatic(&mut self) -> Result<()> {
        let mut remaining = self
            .workflow
            .definition
            .states
            .len()
            .saturating_mul(4)
            .max(16);
        while let Some((state_id, payload)) = self.automatic.pop_front() {
            ensure!(remaining > 0, "strategy_automatic_transition_limit");
            remaining -= 1;
            self.complete_state(&state_id, "complete", &payload)?;
        }
        Ok(())
    }

    fn complete_fork(&mut self, state_id: &str) -> Result<()> {
        self.snapshot.active_states.remove(state_id);
        self.snapshot.completed_states.insert(state_id.to_owned());
        let targets = self
            .workflow
            .transitions(state_id, "complete")
            .map(|transition| transition.to.clone())
            .collect::<Vec<_>>();
        ensure!(targets.len() >= 2, "strategy_fork_invalid");
        for target in targets {
            self.enter(&target, Some(state_id))?;
        }
        Ok(())
    }

    fn complete_state(&mut self, state_id: &str, event: &str, payload: &Value) -> Result<()> {
        self.snapshot.active_states.remove(state_id);
        self.snapshot.completed_states.insert(state_id.to_owned());
        let transition = self
            .workflow
            .select_transition(state_id, event, payload)?
            .ok_or_else(|| anyhow!("strategy_transition_missing"))?;
        let target = transition.to.clone();
        self.enter(&target, Some(state_id))
    }

    fn schedule_workset(&mut self, state_id: &str) -> Result<bool> {
        let state = self.workflow.state(state_id).unwrap();
        let workset_id = state.workset.as_deref().unwrap();
        let items = self
            .snapshot
            .input
            .get("worksets")
            .and_then(|value| value.get(workset_id))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        ensure!(
            items.len() <= self.workflow.definition.limits.max_workset_items as usize
                && items.len() <= MAX_WORKSET_ITEMS,
            "strategy_workset_limit"
        );
        if items.is_empty() {
            return Ok(true);
        }
        let template = self
            .workflow
            .definition
            .worksets
            .iter()
            .find(|template| template.id == workset_id)
            .unwrap();
        let mut seen = BTreeSet::new();
        let mut normalized = Vec::with_capacity(items.len());
        for item in items {
            let item_id = item
                .get(&template.item_binding)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty() && value.len() <= 96)
                .ok_or_else(|| anyhow!("strategy_workset_item_id_invalid"))?;
            ensure!(
                seen.insert(item_id.to_owned()),
                "strategy_workset_item_duplicate"
            );
            let predecessors = if template.predecessor_field.is_empty() {
                BTreeSet::new()
            } else {
                match item.get(&template.predecessor_field) {
                    None | Some(Value::Null) => BTreeSet::new(),
                    Some(Value::Array(values)) => values
                        .iter()
                        .map(|value| {
                            value
                                .as_str()
                                .filter(|value| !value.is_empty() && value.len() <= 96)
                                .map(str::to_owned)
                                .ok_or_else(|| anyhow!("strategy_workset_predecessor_invalid"))
                        })
                        .collect::<Result<BTreeSet<_>>>()?,
                    Some(_) => return Err(anyhow!("strategy_workset_predecessor_invalid")),
                }
            };
            ensure!(
                !predecessors.contains(item_id),
                "strategy_workset_predecessor_invalid"
            );
            normalized.push((item_id.to_owned(), predecessors, item));
        }
        ensure!(
            normalized
                .iter()
                .flat_map(|(_, predecessors, _)| predecessors)
                .all(|predecessor| seen.contains(predecessor)),
            "strategy_workset_predecessor_unknown"
        );
        let mut topological = BTreeSet::new();
        loop {
            let ready = normalized
                .iter()
                .filter(|(id, predecessors, _)| {
                    !topological.contains(id) && predecessors.is_subset(&topological)
                })
                .map(|(id, _, _)| id.clone())
                .collect::<Vec<_>>();
            if ready.is_empty() {
                break;
            }
            topological.extend(ready);
        }
        ensure!(
            topological.len() == normalized.len(),
            "strategy_workset_cycle"
        );

        let succeeded = self
            .snapshot
            .commands
            .values()
            .filter(|command| {
                command.state_id == state_id
                    && command.state_visit == self.snapshot.state_visits[state_id]
                    && command.status == CommandStatus::Succeeded
            })
            .filter_map(|command| command.item_id.clone())
            .collect::<BTreeSet<_>>();
        if succeeded.len() == normalized.len() {
            return Ok(true);
        }
        let issued = self
            .snapshot
            .commands
            .values()
            .filter(|command| {
                command.state_id == state_id
                    && command.state_visit == self.snapshot.state_visits[state_id]
            })
            .filter_map(|command| command.item_id.clone())
            .collect::<BTreeSet<_>>();
        let ready = normalized
            .into_iter()
            .filter(|(id, predecessors, _)| {
                !issued.contains(id) && predecessors.is_subset(&succeeded)
            })
            .collect::<Vec<_>>();
        for (item_id, _, item) in ready {
            let input = self.effect_input(state_id, item)?;
            self.emit_command(state_id, CommandKind::WorksetItem, Some(item_id), input)?;
        }
        Ok(false)
    }

    fn effect_input(&self, state_id: &str, input: Value) -> Result<Value> {
        let state = self.workflow.state(state_id).unwrap();
        if state.instruction.trim().is_empty() {
            return Ok(input);
        }
        let context = serde_json::to_string(&input)?;
        Ok(json!({
            "prompt": format!(
                "{}\n\nState: {}\nInput JSON:\n{}",
                state.instruction, state.id, context
            ),
            "context": input,
        }))
    }

    fn emit_command(
        &mut self,
        state_id: &str,
        kind: CommandKind,
        item_id: Option<String>,
        input: Value,
    ) -> Result<()> {
        let state = self.workflow.state(state_id).unwrap();
        let visit = self.snapshot.state_visits[state_id];
        let input_bytes = serde_json::to_vec(&input)?;
        let input_digest = sha256_hex(&input_bytes);
        let identity = format!(
            "{}\0{}\0{}\0{}\0{}",
            self.snapshot.run_id,
            state_id,
            visit,
            item_id.as_deref().unwrap_or(""),
            1
        );
        let id = format!("command:{}", sha256_hex(identity.as_bytes()));
        let attempt_token = format!(
            "attempt:{}",
            sha256_hex(format!("{}\0{}", id, 1).as_bytes())
        );
        let command = RunCommand {
            id: id.clone(),
            state_id: state_id.to_owned(),
            state_visit: visit,
            kind,
            status: CommandStatus::Pending,
            attempt: 1,
            attempt_token,
            binding_id: state.binding.clone(),
            runtime_id: state.runtime.clone(),
            entry: state.entry.clone(),
            item_id,
            session_policy: state
                .binding
                .as_deref()
                .and_then(|binding| {
                    self.workflow
                        .definition
                        .actor_slots
                        .iter()
                        .find(|slot| slot.id == binding)
                })
                .map_or(SessionPolicy::New, |slot| slot.session_policy),
            resume_session_id: state
                .binding
                .as_ref()
                .and_then(|binding| self.snapshot.actor_sessions.get(binding).cloned()),
            input_digest,
            input,
            output_digest: None,
            failure_class: None,
            failure_code: None,
        };
        ensure!(
            self.snapshot.commands.insert(id, command.clone()).is_none(),
            "strategy_command_identity_conflict"
        );
        self.emitted.push(command);
        Ok(())
    }

    fn transition_command(
        &mut self,
        command_id: &str,
        attempt_token: &str,
        expected: CommandStatus,
        next: CommandStatus,
    ) -> Result<()> {
        let command = self
            .snapshot
            .commands
            .get_mut(command_id)
            .ok_or_else(|| anyhow!("strategy_callback_stale"))?;
        ensure!(
            command.attempt_token == attempt_token,
            "strategy_callback_stale"
        );
        ensure!(command.status == expected, "strategy_callback_conflict");
        command.status = next;
        Ok(())
    }

    fn settle_success(
        &mut self,
        command_id: &str,
        attempt_token: Option<&str>,
        output: Value,
    ) -> Result<()> {
        let output_digest = sha256_hex(&serde_json::to_vec(&output)?);
        let (state_id, binding_id, session_policy, duplicate) = {
            let command = self
                .snapshot
                .commands
                .get_mut(command_id)
                .ok_or_else(|| anyhow!("strategy_callback_stale"))?;
            if let Some(attempt_token) = attempt_token {
                ensure!(
                    command.attempt_token == attempt_token,
                    "strategy_callback_stale"
                );
            }
            if command.status == CommandStatus::Succeeded {
                ensure!(
                    command.output_digest.as_deref() == Some(&output_digest),
                    "strategy_callback_conflict"
                );
                (
                    command.state_id.clone(),
                    command.binding_id.clone(),
                    command.session_policy,
                    true,
                )
            } else {
                ensure!(
                    matches!(
                        command.status,
                        CommandStatus::Pending | CommandStatus::Claimed | CommandStatus::Running
                    ),
                    "strategy_callback_conflict"
                );
                command.status = CommandStatus::Succeeded;
                command.output_digest = Some(output_digest);
                (
                    command.state_id.clone(),
                    command.binding_id.clone(),
                    command.session_policy,
                    false,
                )
            }
        };
        if duplicate {
            self.applied = false;
            return Ok(());
        }
        if session_policy != SessionPolicy::New
            && let (Some(binding_id), Some(session_id)) = (
                binding_id,
                output
                    .get("nativeSessionId")
                    .or_else(|| output.get("sessionId"))
                    .and_then(Value::as_str),
            )
            && !session_id.is_empty()
            && session_id.len() <= 160
            && !session_id.chars().any(char::is_control)
        {
            self.snapshot
                .actor_sessions
                .insert(binding_id, session_id.to_owned());
        }
        let satisfied = if self.workflow.state(&state_id).unwrap().kind == GraphStateKind::Workset {
            self.schedule_workset(&state_id)?
        } else {
            true
        };
        if satisfied {
            self.complete_state(&state_id, "success", &output)?;
        }
        Ok(())
    }

    fn settle_failure(
        &mut self,
        command_id: &str,
        attempt_token: Option<&str>,
        class: FailureClass,
        code: &str,
    ) -> Result<()> {
        ensure!(
            !code.is_empty()
                && code.len() <= 96
                && code.chars().all(|character| {
                    character.is_ascii_lowercase()
                        || character.is_ascii_digit()
                        || matches!(character, '-' | '_')
                }),
            "strategy_failure_code_invalid"
        );
        let (state_id, command_kind, retryable, duplicate) = {
            let command = self
                .snapshot
                .commands
                .get_mut(command_id)
                .ok_or_else(|| anyhow!("strategy_callback_stale"))?;
            if let Some(attempt_token) = attempt_token {
                ensure!(
                    command.attempt_token == attempt_token,
                    "strategy_callback_stale"
                );
            }
            if matches!(
                command.status,
                CommandStatus::Failed | CommandStatus::Retryable
            ) {
                ensure!(
                    command.failure_class == Some(class)
                        && command.failure_code.as_deref() == Some(code),
                    "strategy_callback_conflict"
                );
                (
                    command.state_id.clone(),
                    command.kind,
                    command.status == CommandStatus::Retryable,
                    true,
                )
            } else {
                ensure!(
                    matches!(
                        command.status,
                        CommandStatus::Pending | CommandStatus::Claimed | CommandStatus::Running
                    ),
                    "strategy_callback_conflict"
                );
                command.failure_class = Some(class);
                command.failure_code = Some(code.to_owned());
                let state = self.workflow.state(&command.state_id).unwrap();
                let retryable = command.kind != CommandKind::Authorization
                    && command.attempt < state.retry.max_attempts
                    && match class {
                        FailureClass::Transient
                        | FailureClass::Authority
                        | FailureClass::Runtime
                        | FailureClass::Sandbox => true,
                        FailureClass::Permanent => !state.retry.transient_only,
                        FailureClass::InDoubt => false,
                    };
                command.status = if retryable {
                    CommandStatus::Retryable
                } else if class == FailureClass::InDoubt {
                    CommandStatus::InDoubt
                } else {
                    CommandStatus::Failed
                };
                (command.state_id.clone(), command.kind, retryable, false)
            }
        };
        if duplicate {
            self.applied = false;
            return Ok(());
        }
        self.snapshot.diagnostic_code = Some(code.to_owned());
        if command_kind == CommandKind::Authorization {
            if let Some(transition) =
                self.workflow
                    .select_transition(&state_id, "failure", &json!({"code": code}))?
            {
                let target = transition.to.clone();
                self.snapshot.active_states.remove(&state_id);
                self.enter(&target, Some(&state_id))?;
            } else {
                self.snapshot.status = StrategyRunStatus::Blocked;
            }
            return Ok(());
        }
        match class {
            FailureClass::Transient | FailureClass::Permanent if retryable => {
                self.snapshot.status = StrategyRunStatus::Retryable;
            }
            FailureClass::Authority => {
                self.snapshot.status = StrategyRunStatus::AuthorizationRequired;
            }
            FailureClass::Runtime | FailureClass::Sandbox => {
                self.snapshot.status = StrategyRunStatus::RuntimeMissing
            }
            FailureClass::InDoubt => self.snapshot.status = StrategyRunStatus::CancelInDoubt,
            _ => {
                if let Some(transition) =
                    self.workflow
                        .select_transition(&state_id, "failure", &json!({"code": code}))?
                {
                    let target = transition.to.clone();
                    self.snapshot.active_states.remove(&state_id);
                    self.enter(&target, Some(&state_id))?;
                } else {
                    self.snapshot.status = StrategyRunStatus::Failed;
                }
            }
        }
        Ok(())
    }

    fn retry(&mut self, command_id: &str) -> Result<()> {
        let old = self
            .snapshot
            .commands
            .get(command_id)
            .cloned()
            .ok_or_else(|| anyhow!("strategy_callback_stale"))?;
        ensure!(
            old.status == CommandStatus::Retryable,
            "strategy_run_not_retryable"
        );
        let state = self.workflow.state(&old.state_id).unwrap();
        ensure!(
            old.attempt < state.retry.max_attempts,
            "strategy_run_not_retryable"
        );
        let next_attempt = old.attempt + 1;
        let new_id = format!(
            "command:{}",
            sha256_hex(format!("{}\0{}", old.id, next_attempt).as_bytes())
        );
        let mut command = old;
        command.id = new_id.clone();
        command.status = CommandStatus::Pending;
        command.attempt = next_attempt;
        command.attempt_token = format!(
            "attempt:{}",
            sha256_hex(format!("{}\0{}", new_id, next_attempt).as_bytes())
        );
        command.output_digest = None;
        command.failure_class = None;
        command.failure_code = None;
        self.snapshot.commands.insert(new_id, command.clone());
        self.snapshot.status = StrategyRunStatus::Running;
        self.snapshot.diagnostic_code = None;
        self.emitted.push(command);
        Ok(())
    }

    fn cancel(&mut self) -> Result<()> {
        if matches!(
            self.snapshot.status,
            StrategyRunStatus::Completed | StrategyRunStatus::Cancelled | StrategyRunStatus::Failed
        ) {
            self.applied = false;
            return Ok(());
        }
        let mut in_flight = false;
        for command in self.snapshot.commands.values_mut() {
            match command.status {
                CommandStatus::Pending | CommandStatus::Claimed | CommandStatus::Retryable => {
                    command.status = CommandStatus::Cancelled;
                }
                CommandStatus::Running | CommandStatus::CancelRequested => {
                    command.status = CommandStatus::CancelRequested;
                    in_flight = true;
                }
                _ => {}
            }
        }
        self.snapshot.status = if in_flight {
            StrategyRunStatus::CancelRequested
        } else {
            StrategyRunStatus::Cancelled
        };
        Ok(())
    }

    fn cancel_acknowledged(&mut self, command_id: &str, attempt_token: &str) -> Result<()> {
        self.transition_command(
            command_id,
            attempt_token,
            CommandStatus::CancelRequested,
            CommandStatus::Cancelled,
        )?;
        if self.snapshot.commands.values().all(|command| {
            !matches!(
                command.status,
                CommandStatus::Running | CommandStatus::CancelRequested
            )
        }) {
            self.snapshot.status = StrategyRunStatus::Cancelled;
        }
        Ok(())
    }

    fn cancel_unknown(&mut self, command_id: &str, attempt_token: &str) -> Result<()> {
        self.transition_command(
            command_id,
            attempt_token,
            CommandStatus::CancelRequested,
            CommandStatus::InDoubt,
        )?;
        self.snapshot.status = StrategyRunStatus::CancelInDoubt;
        self.snapshot.diagnostic_code = Some("cancellation_outcome_unknown".into());
        Ok(())
    }
}

fn pending_authorization(snapshot: &RunSnapshot) -> Result<String> {
    snapshot
        .commands
        .values()
        .find(|command| {
            command.kind == CommandKind::Authorization && command.status == CommandStatus::Pending
        })
        .map(|command| command.id.clone())
        .ok_or_else(|| anyhow!("strategy_authorization_not_pending"))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

const fn default_state_visit() -> u64 {
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::adaptive_flywheel::{
        ActorSlot, BindingKind, GraphState, RetryPolicy, SessionPolicy, Transition,
        WorkflowDefinition, WorkflowLimits, WorkflowMetadata, WorksetTemplate, compile_workflow,
    };

    fn state(id: &str, kind: GraphStateKind) -> GraphState {
        GraphState {
            id: id.into(),
            kind,
            label: id.into(),
            instruction: String::new(),
            binding: None,
            runtime: None,
            entry: None,
            workset: None,
            retry: RetryPolicy::default(),
        }
    }

    fn actor_loop() -> CompiledWorkflow {
        compile_workflow(WorkflowDefinition {
            schema: super::super::WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "loop".into(),
                name: "Loop".into(),
                version: "1".into(),
                description: String::new(),
            },
            limits: WorkflowLimits::default(),
            actor_slots: vec![ActorSlot {
                id: "worker".into(),
                kind: BindingKind::Actor,
                label: "Worker".into(),
                required: true,
                session_policy: SessionPolicy::Sticky,
            }],
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
            ],
            transitions: vec![
                Transition {
                    id: "loop-again".into(),
                    from: "work".into(),
                    to: "work".into(),
                    event: "success".into(),
                    guard: Some(super::super::GuardExpression {
                        path: "again".into(),
                        equals: Some(true.into()),
                        exists: false,
                    }),
                },
                Transition {
                    id: "finish".into(),
                    from: "work".into(),
                    to: "done".into(),
                    event: "success".into(),
                    guard: None,
                },
            ],
        })
        .unwrap()
    }

    #[test]
    fn back_edge_is_driven_only_by_matching_callback() {
        let workflow = actor_loop();
        let empty = RunSnapshot::empty("run-1", "revision", "semantics");
        let started = reduce(&workflow, &empty, ReducerEvent::Start { input: json!({}) }).unwrap();
        assert_eq!(started.emitted_commands.len(), 1);
        let command = &started.emitted_commands[0];
        let looped = reduce(
            &workflow,
            &started.snapshot,
            ReducerEvent::CommandSucceeded {
                command_id: command.id.clone(),
                attempt_token: command.attempt_token.clone(),
                output: json!({"again": true, "nativeSessionId": "session-1"}),
            },
        )
        .unwrap();
        assert_eq!(looped.snapshot.status, StrategyRunStatus::Running);
        assert_eq!(looped.emitted_commands.len(), 1);
        assert_ne!(looped.emitted_commands[0].id, command.id);
        assert_eq!(
            looped.emitted_commands[0].resume_session_id.as_deref(),
            Some("session-1")
        );
    }

    #[test]
    fn replay_is_byte_equivalent_and_duplicate_callback_is_idempotent() {
        let workflow = actor_loop();
        let empty = RunSnapshot::empty("run-1", "revision", "semantics");
        let event = ReducerEvent::Start { input: json!({}) };
        let first = reduce(&workflow, &empty, event.clone()).unwrap();
        let replay = reduce(&workflow, &empty, event).unwrap();
        assert_eq!(
            serde_json::to_vec(&first.snapshot).unwrap(),
            serde_json::to_vec(&replay.snapshot).unwrap()
        );
        let command = first.emitted_commands[0].clone();
        let success = ReducerEvent::CommandSucceeded {
            command_id: command.id,
            attempt_token: command.attempt_token,
            output: json!({"again": false}),
        };
        let completed = reduce(&workflow, &first.snapshot, success.clone()).unwrap();
        let duplicate = reduce(&workflow, &completed.snapshot, success).unwrap();
        assert!(!duplicate.applied);
        assert_eq!(duplicate.snapshot, completed.snapshot);
    }

    #[test]
    fn workset_emits_only_the_ready_dag_frontier() {
        let workflow = compile_workflow(WorkflowDefinition {
            schema: super::super::WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "workset".into(),
                name: "Workset".into(),
                version: "1".into(),
                description: String::new(),
            },
            limits: WorkflowLimits::default(),
            actor_slots: vec![ActorSlot {
                id: "worker".into(),
                kind: BindingKind::Actor,
                label: "Worker".into(),
                required: true,
                session_policy: SessionPolicy::New,
            }],
            runtimes: vec![],
            worksets: vec![WorksetTemplate {
                id: "tasks".into(),
                item_binding: "id".into(),
                predecessor_field: "prerequisites".into(),
            }],
            initial: "tasks".into(),
            states: vec![
                GraphState {
                    id: "tasks".into(),
                    kind: GraphStateKind::Workset,
                    label: "Tasks".into(),
                    instruction: "Execute the ready task.".into(),
                    binding: Some("worker".into()),
                    runtime: None,
                    entry: None,
                    workset: Some("tasks".into()),
                    retry: RetryPolicy::default(),
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
            ],
            transitions: vec![Transition {
                id: "done".into(),
                from: "tasks".into(),
                to: "done".into(),
                event: "success".into(),
                guard: None,
            }],
        })
        .unwrap();
        let empty = RunSnapshot::empty("run-1", "revision", "semantics");
        let started = reduce(
            &workflow,
            &empty,
            ReducerEvent::Start {
                input: json!({
                    "worksets": {
                        "tasks": [
                            {"id": "a", "prerequisites": []},
                            {"id": "b", "prerequisites": ["a"]}
                        ]
                    }
                }),
            },
        )
        .unwrap();
        assert_eq!(started.emitted_commands.len(), 1);
        assert_eq!(started.emitted_commands[0].item_id.as_deref(), Some("a"));
        let first = started.emitted_commands[0].clone();
        let second_frontier = reduce(
            &workflow,
            &started.snapshot,
            ReducerEvent::CommandSucceeded {
                command_id: first.id,
                attempt_token: first.attempt_token,
                output: json!({"ok": true}),
            },
        )
        .unwrap();
        assert_eq!(second_frontier.emitted_commands.len(), 1);
        assert_eq!(
            second_frontier.emitted_commands[0].item_id.as_deref(),
            Some("b")
        );
        let second = second_frontier.emitted_commands[0].clone();
        let completed = reduce(
            &workflow,
            &second_frontier.snapshot,
            ReducerEvent::CommandSucceeded {
                command_id: second.id,
                attempt_token: second.attempt_token,
                output: json!({"ok": true}),
            },
        )
        .unwrap();
        assert_eq!(completed.snapshot.status, StrategyRunStatus::Completed);
    }

    #[test]
    fn authorization_denial_uses_the_graph_failure_edge() {
        let workflow = compile_workflow(WorkflowDefinition {
            schema: super::super::WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "authorization".into(),
                name: "Authorization".into(),
                version: "1".into(),
                description: String::new(),
            },
            limits: WorkflowLimits::default(),
            actor_slots: vec![],
            runtimes: vec![],
            worksets: vec![],
            initial: "authorize".into(),
            states: vec![
                state("authorize", GraphStateKind::Authorization),
                state("done", GraphStateKind::Succeed),
                state("blocked", GraphStateKind::Blocked),
            ],
            transitions: vec![
                Transition {
                    id: "granted".into(),
                    from: "authorize".into(),
                    to: "done".into(),
                    event: "success".into(),
                    guard: None,
                },
                Transition {
                    id: "denied".into(),
                    from: "authorize".into(),
                    to: "blocked".into(),
                    event: "failure".into(),
                    guard: None,
                },
            ],
        })
        .unwrap();
        let started = reduce(
            &workflow,
            &RunSnapshot::empty("run", "revision", "semantics"),
            ReducerEvent::Start { input: json!({}) },
        )
        .unwrap();
        let denied = reduce(
            &workflow,
            &started.snapshot,
            ReducerEvent::AuthorizationDenied,
        )
        .unwrap();
        assert_eq!(denied.snapshot.status, StrategyRunStatus::Blocked);
        assert!(denied.snapshot.active_states.is_empty());
    }

    #[test]
    fn workset_back_edge_reissues_items_for_the_new_state_visit() {
        let workflow = compile_workflow(WorkflowDefinition {
            schema: super::super::WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "workset-loop".into(),
                name: "Workset loop".into(),
                version: "1".into(),
                description: String::new(),
            },
            limits: WorkflowLimits::default(),
            actor_slots: vec![ActorSlot {
                id: "worker".into(),
                kind: BindingKind::Actor,
                label: "Worker".into(),
                required: true,
                session_policy: SessionPolicy::New,
            }],
            runtimes: vec![],
            worksets: vec![WorksetTemplate {
                id: "tasks".into(),
                item_binding: "id".into(),
                predecessor_field: String::new(),
            }],
            initial: "tasks".into(),
            states: vec![
                GraphState {
                    id: "tasks".into(),
                    kind: GraphStateKind::Workset,
                    label: "Tasks".into(),
                    instruction: "Execute.".into(),
                    binding: Some("worker".into()),
                    runtime: None,
                    entry: None,
                    workset: Some("tasks".into()),
                    retry: RetryPolicy::default(),
                },
                state("done", GraphStateKind::Succeed),
            ],
            transitions: vec![
                Transition {
                    id: "again".into(),
                    from: "tasks".into(),
                    to: "tasks".into(),
                    event: "success".into(),
                    guard: Some(super::super::GuardExpression {
                        path: "again".into(),
                        equals: Some(true.into()),
                        exists: false,
                    }),
                },
                Transition {
                    id: "done".into(),
                    from: "tasks".into(),
                    to: "done".into(),
                    event: "success".into(),
                    guard: None,
                },
            ],
        })
        .unwrap();
        let started = reduce(
            &workflow,
            &RunSnapshot::empty("run", "revision", "semantics"),
            ReducerEvent::Start {
                input: json!({"worksets": {"tasks": [{"id": "same"}]}}),
            },
        )
        .unwrap();
        let first = &started.emitted_commands[0];
        let looped = reduce(
            &workflow,
            &started.snapshot,
            ReducerEvent::CommandSucceeded {
                command_id: first.id.clone(),
                attempt_token: first.attempt_token.clone(),
                output: json!({"again": true}),
            },
        )
        .unwrap();
        assert_eq!(looped.emitted_commands.len(), 1);
        assert_eq!(looped.emitted_commands[0].item_id.as_deref(), Some("same"));
        assert_eq!(looped.emitted_commands[0].state_visit, 2);
    }
}
