use anyhow::{Result, anyhow, ensure};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

use super::{
    BindingKind, GraphState, GraphStateKind, GuardExpression, MAX_ACTIVE_EFFECTS,
    MAX_BINDING_SLOTS, MAX_GRAPH_STATES, MAX_GRAPH_TRANSITIONS, MAX_RETRY_ATTEMPTS,
    MAX_RUNTIME_REQUIREMENTS, MAX_WORKSET_ITEMS, Transition, TransitionEvent, WorkflowDefinition,
};

#[derive(Clone, Debug)]
pub struct CompiledWorkflow {
    pub definition: WorkflowDefinition,
    state_indexes: BTreeMap<String, usize>,
    transition_indexes: BTreeMap<(String, TransitionEvent), Vec<usize>>,
    outgoing_indexes: BTreeMap<String, Vec<usize>>,
    predecessors: BTreeMap<String, BTreeSet<String>>,
    reachable: BTreeSet<String>,
}

impl CompiledWorkflow {
    pub fn state(&self, id: &str) -> Option<&GraphState> {
        self.state_indexes
            .get(id)
            .map(|index| &self.definition.states[*index])
    }

    pub fn transitions(
        &self,
        from: &str,
        event: TransitionEvent,
    ) -> impl Iterator<Item = &Transition> {
        self.transition_indexes
            .get(&(from.to_owned(), event))
            .into_iter()
            .flatten()
            .map(|index| &self.definition.transitions[*index])
    }

    pub fn outgoing(&self, from: &str) -> impl Iterator<Item = &Transition> {
        self.outgoing_indexes
            .get(from)
            .into_iter()
            .flatten()
            .map(|index| &self.definition.transitions[*index])
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
        event: TransitionEvent,
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
    compile_workflow_inner(definition, false)
}

pub fn compile_persisted_workflow(definition: WorkflowDefinition) -> Result<CompiledWorkflow> {
    compile_workflow_inner(definition, true)
}

fn compile_workflow_inner(
    mut definition: WorkflowDefinition,
    fill_legacy_effect_routing: bool,
) -> Result<CompiledWorkflow> {
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

    unique_ids(
        definition
            .actor_slots
            .iter()
            .map(|slot| (&slot.id, "workflow_binding_id")),
    )?;
    for slot in &definition.actor_slots {
        validate_text(&slot.label, 128, "workflow_binding_label")?;
        ensure!(
            (1..=MAX_RETRY_ATTEMPTS).contains(&slot.fallback.after_transient_attempts),
            "workflow_fallback_invalid"
        );
        if slot.kind != BindingKind::Actor {
            ensure!(!slot.entry, "workflow_entry_slot_invalid");
        }
    }
    if !definition
        .actor_slots
        .iter()
        .any(|slot| slot.kind == BindingKind::Actor && slot.entry)
        && let Some(slot) = definition
            .actor_slots
            .iter_mut()
            .find(|slot| slot.kind == BindingKind::Actor)
    {
        // Definitions created before entry-slot metadata existed used the
        // first actor as the main agent. Normalize that legacy shape once so
        // persisted workflows keep compiling deterministically.
        slot.entry = true;
    }
    let binding_slots = definition
        .actor_slots
        .iter()
        .map(|slot| (slot.id.as_str(), slot))
        .collect::<BTreeMap<_, _>>();
    let actor_entries = definition
        .actor_slots
        .iter()
        .filter(|slot| slot.kind == BindingKind::Actor && slot.entry)
        .count();
    let actor_count = definition
        .actor_slots
        .iter()
        .filter(|slot| slot.kind == BindingKind::Actor)
        .count();
    ensure!(
        actor_count == 0 || actor_entries == 1,
        "workflow_entry_slot_invalid"
    );
    let runtimes = unique_ids(
        definition
            .runtimes
            .iter()
            .map(|runtime| (&runtime.id, "workflow_runtime_id")),
    )?;
    for runtime in &definition.runtimes {
        ensure!(
            binding_slots
                .get(runtime.id.as_str())
                .is_some_and(|slot| { slot.kind == BindingKind::Runtime && slot.required }),
            "workflow_runtime_binding_invalid"
        );
    }
    for slot in definition
        .actor_slots
        .iter()
        .filter(|slot| slot.kind == BindingKind::Runtime)
    {
        ensure!(
            runtimes.contains(&slot.id),
            "workflow_runtime_binding_invalid"
        );
    }
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
            ensure!(
                workset.predecessor_field != workset.item_binding,
                "workflow_workset_field_conflict"
            );
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
                    state.binding.as_ref().is_some_and(|id| binding_slots
                        .get(id.as_str())
                        .is_some_and(|slot| { slot.kind == BindingKind::Actor && slot.required })),
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
                    state.binding.as_ref().is_some_and(|id| binding_slots
                        .get(id.as_str())
                        .is_some_and(|slot| { slot.kind == BindingKind::Actor && slot.required })),
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
    if fill_legacy_effect_routing {
        normalize_legacy_effect_routing(&mut definition, &mut state_indexes)?;
        ensure!(
            definition.states.len() <= MAX_GRAPH_STATES,
            "workflow_state_limit"
        );
        ensure!(
            definition.transitions.len() <= MAX_GRAPH_TRANSITIONS,
            "workflow_transition_limit"
        );
    }

    let mut transition_ids = BTreeSet::new();
    let mut transition_indexes = BTreeMap::<(String, TransitionEvent), Vec<usize>>::new();
    let mut outgoing_indexes = BTreeMap::<String, Vec<usize>>::new();
    let mut predecessors = BTreeMap::<String, BTreeSet<String>>::new();
    for (index, transition) in definition.transitions.iter().enumerate() {
        validate_identifier(&transition.id, "workflow_transition_id")?;
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
            .entry((transition.from.clone(), transition.event))
            .or_default()
            .push(index);
        outgoing_indexes
            .entry(transition.from.clone())
            .or_default()
            .push(index);
        predecessors
            .entry(transition.to.clone())
            .or_default()
            .insert(transition.from.clone());
    }
    validate_guard_sets(&definition, &state_indexes, &transition_indexes)?;
    validate_state_edges(&definition, &transition_indexes, &outgoing_indexes)?;
    let parallel_joins = validate_parallel_regions(
        &definition,
        &state_indexes,
        &transition_indexes,
        &outgoing_indexes,
        &predecessors,
    )?;
    for state in definition
        .states
        .iter()
        .filter(|state| state.kind == GraphStateKind::Join)
    {
        let predecessor_count = predecessors.get(&state.id).map_or(0, BTreeSet::len);
        ensure!(
            predecessor_count == 1 || parallel_joins.contains(&state.id),
            "workflow_join_topology_invalid"
        );
    }

    let reachable = reachable_states(&definition, &outgoing_indexes);
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
    reject_effect_free_cycles(&definition, &state_indexes, &outgoing_indexes)?;

    Ok(CompiledWorkflow {
        definition,
        state_indexes,
        transition_indexes,
        outgoing_indexes,
        predecessors,
        reachable,
    })
}

fn is_effect_state(kind: GraphStateKind) -> bool {
    matches!(
        kind,
        GraphStateKind::Authorization
            | GraphStateKind::Actor
            | GraphStateKind::Script
            | GraphStateKind::Workset
    )
}

fn normalize_legacy_effect_routing(
    definition: &mut WorkflowDefinition,
    state_indexes: &mut BTreeMap<String, usize>,
) -> Result<()> {
    let effect_ids = definition
        .states
        .iter()
        .filter(|state| is_effect_state(state.kind))
        .map(|state| state.id.clone())
        .collect::<BTreeSet<_>>();
    if effect_ids.is_empty() {
        return Ok(());
    }

    let mut has_success = BTreeSet::new();
    let mut has_failure = BTreeSet::new();
    for transition in &definition.transitions {
        if !effect_ids.contains(&transition.from) {
            continue;
        }
        match transition.event {
            TransitionEvent::Success => {
                has_success.insert(transition.from.clone());
            }
            TransitionEvent::Failure => {
                has_failure.insert(transition.from.clone());
            }
            TransitionEvent::Complete => {}
        }
    }
    for transition in &mut definition.transitions {
        if !effect_ids.contains(&transition.from) || transition.event != TransitionEvent::Complete {
            continue;
        }
        // Older graphs used Complete on actor/authorization states.
        // Keep one Success path; reuse extra Complete edges as Failure.
        if !has_success.contains(&transition.from) {
            transition.event = TransitionEvent::Success;
            has_success.insert(transition.from.clone());
        } else if !has_failure.contains(&transition.from) {
            transition.event = TransitionEvent::Failure;
            has_failure.insert(transition.from.clone());
        }
    }
    definition.transitions.retain(|transition| {
        !(effect_ids.contains(&transition.from) && transition.event == TransitionEvent::Complete)
    });
    let missing_failure = effect_ids
        .iter()
        .filter(|id| has_success.contains(*id) && !has_failure.contains(*id))
        .cloned()
        .collect::<Vec<_>>();
    if missing_failure.is_empty() {
        return Ok(());
    }

    let terminal_id = if let Some(state) = definition
        .states
        .iter()
        .find(|state| matches!(state.kind, GraphStateKind::Blocked | GraphStateKind::Fail))
    {
        state.id.clone()
    } else {
        let mut terminal_id = "blocked".to_owned();
        let mut suffix = 0u32;
        while state_indexes.contains_key(&terminal_id) {
            suffix += 1;
            terminal_id = format!("blocked-{suffix}");
        }
        validate_identifier(&terminal_id, "workflow_state_id")?;
        definition.states.push(GraphState {
            id: terminal_id.clone(),
            kind: GraphStateKind::Blocked,
            label: "Blocked".into(),
            instruction: String::new(),
            binding: None,
            runtime: None,
            entry: None,
            workset: None,
            retry: Default::default(),
        });
        ensure!(
            state_indexes
                .insert(terminal_id.clone(), definition.states.len() - 1)
                .is_none(),
            "workflow_state_duplicate"
        );
        terminal_id
    };

    let mut transition_ids = definition
        .transitions
        .iter()
        .map(|transition| transition.id.clone())
        .collect::<BTreeSet<_>>();
    for state_id in missing_failure {
        let mut transition_id = format!("{state_id}-legacy-failure");
        let mut suffix = 0u32;
        while transition_ids.contains(&transition_id) {
            suffix += 1;
            transition_id = format!("{state_id}-legacy-failure-{suffix}");
        }
        validate_identifier(&transition_id, "workflow_transition_id")?;
        transition_ids.insert(transition_id.clone());
        definition.transitions.push(Transition {
            id: transition_id,
            from: state_id,
            to: terminal_id.clone(),
            event: TransitionEvent::Failure,
            guard: None,
        });
    }
    Ok(())
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
    transitions: &BTreeMap<(String, TransitionEvent), Vec<usize>>,
    outgoing_indexes: &BTreeMap<String, Vec<usize>>,
) -> Result<()> {
    for state in &definition.states {
        let outgoing = outgoing_indexes
            .get(&state.id)
            .into_iter()
            .flatten()
            .map(|index| &definition.transitions[*index])
            .collect::<Vec<_>>();
        let success = transitions
            .get(&(state.id.clone(), TransitionEvent::Success))
            .map(Vec::len)
            .unwrap_or(0);
        let failure = transitions
            .get(&(state.id.clone(), TransitionEvent::Failure))
            .map(Vec::len)
            .unwrap_or(0);
        match state.kind {
            GraphStateKind::Succeed | GraphStateKind::Fail | GraphStateKind::Blocked => {
                ensure!(outgoing.is_empty(), "workflow_terminal_has_outgoing_edge");
            }
            GraphStateKind::Pass | GraphStateKind::Join => ensure!(
                outgoing.len() == 1
                    && outgoing[0].event == TransitionEvent::Complete
                    && outgoing[0].guard.is_none(),
                "workflow_automatic_transition_invalid"
            ),
            GraphStateKind::Choice => {
                ensure!(
                    !outgoing.is_empty()
                        && outgoing
                            .iter()
                            .all(|transition| transition.event == TransitionEvent::Complete),
                    "workflow_choice_transition_invalid"
                );
                ensure!(
                    outgoing.iter().any(|transition| transition.guard.is_none()),
                    "workflow_choice_requires_fallback"
                );
            }
            GraphStateKind::Fork => {
                let branches = transitions
                    .get(&(state.id.clone(), TransitionEvent::Complete))
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                ensure!(
                    branches.len() >= 2
                        && branches
                            .iter()
                            .all(|index| definition.transitions[*index].guard.is_none()),
                    "workflow_fork_requires_branches"
                );
                ensure!(
                    branches
                        .iter()
                        .map(|index| definition.transitions[*index].to.as_str())
                        .collect::<BTreeSet<_>>()
                        .len()
                        == branches.len(),
                    "workflow_fork_branch_duplicate"
                );
                ensure!(
                    outgoing
                        .iter()
                        .all(|transition| transition.event == TransitionEvent::Complete),
                    "workflow_fork_requires_branches"
                );
            }
            GraphStateKind::Authorization
            | GraphStateKind::Actor
            | GraphStateKind::Script
            | GraphStateKind::Workset => {
                ensure!(
                    success > 0
                        && failure > 0
                        && outgoing.iter().all(|transition| {
                            matches!(
                                transition.event,
                                TransitionEvent::Success | TransitionEvent::Failure
                            )
                        }),
                    format!("workflow_effect_routing_incomplete:{}", state.id)
                );
            }
        }
    }
    Ok(())
}

fn validate_guard_sets(
    definition: &WorkflowDefinition,
    state_indexes: &BTreeMap<String, usize>,
    indexes: &BTreeMap<(String, TransitionEvent), Vec<usize>>,
) -> Result<()> {
    for ((from, event), values) in indexes {
        let is_fork_fanout = *event == TransitionEvent::Complete
            && state_indexes
                .get(from)
                .is_some_and(|index| definition.states[*index].kind == GraphStateKind::Fork);
        if is_fork_fanout {
            continue;
        }
        let mut fallback = 0usize;
        let mut guard_paths = BTreeMap::<String, BTreeSet<String>>::new();
        for index in values {
            let transition = &definition.transitions[*index];
            if let Some(guard) = &transition.guard {
                let canonical = serde_json::to_string(guard)?;
                ensure!(
                    guard_paths
                        .entry(guard.path.clone())
                        .or_default()
                        .insert(canonical),
                    "workflow_guard_duplicate"
                );
            } else {
                fallback += 1;
            }
        }
        ensure!(fallback <= 1, "workflow_guard_ambiguous");
        let guard_count = guard_paths.values().map(BTreeSet::len).sum::<usize>();
        ensure!(
            guard_count == 0 || fallback == 1,
            "workflow_guard_ambiguous"
        );
        if guard_count > 1 {
            ensure!(
                guard_paths.len() == 1
                    && guard_paths
                        .values()
                        .next()
                        .is_some_and(|canonicals| { canonicals.len() == guard_count })
                    && values
                        .iter()
                        .filter(|index| definition.transitions[**index].guard.is_some())
                        .all(|index| {
                            definition.transitions[*index]
                                .guard
                                .as_ref()
                                .is_some_and(|guard| guard.equals.is_some() && !guard.exists)
                        }),
                "workflow_guard_partition_invalid"
            );
        }
        ensure!(
            guard_count > 0 || values.len() <= 1,
            "workflow_transition_ambiguous"
        );
    }
    Ok(())
}

fn validate_parallel_regions(
    definition: &WorkflowDefinition,
    state_indexes: &BTreeMap<String, usize>,
    transitions: &BTreeMap<(String, TransitionEvent), Vec<usize>>,
    outgoing_indexes: &BTreeMap<String, Vec<usize>>,
    predecessors: &BTreeMap<String, BTreeSet<String>>,
) -> Result<BTreeSet<String>> {
    let mut matched_joins = BTreeSet::new();
    for fork in definition
        .states
        .iter()
        .filter(|state| state.kind == GraphStateKind::Fork)
    {
        let Some(branch_indexes) = transitions.get(&(fork.id.clone(), TransitionEvent::Complete))
        else {
            continue;
        };
        let mut join_id: Option<String> = None;
        let mut covered = BTreeSet::new();
        let mut exits = BTreeSet::new();
        for branch_index in branch_indexes {
            let start = definition.transitions[*branch_index].to.clone();
            let mut branch = BTreeSet::new();
            let mut branch_exits = BTreeSet::new();
            let mut queue = VecDeque::from([start.clone()]);
            while let Some(node) = queue.pop_front() {
                if !branch.insert(node.clone()) {
                    continue;
                }
                let state = &definition.states[*state_indexes
                    .get(&node)
                    .ok_or_else(|| anyhow!("workflow_state_unknown"))?];
                match state.kind {
                    GraphStateKind::Fork
                    | GraphStateKind::Succeed
                    | GraphStateKind::Fail
                    | GraphStateKind::Blocked => {
                        return Err(anyhow!("workflow_parallel_region_invalid"));
                    }
                    GraphStateKind::Join => {
                        if let Some(expected) = &join_id {
                            ensure!(expected == &node, "workflow_parallel_region_invalid");
                        } else {
                            join_id = Some(node.clone());
                        }
                        continue;
                    }
                    _ => {}
                }
                ensure!(!covered.contains(&node), "workflow_parallel_region_invalid");
                for transition_index in outgoing_indexes.get(&node).into_iter().flatten() {
                    let transition = &definition.transitions[*transition_index];
                    let target_state = &definition.states[*state_indexes
                        .get(&transition.to)
                        .ok_or_else(|| anyhow!("workflow_state_unknown"))?];
                    match target_state.kind {
                        GraphStateKind::Fork
                        | GraphStateKind::Succeed
                        | GraphStateKind::Fail
                        | GraphStateKind::Blocked => {
                            return Err(anyhow!("workflow_parallel_region_invalid"));
                        }
                        GraphStateKind::Join => {
                            if let Some(expected) = &join_id {
                                ensure!(
                                    expected == &transition.to,
                                    "workflow_parallel_region_invalid"
                                );
                            } else {
                                join_id = Some(transition.to.clone());
                            }
                            exits.insert(node.clone());
                            branch_exits.insert(node.clone());
                        }
                        _ => queue.push_back(transition.to.clone()),
                    }
                }
            }
            ensure!(!branch.is_empty(), "workflow_parallel_region_invalid");
            ensure!(branch_exits.len() == 1, "workflow_parallel_region_invalid");
            if branch_has_cycle(definition, outgoing_indexes, &branch) {
                return Err(anyhow!("workflow_parallel_region_invalid"));
            }
            for node in &branch {
                if node == &start || Some(node) == join_id.as_ref() {
                    continue;
                }
                let entering = predecessors.get(node).cloned().unwrap_or_default();
                ensure!(
                    entering.iter().all(|from| branch.contains(from)),
                    "workflow_parallel_region_invalid"
                );
            }
            let start_entering = predecessors.get(&start).cloned().unwrap_or_default();
            ensure!(
                start_entering.len() == 1 && start_entering.contains(&fork.id),
                "workflow_parallel_region_invalid"
            );
            covered.extend(branch);
        }
        let join = join_id.ok_or_else(|| anyhow!("workflow_parallel_region_invalid"))?;
        ensure!(
            predecessors.get(&join).is_some_and(|items| items == &exits),
            "workflow_parallel_region_invalid"
        );
        ensure!(
            matched_joins.insert(join),
            "workflow_parallel_region_invalid"
        );
    }
    Ok(matched_joins)
}

fn branch_has_cycle(
    definition: &WorkflowDefinition,
    outgoing_indexes: &BTreeMap<String, Vec<usize>>,
    branch: &BTreeSet<String>,
) -> bool {
    let mut visiting = BTreeSet::new();
    let mut visited = BTreeSet::new();
    fn visit(
        definition: &WorkflowDefinition,
        outgoing_indexes: &BTreeMap<String, Vec<usize>>,
        branch: &BTreeSet<String>,
        node: &str,
        visiting: &mut BTreeSet<String>,
        visited: &mut BTreeSet<String>,
    ) -> bool {
        if visiting.contains(node) {
            return true;
        }
        if visited.contains(node) {
            return false;
        }
        visiting.insert(node.to_owned());
        for transition_index in outgoing_indexes.get(node).into_iter().flatten() {
            let transition = &definition.transitions[*transition_index];
            if branch.contains(&transition.to)
                && visit(
                    definition,
                    outgoing_indexes,
                    branch,
                    &transition.to,
                    visiting,
                    visited,
                )
            {
                return true;
            }
        }
        visiting.remove(node);
        visited.insert(node.to_owned());
        false
    }
    branch.iter().any(|node| {
        visit(
            definition,
            outgoing_indexes,
            branch,
            node,
            &mut visiting,
            &mut visited,
        )
    })
}

fn reachable_states(
    definition: &WorkflowDefinition,
    outgoing_indexes: &BTreeMap<String, Vec<usize>>,
) -> BTreeSet<String> {
    let mut reachable = BTreeSet::new();
    let mut queue = VecDeque::from([definition.initial.clone()]);
    while let Some(state) = queue.pop_front() {
        if !reachable.insert(state.clone()) {
            continue;
        }
        queue.extend(
            outgoing_indexes
                .get(&state)
                .into_iter()
                .flatten()
                .map(|index| definition.transitions[*index].to.clone()),
        );
    }
    reachable
}

fn reject_effect_free_cycles(
    definition: &WorkflowDefinition,
    indexes: &BTreeMap<String, usize>,
    outgoing_indexes: &BTreeMap<String, Vec<usize>>,
) -> Result<()> {
    fn visit(
        definition: &WorkflowDefinition,
        indexes: &BTreeMap<String, usize>,
        outgoing_indexes: &BTreeMap<String, Vec<usize>>,
        state: &str,
        visiting: &mut BTreeSet<String>,
        visited: &mut BTreeSet<String>,
    ) -> Result<()> {
        if visiting.contains(state) {
            return Err(anyhow!("workflow_effect_free_cycle"));
        }
        if visited.contains(state) {
            return Ok(());
        }
        visiting.insert(state.to_owned());
        let kind = definition.states[indexes[state]].kind;
        for transition_index in outgoing_indexes.get(state).into_iter().flatten() {
            let transition = &definition.transitions[*transition_index];
            let automatic = match kind {
                GraphStateKind::Pass
                | GraphStateKind::Choice
                | GraphStateKind::Fork
                | GraphStateKind::Join => true,
                GraphStateKind::Workset => transition.event == TransitionEvent::Success,
                GraphStateKind::Authorization
                | GraphStateKind::Actor
                | GraphStateKind::Script
                | GraphStateKind::Succeed
                | GraphStateKind::Fail
                | GraphStateKind::Blocked => false,
            };
            if automatic {
                visit(
                    definition,
                    indexes,
                    outgoing_indexes,
                    &transition.to,
                    visiting,
                    visited,
                )?;
            }
        }
        visiting.remove(state);
        visited.insert(state.to_owned());
        Ok(())
    }

    let mut visiting = BTreeSet::new();
    let mut visited = BTreeSet::new();
    for state in &definition.states {
        visit(
            definition,
            indexes,
            outgoing_indexes,
            &state.id,
            &mut visiting,
            &mut visited,
        )?;
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
    use serde_json::Value;

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
                event: TransitionEvent::Complete,
                guard: None,
            }],
        ))
        .unwrap();
        assert_eq!(compiled.reachable().len(), 2);
        assert_eq!(
            compiled
                .transitions("start", TransitionEvent::Complete)
                .count(),
            1
        );
    }

    #[test]
    fn actor_graphs_normalize_legacy_entry_and_reject_multiple_entries() {
        let mut definition = workflow(
            vec![
                state("start", GraphStateKind::Pass),
                state("done", GraphStateKind::Succeed),
            ],
            vec![Transition {
                id: "finish".into(),
                from: "start".into(),
                to: "done".into(),
                event: TransitionEvent::Complete,
                guard: None,
            }],
        );
        definition.actor_slots = vec![
            crate::domain::adaptive_flywheel::ActorSlot::required_actor("entry", "Entry"),
            {
                let mut slot = crate::domain::adaptive_flywheel::ActorSlot::required_actor(
                    "worker-a", "Worker",
                );
                slot.entry = false;
                slot
            },
        ];
        definition.actor_slots[0].entry = false;
        let compiled = compile_workflow(definition.clone()).unwrap();
        assert!(compiled.definition.actor_slots[0].entry);
        definition.actor_slots[1].entry = true;
        definition.actor_slots[0].entry = true;
        assert!(compile_workflow(definition).is_err());
    }

    #[test]
    fn rejects_effect_free_cycle() {
        let result = compile_workflow(workflow(
            vec![
                state("first", GraphStateKind::Choice),
                state("second", GraphStateKind::Choice),
                state("done", GraphStateKind::Succeed),
            ],
            vec![
                Transition {
                    id: "a".into(),
                    from: "first".into(),
                    to: "second".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "b".into(),
                    from: "second".into(),
                    to: "first".into(),
                    event: TransitionEvent::Complete,
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
                    event: TransitionEvent::Complete,
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

    #[test]
    fn rejects_unknown_transition_events() {
        let json = serde_json::json!({
            "schema": super::super::WORKFLOW_SCHEMA_VERSION,
            "metadata": {
                "id": "test.workflow",
                "name": "Test",
                "version": "1",
                "description": ""
            },
            "limits": {},
            "actorSlots": [],
            "runtimes": [],
            "worksets": [],
            "initial": "start",
            "states": [
                {"id": "start", "kind": "pass", "label": "start", "retry": {}},
                {"id": "done", "kind": "succeed", "label": "done", "retry": {}}
            ],
            "transitions": [
                {"id": "next", "from": "start", "to": "done", "event": "jump"}
            ]
        });
        let decoded = serde_json::from_value::<WorkflowDefinition>(json);
        assert!(decoded.is_err(), "unknown event decoded: {decoded:?}");
        let definition = serde_json::from_value::<WorkflowDefinition>(serde_json::json!({
            "schema": super::super::WORKFLOW_SCHEMA_VERSION,
            "metadata": {
                "id": "test.workflow",
                "name": "Test",
                "version": "1",
                "description": ""
            },
            "limits": {},
            "actorSlots": [],
            "runtimes": [],
            "worksets": [],
            "initial": "start",
            "states": [
                {"id": "start", "kind": "pass", "label": "start", "retry": {}},
                {"id": "done", "kind": "succeed", "label": "done", "retry": {}}
            ],
            "transitions": [
                {"id": "next", "from": "start", "to": "done", "event": "complete"}
            ]
        }))
        .unwrap();
        assert_eq!(definition.transitions[0].event, TransitionEvent::Complete);
    }

    #[test]
    fn guard_partitions_require_fallback_and_same_path_equality() {
        let choice = |guards: Vec<GuardExpression>| {
            let mut transitions = guards
                .into_iter()
                .enumerate()
                .map(|(index, guard)| Transition {
                    id: format!("guard-{index}"),
                    from: "pick".into(),
                    to: "done".into(),
                    event: TransitionEvent::Complete,
                    guard: Some(guard),
                })
                .collect::<Vec<_>>();
            transitions.push(Transition {
                id: "fallback".into(),
                from: "pick".into(),
                to: "done".into(),
                event: TransitionEvent::Complete,
                guard: None,
            });
            workflow(
                vec![
                    state("pick", GraphStateKind::Choice),
                    state("done", GraphStateKind::Succeed),
                ],
                transitions,
            )
        };
        let guard = |path: &str, value: Option<Value>, exists: bool| GuardExpression {
            path: path.into(),
            equals: value,
            exists,
        };
        assert!(compile_workflow(choice(vec![guard("mode", Some("fast".into()), false)])).is_ok());
        assert!(
            compile_workflow(choice(vec![
                guard("mode", Some("fast".into()), false),
                guard("other", Some("fast".into()), false),
            ]))
            .unwrap_err()
            .to_string()
            .contains("guard_partition_invalid")
        );
        assert!(
            compile_workflow(choice(vec![
                guard("mode", Some("fast".into()), false),
                guard("mode", Some("fast".into()), false),
            ]))
            .unwrap_err()
            .to_string()
            .contains("guard_duplicate")
        );
        assert!(
            compile_workflow(choice(vec![
                guard("mode", Some("fast".into()), false),
                guard("mode", None, true),
            ]))
            .unwrap_err()
            .to_string()
            .contains("guard_partition_invalid")
        );
        let missing_fallback = workflow(
            vec![
                state("pick", GraphStateKind::Choice),
                state("done", GraphStateKind::Succeed),
            ],
            vec![Transition {
                id: "only-guard".into(),
                from: "pick".into(),
                to: "done".into(),
                event: TransitionEvent::Complete,
                guard: Some(guard("mode", Some("fast".into()), false)),
            }],
        );
        assert!(
            compile_workflow(missing_fallback)
                .unwrap_err()
                .to_string()
                .contains("guard_ambiguous")
        );
    }

    #[test]
    fn effect_states_require_total_success_and_failure_routing() {
        let mut definition = workflow(
            vec![
                state("plan", GraphStateKind::Actor),
                state("done", GraphStateKind::Succeed),
            ],
            vec![Transition {
                id: "plan-ready".into(),
                from: "plan".into(),
                to: "done".into(),
                event: TransitionEvent::Success,
                guard: None,
            }],
        );
        definition.actor_slots = vec![crate::domain::adaptive_flywheel::ActorSlot::required_actor(
            "entry", "Entry",
        )];
        definition.states[0].binding = Some("entry".into());
        assert!(
            compile_workflow(definition.clone())
                .unwrap_err()
                .to_string()
                .contains("effect_routing_incomplete")
        );
        definition.transitions.push(Transition {
            id: "plan-failed".into(),
            from: "plan".into(),
            to: "done".into(),
            event: TransitionEvent::Failure,
            guard: None,
        });
        assert!(compile_workflow(definition).is_ok());
    }

    #[test]
    fn effect_states_normalize_legacy_success_only_routing() {
        let mut definition = workflow(
            vec![
                state("plan", GraphStateKind::Actor),
                state("done", GraphStateKind::Succeed),
            ],
            vec![Transition {
                id: "plan-ready".into(),
                from: "plan".into(),
                to: "done".into(),
                event: TransitionEvent::Success,
                guard: None,
            }],
        );
        definition.actor_slots = vec![crate::domain::adaptive_flywheel::ActorSlot::required_actor(
            "entry", "Entry",
        )];
        definition.states[0].binding = Some("entry".into());
        let compiled = compile_persisted_workflow(definition).unwrap();
        assert_eq!(
            compiled
                .transitions("plan", TransitionEvent::Failure)
                .count(),
            1
        );
        assert!(
            compiled
                .state("blocked")
                .is_some_and(|state| state.kind == GraphStateKind::Blocked)
        );
    }

    #[test]
    fn effect_states_reuse_extra_complete_edges_as_failure() {
        let mut definition = workflow(
            vec![
                state("plan", GraphStateKind::Actor),
                state("done", GraphStateKind::Succeed),
                state("blocked", GraphStateKind::Blocked),
            ],
            vec![
                Transition {
                    id: "plan-ready".into(),
                    from: "plan".into(),
                    to: "done".into(),
                    event: TransitionEvent::Success,
                    guard: None,
                },
                Transition {
                    id: "plan-complete".into(),
                    from: "plan".into(),
                    to: "blocked".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
            ],
        );
        definition.actor_slots = vec![crate::domain::adaptive_flywheel::ActorSlot::required_actor(
            "entry", "Entry",
        )];
        definition.states[0].binding = Some("entry".into());
        let compiled = compile_persisted_workflow(definition).unwrap();
        assert_eq!(
            compiled
                .transitions("plan", TransitionEvent::Success)
                .count(),
            1
        );
        assert_eq!(
            compiled
                .transitions("plan", TransitionEvent::Failure)
                .count(),
            1
        );
        assert_eq!(
            compiled
                .transitions("plan", TransitionEvent::Complete)
                .count(),
            0
        );
    }

    #[test]
    fn effect_states_drop_leftover_complete_after_success_and_failure_exist() {
        let mut definition = workflow(
            vec![
                state("plan", GraphStateKind::Actor),
                state("done", GraphStateKind::Succeed),
                state("blocked", GraphStateKind::Blocked),
            ],
            vec![
                Transition {
                    id: "plan-ready".into(),
                    from: "plan".into(),
                    to: "done".into(),
                    event: TransitionEvent::Success,
                    guard: None,
                },
                Transition {
                    id: "plan-failed".into(),
                    from: "plan".into(),
                    to: "blocked".into(),
                    event: TransitionEvent::Failure,
                    guard: None,
                },
                Transition {
                    id: "plan-complete".into(),
                    from: "plan".into(),
                    to: "blocked".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
            ],
        );
        definition.actor_slots = vec![crate::domain::adaptive_flywheel::ActorSlot::required_actor(
            "entry", "Entry",
        )];
        definition.states[0].binding = Some("entry".into());
        let compiled = compile_persisted_workflow(definition).unwrap();
        assert_eq!(
            compiled
                .transitions("plan", TransitionEvent::Complete)
                .count(),
            0
        );
        assert_eq!(
            compiled
                .transitions("plan", TransitionEvent::Success)
                .count(),
            1
        );
        assert_eq!(
            compiled
                .transitions("plan", TransitionEvent::Failure)
                .count(),
            1
        );
    }

    #[test]
    fn structured_fork_join_regions_compile() {
        let result = compile_workflow(workflow(
            vec![
                state("fork", GraphStateKind::Fork),
                state("branch-a", GraphStateKind::Pass),
                state("branch-b", GraphStateKind::Pass),
                state("join", GraphStateKind::Join),
                state("done", GraphStateKind::Succeed),
            ],
            vec![
                Transition {
                    id: "fa".into(),
                    from: "fork".into(),
                    to: "branch-a".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "fb".into(),
                    from: "fork".into(),
                    to: "branch-b".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "aj".into(),
                    from: "branch-a".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "bj".into(),
                    from: "branch-b".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "jd".into(),
                    from: "join".into(),
                    to: "done".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
            ],
        ));
        assert!(result.is_ok(), "structured fork/join rejected: {result:?}");
    }

    #[test]
    fn malformed_parallel_regions_are_rejected() {
        let base_states = || {
            vec![
                state("fork", GraphStateKind::Fork),
                state("branch-a", GraphStateKind::Pass),
                state("branch-b", GraphStateKind::Pass),
                state("join", GraphStateKind::Join),
                state("done", GraphStateKind::Succeed),
            ]
        };
        let base_edges = || {
            vec![
                Transition {
                    id: "fa".into(),
                    from: "fork".into(),
                    to: "branch-a".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "fb".into(),
                    from: "fork".into(),
                    to: "branch-b".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "aj".into(),
                    from: "branch-a".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "bj".into(),
                    from: "branch-b".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "jd".into(),
                    from: "join".into(),
                    to: "done".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
            ]
        };
        let assert_rejected = |definition: WorkflowDefinition| {
            let states = definition
                .states
                .iter()
                .map(|state| state.id.clone())
                .collect::<Vec<_>>();
            let error = compile_workflow(definition).unwrap_err().to_string();
            assert!(
                error.contains("parallel_region_invalid"),
                "malformed region accepted with error: {error}; states: {states:?}"
            );
        };
        let mut missing_join = base_states();
        missing_join[4] = state("done", GraphStateKind::Succeed);
        let mut edges = base_edges();
        edges[2] = Transition {
            id: "ad".into(),
            from: "branch-a".into(),
            to: "done".into(),
            event: TransitionEvent::Complete,
            guard: None,
        };
        assert_rejected(workflow(missing_join, edges));

        let shared = base_states();
        let mut edges = base_edges();
        edges[3] = Transition {
            id: "ba".into(),
            from: "branch-b".into(),
            to: "branch-a".into(),
            event: TransitionEvent::Complete,
            guard: None,
        };
        assert_rejected(workflow(shared, edges));

        let mut nested = base_states();
        nested.insert(3, state("nested-fork", GraphStateKind::Fork));
        let mut edges = base_edges();
        edges[1] = Transition {
            id: "fn".into(),
            from: "fork".into(),
            to: "nested-fork".into(),
            event: TransitionEvent::Complete,
            guard: None,
        };
        edges.push(Transition {
            id: "nj".into(),
            from: "nested-fork".into(),
            to: "join".into(),
            event: TransitionEvent::Complete,
            guard: None,
        });
        edges.push(Transition {
            id: "nb".into(),
            from: "nested-fork".into(),
            to: "branch-b".into(),
            event: TransitionEvent::Complete,
            guard: None,
        });
        assert_rejected(workflow(nested, edges));

        let mut terminal_branch = base_states();
        terminal_branch[2] = state("branch-terminal", GraphStateKind::Succeed);
        let mut edges = base_edges();
        edges[1] = Transition {
            id: "ft".into(),
            from: "fork".into(),
            to: "branch-terminal".into(),
            event: TransitionEvent::Complete,
            guard: None,
        };
        edges.remove(3);
        assert_rejected(workflow(terminal_branch, edges));

        let cyclic = base_states();
        let mut edges = base_edges();
        edges[2] = Transition {
            id: "ab".into(),
            from: "branch-a".into(),
            to: "branch-b".into(),
            event: TransitionEvent::Complete,
            guard: None,
        };
        edges[3] = Transition {
            id: "ba".into(),
            from: "branch-b".into(),
            to: "branch-a".into(),
            event: TransitionEvent::Complete,
            guard: None,
        };
        assert_rejected(workflow(cyclic, edges));

        let extra_predecessor = vec![
            state("choice", GraphStateKind::Choice),
            state("fork", GraphStateKind::Fork),
            state("branch-a", GraphStateKind::Pass),
            state("branch-b", GraphStateKind::Pass),
            state("join", GraphStateKind::Join),
            state("extra", GraphStateKind::Pass),
            state("done", GraphStateKind::Succeed),
        ];
        let edges = vec![
            Transition {
                id: "cf".into(),
                from: "choice".into(),
                to: "fork".into(),
                event: TransitionEvent::Complete,
                guard: Some(GuardExpression {
                    path: "mode".into(),
                    equals: Some("parallel".into()),
                    exists: false,
                }),
            },
            Transition {
                id: "ce".into(),
                from: "choice".into(),
                to: "extra".into(),
                event: TransitionEvent::Complete,
                guard: None,
            },
            Transition {
                id: "fa".into(),
                from: "fork".into(),
                to: "branch-a".into(),
                event: TransitionEvent::Complete,
                guard: None,
            },
            Transition {
                id: "fb".into(),
                from: "fork".into(),
                to: "branch-b".into(),
                event: TransitionEvent::Complete,
                guard: None,
            },
            Transition {
                id: "aj".into(),
                from: "branch-a".into(),
                to: "join".into(),
                event: TransitionEvent::Complete,
                guard: None,
            },
            Transition {
                id: "bj".into(),
                from: "branch-b".into(),
                to: "join".into(),
                event: TransitionEvent::Complete,
                guard: None,
            },
            Transition {
                id: "ej".into(),
                from: "extra".into(),
                to: "join".into(),
                event: TransitionEvent::Complete,
                guard: None,
            },
            Transition {
                id: "jd".into(),
                from: "join".into(),
                to: "done".into(),
                event: TransitionEvent::Complete,
                guard: None,
            },
        ];
        assert_rejected(workflow(extra_predecessor, edges));

        let fork_only = workflow(
            vec![
                state("fork", GraphStateKind::Fork),
                state("branch-a", GraphStateKind::Pass),
                state("done", GraphStateKind::Succeed),
            ],
            vec![
                Transition {
                    id: "fa".into(),
                    from: "fork".into(),
                    to: "branch-a".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
                Transition {
                    id: "ad".into(),
                    from: "branch-a".into(),
                    to: "done".into(),
                    event: TransitionEvent::Complete,
                    guard: None,
                },
            ],
        );
        assert!(
            compile_workflow(fork_only)
                .unwrap_err()
                .to_string()
                .contains("fork_requires_branches")
        );
    }
}
