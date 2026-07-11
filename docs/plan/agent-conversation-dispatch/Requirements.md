# Agent Conversation Dispatch Parity Requirements

## User Problem

Users who install coding agents on their machine expect LicoArc to talk to those agents the same way the agents' own surfaces do. Today every packaged adapter is fail-closed (`0 ready`, `sendEnabled: 0`): discovery and history may work, but sending is gated off because parity evidence is missing or an official local lane is structurally blocked. Dispatching through Arc must not invent a parallel conversation store, guess the newest session, or silently degrade to a generic command template. The product problem is to make Arc dispatch produce the same observable native effect — session continuity, streamed events, cancel behavior, and on-disk history — through each agent's strongest official local lane, and to keep send disabled until versioned evidence proves it.

## Target Users

- Desktop power users who already run one or more local coding agents (CLI, ACP, app-server, or stream-json) and want Arc as the unified conversation surface.
- Operators who orchestrate multi-agent work from Arc and need every send path to share one dispatch contract.
- Mobile users who relay prompts to a paired desktop host and expect the same native session semantics once the desktop adapter is ready.

## Target Workflows

| Workflow | Actor | Required dispatch behavior |
| --- | --- | --- |
| Direct conversation | Desktop user in Agents workspace | Open or resume a native session, send a prompt, stream events into the semantic model, cancel in-flight work, and read back native history — all through the unified dispatch lane. |
| Orchestrated dispatch | Desktop orchestration / multi-agent caller | Reuse the same open/resume/send/stream/cancel/capability-discovery contract; no per-callsite protocol fork or alternate send path. |
| Mobile relay | Paired mobile client via Secure Mesh | Desktop host executes the same dispatch contract for the selected agent; mobile sees readiness and blocked causes, never a silent best-effort send. |

## Functional Requirements

| ID | Requirement | Testable statement |
| --- | --- | --- |
| REQ-ACD-001 | Unified dispatch lane contract | One Dart-facing dispatch contract exposes session open/resume, prompt send, event stream, cancel, and capability discovery. Direct conversation, orchestrated dispatch, and mobile-relay callers all invoke that contract. No caller may open a parallel process-execution or protocol path for conversation send. After convergence, the previous single-lane `AgentCommandRunner.runCliWithStdin` send path does not remain as a production conversation route. |
| REQ-ACD-002 | Native session continuity and event parity | For every adapter whose readiness is `ready`, Arc preserves native session/thread ids on resume (exact session, never “latest”), streams native events losslessly into the semantic event model, honors cancel/timeout with actionable states, and records a per-agent capability matrix covering CL-06 C-01..C-06 as supported by the probed native version. Observable parity is defined by CL-06 P-01..P-10 outcomes, not by matching internal agent implementation details. |
| REQ-ACD-003 | Evidence-backed fail-closed readiness | Automated parity probes produce versioned per-adapter evidence mapped to CL-06 P-01..P-10 (and applicable C-01..C-06). The readiness reducer consumes only that evidence chain (`drivers` → `evidence` → `readiness`). `sendEnabled` remains false for any adapter without current, schema-valid, digest-bound evidence. No implementation may hardcode an adapter to `ready`. |
| REQ-ACD-004 | Official-lane compliance boundary | Dispatch uses only official published local lanes: CLI resume/stdio where the vendor documents a public conversation surface, ACP, app-server, stream-json, or a vendor-published versioned attach protocol. The following techniques are prohibited for conversation dispatch and for parity evidence collection unless the target explicitly publishes a versioned attach protocol that authorizes them: **ptrace**, **input injection**, and **private-database mutation**. Native agent history stores stay read-only for Arc. Adapters without an official lane remain `blocked` with recorded structural reasons and must not be bypassed by a generic command template. |
| REQ-ACD-005 | Parity disclosure UX | The conversation workspace discloses per-agent readiness status, capability matrix, parity evidence age (or missing/stale), and blocked/failure summary codes. Every send-gate message states an actionable cause derived from readiness or evidence, not a generic “unavailable” string. |
| REQ-ACD-006 | End-to-end verification | Final validation proves REQ-ACD-001..005 against the Validation.md matrix: unified contract usage, driver/lane parity semantics, evidence → reducer → send gate chain, official-lane boundary, and disclosure UX. Synthetic harnesses may demonstrate progress but cannot alone promote readiness or close P-10. |

## Official-Lane Boundary (CL-06.3 Hard Requirement)

This boundary is absolute for the plan and must not be relitigated by downstream nodes.

**Allowed lanes (when published by the agent vendor for the installed version):**

- Public CLI conversation surfaces with documented resume/session binding
- ACP (Agent Client Protocol) local stdio/JSON-RPC or NDJSON framing
- Vendor app-server / local JSON-RPC conversation servers
- Documented stream-json / structured stdout conversation protocols
- Vendor-published versioned attach protocols that explicitly authorize a stronger local control surface

**Prohibited techniques (exact list):**

1. **ptrace** (or equivalent process debugging attach) to drive or inspect agent conversation state
2. **input injection** into the agent UI or process (synthetic keystrokes, accessibility injection, or similar) to simulate native conversation
3. **private-database mutation** of the agent's on-disk history, session, or credential stores

Full local machine control does **not** license these techniques. An adapter that cannot reach parity through an allowed lane stays `blocked` with a recorded structural cause (for example `official_native_lane_missing`, `exact_session_resume_unavailable`, `antigravity_public_transport_unavailable`).

## Adapter Acceptance Targets

Canonical packaged adapters are owned by `apps/desktop/packaging.modules.json`. Readiness authority is `crates/lico-client-native/resources/agent-conversation-readiness.json` (currently `0 ready / 3 blocked / 7 unverified`, `sendEnabled: 0`). Per-adapter lane choice and structural blockers are evidence questions for the Evidence node; this contract fixes the acceptance tiers every adapter must land in.

| Tier | Meaning | Product behavior |
| --- | --- | --- |
| `ready` | Official lane proven; P-01..P-10 pass; every native-supported C-01..C-06 passes; release-UI consecutive passes meet the reducer minimum. | Composer enabled; native-parity claim allowed. |
| `partial` | Core text may pass, but at least one native-supported conditional capability is not equivalent. | Explicit preview only; exact gap shown; no full-parity claim; send policy follows product preview rules without claiming ready. |
| `failed` | A mandatory or applicable check was executed and failed. | Composer disabled; sanitized failure category shown. |
| `blocked` | Canonical driver, official native lane, authorized test environment, or safe cleanup path is missing. | Composer disabled; structural reason recorded; generic command cannot bypass. |
| `unverified` | Evidence missing, stale, or version-mismatched. | Send disabled by default; discovery/history may remain independent. |
| `history-only` | Only safe native-history reading/rendering is supported. | Read-only UI; no message composer. |

Baseline inventory at plan start (authoritative counts live in the readiness resource; this table is the product expectation, not a hardcoded ready list):

| Agent id | Starting readiness class | Acceptance target for this plan |
| --- | --- | --- |
| openclaw | unverified | Ready via official ACP lane once evidence closes, else remain unverified/failed with recorded cause. |
| claude-code | blocked (`official_native_lane_missing`) | Ready only if an official exact-resume lane is proven without prohibited techniques; otherwise stay blocked with recorded cause. |
| codex | unverified | Ready via official app-server lane once evidence closes, else remain unverified/failed with recorded cause. |
| antigravity | blocked (`antigravity_public_transport_unavailable`) | Stay blocked unless a safe public structured send/resume transport appears; no unofficial attach. |
| opencode | unverified | Ready via official ACP lane once evidence closes, else remain unverified/failed with recorded cause. |
| copilot | unverified | Ready via official ACP lane once evidence closes, else remain unverified/failed with recorded cause. |
| kilo-code | unverified | Ready via official ACP lane once evidence closes, else remain unverified/failed with recorded cause. |
| cursor | blocked (`exact_session_resume_unavailable`) | Ready only if exact native-session resume is proven on the official ACP lane; otherwise stay blocked with recorded cause. |
| hermes | unverified | Ready via official ACP lane once evidence closes, else remain unverified/failed with recorded cause. |
| kimi-code | unverified | Ready via official ACP lane once evidence closes, else remain unverified/failed with recorded cause. |

Which currently-blocked adapters gain an official lane during this plan is decided by the Evidence node after per-agent lane enumeration; implementation must not assume readiness.

## Non-Functional Requirements

- Evidence and readiness artifacts contain only booleans, counts, redacted version/source classes, digests, and error codes — never prompts, responses, paths, session ids, argv text, accounts, credentials, or raw logs.
- Child process stdout/stderr are drained concurrently, bounded, and sanitized (CL-06 P-08).
- The readiness reducer stays fail-closed; release packaging rejects drift or forged `ready` state.
- Existing single-lane send behavior converges into the unified dispatch contract; no parallel legacy conversation send path survives.
- Multi-agent routing and context distillation (child plan) consume this dispatch contract; they do not define a second send path.

## Scope

**In scope**

- Unified dispatch lane contract for direct, orchestrated, and mobile-relay callers
- Per-protocol official-lane executors with native session continuity
- Automated parity probe harness and evidence → readiness reducer wiring
- Fail-closed send gating and conversation-workspace parity disclosure
- End-to-end validation against REQ-ACD-001..006

**Out of scope (non-goals)**

- Achieving parity via ptrace, input injection, or private-database mutation
- Mutating native agent history databases to fabricate continuity
- Hardcoding adapters to `ready` without current evidence
- Treating discovery, history import, or a generic command template as conversation support
- Redefining the packaged adapter set outside `packaging.modules.json`
- Multi-agent role/priority routing and context distillation (owned by the child plan `multi-agent-routing`, which depends on this foundation)
- Server-side policy or core gateway protocol authority

## Final Acceptance Target

This plan is complete when:

1. REQ-ACD-001..006 are implemented and mapped checks in Validation.md pass.
2. Every packaged conversation adapter is either `ready` through an official lane with current evidence, or explicitly non-ready (`partial` / `failed` / `blocked` / `unverified` / `history-only`) with a recorded actionable cause.
3. `sendEnabled` is true only for reducer-owned `ready` adapters.
4. No production conversation send path exists outside the unified dispatch contract.
5. The CL-06.3 prohibited techniques list remains enforced in architecture, implementation, and validation.

Until then, product copy and release behavior must not claim native-conversation parity for any adapter that is not reducer-ready.
