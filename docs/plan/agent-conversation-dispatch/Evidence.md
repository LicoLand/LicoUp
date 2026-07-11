# Agent Conversation Dispatch — Per-Adapter Lane Evidence

Observation host date: **2026-07-11** (UTC).  
Authority sources: `crates/lico-client-native/resources/agent-conversation-drivers.json`, `agent-conversation-readiness.json`, `agent-conversation-evidence.json` (adapters array empty), CL-06 in `docs/functionality/CLIENT-DESKTOP.md`, and platform driver sources under `crates/lico-client-native/src/platform/`.  
Evidence kinds: **local-observation** (CLI `--version` / `--help` on this host), **repo-fact** (checked-in driver/reducer resources and source), **vendor-doc** (URLs cited in CL-06.1; not a substitute for live parity evidence).

## Classification Legend

| Class | Meaning for this plan |
| --- | --- |
| ready-candidate | Official local lane is declared and implemented in conversation mode; no structural blocker codes; only missing/stale live evidence keeps readiness `unverified`. |
| lane-upgrade-candidate | A public lane exists in part, but exact resume and/or privacy-safe session binding is incomplete; driver or reducer records a structural gap that must be closed before ready. |
| structurally-blocked | No safe public structured send/resume transport exists under REQ-ACD-004; adapter stays blocked until the vendor publishes an allowed lane. |

## Summary Matrix

| Agent | Driver / source | Official lane | Reducer verdict | Observed version (2026-07-11) | Class |
| --- | --- | --- | --- | --- | --- |
| openclaw | `openclaw-acp` / `openclaw_driver.rs` | ACP stdio JSON-RPC | unverified (`evidence_missing`) | not-installed | ready-candidate |
| claude-code | `claude-code-stream-json` / `claude_code_driver.rs` | partial CLI stream-json (new session); exact resume argv-bound | blocked (`official_native_lane_missing`) | Claude Code **2.1.206** | lane-upgrade-candidate |
| codex | `codex-app-server` / `codex_app_server.rs` | app-server `--stdio` JSON-RPC | unverified (`evidence_missing`) | codex-cli **0.144.0** | ready-candidate |
| antigravity | `antigravity-public-transport` / `antigravity_driver.rs` | unavailable | blocked (`antigravity_public_transport_unavailable`) | not-installed | structurally-blocked |
| opencode | `opencode-acp` / `opencode_driver.rs` | ACP v1 NDJSON (`opencode acp`) | unverified (`evidence_missing`) | **1.17.12** | ready-candidate |
| copilot | `copilot-acp` / `copilot_driver.rs` | ACP (`copilot --acp --stdio`) | unverified (`evidence_missing`) | GitHub Copilot CLI **1.0.46** | ready-candidate |
| kilo-code | `kilo-code-acp` / `kilo_code_driver.rs` | ACP v1 NDJSON (`kilo`/`kilo-code acp`) | unverified (`evidence_missing`) | not-installed | ready-candidate |
| cursor | `cursor-acp` / `cursor_driver.rs` | ACP v1 (`agent acp` / `cursor-agent acp`) | blocked (`exact_session_resume_unavailable`) | not-installed | lane-upgrade-candidate |
| hermes | `hermes-acp` / `hermes_driver.rs` | ACP stdio JSON-RPC | unverified (`evidence_missing`) | not-installed | ready-candidate |
| kimi-code | `kimi-code-acp` / `kimi_code_driver.rs` | ACP v1 (`kimi acp`) | unverified (`evidence_missing`) | kimi **0.23.4** | ready-candidate |

Live parity evidence store: `agent-conversation-evidence.json` → `"adapters": []`. No adapter has current reducer-consumable evidence; `sendEnabled` remains 0 for all ten.

## P-01..P-10 Capability Mapping Key

For each adapter, cells are **expected from driver/docs** vs **proven by live evidence**:

- `impl` — driver implements the dimension on the official lane (repo-fact); not live-proven.
- `gap` — known structural gap preventing the dimension under REQ-ACD-004 / CL-06.
- `unproven` — no live evidence row; cannot claim pass.
- `n/a-blocked` — adapter structurally blocked before the check can run.

All adapters today: every P-* is at best `impl`/`gap`/`n/a-blocked` plus `unproven` for live A/B. None are live-pass.

---

## Per-Adapter Evidence

### openclaw

- **Sources:** `crates/lico-client-native/src/platform/openclaw_driver.rs`; drivers.json `openclaw-acp`; history via `conversations.rs` `HistoryAdapter::OpenClaw`.
- **Official lane:** ACP over stdio JSON-RPC (`RUNTIME_PROTOCOL = openclaw-acp-stdio-jsonrpc`). Session open uses `session/new`; resume uses `session/load` with native session key metadata (repo-fact). Vendor-doc: OpenClaw ACP (CL-06.1 link).
- **Resume / streaming:** Protocol methods carry session identity on the JSON-RPC channel (not argv). Streaming/events owned by ACP session updates (impl).
- **P-01..P-10:** P-01..P-10 = impl + unproven. No structural blocker codes.
- **Reducer:** `unverified` / `evidence_missing`; `officialNativeLaneProven: false`; `consecutivePasses: 0`.
- **Observed version:** not-installed on this host (2026-07-11).
- **Class:** **ready-candidate** — implement live evidence harness against installed OpenClaw; do not invent readiness.

### claude-code

- **Sources:** `crates/lico-client-native/src/platform/claude_code_driver.rs`; drivers.json `claude-code-stream-json`.
- **Official lane:** Public CLI `--print` with `--output-format stream-json` and stdin prompt for **new** sessions (local-observation: `claude --help` lists `stream-json`, `--resume`/`--continue`). Exact resume requires placing the native session id in CLI options/argv; driver sets `resume_session: false` and fails closed with `claude_code_secure_resume_unavailable` when a session id is requested (repo-fact comments at capability probe).
- **Resume / streaming:** Streaming for new sessions via stream-json stdout (impl). Exact resume (P-03) cannot satisfy P-08 while the only public resume channel puts the native id in argv → blocker `official_native_lane_missing`.
- **P-01..P-10:** P-02/P-04/P-07 (new-session path) = impl + unproven; P-03 = gap; P-08 for resume = gap; P-01/P-05/P-06/P-09/P-10 = unproven; overall reducer blocked.
- **Reducer:** `blocked` / `official_native_lane_missing`.
- **Observed version:** Claude Code **2.1.206** (local-observation).
- **Class:** **lane-upgrade-candidate** — needs a vendor-published resume channel that keeps session id off argv (stdin/IPC/ACP-equivalent). Until then stay blocked; no ptrace/input-injection/DB mutation.

### codex

- **Sources:** `crates/lico-client-native/src/platform/codex_app_server.rs`; `runtime_adapters.rs` Codex path; drivers.json `codex-app-server`.
- **Official lane:** `codex app-server --stdio` JSON-RPC (local-observation: `codex --help` lists `app-server`; launch args in source). Thread/turn binding and effective settings implemented (repo-fact / CL-06.1).
- **Resume / streaming:** App-server thread id binding for exact resume (impl). Interactive `codex resume` exists separately (local-observation) but Arc’s canonical lane is app-server, not TUI resume.
- **P-01..P-10:** P-01..P-10 = impl + unproven. No blocker codes. Prior core-only live verifier (`npm run client:verify:codex-conversation:live`) is explicitly **not** full readiness / P-10 (CL-06.4).
- **Reducer:** `unverified` / `evidence_missing`.
- **Observed version:** codex-cli **0.144.0** (local-observation).
- **Class:** **ready-candidate** — close live + release-UI evidence on app-server lane.

### antigravity

- **Sources:** `crates/lico-client-native/src/platform/antigravity_driver.rs`; drivers.json `antigravity-public-transport`.
- **Official lane:** **unavailable**. Driver documents TUI / prompt-bearing CLI args / sidecar `agentapi` with positional conversation id — none keep message text and native ids out of argv (repo-fact module docs). Vendor-doc: Google Antigravity conversation resume (CL-06.1).
- **Resume / streaming:** Fail-closed probe only; `antigravity_public_transport_unavailable` / `antigravity_secure_resume_unavailable`.
- **P-01..P-10:** all n/a-blocked for send parity.
- **Reducer:** `blocked` / `antigravity_public_transport_unavailable`.
- **Observed version:** not-installed (2026-07-11).
- **Class:** **structurally-blocked** — out of implementation upgrade scope until a public structured transport appears.

### opencode

- **Sources:** `crates/lico-client-native/src/platform/opencode_driver.rs` (shared ACP state machine); drivers.json `opencode-acp`.
- **Official lane:** `opencode acp` ACP v1 NDJSON (local-observation help; launch args `["acp"]`).
- **Resume / streaming:** Uses `session/load` when `loadSession` advertised; `session/resume` when capability present; fails closed with `acp_resume_unsupported` otherwise (repo-fact). Streaming via ACP updates (impl).
- **P-01..P-10:** P-01..P-10 = impl + unproven (resume depends on probed capabilities).
- **Reducer:** `unverified` / `evidence_missing`.
- **Observed version:** **1.17.12** (local-observation).
- **Class:** **ready-candidate**.

### copilot

- **Sources:** `crates/lico-client-native/src/platform/copilot_driver.rs`; drivers.json `copilot-acp`.
- **Official lane:** `copilot --acp --stdio --no-auto-update` (repo-fact launch args; local-observation `--acp` in help). Vendor-doc: GitHub Copilot CLI ACP server (CL-06.1).
- **Resume / streaming:** Shared ACP machine (`session/new` / load-or-resume per capabilities). Interactive `--resume`/`--continue` exist but are not the Arc lane.
- **P-01..P-10:** impl + unproven.
- **Reducer:** `unverified` / `evidence_missing`.
- **Observed version:** GitHub Copilot CLI **1.0.46** (local-observation).
- **Class:** **ready-candidate**.

### kilo-code

- **Sources:** `crates/lico-client-native/src/platform/kilo_code_driver.rs`; drivers.json `kilo-code-acp`.
- **Official lane:** ACP v1 NDJSON via `acp` launch arg; independent driver identity from OpenCode (repo-fact). Vendor-doc: Kilo Code CLI (CL-06.1).
- **Resume / streaming:** Same ACP load/resume capability negotiation as OpenCode wrapper family.
- **P-01..P-10:** impl + unproven.
- **Reducer:** `unverified` / `evidence_missing`.
- **Observed version:** not-installed (2026-07-11).
- **Class:** **ready-candidate** — evidence must be kilo-specific; must not inherit OpenCode evidence.

### cursor

- **Sources:** `crates/lico-client-native/src/platform/cursor_driver.rs`; drivers.json `cursor-acp`.
- **Official lane:** Public `agent acp` / `cursor-agent acp` ACP v1 NDJSON with fixed launch args (repo-fact module docs; vendor-doc Cursor ACP). Executable discovery must pass ACP initialize probe.
- **Resume / streaming:** ACP framing keeps prompts/session ids off argv (impl for transport privacy). Reducer/driver inventory still records **`exact_session_resume_unavailable`** — reliable exact native-session load/resume has not been proven (CL-06.1 / drivers.json). That is a P-03 gap, not a missing protocol entrypoint.
- **P-01..P-10:** P-02/P-08 transport = impl + unproven; P-03 = gap; others unproven; overall blocked.
- **Reducer:** `blocked` / `exact_session_resume_unavailable`.
- **Observed version:** `agent` / `cursor-agent` not-installed on this host (2026-07-11).
- **Class:** **lane-upgrade-candidate** — prove or obtain exact `session/load` (or equivalent) against a real Cursor ACP build; until proven, stay blocked.

### hermes

- **Sources:** `crates/lico-client-native/src/platform/hermes_driver.rs`; drivers.json `hermes-acp`.
- **Official lane:** ACP stdio JSON-RPC (`hermes-acp-stdio-jsonrpc`); `session/new` and `session/load` (repo-fact). Vendor-doc: Hermes Agent ACP (CL-06.1).
- **Resume / streaming:** Session methods on JSON-RPC channel; permission fail-closed and bounded supervision (CL-06.1 / impl).
- **P-01..P-10:** impl + unproven.
- **Reducer:** `unverified` / `evidence_missing`.
- **Observed version:** not-installed (2026-07-11).
- **Class:** **ready-candidate**.

### kimi-code

- **Sources:** `crates/lico-client-native/src/platform/kimi_code_driver.rs`; drivers.json `kimi-code-acp`; history `HistoryAdapter::KimiCode` in `conversations.rs` (distinct from desktop/mobile `kimi` provider identity).
- **Official lane:** `kimi acp` ACP v1 NDJSON (repo-fact; local-observation: `kimi --help` lists `acp`).
- **Resume / streaming:** ACP session ownership; interactive `-S/--session` and `--continue` exist on CLI but Arc lane is ACP.
- **P-01..P-10:** impl + unproven.
- **Reducer:** `unverified` / `evidence_missing`.
- **Observed version:** kimi **0.23.4** (local-observation).
- **Class:** **ready-candidate**.

---

## Native Resume / Streaming Comparison Notes

| Pattern | Agents | How resume is exposed | How streaming is exposed |
| --- | --- | --- | --- |
| ACP session methods | openclaw, opencode, copilot, kilo-code, cursor, hermes, kimi-code | `session/new` + `session/load` and/or capability-gated `session/resume`; identity on stdio JSON, not argv | ACP session update / NDJSON or JSON-RPC notifications |
| App-server JSON-RPC | codex | Thread/conversation id returned and rebound by app-server protocol | App-server turn/event stream on stdio |
| CLI stream-json | claude-code | Public `--resume`/`--continue` put session id in CLI options → Arc rejects for P-08 | `--output-format stream-json` stdout events for new sessions |
| No public transport | antigravity | Only argv/TUI/`agentapi` positional contracts documented → blocked | N/A for Arc send |

## Implementation Scope Lock (for later nodes)

1. **Driver-parity / lane executor work** prioritizes **ready-candidate** adapters: openclaw, codex, opencode, copilot, kilo-code, hermes, kimi-code — close evidence and any remaining semantic gaps on existing official lanes.
2. **Lane-upgrade** work is in scope only as fail-closed improvements that stay on official protocols: claude-code (non-argv resume if vendor publishes), cursor (prove exact session load). No unofficial attach.
3. **antigravity** remains **structurally-blocked**; do not spend implementation nodes inventing a transport.
4. Empty `agent-conversation-evidence.json` adapters list is the current evidence gap for every ready-candidate; the probe harness node must populate versioned rows the reducer can consume.

## Staleness

Re-probe `--version` and capability surfaces before any live acceptance run. Entries above are bound to **2026-07-11** observations and the checked-in driver/readiness resources at that date. A different installed version invalidates prior live evidence digests per CL-06.4.
