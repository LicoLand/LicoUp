# Agent Conversation Dispatch Parity

## Goal

Dispatching a conversation to an installed agent through LicoArc must produce the same observable effect as talking to that agent natively: the same session continuity, the same streamed events, the same interrupt behavior, and the same on-disk history the native tool would have produced. LicoArc owns the whole local machine, so parity is achieved by driving each agent through its strongest official local lane (CLI resume, ACP, app-server, stream-json) and proving the result with recorded evidence — never by assuming it.

## Current Evidence

- `docs/functionality/CLIENT-DESKTOP.md` CL-06 defines native-conversation parity as a product contract with core checks P-01..P-10, conditional capabilities C-01..C-06, a per-adapter evidence chain, and fail-closed readiness. CL-06.3 forbids ptrace, input injection, and private-database mutation unless a versioned attach protocol is published by the agent vendor.
- `crates/lico-client-native/resources/agent-conversation-readiness.json` is the authoritative reducer output and currently reports 0 ready, 3 blocked, 7 unverified adapters with `sendEnabled: 0` — every send today is gated off.
- `crates/lico-client-native/resources/agent-conversation-drivers.json` and `agent-conversation-evidence.json` record the driver inventory and structural blockers per agent.
- `crates/lico-client-native/src/domain/conversations.rs` plus `crates/lico-client-native/src/platform/*_driver.rs` implement per-agent history adapters; runtime send lanes exist only for a subset and diverge in resume/cancel semantics.
- `apps/desktop/lib/src/application/features/agents/controller/agent_conversation_messaging_actions.dart` gates sending on `conversationReadiness == ready`, and `apps/desktop/lib/src/backend/features/agents/services/agent_conversation_service.dart` sends through `AgentCommandRunner.runCliWithStdin` — a single lane that not every agent supports equally.
- `apps/desktop/lib/src/contracts/agent_command_runner.dart` is the only process-execution contract; orchestrated and mobile-relay callers reuse the same messaging actions.

## Final State

One dispatch lane contract covers session open/resume, prompt send, event streaming, cancel, and capability discovery for every supported agent. Each adapter drives its agent through the best official local protocol, and an automated parity probe harness produces versioned evidence per adapter that the readiness reducer consumes. Send stays fail-closed until parity evidence exists. The conversation UI discloses per-agent parity state, capability matrix, and blocked reasons. Adapters that cannot reach parity through an official lane remain blocked with recorded structural causes instead of degraded silent behavior.

## Requirements

| ID | Requirement |
| --- | --- |
| REQ-ACD-001 | A single dispatch lane contract (open/resume, send, stream, cancel, capability discovery) serves direct, orchestrated, and mobile-relay callers for every supported agent, with no per-callsite protocol forks. |
| REQ-ACD-002 | Each ready adapter preserves native session continuity (native session ids resume the same conversation), streams native events losslessly into the semantic event model, honors cancel, and records a per-agent capability matrix. |
| REQ-ACD-003 | Automated parity probes produce versioned per-adapter evidence mapped to CL-06 P-01..P-10; the readiness reducer consumes only that evidence; send remains disabled for adapters without current evidence. |
| REQ-ACD-004 | Dispatch uses only official published local lanes (CLI, ACP, app-server, stream-json, vendor-published attach protocols); no ptrace, input injection, or private-database mutation; adapters without an official lane stay blocked with recorded structural reasons. |
| REQ-ACD-005 | The conversation workspace disclosures per-agent readiness, capability matrix, parity evidence age, and blocked reasons, and every send-gate message states an actionable cause. |
| REQ-ACD-006 | End-to-end verification proves the dispatch contract, driver parity semantics, evidence chain, fail-closed gating, and disclosure UX against the requirements above. |

## Constraints

- CL-06.3 compliance boundary is absolute for this plan: full local control does not license unofficial process access. Attach lanes beyond official protocols require a vendor-published versioned contract first.
- Native agent history stores stay read-only; parity evidence is captured from official lane outputs, not by mutating agent databases.
- The readiness reducer stays fail-closed; no implementation node may hardcode an adapter to ready without evidence.
- Existing single-lane behavior converges into the unified dispatch contract; no parallel legacy send path survives.

## Open Points

- Which currently-blocked adapters gain an official lane during this plan is an evidence question; the evidence node must enumerate per-agent lane options before implementation locks scope.
