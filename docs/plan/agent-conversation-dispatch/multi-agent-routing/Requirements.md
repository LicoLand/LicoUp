# Multi-Agent Routing And Context Distillation Requirements

## User Problem

Users who run several local agents need Arc to choose *which* agent should take the next turn using explicit policy — role, capability, priority, and remaining allowance — and to switch agents mid-task without losing the goals, decisions, and constraints already established. Today orchestration is a hardcoded fallback/allowance skipper with wrapped prompts, no policy files, no hot reload, no mid-task switch, and no distilled handoff. Routing must stay optional and lightweight so single-agent users are not taxed by an always-on subsystem.

## Target Users

- Operators who maintain declarative routing policy for a multi-agent desktop workspace.
- Power users who start with one agent and need a mid-task switch when allowance, capability, or health changes.
- Users who disable or uninstall routing and expect plain direct dispatch to keep working unchanged.

## Target Workflows

| Workflow | Actor | Required behavior |
| --- | --- | --- |
| Single prompt auto-routed | Desktop user | One user message is resolved by the routing engine into an explainable route decision; send goes through the parent dispatch lane only if the selected adapter is parity-ready. |
| Long task survives agent switch | Desktop user / policy | At a message boundary, policy or health triggers a switch; distillation produces a fidelity-checked handoff; the next agent resumes with preserved goals/decisions/constraints and native session continuity on each side. |
| Operator edits policy mid-task | Operator | Policy file change is validated and hot-reloaded; subsequent message boundaries use the new policy without client restart. |
| Module disabled entirely | Operator / packaging | Runtime toggle or package exclusion removes routing UI, state, and policy artifacts; direct single-agent dispatch remains fully functional. |

## Functional Requirements

| ID | Requirement | Testable statement |
| --- | --- | --- |
| REQ-MAR-001 | Declarative hot-reloadable policy | Routing policy documents declare roles, capability requirements, priorities, allowance thresholds, and distillation directives. Documents validate against a published schema. Loading a new or changed file applies without client restart (hot reload). Invalid documents are rejected with actionable errors and do not partially apply. |
| REQ-MAR-002 | Single routing engine | Exactly one routing engine resolves each dispatch from role/capability match, priority order, remaining allowance, and circuit-breaker health into an explainable route decision record (selected agent, rejected candidates, reasons). The previous hardcoded orchestration plan resolver is removed in the same convergence; it is not retained as a fallback. |
| REQ-MAR-003 | Context distillation fidelity | Before a conversation enters a *different* agent, the next agent or a policy-designated distiller produces a handoff package. **Fidelity (testable):** the package must include explicit fields for (1) stated goals, (2) decisions already taken, and (3) active constraints; a fidelity check asserts each field is non-empty when the prior context contained that class of content, and records pass/fail with redacted digests. The package and fidelity result are auditable without storing raw conversation text in policy or route-decision records. |
| REQ-MAR-004 | Mid-task switch at message boundaries | Policy changes and agent switches apply at message boundaries (never mid-stream token). Session continuity is preserved on both sides of the switch: the leaving agent’s native session remains addressable; the entering agent opens/resumes via the parent dispatch lane. No silent “latest session” selection. |
| REQ-MAR-005 | Optional uninstallable module | Routing ships as one optional packaged unit with a runtime enable/disable toggle. Disabling or excluding the module leaves direct dispatch fully functional and removes routing UI, persisted routing state, and loaded policy artifacts (no residue). |
| REQ-MAR-006 | Lightweight footprint | The module is a pure Dart policy engine with no new heavyweight native/runtime dependencies. Documented budgets: cold start of the routing engine ≤ 50 ms on a reference desktop host for a policy ≤ 64 KiB; resident memory attributable to the loaded policy + engine ≤ 8 MiB above baseline direct-dispatch. Exceeding the budget fails the module’s acceptance checks. |
| REQ-MAR-007 | Routing disclosure UX | Where dispatch happens, the client discloses: active policy identity/version, route decisions with reasons, allowance state used for the decision, and distillation previews (redacted) before/after handoff. |

## Parent Dispatch Dependency (Consumed Interface)

This plan **consumes** the parent Agent Conversation Dispatch Parity contract; it does **not** redefine parity, lanes, or readiness.

| Consumed interface | Source | Routing obligation |
| --- | --- | --- |
| `AgentDispatchLane` (open/resume, send, stream, cancel, capabilities) | Parent Architecture / Dart contract | All routed sends, including distillation prompts, use this lane only. |
| Fail-closed readiness / `sendEnabled` | Parent REQ-ACD-003 / readiness reducer | Routing must not select or send to a non-ready adapter; non-ready candidates are skipped with recorded reasons. |
| Official-lane boundary | Parent REQ-ACD-004 / CL-06.3 | No second send path; no ptrace/input injection/private-database mutation. |

Out of scope for this child plan: implementing parity probes, lane executors, or readiness reduction (parent plan owns those).

## Stale Usage / Allowance Degradation

Quota signals come from CL-13 agent usage metering (`agent_usage_models` / allowances).

| Usage data state | Routing behavior |
| --- | --- |
| Fresh within the metering refresh window | Use remaining allowance thresholds as declared in policy. |
| Stale, missing, or metering `unavailable` | **Conservative skip:** treat allowance as exhausted for thresholded routes (do not best-effort route onto an agent whose quota cannot be confirmed). Record reason `allowance_data_stale` or `allowance_unavailable` on the route decision. |
| Explicit operator override in policy (`allowStaleUsage: true` on a route) | Allowed only when the policy schema permits it; decision record must flag `staleUsageOverride`. Default policies must not set this. |

## Scope

**In scope**

- Declarative policy schema, load/hot-reload, routing engine, distillation broker, mid-task switch, optional module packaging/toggle, disclosure UX, footprint budgets
- Replacement of hardcoded orchestration resolver

**Out of scope (non-goals)**

- Result merging / synthesis across parallel fan-out agents (unless a later plan proves demand; not required now)
- Weakening or bypassing parent parity send gates
- Server-side routing authority or core gateway policy
- Storing raw conversation content in policy files or route-decision audit records
- Re-implementing CL-13 metering

## Acceptance Targets

1. REQ-MAR-001..007 have mapped Validation.md checks and pass.
2. With the module disabled/excluded, direct dispatch behaves as if routing never existed (no routing UI/state/policy residue).
3. Every routed send (including distillation) is observable as a parent dispatch-lane call and respects readiness fail-closed.
4. Distillation fidelity checks fail closed when goals/decisions/constraints required by prior context are missing from the handoff package.
5. Footprint budgets in REQ-MAR-006 are measured and within limits on the reference desktop verification host.
6. Stale usage data triggers conservative skip unless an explicit schema-valid override is present and disclosed.

## Final Acceptance Target

The multi-agent routing module is complete when operators can load and hot-reload declarative policy, receive explainable route decisions, switch agents mid-task with fidelity-checked distilled handoffs, disable/uninstall the module cleanly, and verify the lightweight budgets — all strictly above the parent parity-gated dispatch lane.
