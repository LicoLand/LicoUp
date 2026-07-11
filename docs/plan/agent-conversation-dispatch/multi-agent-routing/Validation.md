# Multi-Agent Routing And Context Distillation Validation Matrix

## Requirement-To-Check Mapping

### REQ-MAR-001 — Declarative Hot-Reloadable Policy

| Check ID | Check Name | Type | Delivering Node | Pass Condition |
| --- | --- | --- | --- | --- |
| V-001-A | Policy schema full-surface validation | Unit test | Policy Schema Store (402e4e92) | All valid policy documents (roles, capabilities, priorities, allowance thresholds, distillation directives) parse to typed objects; all invalid documents produce precise error positions and do not partially apply |
| V-001-B | Hot-reload atomic snapshot swap | Integration test | Policy Schema Store (402e4e92) | A live file change replaces the active policy snapshot atomically; concurrent readers never observe a torn intermediate state |
| V-001-C | Invalid change retains last good policy | Integration test | Policy Schema Store (402e4e92) | Writing a malformed policy file keeps the previous valid snapshot active and surfaces a validation error with file path and position |
| V-001-D | Editor write-burst debounce | Integration test | Policy Schema Store (402e4e92) | Rapid sequential writes (simulating editor auto-save) coalesce into one reload event after the debounce window (≥ 200ms quiet) |
| V-001-E | Schema version validation | Unit test | Policy Schema Store (402e4e92) | Documents with unsupported `schemaVersion` are rejected with a clear version-mismatch error |

### REQ-MAR-002 — Single Routing Engine

| Check ID | Check Name | Type | Delivering Node | Pass Condition |
| --- | --- | --- | --- | --- |
| V-002-A | Role matching | Decision-table test | Routing Engine (9f5022e3) | Engine selects only agents whose declared roles intersect the task's required roles from policy |
| V-002-B | Capability matching | Decision-table test | Routing Engine (9f5022e3) | Engine excludes agents missing required capabilities with recorded exclusion reasons |
| V-002-C | Priority ordering | Decision-table test | Routing Engine (9f5022e3) | Route candidates appear in policy-declared priority order, not array-insertion order |
| V-002-D | Allowance exhaustion exclusion | Decision-table test | Routing Engine (9f5022e3) | Agent with status `blocked`/`depleted`/`exhausted` is excluded with reason `allowance_exhausted` |
| V-002-E | Circuit-breaker exclusion | Decision-table test | Routing Engine (9f5022e3) | Agent in breaker set is excluded with reason `circuit_broken` and its cooldown is policy-tunable |
| V-002-F | Readiness hard-exclusion | Decision-table test | Routing Engine (9f5022e3) | Agent with `canRelayRuntime == false` is excluded with reason `not_ready`; never appears in routes |
| V-002-G | Deterministic tiebreak | Decision-table test | Routing Engine (9f5022e3) | Identical inputs produce identical route orders across invocations; tiebreak is by policy document order |
| V-002-H | Stale usage conservative skip | Decision-table test | Routing Engine (9f5022e3) | When `AgentUsageReport.isFresh() == false` and no `allowStaleUsage` override, allowance-gated agents are excluded with reason `allowance_data_stale` |
| V-002-I | Decision record completeness | Unit test | Routing Engine (9f5022e3) | Every route decision contains: chosen agent, ordered alternatives, per-candidate reasons, policy identity (name + version), and allowance headroom |
| V-002-J | Legacy resolver removed | Static analysis | Routing Engine (9f5022e3) | `resolveAgentDispatchPlan` function and `AgentOrchestrationRule`/`AgentOrchestrationStrategy` types have zero remaining references in the codebase |

### REQ-MAR-003 — Context Distillation Fidelity

| Check ID | Check Name | Type | Delivering Node | Pass Condition |
| --- | --- | --- | --- | --- |
| V-003-A | Handoff package assembly | Unit test | Distillation Broker (979a3024) | Broker produces a package with non-empty `objective`, `currentState`, `decisions`, `constraints`, `openItems` fields from a fixture conversation containing all those classes |
| V-003-B | Fidelity validation pass | Unit test | Distillation Broker (979a3024) | Package with all required sections passes structural fidelity check |
| V-003-C | Fidelity validation fail-closed | Unit test | Distillation Broker (979a3024) | Package missing a required section when the source conversation contained that class of content fails fidelity with recorded reason; no raw undistilled handoff proceeds |
| V-003-D | Corrective retry | Unit test | Distillation Broker (979a3024) | First fidelity failure triggers exactly one corrective re-prompt; second failure surfaces error to caller |
| V-003-E | Alternate-distiller fallback | Unit test | Distillation Broker (979a3024) | When primary distiller is non-ready, broker falls back to policy's alternate distiller; if both non-ready, error surfaces |
| V-003-F | Audit storage with source references only | Unit test | Distillation Broker (979a3024) | Stored audit record contains the handoff package and fidelity result but never raw source conversation text |
| V-003-G | Distillation cost metering | Integration test | Distillation Broker (979a3024) | Distillation sends are counted as dispatch-lane calls and their token cost appears in the usage report |

### REQ-MAR-004 — Mid-Task Switch At Message Boundaries

| Check ID | Check Name | Type | Delivering Node | Pass Condition |
| --- | --- | --- | --- | --- |
| V-004-A | Re-routing at message boundary | Integration test (fixture agents) | Mid-Task Switch (5b8f9227) | Between messages, policy or health change triggers route re-evaluation; a different route invokes distillation and opens the target agent session with the handoff package |
| V-004-B | No mid-stream interruption | Integration test (fixture agents) | Mid-Task Switch (5b8f9227) | A policy swap arriving during token streaming does not interrupt or corrupt the in-flight message |
| V-004-C | Route history recording | Integration test (fixture agents) | Mid-Task Switch (5b8f9227) | Every switch appends to the per-task route history with decision record, timestamp, and source/target session IDs |
| V-004-D | Source session resumable | Integration test (fixture agents) | Mid-Task Switch (5b8f9227) | After a switch, the leaving agent's native session remains addressable and resumable |
| V-004-E | Target session resumable | Integration test (fixture agents) | Mid-Task Switch (5b8f9227) | The entering agent's session opened with the handoff package is resumable on subsequent switches |
| V-004-F | Concurrency: policy swap during distillation | Concurrency test | Mid-Task Switch (5b8f9227) | A policy swap arriving during an active distillation queues safely and does not race or corrupt the handoff |
| V-004-G | Switch frequency bounded | Integration test (fixture agents) | Mid-Task Switch (5b8f9227) | Rapid oscillating policy changes respect the policy-tunable minimum switch interval; excess switches are suppressed with recorded reasons |
| V-004-H | Failed switch stays on source | Integration test (fixture agents) | Mid-Task Switch (5b8f9227) | A switch that fails (distillation failure, target non-ready) leaves the task on the source agent and surfaces a reason |

### REQ-MAR-005 — Optional Uninstallable Module

| Check ID | Check Name | Type | Delivering Node | Pass Condition |
| --- | --- | --- | --- | --- |
| V-005-A | Module-excluded build compiles | Build verification | Optional Module (0a2098da) | `flutter build` with routing module excluded from `packaging.modules.json` succeeds; no routing imports, widgets, or types referenced |
| V-005-B | Direct dispatch fully functional when excluded | Smoke test | Optional Module (0a2098da) | With module excluded, single-agent conversation send works identically to pre-routing behavior |
| V-005-C | Runtime toggle deactivation | Integration test | Optional Module (0a2098da) | Runtime disable removes routing registration at the single integration point; dispatch passes through to direct lane |
| V-005-D | Unload removes state artifacts | Integration test | Optional Module (0a2098da) | After unload: no routing settings keys, no policy watch handles, no per-task route history files remain on disk |
| V-005-E | Re-enable starts clean | Integration test | Optional Module (0a2098da) | After disable→re-enable cycle, routing starts with no stale state from the previous session |

### REQ-MAR-006 — Lightweight Footprint

| Check ID | Check Name | Type | Delivering Node | Pass Condition |
| --- | --- | --- | --- | --- |
| V-006-A | Cold start ≤ 50ms | Performance measurement | Optional Module (0a2098da) | Routing engine cold start (policy load + engine init) on a reference desktop host with a policy ≤ 64 KiB completes in ≤ 50ms |
| V-006-B | Resident memory ≤ 8 MiB above baseline | Performance measurement | Optional Module (0a2098da) | Measured resident memory delta (module enabled vs. disabled) is ≤ 8 MiB |
| V-006-C | No new native/runtime dependencies | Static analysis | Policy Schema Store (402e4e92) | `pubspec.yaml` diff shows zero new non-dev dependencies added by the routing module; the module is pure Dart |

### REQ-MAR-007 — Routing Disclosure UX

| Check ID | Check Name | Type | Delivering Node | Pass Condition |
| --- | --- | --- | --- | --- |
| V-007-A | Policy identity and reload state display | Widget test | Disclosure UI (b407428a) | Widget shows active policy name, version, and validation state (valid/error with message) |
| V-007-B | Decision record rendering | Widget test | Disclosure UI (b407428a) | Per-dispatch disclosure renders chosen agent, alternatives, per-candidate reasons, and allowance headroom from the decision record contract type |
| V-007-C | Distillation preview | Widget test | Disclosure UI (b407428a) | Handoff package preview renders before/as the package is sent; privacy redaction removes raw source text |
| V-007-D | Per-task route history | Widget test | Disclosure UI (b407428a) | Route history panel renders the chronological switch timeline with decision records per entry |
| V-007-E | Contract-type-only rendering | Static analysis | Disclosure UI (b407428a) | All routing UI widgets consume only the decision-record and route-history contract types; no UI-side re-derivation of routing logic |
| V-007-F | Privacy redaction | Widget test | Disclosure UI (b407428a) | Preview surfaces never render raw source conversation text; only the distilled package content is displayed |

---

## End-To-End Acceptance Scenario

### Fixture Requirements

| Fixture | Purpose |
| --- | --- |
| Fake Agent A | Deterministic responder with known model catalog and skill capability; starts as primary route target |
| Fake Agent B | Deterministic responder with different role/capability profile; becomes target after policy hot-swap |
| Fake Distiller Agent | Returns a well-formed handoff package from a fixture prompt; validates fidelity contract |
| Policy File Alpha | Routes all tasks to Agent A as primary, Agent B as fallback; distiller is Agent A |
| Policy File Beta | Routes all tasks to Agent B as primary, Agent A as fallback; distiller is Fake Distiller |
| Fixture Conversation | 5-message conversation with identifiable goals, decisions, and constraints for fidelity checks |

### Scenario Steps

1. **Start:** Load Policy Alpha. Send a user message. Verify the routing engine selects Agent A with an explainable decision record (V-002-A through V-002-I).
2. **Message delivery:** Agent A responds. Verify the message is delivered through the parent dispatch lane and the route decision is disclosed in UX (V-007-B).
3. **Hot policy swap:** Replace Policy Alpha with Policy Beta on disk. Verify the policy store detects the change, validates the new schema, and atomically swaps the active snapshot (V-001-B, V-001-C).
4. **Mid-task re-evaluation:** At the next message boundary, verify the routing engine re-evaluates and determines Agent B is now the primary route (V-004-A).
5. **Distilled handoff:** Verify the distillation broker assembles the conversation, sends a distillation prompt through the dispatch lane to the Fake Distiller, receives a package, and validates fidelity (V-003-A through V-003-C).
6. **Target session open:** Verify the next agent (Agent B) opens a session with the handoff package as opening context (V-004-E).
7. **Task completion:** Send a follow-up message. Verify Agent B responds normally using the distilled context. Verify the route history shows the switch with decision records (V-004-C).
8. **Disclosure intact:** Verify the routing disclosure UX shows: policy identity = Beta, route decision for Agent B, distillation preview, and full route history timeline (V-007-A through V-007-D).

### Pass Conditions

- All 8 steps complete without error.
- Route decisions are deterministic and reproducible with the same fixture inputs.
- No raw undistilled conversation text appears in any audit record, policy file, or UX disclosure surface.
- Both Agent A's and Agent B's native sessions remain resumable after the scenario.

---

## Module-Disabled / Module-Excluded Verification

### Module-Excluded Build

1. Remove the routing module entry from `packaging.modules.json` (or set `enabled: false`).
2. Run `flutter build` — must succeed with zero compilation errors.
3. Verify via static analysis: no routing contract types, widgets, services, or settings keys are imported or referenced.
4. Run existing direct-dispatch tests — all pass unchanged.

### Runtime-Disabled Unload

1. With the module included but runtime toggle set to disabled:
   - Verify the registration point is not reached.
   - Verify no routing widgets render in the agents UI.
   - Verify no routing settings keys exist in the settings store.
   - Verify no policy file watcher is active.
   - Verify no route history state files exist on disk.
2. Enable → disable → verify all artifacts removed (V-005-D).
3. Disable → enable → verify clean startup with no stale state (V-005-E).

---

## Footprint Budget Verification

| Metric | Budget | Measurement Method |
| --- | --- | --- |
| Cold start time | ≤ 50ms | Stopwatch around `PolicyStore.load()` + `RoutePlanner.init()` on macOS reference host with a 64 KiB policy fixture |
| Resident memory delta | ≤ 8 MiB | Measure RSS with module enabled vs. disabled using macOS `footprint` or Dart DevTools memory snapshot; take median of 5 cold starts |
| Package dependencies | 0 new non-dev deps | `diff pubspec.lock` before and after routing module addition |

---

## Traceability

| REQ Label | Check IDs | Delivering Nodes |
| --- | --- | --- |
| REQ-MAR-001 | V-001-A..E | 402e4e92 |
| REQ-MAR-002 | V-002-A..J | 9f5022e3 |
| REQ-MAR-003 | V-003-A..G | 979a3024 |
| REQ-MAR-004 | V-004-A..H | 5b8f9227 |
| REQ-MAR-005 | V-005-A..E | 0a2098da |
| REQ-MAR-006 | V-006-A..C | 0a2098da, 402e4e92 |
| REQ-MAR-007 | V-007-A..F | b407428a |
