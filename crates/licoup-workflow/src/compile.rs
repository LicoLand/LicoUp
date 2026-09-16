use anyhow::{Result, ensure};
use std::collections::{BTreeMap, BTreeSet};

use crate::{
    GraphState, GuardExpression, Transition, TransitionEvent, WorkflowDefinition,
    analysis::AnalyzedWorkflow,
};

#[derive(Clone, Debug)]
pub struct CompiledWorkflow {
    pub(crate) definition: WorkflowDefinition,
    state_indexes: BTreeMap<String, usize>,
    transition_indexes: BTreeMap<(String, TransitionEvent), Vec<usize>>,
    outgoing_indexes: BTreeMap<String, Vec<usize>>,
    predecessors: BTreeMap<String, BTreeSet<String>>,
    reachable: BTreeSet<String>,
}

impl CompiledWorkflow {
    pub fn definition(&self) -> &WorkflowDefinition {
        &self.definition
    }

    pub fn into_definition(self) -> WorkflowDefinition {
        self.definition
    }
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

/// Lower one definition that has already passed semantic analysis. This phase
/// only materializes immutable lookup facts; it does not validate source
/// semantics a second time.
pub(crate) fn compile_validated_workflow(analyzed: AnalyzedWorkflow) -> CompiledWorkflow {
    let definition = analyzed.into_definition();
    let state_indexes = definition
        .states
        .iter()
        .enumerate()
        .map(|(index, state)| (state.id.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let mut transition_indexes = BTreeMap::<(String, TransitionEvent), Vec<usize>>::new();
    let mut outgoing_indexes = BTreeMap::<String, Vec<usize>>::new();
    let mut predecessors = BTreeMap::<String, BTreeSet<String>>::new();
    for (index, transition) in definition.transitions.iter().enumerate() {
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
    // Semantic analysis rejects every unreachable state, so the complete
    // validated state set is the reachability fact. Do not walk the graph a
    // second time during lowering.
    let reachable = definition
        .states
        .iter()
        .map(|state| state.id.clone())
        .collect();
    CompiledWorkflow {
        definition,
        state_indexes,
        transition_indexes,
        outgoing_indexes,
        predecessors,
        reachable,
    }
}

#[cfg(test)]
fn compile_workflow(
    definition: WorkflowDefinition,
) -> std::result::Result<CompiledWorkflow, crate::WorkflowValidationFailure> {
    crate::compile_workflow(definition)
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

pub(super) fn valid_instruction(value: &str) -> bool {
    value == value.trim()
        && !value.is_empty()
        && value.len() <= 16 * 1024
        && !value
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\r' | '\t'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        ActorSlot, GraphStateKind, RetryPolicy, TransitionMode, WorkflowLimits, WorkflowMetadata,
    };
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
                mode: TransitionMode::Flow,
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
    fn transition_mode_defaults_to_flow_and_rejects_unknown_values() {
        let transition = |mode: Option<&str>| {
            let mut value = serde_json::json!({
                "id": "next",
                "from": "start",
                "to": "done",
                "event": "complete"
            });
            if let Some(mode) = mode {
                value["mode"] = mode.into();
            }
            serde_json::from_value::<Transition>(value)
        };
        assert_eq!(transition(None).unwrap().mode, TransitionMode::Flow);
        assert_eq!(transition(Some("flow")).unwrap().mode, TransitionMode::Flow);
        assert_eq!(
            transition(Some("callback")).unwrap().mode,
            TransitionMode::Callback
        );
        assert!(transition(Some("warp")).is_err(), "unknown mode decodes");
        // Flow is the canonical default: it never lands in the stored bytes.
        let serialized = serde_json::to_value(transition(None).unwrap()).unwrap();
        assert!(serialized.get("mode").is_none());
        let serialized = serde_json::to_value(transition(Some("callback")).unwrap()).unwrap();
        assert_eq!(serialized["mode"], "callback");
    }

    #[test]
    fn flow_mode_targets_may_not_leave_actor_binding_empty() {
        let build = |entry_mode: TransitionMode| {
            let mut definition = workflow(
                vec![
                    state("start", GraphStateKind::Pass),
                    state("review", GraphStateKind::Actor),
                    state("done", GraphStateKind::Succeed),
                ],
                vec![
                    Transition {
                        id: "begin".into(),
                        from: "start".into(),
                        to: "review".into(),
                        event: TransitionEvent::Complete,
                        mode: entry_mode,
                        guard: None,
                    },
                    Transition {
                        id: "reviewed".into(),
                        from: "review".into(),
                        to: "done".into(),
                        event: TransitionEvent::Success,
                        mode: TransitionMode::Flow,
                        guard: None,
                    },
                    Transition {
                        id: "review-failed".into(),
                        from: "review".into(),
                        to: "done".into(),
                        event: TransitionEvent::Failure,
                        mode: TransitionMode::Flow,
                        guard: None,
                    },
                ],
            );
            definition.actor_slots = vec![ActorSlot::required_actor("worker", "Worker")];
            definition
        };
        // A callback-only target may defer its binding to the master decision.
        assert!(compile_workflow(build(TransitionMode::Callback)).is_ok());
        // A flow-entered actor state may not leave its binding empty: no
        // master agent fills parameters on the flow path.
        let error = compile_workflow(build(TransitionMode::Flow)).unwrap_err();
        assert!(
            error.diagnostics.iter().any(|diagnostic| {
                diagnostic.code == crate::WorkflowDiagnosticCode::WorkflowFlowTargetIncomplete
            }),
            "flow target with empty binding rejected with the rule: {error}"
        );
        let mut initial_actor = build(TransitionMode::Callback);
        initial_actor.initial = "review".into();
        let error = compile_workflow(initial_actor).unwrap_err();
        assert!(
            error.diagnostics.iter().any(|diagnostic| {
                diagnostic.code == crate::WorkflowDiagnosticCode::WorkflowFlowTargetIncomplete
            }),
            "the initial state is flow-entered: {error}"
        );
    }

    #[test]
    fn fork_branch_edges_must_stay_flow_mode() {
        let mut definition = workflow(
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
                    mode: TransitionMode::Callback,
                    guard: None,
                },
                Transition {
                    id: "fb".into(),
                    from: "fork".into(),
                    to: "branch-b".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "aj".into(),
                    from: "branch-a".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "bj".into(),
                    from: "branch-b".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "jd".into(),
                    from: "join".into(),
                    to: "done".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
            ],
        );
        let error = compile_workflow(definition.clone()).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("workflow_transition_mode_invalid"),
            "callback fan-out rejected: {error}"
        );
        definition.transitions[0].mode = TransitionMode::Flow;
        assert!(compile_workflow(definition).is_ok());
    }

    #[test]
    fn actor_graphs_require_exactly_one_declared_entry() {
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
                mode: TransitionMode::Flow,
                guard: None,
            }],
        );
        definition.actor_slots = vec![ActorSlot::required_actor("entry", "Entry"), {
            let mut slot = ActorSlot::required_actor("worker-a", "Worker");
            slot.entry = false;
            slot
        }];
        definition.actor_slots[0].entry = false;
        assert!(compile_workflow(definition.clone()).is_err());
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
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "b".into(),
                    from: "second".into(),
                    to: "first".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
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
                    mode: TransitionMode::Flow,
                    guard: None,
                },
            ],
        ));
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("workflow_effect_cycle")
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
                    mode: TransitionMode::Flow,
                    guard: Some(guard),
                })
                .collect::<Vec<_>>();
            transitions.push(Transition {
                id: "fallback".into(),
                from: "pick".into(),
                to: "done".into(),
                event: TransitionEvent::Complete,
                mode: TransitionMode::Flow,
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
            .contains("workflow_guard_ambiguous")
        );
        assert!(
            compile_workflow(choice(vec![
                guard("mode", Some("fast".into()), false),
                guard("mode", Some("fast".into()), false),
            ]))
            .unwrap_err()
            .to_string()
            .contains("workflow_guard_ambiguous")
        );
        assert!(
            compile_workflow(choice(vec![
                guard("mode", Some("fast".into()), false),
                guard("mode", None, true),
            ]))
            .unwrap_err()
            .to_string()
            .contains("workflow_guard_ambiguous")
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
                mode: TransitionMode::Flow,
                guard: Some(guard("mode", Some("fast".into()), false)),
            }],
        );
        assert!(
            compile_workflow(missing_fallback)
                .unwrap_err()
                .to_string()
                .contains("workflow_guard_ambiguous")
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
                mode: TransitionMode::Flow,
                guard: None,
            }],
        );
        definition.actor_slots = vec![ActorSlot::required_actor("entry", "Entry")];
        definition.states[0].binding = Some("entry".into());
        assert!(
            compile_workflow(definition.clone())
                .unwrap_err()
                .to_string()
                .contains("workflow_routing_invalid")
        );
        definition.transitions.push(Transition {
            id: "plan-failed".into(),
            from: "plan".into(),
            to: "done".into(),
            event: TransitionEvent::Failure,
            mode: TransitionMode::Flow,
            guard: None,
        });
        assert!(compile_workflow(definition).is_ok());
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
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "fb".into(),
                    from: "fork".into(),
                    to: "branch-b".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "aj".into(),
                    from: "branch-a".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "bj".into(),
                    from: "branch-b".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "jd".into(),
                    from: "join".into(),
                    to: "done".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
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
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "fb".into(),
                    from: "fork".into(),
                    to: "branch-b".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "aj".into(),
                    from: "branch-a".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "bj".into(),
                    from: "branch-b".into(),
                    to: "join".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "jd".into(),
                    from: "join".into(),
                    to: "done".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
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
                error.contains("workflow_topology_invalid"),
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
            mode: TransitionMode::Flow,
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
            mode: TransitionMode::Flow,
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
            mode: TransitionMode::Flow,
            guard: None,
        };
        edges.push(Transition {
            id: "nj".into(),
            from: "nested-fork".into(),
            to: "join".into(),
            event: TransitionEvent::Complete,
            mode: TransitionMode::Flow,
            guard: None,
        });
        edges.push(Transition {
            id: "nb".into(),
            from: "nested-fork".into(),
            to: "branch-b".into(),
            event: TransitionEvent::Complete,
            mode: TransitionMode::Flow,
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
            mode: TransitionMode::Flow,
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
            mode: TransitionMode::Flow,
            guard: None,
        };
        edges[3] = Transition {
            id: "ba".into(),
            from: "branch-b".into(),
            to: "branch-a".into(),
            event: TransitionEvent::Complete,
            mode: TransitionMode::Flow,
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
                mode: TransitionMode::Flow,
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
                mode: TransitionMode::Flow,
                guard: None,
            },
            Transition {
                id: "fa".into(),
                from: "fork".into(),
                to: "branch-a".into(),
                event: TransitionEvent::Complete,
                mode: TransitionMode::Flow,
                guard: None,
            },
            Transition {
                id: "fb".into(),
                from: "fork".into(),
                to: "branch-b".into(),
                event: TransitionEvent::Complete,
                mode: TransitionMode::Flow,
                guard: None,
            },
            Transition {
                id: "aj".into(),
                from: "branch-a".into(),
                to: "join".into(),
                event: TransitionEvent::Complete,
                mode: TransitionMode::Flow,
                guard: None,
            },
            Transition {
                id: "bj".into(),
                from: "branch-b".into(),
                to: "join".into(),
                event: TransitionEvent::Complete,
                mode: TransitionMode::Flow,
                guard: None,
            },
            Transition {
                id: "ej".into(),
                from: "extra".into(),
                to: "join".into(),
                event: TransitionEvent::Complete,
                mode: TransitionMode::Flow,
                guard: None,
            },
            Transition {
                id: "jd".into(),
                from: "join".into(),
                to: "done".into(),
                event: TransitionEvent::Complete,
                mode: TransitionMode::Flow,
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
                    mode: TransitionMode::Flow,
                    guard: None,
                },
                Transition {
                    id: "ad".into(),
                    from: "branch-a".into(),
                    to: "done".into(),
                    event: TransitionEvent::Complete,
                    mode: TransitionMode::Flow,
                    guard: None,
                },
            ],
        );
        assert!(
            compile_workflow(fork_only)
                .unwrap_err()
                .to_string()
                .contains("workflow_routing_invalid")
        );
    }
}
