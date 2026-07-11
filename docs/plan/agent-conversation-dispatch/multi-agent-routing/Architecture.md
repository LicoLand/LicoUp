# Multi-Agent Routing And Context Distillation Architecture

## Module Map

The routing module lives under `apps/desktop/lib/src/application/features/routing/` and follows the three-layer structure established by existing features (agents, feed, mobile_relay):

```
apps/desktop/lib/src/
├── contracts/routing/                    # Layer: Interface
│   ├── routing_policy_schema.dart        # Policy document types
│   ├── route_decision_record.dart        # Decision output contract
│   ├── distillation_package.dart         # Handoff package contract
│   └── routing_module_registration.dart  # Integration-point contract
│
├── application/features/routing/         # Layer: Application Logic
│   ├── controller/
│   │   └── routing_actions.dart          # Controller extension (part file)
│   ├── engine/
│   │   ├── route_planner.dart            # Pure decision function
│   │   └── route_evaluator.dart          # Signal aggregation
│   └── broker/
│       ├── distillation_broker.dart       # Handoff orchestration
│       └── distillation_prompt.dart       # Template assembly
│
└── backend/features/routing/             # Layer: Infrastructure
    └── services/
        ├── policy_store.dart             # Load, validate, watch, reload
        ├── policy_file_watcher.dart      # FFI bridge for notify events
        └── route_history_store.dart      # Per-task route history
```

### Responsibility Per File

| File | Single Responsibility |
| --- | --- |
| `routing_policy_schema.dart` | Typed policy document, schema validation, error positions |
| `route_decision_record.dart` | Immutable decision output: chosen agent, alternatives, per-candidate reasons, policy identity |
| `distillation_package.dart` | Handoff package shape: objective, currentState, decisions, constraints, openItems, source references |
| `routing_module_registration.dart` | Registration contract: the single interface the controller consumes to conditionally activate routing |
| `route_planner.dart` | Pure function: (task metadata, policy, signals) → RouteDecisionRecord |
| `route_evaluator.dart` | Aggregates readiness, allowance, breaker signals into the inputs RoutePlanner expects |
| `distillation_broker.dart` | Assembles source conversation, dispatches distillation through the lane, validates fidelity, stores audit |
| `distillation_prompt.dart` | Builds the distillation prompt template from policy config and conversation references |
| `policy_store.dart` | Manages the active policy snapshot: initial load, schema validation, atomic swap on reload |
| `policy_file_watcher.dart` | Bridges Rust sidecar `notify` events to Dart; debounces and delivers change signals to PolicyStore |
| `route_history_store.dart` | Persists per-task route history (append-only decision records with timestamps) |
| `routing_actions.dart` | Controller extension: registers the module, wires lifecycle, coordinates engine + broker for dispatch |

---

## Layer Boundaries And Dependency Direction

```
                 ┌─────────────────────────────────┐
                 │         contracts/routing/       │  ← Pure types, no dependencies
                 │  (schema, decision, package)     │     except dart:core
                 └─────────────┬───────────────────┘
                               │ consumed by
                 ┌─────────────▼───────────────────┐
                 │   application/features/routing/  │  ← Application logic
                 │  (engine, broker, controller)    │     depends on: contracts/routing/*,
                 │                                  │     contracts/agent_usage_models,
                 │                                  │     contracts/target_candidate
                 └─────────────┬───────────────────┘
                               │ depends on
                 ┌─────────────▼───────────────────┐
                 │    backend/features/routing/     │  ← Infrastructure
                 │  (policy store, watcher, history)│     depends on: contracts/routing/*,
                 │                                  │     platform/storage,
                 │                                  │     platform/native_client (FFI)
                 └─────────────────────────────────┘
```

**Dependency direction:** Outer layers depend on inner layers. Infrastructure depends on application logic contracts. Application logic depends on interface contracts. Contracts depend on nothing except `dart:core`.

**Forbidden directions:**
- Contracts must never import application or infrastructure.
- Application logic must never import infrastructure implementations directly — it consumes them through abstract interfaces injected at registration time.
- The routing module must never import `agent_orchestration_policy.dart` after migration is complete (the engine replaces it entirely).

---

## Interface Contracts

### PolicyStore

```dart
abstract class RoutingPolicyStore {
  /// Load the policy from persistent storage. Returns the default empty policy
  /// if no file exists yet.
  Future<RoutingPolicyDocument> load();

  /// Start watching the policy directory for changes. On valid change, swaps
  /// the active snapshot and notifies listeners. On invalid change, retains
  /// last good snapshot and reports the validation error.
  Stream<RoutingPolicyStoreEvent> watch();

  /// The current active policy snapshot. Never null after load() completes.
  RoutingPolicyDocument get active;

  /// The most recent validation error, or null if the active snapshot is valid.
  RoutingPolicyValidationError? get lastError;

  /// Stop watching and release resources.
  Future<void> dispose();
}
```

**Events:** `RoutingPolicyStoreEvent` is a sealed type with variants: `loaded`, `reloaded(RoutingPolicyDocument)`, `validationFailed(RoutingPolicyValidationError)`.

### RoutePlanner

```dart
abstract class RoutePlanner {
  /// Pure decision function. Deterministic: identical inputs produce identical
  /// outputs. No side effects, no I/O.
  RouteDecisionRecord plan({
    required RoutingTaskMetadata task,
    required RoutingPolicyDocument policy,
    required RoutingSignals signals,
  });
}
```

**Inputs:**
- `RoutingTaskMetadata` — prompt content class, required roles/capabilities from policy match.
- `RoutingPolicyDocument` — the active policy snapshot.
- `RoutingSignals` — aggregated readiness states, allowance reports (with freshness), breaker states.

**Output:** `RouteDecisionRecord` — chosen agent, ordered alternatives, per-candidate reasons (matched role, capability satisfaction, priority tier, allowance headroom, health), policy identity (name + version).

### DistillationBroker

```dart
abstract class DistillationBroker {
  /// Assembles the source conversation into distillation input, dispatches
  /// to the policy-selected distiller through the dispatch lane, validates
  /// the returned package against the fidelity contract, and returns the
  /// verified package or an error.
  ///
  /// Retries exactly once with a corrective prompt on first fidelity failure.
  /// Falls back to the alternate distiller if the primary is non-ready.
  Future<DistillationResult> distill({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
    required DispatchLaneSend send,
  });
}
```

**DistillationRequest:** source session references, conversation summary inputs, fidelity contract from policy.  
**DistillationResult:** sealed type — `success(DistillationPackage, FidelityCheckResult)` | `failure(DistillationError)`.  
**DispatchLaneSend:** callback type matching the parent plan's dispatch lane interface — the broker never opens its own send path.

---

## Policy Schema Design

Based on Evidence.md Section 3.3 (synthesized from OpenRouter and LiteLLM practice):

```json
{
  "schemaVersion": 2,
  "id": "workspace-default",
  "label": "Default Workspace Policy",
  "agents": [
    {
      "id": "claude-code",
      "roles": ["code-review", "architecture", "implementation"],
      "capabilities": ["reasoning-deep", "tool-use", "long-context"],
      "priority": 1,
      "allowanceThreshold": { "kind": "token", "minimum": 1000 },
      "distillation": { "distiller": "self", "maxLength": 4096, "preserveFields": ["objective", "decisions", "constraints"] }
    },
    {
      "id": "codex",
      "roles": ["implementation", "quick-edit"],
      "capabilities": ["tool-use"],
      "priority": 2,
      "allowanceThreshold": { "kind": "token", "minimum": 500 }
    }
  ],
  "routing": {
    "strategy": "priority-fallback",
    "matchMode": "role-first",
    "staleBehavior": "conservative-skip",
    "allowStaleUsage": false,
    "circuitBreaker": {
      "allowedFails": 3,
      "cooldownSeconds": 60
    },
    "switchPolicy": {
      "minimumIntervalSeconds": 30,
      "triggerOn": ["policy-reload", "allowance-exhausted", "circuit-broken", "readiness-lost"]
    }
  },
  "distillation": {
    "defaultDistiller": "claude-code",
    "alternateDistiller": "codex",
    "fidelityContract": {
      "requiredSections": ["objective", "currentState", "decisions", "constraints", "openItems"],
      "maxPackageLength": 8192,
      "retryOnFailure": true,
      "maxRetries": 1
    }
  }
}
```

Schema validation produces `RoutingPolicyValidationError` with: `path` (JSON pointer), `message`, `position` (line:col when parsing from file).

---

## Design Pattern Rationale

| Pattern | Where Applied | Why It Earns Its Complexity |
| --- | --- | --- |
| **Immutable value objects** | All contract types (policy, decision, package) | Thread safety without locks; atomic snapshot swap is a pointer assignment; deterministic engine testing |
| **Pure function engine** | `RoutePlanner.plan()` | No I/O, no state, no side effects → trivially testable by decision table; determinism guarantee from REQ-MAR-002 |
| **Stream-based observation** | `PolicyStore.watch()` → controller | Decouples file-system events from consumption; debounce and error handling live in the store, not scattered through UI code |
| **Sealed result types** | `RoutingPolicyStoreEvent`, `DistillationResult` | Exhaustive pattern matching; impossible to forget error cases at call sites |
| **Callback injection for dispatch** | `DispatchLaneSend` parameter in broker | Broker never owns a send path; dependency on parent dispatch lane is explicit and testable with fakes |

**Deliberately pattern-free:**
- `routing_actions.dart` (controller extension) — procedural coordination only; no framework, no DI container, no middleware chain. It sequences store, engine, and broker through direct calls.
- `route_history_store.dart` — append-only JSON-lines file; no ORM, no database, no complex query. Simplest possible audit trail.

---

## Single Integration Point

The routing module registers through **one extension on `FutureClientController`** (`routing_actions.dart` as a `part` file) that:

1. **Activates** only when the module is enabled (runtime toggle) AND packaging includes it.
2. **Injects** the `RoutingPolicyStore`, `RoutePlanner`, and `DistillationBroker` instances at controller construction.
3. **Hooks** into the existing conversation dispatch flow by replacing the `_sendOrchestratedConversationMessage` path.
4. **Deactivates** cleanly: disposes the policy watcher, clears in-memory route state, removes settings keys.

When disabled or excluded:
- The `part` file is conditionally included (Dart conditional import based on a generated flag from packaging).
- No routing types, widgets, or services are instantiated.
- The controller falls through to direct dispatch (existing `conversationService.send` path) unchanged.

---

## Optional-Module Packaging Strategy

### packaging.modules.json entry

```json
{
  "multi-agent-routing": {
    "label": "Multi-agent routing and context distillation",
    "category": "routing",
    "enabled": true,
    "required": false,
    "platforms": ["macos", "linux", "windows"],
    "packaging": "runtime-capability",
    "requires": ["target-adapters", "portable-data"],
    "runtimeToggle": true,
    "stateDirectories": ["future-client/routing"],
    "settingsKeys": ["routing.enabled", "routing.policyPath"]
  }
}
```

### Exclusion mechanism

1. **Build-time exclusion:** When `required: false` and `enabled: false`, the packaging build script excludes the module's source tree from compilation via Dart conditional imports. The generated flag file controls inclusion.
2. **Runtime toggle:** When included but toggled off, the registration extension's `_initRouting()` returns early without instantiating any routing services.
3. **Unload contract:** On disable, the module must:
   - Cancel the policy file watcher subscription.
   - Clear `routing.*` settings keys from the portable settings store.
   - Delete `future-client/routing/` state directory contents (route history files).
   - Remove any routing widgets from the UI tree (they check registration state).

### Absence verification

After exclusion or unload, verification asserts:
- Zero references to routing contract types in the compiled application.
- Zero routing widgets in the widget tree.
- Zero `routing.*` keys in the settings store.
- Zero files in `future-client/routing/`.
- The policy file watcher is not running (no FFI subscription active).

---

## Consumed Interfaces (External Dependencies)

| Interface | Source | How Routing Consumes It |
| --- | --- | --- |
| `TargetCandidate.canRelayRuntime` | `contracts/target_candidate.dart` | Hard readiness gate in `RouteEvaluator` |
| `AgentUsageReport` + `AgentUsageAllowance` | `contracts/agent_usage_models.dart` | Freshness check + allowance threshold evaluation |
| `conversationService.send(...)` | `backend/features/agents/services/` | Dispatch lane for routed sends and distillation prompts |
| Rust sidecar FFI (notify events) | `platform/native_client/` | File-change signals for policy hot reload |
| Portable data root | `platform/storage/portable_data_root.dart` | Storage location for policy files and route history |

The routing module depends on these interfaces **read-only** and through their declared public APIs. It never reaches into their internals or modifies their behavior.

---

## Module Skeleton (Compile Verification)

The skeleton consists of interface-only contract files that establish the type system without implementing behavior. These files compile independently and are gated behind the integration point:

- `contracts/routing/routing_policy_schema.dart` — empty `RoutingPolicyDocument` and `RoutingPolicyValidationError` classes
- `contracts/routing/route_decision_record.dart` — empty `RouteDecisionRecord` class
- `contracts/routing/distillation_package.dart` — empty `DistillationPackage` and `FidelityCheckResult` classes
- `contracts/routing/routing_module_registration.dart` — abstract `RoutingModuleRegistration` with `isEnabled` getter

These files are created by the implementation nodes but the architecture defines their responsibilities, shapes, and compilation requirements here. The skeleton compiles without touching any existing controller, service, or UI code — it introduces no new behavior until the routing_actions.dart part file is wired in by the implementation nodes.
