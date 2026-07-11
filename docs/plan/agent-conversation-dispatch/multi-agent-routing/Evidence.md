# Multi-Agent Routing And Context Distillation Evidence

## 1. Routing Signal Sources

### 1.1 AgentOrchestrationPolicy (current resolver authority)

**File:** `apps/desktop/lib/src/contracts/agent_orchestration_policy.dart`

The current orchestration contract provides:

| Field / Type | Routing Signal | Usable For |
| --- | --- | --- |
| `AgentOrchestrationPolicy.commanderAgentId` | Designated primary agent | Identifies the coordinator |
| `AgentOrchestrationPolicy.commanderModelName` | Model selection hint | Binds a model to the commander |
| `AgentOrchestrationPolicy.modelLibrary` → `List<AgentModelLibraryEntry>` | Ordered agent/model/effort tuples | Defines dispatch candidates |
| `AgentOrchestrationPolicy.rules` → `List<AgentOrchestrationRule>` | Strategy + routeKeys | Selects the dispatch path |
| `AgentOrchestrationStrategy.fallback` | Sequential degradation | First success wins |
| `AgentOrchestrationStrategy.dynamicAllocation` | Parallel fanout | All candidates dispatched |
| `AgentDispatchPlan.routes` → `List<AgentDispatchRoute>` | Resolved ordered agents with role, priority, model | Decision output |
| `AgentDispatchPlan.skipped` → `List<AgentDispatchSkip>` | Rejected candidates with reasons | Circuit-breaker, quota |

**Schema version:** `schemaVersion: 1` (hardcoded in `toJson`).

**Key function:** `resolveAgentDispatchPlan` — the single dispatch resolver. Inputs: targets, rule, prompt, model library, usage report, allowance overrides, circuit-broken agent IDs. Produces an `AgentDispatchPlan`.

### 1.2 AgentUsageModels (allowance data)

**File:** `apps/desktop/lib/src/contracts/agent_usage_models.dart`

| Type | Routing Signal | Usable For |
| --- | --- | --- |
| `AgentUsageReport.isFresh({maxAge})` | Staleness check (default 1-hour window) | Determines whether allowance data is fresh or stale |
| `AgentUsageReport.agents` → per-agent summaries | Token counts, traffic bytes, confidence | Usage metering |
| `AgentUsageAgentSummary.allowances` → `List<AgentUsageAllowance>` | Per-agent quota status | Route exclusion |
| `AgentUsageAllowance.status` | `blocked`, `depleted`, `exhausted`, etc. | Hard exclusion signal |
| `AgentUsageAllowance.kind`, `.period`, `.provider` | Quota classification | Granular threshold routing |

**Freshness semantics:** `isFresh()` compares `generatedAt` UTC against `now` with a configurable `maxAge` (default `Duration(hours: 1)`). The routing module can use this to detect stale data and apply the conservative-skip degradation policy from Requirements.md.

**Polling:** `agent_usage_scan_actions.dart` implements 1-minute polling with `_agentUsagePollingInterval`, coalesced single-flight scans via `_agentUsageScanFuture`, and an `ensureAgentUsageLoadedAndFresh` entrypoint.

### 1.3 SkillAgentCompatibility (capability mapping)

**File:** `apps/desktop/lib/src/application/features/skill_hub/models/skill_agent_compatibility.dart`

| Constant / Function | Routing Signal | Usable For |
| --- | --- | --- |
| `skillCapableAgentIds` | Static set of agents with skill execution | Capability: skill execution |
| `_sharedAgentSkillIds` | Agents sharing the generic skill format | Cross-agent skill compatibility |
| `_claudeCompatibleSkillIds`, `_codexCompatibleSkillIds` | Agent-specific format compatibility | Capability: specific skill formats |
| `canonicalSkillAgentId(value)` | Normalizes aliases to canonical IDs | Identity resolution for routing |
| `skillLoaderAgentIdsForPath(...)` | Which agents can load a skill at a path | Capability: path-based routing |

**Gap:** This file provides the *only* existing capability mapping in the codebase — and it covers only skill execution compatibility. There is no general-purpose role/capability registry (e.g., "can do code review", "can do web search", "supports image input"). The routing module must introduce this.

### 1.4 packaging.modules.json (module packaging precedent)

**File:** `apps/desktop/packaging.modules.json`

| Field | Value | Relevance |
| --- | --- | --- |
| `schemaVersion` | `v0.0.1:client-desktop:packaging-modules-1` | Versioned schema |
| Every module's `required` | `true` | No optional module exists yet |
| `modules.*.category` | e.g., `"agents"`, `"storage"`, `"mcp"` | Grouping mechanism |
| `modules.*.requires` | Dependency array | Declares inter-module deps |
| `modules.*.platforms` | Platform array | Per-platform inclusion |
| `deferredCapabilities` | Status + reason | Placeholder for future work |

**Gap:** The routing module will be the first `required: false` entry. Build tooling has never exercised conditional module exclusion. The `requires` and `platforms` fields already express the dependency graph the routing module will plug into.

### 1.5 Agent Render Adapters (per-agent metadata shape)

**Directory:** `apps/desktop/assets/agent-render-adapters/`  
**Index:** `index.json` lists 12 named adapters + `generic.json` fallback.

Per-adapter JSON shape (from `claude-code.json`):

| Field | Content | Relevance |
| --- | --- | --- |
| `id` | Canonical agent identifier | Identity authority for rendering |
| `displayName` | Human label | Display in routing disclosure UX |
| `match.agentIds` | Array of matching agent IDs | Wildcard `*` for generic |
| `match.sourceClients` | Matching source client IDs | Disambiguation |
| `match.adapterIds` | Matching adapter IDs | Adapter identity |
| `layout`, `userBubble`, `markdown`, `tones` | Visual rendering config | Rendering only — no routing signal |

**Conclusion:** Render adapters own *presentation* metadata. They do **not** declare roles, capabilities, priority, or routing policy. This is the right boundary: rendering concerns stay in render adapters; routing metadata belongs in a separate authority (the policy document).

### 1.6 TargetCandidate (adapter readiness and capabilities)

**File:** `apps/desktop/lib/src/contracts/target_candidate.dart`

| Field / Getter | Routing Signal | Usable For |
| --- | --- | --- |
| `target` | Canonical agent ID | Identity |
| `adapterCapabilities` | Dynamic capability map | Model catalogs, conversation protocol |
| `conversationReadiness` | `ready` / `unverified` / blocked | Hard-gate: non-ready → excluded |
| `conversationBlocker` | Blocking reason string | Exclusion reason for disclosure |
| `canRelayRuntime` | `visibleInClient && readiness == 'ready' && supportsAction('runtime.message.send')` | Send eligibility |
| `modelCatalog` | Nested model list with reasoning efforts | Model/effort candidate enumeration |
| `supportedActions` | Action capability list | Feature-gate signals |

**This is the runtime readiness authority.** The routing engine must consume `canRelayRuntime` as a hard exclusion gate (parent plan's fail-closed readiness).

---

## 2. Current Orchestrator Capabilities And Gaps

### 2.1 What the current resolver can do

1. **Fallback chain dispatch:** Walk an ordered list of `AgentModelLibraryEntry` candidates; first successful send wins (`AgentOrchestrationStrategy.fallback`).
2. **Dynamic allocation (parallel fanout):** Send to all candidates in the rule (`AgentOrchestrationStrategy.dynamicAllocation`).
3. **Circuit breaker exclusion:** Skip agents in `circuitBrokenAgentIds` with reason `circuit-open`.
4. **Allowance exhaustion skip:** Check `AgentUsageAllowance.status` against a hardcoded set of blocking statuses; skip with reason `quota-insufficient`.
5. **Deduplication:** `seenRoutes` set prevents the same agent/model/effort tuple from appearing twice.
6. **Normalization:** Validate entries against currently detected targets' model catalogs.
7. **Single policy persistence:** `PlatformAgentOrchestrationPolicyStore` saves/loads one JSON file via `MobileRelayJsonStore`.

### 2.2 What the current resolver cannot do

| Missing Capability | REQ | Evidence (file:line proving the gap) |
| --- | --- | --- |
| Role/capability matching | REQ-MAR-002 | `resolveAgentDispatchPlan` has no role/capability parameters; routes are selected purely by `routeKeys` position |
| Priority ordering beyond array position | REQ-MAR-002 | Priority is assigned as `routes.length + 1` — sequential, not policy-declared |
| Hot-reload policy from file system | REQ-MAR-001 | `PlatformAgentOrchestrationPolicyStore.load` is called once at startup; no watcher, no reload signal |
| Policy schema validation with error positions | REQ-MAR-001 | `fromJson` silently falls back on invalid input rather than reporting errors |
| Mid-task agent switch | REQ-MAR-004 | `_sendOrchestratedConversationMessage` dispatches once per user message and never re-evaluates |
| Distillation or handoff package | REQ-MAR-003 | `_dispatchPromptForRoute` wraps the raw user text in a template; no prior-context compression |
| Explainable per-candidate reasons | REQ-MAR-002 | `AgentDispatchSkip.reason` exists but `AgentDispatchRoute.reason` is always a fixed Chinese string |
| Optional module packaging | REQ-MAR-005 | All modules in `packaging.modules.json` are `required: true` |
| Stale-usage degradation policy | REQ-MAR-001 | `resolveAgentDispatchPlan` does not check `AgentUsageReport.isFresh()`; stale data is used as-is |
| File-watch infrastructure in Dart layer | REQ-MAR-001 | No `watchFile` / `Directory.watch` / `Stream` file usage found in `apps/desktop/lib/` |

### 2.3 Existing infrastructure that routing can reuse

| Component | Reuse Opportunity |
| --- | --- |
| `notify` crate in `crates/lico-client-native/Cargo.toml` | Cross-platform file system watcher already available in the Rust sidecar; can push change events to Dart via FFI |
| `AgentUsageReport.isFresh()` | Ready-made staleness check with configurable maxAge |
| `TargetCandidate.canRelayRuntime` | Readiness hard-gate already in place |
| `conversationService.send(...)` with `AgentDispatchBind` | Existing dispatch lane call site — the routing engine outputs a plan, the lane executes it |
| `agentOrchestrationCircuitBrokenAgentIds` | Circuit-breaker state management pattern |
| `_syncAgentAllowanceOverrides` | Pattern for merging fresh allowance data into override maps |

---

## 3. Comparable Router Practice Survey

### 3.1 OpenRouter (server-side model routing)

**Source:** openrouter.ai/blog/insights/model-routing, openrouter.ai/docs

| Feature | Schema / Mechanism | Adopt / Reject | Reason |
| --- | --- | --- | --- |
| Two-layer routing (model selection + provider failover) | `models[]` array for model fallback; `provider{}` object for provider routing | **Adopt concept** | Separating "which agent" from "which provider/model" mirrors our routing engine vs. dispatch lane split |
| Declarative preset with named slug | Server-side config referenced by `@preset/slug`; changes propagate without code edits | **Adopt concept** | Directly maps to hot-reloadable policy files referenced by `id` |
| Provider routing fields: `order`, `sort`, `allow_fallbacks`, `only`, `ignore`, `zdr`, `max_price` | Flat object with typed fields | **Adopt structure** | Priority order, exclusion lists, and data-governance constraints are useful policy schema patterns |
| Auto Router with `cost_quality_tradeoff` | ML-based model selection, session stickiness via `session_id` | **Reject** | Requires external ML service (NotDiamond); the routing module is a pure Dart local engine with no network dependency |
| Session stickiness (model+provider pinned per conversation) | Implicit hash or explicit `session_id` | **Adopt concept** | Maps to per-task route history: once a route is chosen, stay until policy or health forces a switch |

**Key takeaway:** OpenRouter's preset mechanism validates the hot-swap-without-restart pattern. Its field-level schema (`order`, `sort`, `allow_fallbacks`, constraints) provides a proven vocabulary for declarative routing policy.

### 3.2 LiteLLM (proxy-side load balancing + fallback)

**Source:** docs.litellm.ai/docs/routing, docs.litellm.ai/docs/proxy/reliability

| Feature | Schema / Mechanism | Adopt / Reject | Reason |
| --- | --- | --- | --- |
| YAML config with `model_list` and `router_settings` | Declarative YAML; models declare `litellm_params`, `order`, `rpm`, `tpm` | **Adopt concept** | File-based config with schema validation is the target pattern |
| `routing_strategy` field | `simple-shuffle`, `least-busy`, `usage-based-routing`, `latency-based-routing` | **Adapt** | Our strategies are role/capability-first, not pure load-balancing; adopt the field shape but define routing-appropriate strategies |
| `fallbacks` with `primary_model` + `fallback_models` | Ordered fallback chain per model group | **Adopt structure** | Maps directly to priority-ordered route candidates per policy rule |
| `allowed_fails` + `cooldown_time` | Cooldown unhealthy deployments after N failures | **Adopt concept** | Matches circuit-breaker pattern already in codebase; adopt tunable thresholds into policy schema |
| `context_window_fallbacks` / `content_policy_fallbacks` | Error-type-specific fallback chains | **Reject** | Over-engineering for a local routing engine; the routing module treats all dispatch failures uniformly with circuit-breaker escalation |
| `routing_groups` with per-group strategy + args | Named groups with independent routing parameters | **Reject** | Adds complexity without value; our policy rules already scope routing to named agent sets |
| Hot reload via `/config/update` API or DB-backed changes | Runtime config update endpoint | **Adopt concept, reject mechanism** | We use file-system watch (not HTTP API) for hot reload to stay in the fail-closed local-only posture |

**Key takeaway:** LiteLLM validates YAML/JSON config → ordered fallback → cooldown → retry as a proven pipeline. The `router_settings` structure (strategy, retries, timeout, cooldown, allowed_fails) is directly adoptable as tunable policy fields. The key difference: LiteLLM is a network proxy with server-side storage; our module is a local pure-Dart engine reading policy from the file system.

### 3.3 Synthesized design implications

| Design Decision | Evidence Basis |
| --- | --- |
| Policy schema uses typed JSON with named fields (not opaque routeKeys) | Both OpenRouter (typed `provider{}` object) and LiteLLM (typed `router_settings`) validate this over positional arrays |
| Hot reload is file-watch-driven with atomic snapshot swap | OpenRouter presets propagate without code changes; LiteLLM supports runtime config reload; local file watch fits our no-network-dependency posture |
| Fallback is ordered by priority with circuit-breaker cooldown | Both systems use ordered fallback with automatic cooldown; LiteLLM's `allowed_fails` + `cooldown_time` and OpenRouter's 30-second deprioritization are the proven patterns |
| Routing decision is explainable with per-candidate status | OpenRouter surfaces provider selection reasons; LiteLLM logs routing decisions; our REQ-MAR-007 mandates UX disclosure of the same |
| Stickiness within a task, re-evaluation at boundaries | OpenRouter's session stickiness + cache expiry models this: pin the route within a conversation, but allow re-routing on health/policy change |

---

## 4. Metadata Authority Decision

### 4.1 Problem statement

The routing engine needs per-agent role and capability declarations to match policy requirements against available agents. Three existing sources partially address this, but none is authoritative for routing:

| Source | What it declares | Why it is insufficient |
| --- | --- | --- |
| `agent-render-adapters/*.json` | Display rendering preferences | No roles, capabilities, or routing-relevant metadata |
| `TargetCandidate.adapterCapabilities` | Runtime capability map (models, protocol, readiness) | Dynamic runtime state, not declarative routing policy |
| `skill_agent_compatibility.dart` | Skill-format compatibility sets | Covers only skill execution; not general-purpose capabilities |

### 4.2 Decision: Policy document is the sole routing metadata authority

**Per-agent role and capability declarations belong in the policy document itself, not in render adapters or runtime capabilities.**

**Justification:**

1. **Operator control:** Roles and capabilities are policy decisions (e.g., "Claude Code is the code-review agent with deep reasoning") not runtime facts. The operator who writes the policy assigns roles.
2. **Hot-reload scope:** When an operator changes which agent handles which role, only the policy file should change. Render adapters and runtime capabilities are not operator-editable routing configuration.
3. **Fail-closed boundary:** Routing metadata must not depend on runtime discovery succeeding. A policy file that declares agent roles works even when readiness probes have not yet completed — the engine simply excludes non-ready candidates from routes it otherwise knows about.
4. **Separation of concerns:** Render adapters serve the UI layer. `TargetCandidate.adapterCapabilities` serves the dispatch lane. `skill_agent_compatibility.dart` serves the skill hub. The routing module owns its own domain data.

**Runtime capabilities (readiness, supported models, health) remain signals consumed from `TargetCandidate` at decision time** — they gate which declared candidates are eligible, but they do not *declare* routing roles or capabilities.

**Schema implication:** The policy document gains per-agent declarations:

```
agents:
  - id: "claude-code"
    roles: ["code-review", "architecture"]
    capabilities: ["reasoning-deep", "tool-use"]
    priority: 1
    allowanceThreshold: { kind: "token", minimum: 1000 }
    distillation: { distiller: "self", maxLength: 4096 }
```

This lives alongside strategy rules and route declarations in the same policy file, keeping the routing module's external surface to one file type.

### 4.3 Consequences

- Render adapters (`agent-render-adapters/`) are **not modified** by this plan.
- `TargetCandidate` is **consumed read-only** by the routing engine for readiness gating.
- `skill_agent_compatibility.dart` is **not consumed** by the routing engine — skill compatibility is a skill-hub concern, not a routing concern.
- The policy schema's `agents[].capabilities` field is a string set defined by the operator; it is not derived from or validated against `adapterCapabilities`.

---

## 5. File-Watch Hot-Reload Precedent

### 5.1 Available infrastructure

| Layer | Component | Status |
| --- | --- | --- |
| Rust sidecar | `notify = "6.1"` crate in `crates/lico-client-native/Cargo.toml` | Declared dependency, not yet used in source |
| Dart layer | No `watchFile` / `Directory.watch` / `FileSystemEntity.watch` usage found | Not available |
| Policy persistence | `PlatformAgentOrchestrationPolicyStore` reads/writes via `MobileRelayJsonStore` | One-shot load, no watch |

### 5.2 Design path for hot reload

The `notify` crate in the Rust sidecar provides cross-platform file-system event notification (kqueue on macOS, inotify on Linux, ReadDirectoryChanges on Windows). The recommended approach:

1. **Rust sidecar** registers a `notify::RecommendedWatcher` on the policy directory.
2. **Debounce** write bursts (editor save storms) using `notify`'s built-in debounce or a manual timer (e.g., 200ms quiet period).
3. **FFI bridge** pushes a "policy file changed" event to Dart via the existing FFI command channel.
4. **Dart PolicyStore** re-reads and validates the file on the changed event; on success, atomically swaps the policy snapshot; on failure, retains the last good snapshot and surfaces the validation error.

This matches the `notify` crate's intended use and avoids polling. The Dart layer stays poll-free and reactive.

---

## 6. Summary Of Evidence Gaps Requiring Design Decisions

| Gap | Resolved By | Where Decided |
| --- | --- | --- |
| No role/capability metadata in any existing source | Policy document declares roles and capabilities (Section 4.2) | This Evidence |
| No file-watch pattern in Dart | Rust sidecar `notify` crate → FFI event → Dart reactive reload (Section 5.2) | This Evidence |
| No optional module packaging precedent | Routing module will be the first `required: false` entry (Section 1.4 gap) | Architecture.md (next node) |
| `resolveAgentDispatchPlan` is the only dispatch resolver | Routing engine replaces it entirely per REQ-MAR-002 and migration-completion rule | Architecture.md (next node) |
| Comparable router schema patterns identified but not bound | Synthesized takeaways (Section 3.3) inform policy schema design | Architecture.md (next node) |
