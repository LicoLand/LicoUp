# Multi-Agent Routing And Context Distillation

## Goal

LicoArc should automatically route work across installed agents using declarative policy: match by role and capability, order by priority, respect remaining allowance, and switch agents mid-task with distilled context so the core logic survives the handoff. The whole routing capability ships as one lightweight optional module that can be disabled or uninstalled without leaving residue, while direct single-agent dispatch keeps working without it.

## Current Evidence

- `apps/desktop/lib/src/contracts/agent_orchestration_policy.dart` implements `fallback` and `dynamicAllocation` rules with allowance-based skipping and a circuit breaker, but policies are hardcoded in code, selection ignores roles/capabilities, and there is no policy file, no hot reload, and no explainable route decision record.
- `apps/desktop/lib/src/application/features/agents/controller/agent_orchestration_actions.dart` dispatches to each route with a wrapped prompt; there is no context distillation between agents, no mid-task agent switch, and no result merging contract.
- `apps/desktop/lib/src/contracts/agent_usage_models.dart` and the agent usage actions already meter per-agent tokens and allowances (CL-13), providing the quota signal routing needs.
- `apps/desktop/lib/src/application/features/skill_hub/models/skill_agent_compatibility.dart` maps skills to compatible agents but carries no role/capability metadata usable for routing.
- `apps/desktop/packaging.modules.json` declares build-time client modules; today every module is `required: true`, so optional-module packaging must be established for pluggability.
- The parent plan (`docs/plan/agent-conversation-dispatch/Plan.md`) delivers the unified dispatch lane and parity-gated readiness this module routes over; routing never bypasses the parity send gate.

## Final State

Routing policy lives in versioned declarative policy documents validated against a published schema, loaded dynamically and hot-reloaded during a running task. A single routing engine resolves each dispatch into an explainable route decision from role, capability, priority, allowance, and health signals. When the route moves a conversation to a different agent, a distillation broker uses the next agent (or a policy-designated distiller) to compress prior context into a fidelity-checked handoff package before the next session starts. The module registers as one optional packaged unit: disabling or removing it restores plain direct dispatch with zero routing residue in UI, settings, or state files.

## Requirements

| ID | Requirement |
| --- | --- |
| REQ-MAR-001 | Routing policy documents (roles, capability requirements, priorities, allowance thresholds, distillation directives) are declarative files validated against a published schema, dynamically loadable, and hot-reloadable without client restart. |
| REQ-MAR-002 | One routing engine resolves dispatches from role/capability match, priority order, remaining allowance, and circuit-breaker health into explainable route decisions, replacing the hardcoded plan resolver as the only implementation. |
| REQ-MAR-003 | Before a conversation enters a different agent, the next agent or a policy-designated distiller produces a handoff package that preserves stated goals, decisions, and constraints, and the package plus its fidelity check are auditable. |
| REQ-MAR-004 | Policy changes and agent switches apply mid-task at message boundaries without losing session continuity on either side of the switch. |
| REQ-MAR-005 | The routing module is one optional packaged unit with a runtime toggle; disabling or excluding it leaves direct dispatch fully functional and removes all routing UI, state, and policy artifacts. |
| REQ-MAR-006 | The module stays lightweight: pure Dart policy engine, no new heavyweight dependencies, and a documented bounded startup and memory footprint. |
| REQ-MAR-007 | Routing operations are disclosed in the client: active policy, route decisions with reasons, allowance state, and distillation previews are visible where dispatch happens. |

## Constraints

- Routing consumes the parent plan's dispatch lane and readiness gates; it must not add a second send path or weaken fail-closed behavior.
- Distillation runs through normal agent dispatch (a distillation prompt is an ordinary parity-gated send), not through any private lane.
- Policy files are local client configuration; no secret material, machine identity, or raw conversation text may be written into policy or route-decision records beyond redacted summaries.
- Single implementation rule: the existing hardcoded orchestration resolver is replaced, not wrapped or kept as a fallback.

## Open Points

- Where role/capability metadata for each agent authoritatively lives (render adapters, a new registry file, or policy documents themselves) is an architecture decision that must land before the routing engine node starts.
- Result merging when one task fans out to multiple agents is out of scope unless the requirements node proves users need it now.
