use anyhow::{Result, anyhow, ensure};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

use super::{
    GraphState, GraphStateKind, GuardExpression, MAX_ACTIVE_EFFECTS, MAX_BINDING_SLOTS,
    MAX_GRAPH_STATES, MAX_GRAPH_TRANSITIONS, MAX_RETRY_ATTEMPTS, MAX_RUNTIME_REQUIREMENTS,
    MAX_WORKSET_ITEMS, Transition, WorkflowDefinition,
};

#[derive(Clone, Debug)]
pub struct CompiledWorkflow {
    pub definition: WorkflowDefinition,
    state_indexes: BTreeMap<String, usize>,
    transition_indexes: BTreeMap<(String, String), Vec<usize>>,
    predecessors: BTreeMap<String, BTreeSet<String>>,
    reachable: BTreeSet<String>,
}

impl CompiledWorkflow {
    pub fn state(&self, id: &str) -> Option<&GraphState> {
        self.state_indexes
            .get(id)
            .map(|index| &self.definition.states[*index])
    }

    pub fn transitions(&self, from: &str, event: &str) -> impl Iterator<Item = &Transition> {
        self.transition_indexes
            .get(&(from.to_owned(), event.to_owned()))
            .into_iter()
            .flatten()
            .map(|index| &self.definition.transitions[*index])
    }

    pub fn outgoing(&self, from: &str) -> impl Iterator<Item = &Transition> {
        self.definition
            .transitions
            .iter()
            .filter(move |transition| transition.from == from)
    }

    pub fn predecessors(&self, state: &str) -> &BTreeSet<String> {
        static EMPTY: std::sync::LazyLock<BTreeSet<String>> =
            std::sync::LazyLock::new(BTreeSet::new);
        self.predecessors.get(state).unwrap_or(&EMPTY)
    }

    pub fn reachable(&self) -> &BTreeSet<String> {
        &self.reachable
    }

    pub fn select_transition<'a>(
        &'a self,
        from: &str,
        event: &str,
        payload: &serde_json::Value,
    ) -> Result<Option<&'a Transition>> {
        let candidates = self.transitions(from, event).collect::<Vec<_>>();
        let mut selected = None;
        let mut fallback = None;
        for transition in candidates {
            match &transition.guard {
                Some(guard) if guard_matches(guard, payload) => {
                    ensure!(selected.is_none(), "graph_guard_ambiguous_at_runtime");
                    selected = Some(transition);
                }
                Some(_) => {}
                None => fallback = Some(transition),
            }
        }
        Ok(selected.or(fallback))
    }
}

pub fn compile_workflow(definition: WorkflowDefinition) -> Result<CompiledWorkflow> {
    ensure!(
        definition.has_supported_schema(),
        "workflow_schema_unsupported"
    );
    validate_identifier(&definition.metadata.id, "workflow_metadata_id")?;
    validate_text(&definition.metadata.name, 128, "workflow_metadata_name")?;
    validate_text(
        &definition.metadata.version,
        64,
        "workflow_metadata_version",
    )?;
    ensure!(
        !definition.states.is_empty() && definition.states.len() <= MAX_GRAPH_STATES,
        "workflow_state_limit"
    );
    ensure!(
        !definition.transitions.is_empty() && definition.transitions.len() <= MAX_GRAPH_TRANSITIONS,
        "workflow_transition_limit"
    );
    ensure!(
        definition.actor_slots.len() <= MAX_BINDING_SLOTS,
        "workflow_binding_limit"
    );
    ensure!(
        definition.runtimes.len() <= MAX_RUNTIME_REQUIREMENTS,
        "workflow_runtime_limit"
    );
    ensure!(
        (1..=MAX_ACTIVE_EFFECTS as u8).contains(&definition.limits.max_parallelism),
        "workflow_parallelism_invalid"
    );
    ensure!(
        (1..=MAX_WORKSET_ITEMS as u16).contains(&definition.limits.max_workset_items),
        "workflow_workset_limit_invalid"
    );
    ensure!(
        (1..=MAX_RETRY_ATTEMPTS).contains(&definition.limits.max_attempts),
        "workflow_retry_limit_invalid"
    );

    let actor_slots = unique_ids(
        definition
            .actor_slots
            .iter()
            .map(|slot| (&slot.id, "workflow_binding_id")),
    )?;
    for slot in &definition.actor_slots {
        validate_text(&slot.label, 128, "workflow_binding_label")?;
    }
    let runtimes = unique_ids(
        definition
            .runtimes
            .iter()
            .map(|runtime| (&runtime.id, "workflow_runtime_id")),
    )?;
    let worksets = unique_ids(
        definition
            .worksets
            .iter()
            .map(|workset| (&workset.id, "workflow_workset_id")),
    )?;
    for workset in &definition.worksets {
        validate_identifier(&workset.item_binding, "workflow_workset_item_binding")?;
        if !workset.predecessor_field.is_empty() {
            validate_identifier(
                &workset.predecessor_field,
                "workflow_workset_predecessor_field",
            )?;
        }
    }

    let mut state_indexes = BTreeMap::new();
    for (index, state) in definition.states.iter().enumerate() {
        validate_identifier(&state.id, "workflow_state_id")?;
        validate_text(&state.label, 128, "workflow_state_label")?;
        if !state.instruction.is_empty() {
            validate_text(&state.instruction, 16 * 1024, "workflow_state_instruction")?;
        }
        ensure!(
            state_indexes.insert(state.id.clone(), index).is_none(),
            "workflow_state_duplicate"
        );
        ensure!(
            (1..=MAX_RETRY_ATTEMPTS).contains(&state.retry.max_attempts),
            "workflow_state_retry_invalid"
        );
        match state.kind {
            GraphStateKind::Actor => {
                ensure!(
                    state
                        .binding
                        .as_ref()
                        .is_some_and(|id| actor_slots.contains(id)),
                    "workflow_actor_binding_invalid"
                );
                ensure!(
                    state.runtime.is_none() && state.entry.is_none() && state.workset.is_none(),
                    "workflow_state_field_invalid"
                );
            }
            GraphStateKind::Script => {
                ensure!(
                    state.binding.is_none()
                        && state.workset.is_none()
                        && state.instruction.is_empty(),
                    "workflow_state_field_invalid"
                );
                ensure!(
                    state
                        .runtime
                        .as_ref()
                        .is_some_and(|id| runtimes.contains(id)),
                    "workflow_script_runtime_invalid"
                );
                let entry = state
                    .entry
                    .as_deref()
                    .ok_or_else(|| anyhow!("workflow_script_entry_missing"))?;
                validate_script_entry(entry)?;
            }
            GraphStateKind::Workset => {
                ensure!(
                    state
                        .workset
                        .as_ref()
                        .is_some_and(|id| worksets.contains(id)),
                    "workflow_workset_reference_invalid"
                );
                ensure!(
                    state
                        .binding
                        .as_ref()
                        .is_some_and(|id| actor_slots.contains(id)),
                    "workflow_workset_binding_invalid"
                );
                ensure!(
                    state.runtime.is_none() && state.entry.is_none(),
                    "workflow_state_field_invalid"
                );
            }
            _ => ensure!(
                state.binding.is_none()
                    && state.runtime.is_none()
                    && state.entry.is_none()
                    && state.workset.is_none()
                    && state.instruction.is_empty(),
                "workflow_state_field_invalid"
            ),
        }
    }
    ensure!(
        state_indexes.contains_key(&definition.initial),
        "workflow_initial_unknown"
    );

    let mut transition_ids = BTreeSet::new();
    let mut transition_indexes = BTreeMap::<(String, String), Vec<usize>>::new();
    let mut predecessors = BTreeMap::<String, BTreeSet<String>>::new();
    for (index, transition) in definition.transitions.iter().enumerate() {
        validate_identifier(&transition.id, "workflow_transition_id")?;
        validate_event(&transition.event)?;
        ensure!(
            transition_ids.insert(transition.id.clone()),
            "workflow_transition_duplicate"
        );
        ensure!(
            state_indexes.contains_key(&transition.from)
                && state_indexes.contains_key(&transition.to),
            "workflow_transition_state_unknown"
        );
        if let Some(guard) = &transition.guard {
            validate_guard(guard)?;
        }
        transition_indexes
            .entry((transition.from.clone(), transition.event.clone()))
            .or_default()
            .push(index);
        predecessors
            .entry(transition.to.clone())
            .or_default()
            .insert(transition.from.clone());
    }
    validate_guard_sets(&definition, &transition_indexes)?;
    validate_state_edges(&definition, &transition_indexes, &predecessors)?;

    let reachable = reachable_states(&definition);
    ensure!(
        reachable.len() == definition.states.len(),
        "workflow_state_unreachable"
    );
    ensure!(
        definition.states.iter().any(|state| {
            reachable.contains(&state.id)
                && matches!(
                    state.kind,
                    GraphStateKind::Succeed | GraphStateKind::Fail | GraphStateKind::Blocked
                )
        }),
        "workflow_terminal_unreachable"
    );
    reject_effect_free_cycles(&definition, &state_indexes)?;

    Ok(CompiledWorkflow {
        definition,
        state_indexes,
        transition_indexes,
        predecessors,
        reachable,
    })
}

fn unique_ids<'a>(
    values: impl Iterator<Item = (&'a String, &'static str)>,
) -> Result<BTreeSet<String>> {
    let mut result = BTreeSet::new();
    for (value, label) in values {
        validate_identifier(value, label)?;
        ensure!(
            result.insert(value.clone()),
            "workflow_identifier_duplicate"
        );
    }
    Ok(result)
}

fn validate_state_edges(
    definition: &WorkflowDefinition,
    transitions: &BTreeMap<(String, String), Vec<usize>>,
    predecessors: &BTreeMap<String, BTreeSet<String>>,
) -> Result<()> {
    for state in &definition.states {
        let outgoing = definition
            .transitions
            .iter()
            .filter(|transition| transition.from == state.id)
            .count();
        match state.kind {
            GraphStateKind::Succeed | GraphStateKind::Fail | GraphStateKind::Blocked => {
                ensure!(outgoing == 0, "workflow_terminal_has_outgoing_edge");
            }
            GraphStateKind::Fork => {
                ensure!(
                    transitions
                        .get(&(state.id.clone(), "complete".to_owned()))
                        .is_some_and(|items| items.len() >= 2),
                    "workflow_fork_requires_branches"
                );
            }
            GraphStateKind::Join => ensure!(
                predecessors
                    .get(&state.id)
                    .is_some_and(|items| items.len() >= 2),
                "workflow_join_requires_predecessors"
            ),
            _ => ensure!(outgoing > 0, "workflow_state_has_no_outgoing_edge"),
        }
    }
    Ok(())
}

fn validate_guard_sets(
    definition: &WorkflowDefinition,
    indexes: &BTreeMap<(String, String), Vec<usize>>,
) -> Result<()> {
    for values in indexes.values() {
        let mut fallback = 0usize;
        let mut guards = BTreeSet::new();
        for index in values {
            let transition = &definition.transitions[*index];
            if let Some(guard) = &transition.guard {
                let canonical = serde_json::to_string(guard)?;
                ensure!(guards.insert(canonical), "workflow_guard_duplicate");
            } else {
                fallback += 1;
            }
        }
        ensure!(fallback <= 1, "workflow_guard_ambiguous");
        if values.len() > 1 {
            ensure!(
                values
                    .iter()
                    .any(|index| definition.transitions[*index].guard.is_some()),
                "workflow_transition_ambiguous"
            );
        }
    }
    Ok(())
}

fn reachable_states(definition: &WorkflowDefinition) -> BTreeSet<String> {
    let mut reachable = BTreeSet::new();
    let mut queue = VecDeque::from([definition.initial.clone()]);
    while let Some(state) = queue.pop_front() {
        if !reachable.insert(state.clone()) {
            continue;
        }
        queue.extend(
            definition
                .transitions
                .iter()
                .filter(|transition| transition.from == state)
                .map(|transition| transition.to.clone()),
        );
    }
    reachable
}

fn reject_effect_free_cycles(
    definition: &WorkflowDefinition,
    indexes: &BTreeMap<String, usize>,
) -> Result<()> {
    struct Tarjan<'a> {
        definition: &'a WorkflowDefinition,
        indexes: &'a BTreeMap<String, usize>,
        next: usize,
        stack: Vec<String>,
        on_stack: BTreeSet<String>,
        discovery: BTreeMap<String, usize>,
        low: BTreeMap<String, usize>,
    }

    impl Tarjan<'_> {
        fn visit(&mut self, state: &str) -> Result<()> {
            let position = self.next;
            self.next += 1;
            self.discovery.insert(state.to_owned(), position);
            self.low.insert(state.to_owned(), position);
            self.stack.push(state.to_owned());
            self.on_stack.insert(state.to_owned());

            let targets = self
                .definition
                .transitions
                .iter()
                .filter(|transition| transition.from == state)
                .map(|transition| transition.to.clone())
                .collect::<Vec<_>>();
            for target in targets {
                if !self.discovery.contains_key(&target) {
                    self.visit(&target)?;
                    let target_low = self.low[&target];
                    self.low
                        .entry(state.to_owned())
                        .and_modify(|value| *value = (*value).min(target_low));
                } else if self.on_stack.contains(&target) {
                    let target_position = self.discovery[&target];
                    self.low
                        .entry(state.to_owned())
                        .and_modify(|value| *value = (*value).min(target_position));
                }
            }
            if self.low[state] != self.discovery[state] {
                return Ok(());
            }
            let mut component = Vec::new();
            loop {
                let member = self
                    .stack
                    .pop()
                    .ok_or_else(|| anyhow!("workflow_cycle_analysis_failed"))?;
                self.on_stack.remove(&member);
                component.push(member.clone());
                if member == state {
                    break;
                }
            }
            let self_loop = component.len() == 1
                && self.definition.transitions.iter().any(|transition| {
                    transition.from == component[0] && transition.to == component[0]
                });
            if component.len() > 1 || self_loop {
                let has_effect = component.iter().any(|id| {
                    matches!(
                        self.definition.states[self.indexes[id]].kind,
                        GraphStateKind::Authorization
                            | GraphStateKind::Actor
                            | GraphStateKind::Script
                            | GraphStateKind::Workset
                    )
                });
                ensure!(has_effect, "workflow_effect_free_cycle");
            }
            Ok(())
        }
    }

    let mut tarjan = Tarjan {
        definition,
        indexes,
        next: 0,
        stack: Vec::new(),
        on_stack: BTreeSet::new(),
        discovery: BTreeMap::new(),
        low: BTreeMap::new(),
    };
    for state in &definition.states {
        if !tarjan.discovery.contains_key(&state.id) {
            tarjan.visit(&state.id)?;
        }
    }
    Ok(())
}

fn guard_matches(guard: &GuardExpression, payload: &serde_json::Value) -> bool {
    let value = guard
        .path
        .split('.')
        .filter(|part| !part.is_empty())
        .try_fold(payload, |value, part| value.get(part));
    if guard.exists && value.is_none() {
        return false;
    }
    guard
        .equals
        .as_ref()
        .is_none_or(|expected| value == Some(expected))
}

fn validate_guard(guard: &GuardExpression) -> Result<()> {
    ensure!(
        !guard.path.is_empty()
            && guard.path.len() <= 256
            && guard.path.split('.').all(is_identifier),
        "workflow_guard_path_invalid"
    );
    ensure!(
        guard.exists || guard.equals.is_some(),
        "workflow_guard_operation_missing"
    );
    if let Some(value) = &guard.equals {
        ensure!(
            serde_json::to_vec(value)?.len() <= 4 * 1024,
            "workflow_guard_value_too_large"
        );
    }
    Ok(())
}

fn validate_script_entry(value: &str) -> Result<()> {
    ensure!(
        value.starts_with("scripts/")
            && value.len() <= 240
            && !value.contains('\\')
            && !value.contains('\0')
            && value
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != ".."),
        "workflow_script_entry_invalid"
    );
    Ok(())
}

fn validate_event(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 64
            && value.chars().all(|character| character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || character == '-'),
        "workflow_transition_event_invalid"
    );
    Ok(())
}

fn validate_identifier(value: &str, label: &str) -> Result<()> {
    ensure!(is_identifier(value), "{label}_invalid");
    Ok(())
}

fn is_identifier(value: &str) -> bool {
    let mut characters = value.chars();
    characters
        .next()
        .is_some_and(|first| first.is_ascii_lowercase())
        && value.len() <= 96
        && characters.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '-' | '_' | '.')
        })
}

fn validate_text(value: &str, max: usize, label: &str) -> Result<()> {
    ensure!(
        value == value.trim()
            && !value.is_empty()
            && value.len() <= max
            && !value.chars().any(char::is_control),
        "{label}_invalid"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::adaptive_flywheel::{RetryPolicy, WorkflowLimits, WorkflowMetadata};

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

    fn workflow(states: Vec<GraphState>, transitions: Vec<Transition>) -> WorkflowDefinition {
        WorkflowDefinition {
            schema: super::super::WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "test.workflow".into(),
                name: "Test".into(),
                version: "1".into(),
                description: String::new(),
            },
            limits: WorkflowLimits::default(),
            actor_slots: vec![],
            runtimes: vec![],
            worksets: vec![],
            initial: states[0].id.clone(),
            states,
            transitions,
        }
    }

    #[test]
    fn compiles_pipeline_in_linear_time_indexes() {
        let compiled = compile_workflow(workflow(
            vec![
                state("start", GraphStateKind::Pass),
                state("done", GraphStateKind::Succeed),
            ],
            vec![Transition {
                id: "finish".into(),
                from: "start".into(),
                to: "done".into(),
                event: "complete".into(),
                guard: None,
            }],
        ))
        .unwrap();
        assert_eq!(compiled.reachable().len(), 2);
        assert_eq!(compiled.transitions("start", "complete").count(), 1);
    }

    #[test]
    fn rejects_effect_free_cycle() {
        let result = compile_workflow(workflow(
            vec![
                state("first", GraphStateKind::Pass),
                state("second", GraphStateKind::Pass),
                state("done", GraphStateKind::Succeed),
            ],
            vec![
                Transition {
                    id: "a".into(),
                    from: "first".into(),
                    to: "second".into(),
                    event: "complete".into(),
                    guard: None,
                },
                Transition {
                    id: "b".into(),
                    from: "second".into(),
                    to: "first".into(),
                    event: "complete".into(),
                    guard: Some(GuardExpression {
                        path: "loop".into(),
                        equals: Some(true.into()),
                        exists: false,
                    }),
                },
                Transition {
                    id: "c".into(),
                    from: "second".into(),
                    to: "done".into(),
                    event: "complete".into(),
                    guard: None,
                },
            ],
        ));
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("effect_free_cycle")
        );
    }
}
