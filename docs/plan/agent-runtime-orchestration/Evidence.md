# Local Agent Runtime and Orchestration Evidence

## Current repository evidence

- `AgentDispatchLane` already declares open/resume, streaming, cancel, cleanup, and capability operations. `AgentConversationService` uses stdin JSON and NDJSON, rejects exact-session mismatch, and projects progressive plus terminal events.
- `sendConversationMessage` forwards the selected conversation's native session ID, appends progressive events, and commits the terminal reply to the selected thread. This is a useful control-plane base, not proof that product sending is currently available.
- The native runtime dispatches the packaged adapter set and multiple drivers emit structured turn events. The current readiness snapshot nevertheless reports no ready or send-enabled adapter, so fixture and unit coverage cannot be promoted to a product claim.
- The routing policy supports priority fallback, serial, parallel, and coordinator-worker strategies. The planner evaluates readiness, role, capability, priority, allowance, and circuit state; route-session binding preserves an adapter session per routed branch.
- The current distillation broker bounds source turns and calls a configured distiller through the dispatch lane with fidelity checks. Its bounds are global estimates rather than the destination model's real budget, and the handoff remains inline JSON rather than a protected local context path.
- Routing policy files already use atomic last-good reload and a debounced watcher. Adapter transport/readiness configuration remains spread across contract fixtures, native resources, renderer assets, and hard-coded runtime adapter identities, and most projections require a rebuild.
- The adapter schema, template, canonical manifests, contributor standard, and parity checks already describe much of the required lifecycle. They need one current ownership location, runtime configuration semantics, dynamic refresh, and full-inventory acceptance.
- The release plan currently owns blocked adapter and routing leaves and permits a supported subset. That boundary conflicts with the requested exact all-adapter product goal and must become a receipt consumer.

## Product gap

| Required outcome | Current state | Gap to close |
| --- | --- | --- |
| Real local forwarding for every packaged adapter | Shared interfaces and driver skeletons exist; product readiness is empty | Prove every official lane live and promote the exact manifest set together |
| Realtime UI | Ordered event plumbing and tests exist | Bind real driver events to the release-product UI for every adapter |
| Same-session follow-up | Exact-ID checks exist | Prove native↔Arc bidirectional continuation and persistence across later turns |
| Automatic orchestration | Policy planner and strategy execution exist | Execute only ready adapters through one bounded scheduler and failure model |
| Context passed as local path | Inline distillation package only | Add private immutable artifact, typed path reference, digest, acknowledgement, and cleanup |
| Overflow handling | Fixed approximate input window | Add target model/adapter limits, reserved budgets, deterministic overflow, and unknown-limit policy |
| Framework compression | Agent-based distillation exists | Declare compression capability, select an eligible framework, add hierarchical bounded cache and fidelity gates |
| Dynamic adapter configuration | Routing-only watcher exists | Establish canonical manifests plus runtime overrides, atomic snapshot reload, drain semantics, and generated projections |
| Adapter onboarding | Static standard/schema exists | Make it the only workflow and prove a synthetic adapter touches no unrelated inventory |

## Open-source and primary-source practice

- The OpenAI Agents SDK separates durable sessions from server-managed continuation and warns against layering both mechanisms. Lico Arc therefore keeps exactly one native continuity authority per adapter and rejects silent fallback: <https://openai.github.io/openai-agents-python/sessions/>.
- Its handoff contract supports typed handoff input and explicit input filtering; Lico Arc applies the same principle with a versioned context artifact and adapter-owned typed reference rather than forwarding an unbounded transcript: <https://openai.github.io/openai-agents-python/handoffs/>.
- Its runner exposes streamed runs, bounded tool execution controls, and privacy controls for tracing. Lico Arc similarly centralizes lifecycle and excludes sensitive input/output from public evidence: <https://openai.github.io/openai-agents-python/running_agents/> and <https://openai.github.io/openai-agents-python/tracing/>.
- LangGraph documents router, supervisor, handoff, and subagent patterns as distinct choices and identifies context engineering as the central multi-agent concern. The existing four explicit Lico strategies remain policy concepts rather than being collapsed into one opaque LLM router: <https://langchain-ai.github.io/langgraph/tutorials/multi_agent/multi-agent-collaboration/>.
- LangGraph supervisor defaults to returning only the last worker message and supports explicit history modes. Lico Arc keeps a compact context artifact and real terminal result rather than copying every worker transcript into every branch: <https://langchain-ai.github.io/langgraphjs/reference/functions/langgraph-supervisor.createSupervisor.html>.

## Data-structure and algorithm choices

- Immutable maps keyed by adapter ID, native session handle, configuration revision, and context digest provide expected O(1) lookup and prevent repeated inventory scans.
- A bounded DAG uses indegree counts plus a stable ready queue, giving O(V+E) scheduling before adapter execution. Global and per-adapter semaphores cap concurrency; unknown outcomes are never retried automatically.
- Context selection is one chronological O(n) pass with pinned required sections. Oversize input uses bounded hierarchical chunks; cache lookup is content-addressed and O(1), with byte/count LRU limits.
- Configuration reload parses and validates off to the side, then atomically swaps one immutable snapshot. Active turns pin their revision; removals drain rather than mutating an in-flight transport.

## Risks and unresolved external facts

Some packaged frameworks may not currently expose an official safe protocol, exact resume, cleanup, or live evidence in the authorized environment. The plan intentionally does not convert that external limitation into an accepted exclusion. The corresponding adapter Node records the official capability gap and remains blocked until an implementation that controls the same native session exists.
