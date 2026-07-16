# Local Agent Execution and Orchestration Architecture

## Ownership and dependency direction

```text
canonical adapter manifests + runtime override schemas
        ↓ validate / compile immutable registry revision
Agent Execution Registry
        ↓
Session Supervisor → official transport drivers → native frameworks
        ↓ ordered events / exact native IDs
Conversation application service → GUI / CLI / acceptance

conversation snapshot + routing policy + target registry
        ↓
Context Budgeter → Compression Broker → protected Context Artifact
        ↓
Deterministic Planner → bounded DAG Scheduler → Session Supervisor
        ↓
real worker results → same Lico thread → next routing boundary
```

Contracts and domain logic do not import Flutter widgets, process APIs, filesystem implementations, or driver internals. Platform adapters implement process, file-watch, private-file, native credential, and agent transport interfaces. UI and CLI depend only on application services.

## Module map

### Canonical contracts and configuration

- `packages/contracts/client/agent-conversation-adapter.schema.json` evolves into the adapter contribution and runtime capability contract.
- Canonical manifests move out of a fixture-shaped directory into one production manifest root. Template and negative fixtures stay separate.
- Generated projections replace handwritten packaged-ID lists in native runtime, packaging, render adapters, and readiness reducers.
- Non-secret execution configuration uses one private product root with `agents/registry.json`, `agents/adapters/<id>.json`, and `routing/policy.json`. These are logical product-relative paths; code resolves them through the current portable-data authority and never logs their absolute values.

### Native runtime

- `domain/agent_runtime/registry.rs`: immutable manifest/config snapshot, exact-set validation, revision digest, capability queries.
- `domain/agent_runtime/session_supervisor.rs`: native-session bindings, process/turn handles, cancellation, timeout, concurrency, drain, and cleanup.
- `domain/agent_runtime/context_budget.rs`: target limit/reserve calculation and deterministic fit decision.
- `domain/agent_runtime/context_artifact.rs`: versioned package, digest, acknowledgement, TTL, and bounded cleanup contract.
- `domain/agent_runtime/compression.rs`: compression request/result, fidelity, hierarchical plan, cache key, and bounded cache policy.
- `platform/agent_runtime_config_store.rs`: private atomic reads/writes, watcher debounce, last-good swap, and message-boundary revision events.
- Existing `platform/*_driver.rs` files remain transport-specific leaves and implement the one runtime driver trait. They cannot own product readiness, route policy, or a second session map.

### Flutter application

- `contracts/agent_dispatch_lane.dart` remains the execution port and gains typed configuration revision and context reference fields without exposing platform paths to UI.
- `application/features/agents` owns direct conversation use cases and maps ordered events into the current Lico thread.
- `application/features/routing/engine` remains pure deterministic planning.
- `application/features/routing/context` owns target-budget resolution, artifact preparation requests, compression selection, and fidelity decisions.
- `application/features/routing/scheduler` owns the bounded DAG, stable ready queue, semaphores, cancellation propagation, and aggregation.
- `backend/features/routing` and the native configuration store expose one immutable policy/adapter snapshot stream; controllers apply revisions only at message boundaries.

## Deliberate patterns

- **Strategy** is retained for official transport drivers and routing strategies because protocol framing and orchestration semantics genuinely vary behind stable contracts.
- **Supervisor** owns transport/session lifecycle because scattered process maps cause leaks, duplicate cancellation, and identity drift.
- **Repository plus immutable snapshot** is used for configuration because parse-then-swap provides last-good rollback and stable in-flight revision pinning.
- **Content-addressed artifact/cache** is used for context because the same source and target budget may be routed repeatedly; digest keys avoid repeated compression and make cleanup/evidence bounded.
- **DAG scheduler** is used only for multi-route execution. Direct and priority-fallback plans stay simple linear graphs; no general workflow engine is introduced.
- UI rendering and simple data mapping remain pattern-free local code.

## Session and event invariants

`SessionSupervisor` owns a map keyed by opaque Lico session handle. Each entry pins adapter ID, native session ID, registry revision, lifecycle state, and at most one active turn unless the manifest explicitly allows more. A turn emits monotonic sequence numbers and exactly one terminal event. The supervisor rejects changed native IDs, late events, duplicate terminals, revision mutation during a turn, and automatic retry after unknown outcome.

## Context artifact and compression flow

1. Select the minimum chronological source with pinned objective, decisions, constraints, open items, and the latest user turn.
2. Resolve the destination adapter/model input limit from a probed capability or conservative manifest bound, subtract reserved output/tool/system capacity, and measure bytes plus adapter tokenizer estimate when available.
3. If it fits, write one private immutable artifact atomically. If it overflows, choose a ready compressor declared by policy and capability, then call it through the same session supervisor.
4. For input larger than one compressor window, partition into bounded chronological chunks, compress with a fixed fan-out limit, then reduce the summaries. Cache only fidelity-passing results by source digest, destination budget, compressor/model, and registry/policy revisions.
5. The destination receives `{schema, opaqueHandle, localPath, digest, byteCount, tokenEstimate}` in a typed protocol or stdin field. It acknowledges the digest before execution. The absolute path never enters argv, UI, route history, logs, or public evidence.
6. Cleanup occurs after acknowledgement and terminal completion, cancellation, expiry, or failure. Failed cleanup is bounded and observable without exposing the path.

## Scheduling and policy revision

The planner produces an immutable route DAG. Kahn indegree accounting and a stable policy-order queue determine ready work. A global semaphore and per-adapter semaphores enforce concurrency. Priority fallback advances only after a transient, known-outcome failure. Parallel and coordinator-worker aggregation preserve route/turn ownership and cancel descendants when their prerequisite cannot safely complete.

Valid configuration is parsed into a new registry revision off-thread, exact-set and schema checked, then queued. Active turns keep the old revision; the next message boundary swaps to the new snapshot. Removed or disabled adapters enter draining state until their active turns finish, after which watchers, sessions, artifacts, and cache entries are released.

## Complete migration

The first implementation cutover moves current feature authority out of `client-release`, updates release documents to consume one final capability receipt, and retires superseded blocked feature leaves. The delivery removes hard-coded adapter enums/lists, compile-time-only manifest readers, inline routed-context handoff, duplicate session maps, and parallel readiness truth. Completed release Nodes remain immutable historical receipts but are not current product authority.
