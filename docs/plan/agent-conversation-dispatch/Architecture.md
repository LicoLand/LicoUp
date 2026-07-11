# Agent Conversation Dispatch Parity — Architecture

## Architecture Goal

One dispatch lane contract covers session open/resume, prompt send, event streaming, cancel, and capability discovery for every packaged agent. Protocol differences live behind strategy-selected Rust lane executors keyed by driver metadata. Readiness stays fail-closed in the existing CL-06 resource chain. Full local control does not license ptrace, input injection, or private-database mutation.

## Layer Boundaries and Dependency Direction

```text
frontend (UI)
    -> application (controllers / messaging actions)
        -> contracts (dispatch lane + conversation models)
            <- backend (AgentConversationService implements contracts over sidecar)
                <- platform/native_client (AgentCommandRunner / stdio RPC)
                    <- crates/lico-client-native (runtime_adapters + lane executors)
                        <- resources (drivers / evidence / readiness JSON)
```

Rules:

- UI and application depend only on `contracts/` types and the dispatch lane interface.
- Backend implements contracts; it does not expose `runCliWithStdin` as a conversation API to callers.
- Native Rust owns protocol machines and readiness projection; Dart never selects argv templates per agent for conversation send.
- Tools/scripts own the parity probe harness and reducer; they consume the same dispatch lane the product uses (or a documented fixture substitute).

## Module and File Map

| Module | Path | Responsibility | Pattern |
| --- | --- | --- | --- |
| Dispatch lane contract | `apps/desktop/lib/src/contracts/agent_dispatch_lane.dart` | Abstract open/resume, send, stream, cancel, capabilities | Interface / ports |
| Conversation models | `apps/desktop/lib/src/contracts/agent_conversation_models.dart` | Semantic event/session types (existing) | Pattern-free DTOs |
| Process runner | `apps/desktop/lib/src/contracts/agent_command_runner.dart` | Low-level CLI/RPC transport only — not conversation semantics | Existing port |
| Dispatch service | `apps/desktop/lib/src/backend/features/agents/services/agent_conversation_service.dart` | Implements `AgentDispatchLane` over sidecar RPC; removes production conversation use of one-shot stdin-only send | Adapter |
| Messaging actions | `apps/desktop/lib/src/application/features/agents/controller/agent_conversation_messaging_actions.dart` | Direct send UX; readiness gate; consumes dispatch lane only | Application service |
| Orchestration / mobile relay callers | existing controller action files under `application/features/` | Must call the same dispatch lane; no protocol forks | Application service |
| Workspace disclosure | `apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart` (+ runtime settings) | Readiness, capabilities, evidence age, blocked causes | UI |
| Runtime adapter registry | `crates/lico-client-native/src/platform/runtime_adapters.rs` | Enum dispatch to protocol families; normalize results; readiness binding | Facade + strategy selection |
| ACP family executors | `opencode_driver.rs` (+ thin wrappers: `copilot_driver.rs`, `cursor_driver.rs`, `kilo_code_driver.rs`, `kimi_code_driver.rs`) and dedicated `openclaw_driver.rs` / `hermes_driver.rs` | ACP open/load/resume, stream, cancel, capability probe | Strategy (shared machine + launch spec) |
| App-server executor | `codex_app_server.rs` | Codex app-server stdio JSON-RPC | Strategy |
| Stream-json executor | `claude_code_driver.rs` | Claude Code stream-json; fail-closed exact resume until non-argv lane exists | Strategy |
| Blocked transport | `antigravity_driver.rs` | Fail-closed public-transport-unavailable | Strategy (null object / fail-closed) |
| History adapters | `crates/lico-client-native/src/domain/conversations.rs` | Read-only native history projection | Pattern-free parsers |
| Driver inventory | `crates/lico-client-native/resources/agent-conversation-drivers.json` | Canonical driver/protocol/blocker metadata | Config resource |
| Evidence store | `crates/lico-client-native/resources/agent-conversation-evidence.json` | Versioned sanitized parity evidence rows | Config resource |
| Readiness store | `crates/lico-client-native/resources/agent-conversation-readiness.json` | Reducer output; send gate authority | Config resource |
| Parity harness | `tools/scripts/client-acp-conversation-parity.mjs` (unified runner extended per Validation.md) | Live/fixture A/B producing evidence | Harness |
| Readiness reducer | `tools/scripts/client-agent-conversation-parity-reducer.mjs` | Deterministic evidence → readiness | Pure reducer |

### Pattern rationale

| Choice | Why it earns complexity | What stays simpler |
| --- | --- | --- |
| Strategy per protocol family selected by driver metadata | Agents differ by protocol family (ACP / app-server / stream-json / unavailable), not by unrelated product rules; shared ACP machine already exists | No per-agent Dart protocol branches; no second executor registry beside `RuntimeAdapter` |
| Ports & adapters (Dart contract → backend → native) | Lets direct, orchestrated, and mobile-relay callers share one API (REQ-ACD-001) | Controllers stay free of RPC argument packing |
| Versioned JSON evidence schema + pure reducer | Fail-closed readiness must be deterministic and forge-resistant (REQ-ACD-003) | No new database; no in-memory readiness authority in Flutter |
| Fail-closed null strategy for blocked transports | Encodes REQ-ACD-004 without special-case UI hacks | Antigravity does not get a fake send path |
| Pattern-free DTOs for conversation models | Existing semantic model is sufficient | Do not introduce event-sourcing or a second message store for dispatch |

## Interface Contracts

### Dart — `AgentDispatchLane`

Scaffold: `apps/desktop/lib/src/contracts/agent_dispatch_lane.dart`.

```dart
abstract class AgentDispatchLane {
  Future<AgentDispatchSession> openOrResume({
    required AgentCommandRunner runner,
    required String agentId,
    String sessionId = '',
    AgentDispatchBind bind = const AgentDispatchBind(),
  });

  Future<AgentDispatchTurnResult> send({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  });

  Stream<AgentDispatchEvent> stream({
    required AgentCommandRunner runner,
    required String agentId,
    required String sessionId,
    String turnId = '',
  });

  Future<AgentDispatchCancelResult> cancel({
    required AgentCommandRunner runner,
    required String agentId,
    required String sessionId,
    String turnId = '',
  });

  Future<AgentDispatchCapabilities> capabilities({
    required AgentCommandRunner runner,
    required String agentId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  });
}
```

Supporting types (same file or adjacent models): `AgentDispatchBind` (cwd, binary, model, reasoning, permission fields), `AgentDispatchSession`, `AgentDispatchTurnResult`, `AgentDispatchEvent` (maps into existing semantic event model), `AgentDispatchCancelResult`, `AgentDispatchCapabilities` (C-01..C-06 + lane kind + blocker codes).

`AgentConversationService` becomes the production implementer. `sendRuntimeMessage` converges into `send` / `openOrResume`; callers must not invoke `runCliWithStdin(['agent','message','send',…])` directly after the Dart implementation node.

### Rust — lane executor surface

Keep selection in `runtime_adapters::send_message` / capability probe. Each protocol family exposes the same logical operations (already partially present as `execute` + `capability_probe`):

```text
probe(executable, cwd, limits) -> CapabilityProbe | ProtocolFailure
execute(executable, params, prompt, session_id, cwd, limits) -> RunResult
cancel(handle | session/turn ids) -> CancelResult   // extend where missing
stream events: either incremental RunResult events or a dedicated stream RPC (below)
```

Do **not** add a parallel executor registry. Extend `RuntimeAdapter` match arms and shared ACP/`AcpDriverSpec` machines. Lane-upgrade adapters stay fail-closed with recorded codes until official resume exists.

### stdio RPC additions (`lico-client.stdio.v1`)

Today conversation send uses CLI `agent message send --stdin-json` (often via process spawn). Architecture requires explicit RPC methods so long-lived stdio sessions can stream and cancel without a new process per turn:

| Method | Purpose | Request (conceptual) | Result (conceptual) |
| --- | --- | --- | --- |
| `agent.conversation.open` | Open or resume native session | `agentId`, optional `sessionId`, bind fields | `sessionId`, `threadId`, capabilities snapshot |
| `agent.conversation.send` | Send prompt on bound session | `agentId`, `sessionId`, `text`, bind fields | `turnId`, `status`, final/partial payload refs |
| `agent.conversation.stream` | Subscribe to turn/session events | `agentId`, `sessionId`, optional `turnId` | NDJSON event frames → semantic events |
| `agent.conversation.cancel` | Cancel in-flight turn | `agentId`, `sessionId`, `turnId` | `status`, actionable error codes |
| `agent.conversation.capabilities` | Probe lane capabilities | `agentId`, bind fields | capability matrix + blocker codes |

Compatibility: existing `agent message send` CLI may remain as a thin wrapper that calls the same Rust `send_message` path during migration, then is removed from production conversation callers in the Dart node (complete-migration). RPC protocol name stays `lico-client.stdio.v1`; new methods are additive.

## Evidence Artifact Schema

Authority remains CL-06 / existing schemas:

- Drivers: `v0.0.1:client-agent-conversation-drivers-1`
- Evidence: `v0.0.1:client-agent-conversation-parity-evidence-1`
- Readiness: `v0.0.1:client-agent-conversation-readiness-1`

Evidence row minimum fields (already required by drivers.json `evidenceContract`): schema/harness version, `agentId`, `driverId`, `runtimeProtocol`, redacted `runtimeVersionClass` / `runtimeSourceClass`, capability snapshot, core/conditional booleans, `officialNativeLane`, `releaseUiPassed`, `cleanupPassed`, `privacyPassed`, `consecutivePasses`, failure stage/code, digests (`runtimeVersionDigest`, `capabilitySnapshotDigest`, `registryDigest`, `driverInventoryDigest`, `evidenceDigest`).

Flow:

```text
parity harness (live or fixture)
  -> writes sanitized rows to agent-conversation-evidence.json
  -> client-agent-conversation-parity-reducer.mjs
  -> regenerates agent-conversation-readiness.json
  -> targets scan / UI read readiness; sendEnabled only when ready
```

No alternate Flutter-side readiness writer.

## Implementation Node Ownership (disjoint files)

| Node | Owns (write) | Consumes (read-only interfaces) |
| --- | --- | --- |
| `850437e2-…` Dart dispatch contract | `agent_dispatch_lane.dart`, `agent_conversation_service.dart`, messaging/orchestration/relay call sites, Dart contract tests | Native RPC methods as specified; existing conversation models |
| `8b22e4bb-…` Rust lane executors | `runtime_adapters.rs`, `*_driver.rs`, `codex_app_server.rs`, stdio RPC method wiring in `lico-client` bin/domain | drivers.json blocker codes; Evidence.md classifications |
| `5d34af8d-…` Probe + reducer | `client-acp-conversation-parity.mjs`, reducer script, `agent-conversation-evidence.json`, readiness regeneration | Dispatch lane / RPC; drivers inventory |
| `0565bc71-…` Disclosure UX | `agent_conversation_workspace.dart`, runtime settings UI, related widget tests | Readiness/capabilities from controller shell state; no new fetch authority |
| `f5b1477a-…` Final validation | Validation receipts only | Runs Validation.md matrix |

Parallelism: Dart node and Rust node may proceed in parallel after this architecture lands, because they own disjoint trees and meet at the named RPC methods. Probe node depends on both for live path but can extend fixtures earlier. UI disclosure depends on readiness fields already projected today and on capability matrix fields emitted by the Rust node.

## Scaffold Delivered With This Node

- `docs/plan/agent-conversation-dispatch/Architecture.md` (this file)
- `apps/desktop/lib/src/contracts/agent_dispatch_lane.dart` — abstract interface + bind/result type stubs (no production wiring yet)

Implementation nodes fill behavior; they must not redefine the module map without updating this document first.

## Non-Goals Inside Architecture

- New readiness store or parallel send path
- Unofficial attach (ptrace / input injection / private DB mutation)
- Hardcoding any adapter to `ready`
- Multi-agent routing/distillation (child plan consumes this dispatch lane as a dependency)
