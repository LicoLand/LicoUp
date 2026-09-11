# Interface Surface Baseline

[Architecture](README.md) · [简体中文](INTERFACE-SURFACE-BASELINE.zh-CN.md)

This document freezes the interface surface that the CLI/MCP refactor
([#285](https://github.com/LicoLand/LicoUp/issues/285) and its subtasks) must
preserve. It records what exists today, where each contract lives, and which
task owns which path. Nothing here is a design proposal: every row was read from
the tree at the revision named below.

Baseline revision: **`8638e1040ac7abfa4005673a9fdac05065b3f5cc`** (`nightly`). Pin
this commit when checking any claim below; a later `nightly` may have moved.
Agent counts, tool catalogues, and binary names are the ones contract tests
already pin.

**Path convention.** A path starting with `crates/`, `apps/`, `tests/`,
`tools/`, `schemas/`, or `docs/` is repository-relative. Any other path is
relative to `crates/licoup-native/src/` — so `domain/subagent_mcp/mod.rs` means
`crates/licoup-native/src/domain/subagent_mcp/mod.rs`.

**Every reference carries its own file.** No reference below is a bare line
number: each names the file it belongs to, even in a table whose neighbouring
rows name the same file. That makes every reference checkable without reading
its surroundings, and it is enforced mechanically.

## 1. Command surface

### 1.1 What the CLI accepts

The authoritative argv surface is the command registry, not the help text.

| Item | Owner | Count / value |
| --- | --- | --- |
| Registered command paths | `crates/licoup-native/src/ffi/commands/mod.rs:893` (`build_command_table`) | **162** |
| Dynamic lane: `licoup rpc stdio` | `crates/licoup-native/src/bin/licoup.rs:39-52` | NDJSON RPC |
| Dynamic lane: `licoup rpc conversation` | `crates/licoup-native/src/bin/licoup.rs:54-58` | stdio↔socket proxy |
| Dynamic lane: `licoup rpc conversation-host` | `crates/licoup-native/src/bin/licoup.rs:60-64` | persistent host |
| Everything else | `crates/licoup-native/src/bin/licoup.rs:66-71` | `execute_cli(argv)` |

`crates/licoup-native/src/bin/licoup/presentation.rs` prints usage only. It
under-documents several command families and is **not** a contract; do not
derive a baseline from it.

### 1.2 Admission

| Concern | Location | Behaviour to preserve |
| --- | --- | --- |
| Registry types | `ffi/commands/mod.rs:276-422` | `CommandSpec` → `CommandDef` → `CommandTable` |
| Admission | `ffi/commands/mod.rs:354-421` | exact positional prefix, then cardinality, then options |
| Argument bounds | `ffi/commands/mod.rs:532-554` | ≤4096 arguments, ≤2 MiB per argument, `help` must stand alone |
| Options | `ffi/commands/mod.rs:556-677` | Boolean vs Value arity, repeatable, required |
| Constraints | `ffi/commands/mod.rs:679-721` | `AtLeastOne`, `MutuallyExclusive`, `OneOf`, `ConditionalRequired` |
| Handler inputs | `ffi/commands/mod.rs:779-801` (`admitted_params`) | only present keys are inserted; flags become `Bool(true)` |
| Error shape | `ffi/commands/mod.rs:188-260` (`CliCommandError`) | `code` / `stage` / `component` / `retryable` / `recovery` |

Admission error codes are a published contract. **Thirteen** exist; the contract
test suite asserts each one
(`crates/licoup-native/tests/cli_command_contract_cases.rs:61-110`).

| Code | Raised when |
| --- | --- |
| `cli_command_missing` | no registered path matched |
| `cli_command_unknown` | path prefix is known but the command is incomplete |
| `cli_operation_unsupported` | the operation token is not registered for that path |
| `cli_required_argument_missing` | a required positional was not supplied |
| `cli_required_option_missing` | a required option was not supplied |
| `cli_argument_unexpected` | a token appeared where `Cardinality::Exact` forbids it |
| `cli_option_unknown` | an option is not in the spec |
| `cli_option_duplicate` | a non-repeatable option was given twice |
| `cli_option_value_missing` | a value-arity option was given without its value |
| `cli_option_constraint_violation` | an `AtLeastOne` / `MutuallyExclusive` / `OneOf` / `ConditionalRequired` constraint failed |
| `cli_argument_count_exceeded` | more than 4096 arguments supplied |
| `cli_argument_bytes_exceeded` | a single argument exceeds 2 MiB |
| `cli_json_invalid` | a JSON argument did not parse |

Command handler modules (one per file, declared at `ffi/commands/mod.rs:8-28`):
`adapter`, `agent_conversation`, `agent_hub`, `agent_usage`, `autostart`,
`client_conversation`, `client_update`, `collaboration`, `gateway`,
`llm_gateway`, `mcp`, `mobile`, `opencode_serve`, `provider_quota`,
`resource_usage`, `secure_mesh`, `skill`, `snapshots`, `state`, `strategy`,
`targets`.

### 1.3 The RPC protocol

| Item | Value | Location |
| --- | --- | --- |
| Protocol string | `licoup.stdio.v1` | `bin/licoup.rs:29`; contract copy at `contracts/conversation_protocol.rs:5` |
| Methods | **29** | `contracts/conversation_protocol.rs:14-44` |
| Frame limit | 16 MiB | `contracts/conversation_protocol.rs:6-9` |
| Frame framing | newline-delimited | `contracts/frame.rs:16` |
| Parser | `parse_stdio_rpc_request` | `bin/licoup/stdio_rpc/request.rs:13-170` |
| Dispatch | `serve_stdio_rpc_inner` | `bin/licoup/stdio_rpc/server.rs:66-608` |

The 29 wire methods collapse onto 8 dispatch variants
(`bin/licoup/stdio_rpc/model.rs:11-43`): `Execute`, `Conversation{operation}`,
`ClientConversation`, `StrategyExecute`, `Catalog{operation}`, `StateGet`,
`StateSet`, `Shutdown`.

Envelope shapes, all owned by `bin/licoup/stdio_rpc/response.rs`:

| Kind | Fields | Location |
| --- | --- | --- |
| Success | `protocol`, `id`, `workflowId`, `ok: true`, `result` | `bin/licoup/stdio_rpc/response.rs:184-203` |
| Error | `protocol`, `id`, `workflowId`, `ok: false`, `error: ClientError` | `bin/licoup/stdio_rpc/response.rs:205-223` |
| Stream event | `protocol`, `id`, `workflowId`, `kind: "event"`, `sequence`, `event` | `bin/licoup/stdio_rpc/response.rs:60-103` |
| Stream terminal | `protocol`, `id`, `workflowId`, `kind: "terminal"`, `sequence`, `ok`, `result`/`error` | `bin/licoup/stdio_rpc/response.rs:105-167` |

`ClientError` fields are `code`, `stage`, `component`, `retryable`, `recovery`,
`presentationArgs` (`ffi/generated/client_error.rs:159-172`). The `code`
enumeration holds **45** values (`ffi/generated/client_error.rs:6-97`).

### 1.4 Binaries

`crates/licoup-native/Cargo.toml:107-134` builds seven binaries. Five are
packaged, one is an embedded duplicate, one is test-only.

| Binary | Role | Packaging |
| --- | --- | --- |
| `licoup-cli` | all CLI surfaces | sidecar, plus Xcode embed |
| `lico-subagent-mcp` | Subagent MCP connector | sidecar **and** embedded in the Codex plugin |
| `lico-conversation-mcp` | Conversation MCP server | sidecar |
| `lico-gateway` | gateway runtime | sidecar |
| `lico-llm-gateway` | legacy gateway alias | Xcode embed only, absent from `packaging.modules.json` |
| `lico-agent` | agent sidecar | sidecar |
| `lico-secure-mesh-kt-mock` | acceptance test only | not packaged (feature-gated) |

## 2. MCP tool catalogues

Two servers, one shared engine (`core/mcp`). The refactor must keep each
catalogue, both identity triples, and both error projections byte-identical.

| | Subagent | Conversation |
| --- | --- | --- |
| Binary | `lico-subagent-mcp` | `lico-conversation-mcp` |
| `SERVER_NAME` | `lico-up-subagents` | `lico-up-conversations` |
| `SERVER_VERSION` | `0.12.0` | `0.1.0` |
| `PROTOCOL_REVISION` | `2025-06-18` | `2025-06-18` |
| Compatible revisions | `["2025-11-25"]` | none |
| Tools | **10** | **5** |
| Transport | stdio connector → desktop-owned loopback HTTP `/mcp` | stdio only |
| Catalog order | `domain/subagent_mcp/mod.rs:42-53` (`TOOL_NAMES`) | `bin/lico-conversation-mcp.rs:133-174` |
| Catalog construction (schemas, `required`) | `domain/subagent_mcp/mod.rs:736-808` | `bin/lico-conversation-mcp.rs:133-174` |

**Correction to the task list:** issue #289 describes "the existing 9 + 5 tool
catalog". The verified count today is **10 + 5**; the tenth subagent tool is
`lico_assistant_workflow_policy`. Any parity test must use the counts below, not
the issue text.

Subagent tools, in order: `lico_assistant_profiles`,
`lico_assistant_workflow_execute`, `lico_assistant_workflow_inspect`,
`lico_assistant_workflow_cancel`, `lico_subagents_list`, `lico_subagent_probe`,
`lico_subagent_delegate`, `lico_subagent_continue`, `lico_subagent_cancel`,
`lico_assistant_workflow_policy`.

Conversation tools, in order: `lico_conversation_list`, `lico_conversation_get`,
`lico_conversation_search`, `lico_conversation_export`, `lico_conversation_import`.

### 2.1 Schema and validation

Input schemas are JSON Schema literals with `additionalProperties: false`
(subagent: `domain/subagent_mcp/mod.rs:869-884`; conversation:
`bin/lico-conversation-mcp.rs:176-187`). Validation runs before business logic in
the engine (`core/mcp/server.rs:298-308`), which rejects unknown tool names with
`-32601` and invalid arguments with `-32602`.

### 2.2 Error projection

Application failures are returned as a **successful** JSON-RPC result carrying
`isError: true` and this body (owner: `core/mcp/server.rs:323-337`):

`schemaVersion: "licoup.mcp.error.v1"`, `reasonCode`, `stage`, `retryable`,
`recovery`.

Note the field is `reasonCode`, not `code`. Engine-level JSON-RPC `error`
envelopes are separate (`core/mcp/wire.rs:45-56`) and use the standard codes
`-32600`, `-32601`, `-32602`, `-32002`, `-32700`, `-32800`.

Native→MCP projection owners, which must stay in lockstep with the store's error
strings:

| Projection | Location |
| --- | --- |
| Adapter failures | `domain/subagent_mcp/mod.rs:650-663` |
| Host failures | `domain/subagent_mcp/production.rs:429-468` |
| stdio server host errors | `bin/licoup/stdio_rpc/server/client_conversation.rs:81-99` |
| host client errors | `platform/subagent_mcp_host_client.rs:128-154` |
| store admission errors | `crates/licoup-conversation/src/store/dispatches.rs:69-163` |

### 2.3 Receipt and envelope schema versions

| Schema string | Used by | Location |
| --- | --- | --- |
| `licoup.subagent.receipt.v3` | delegate / continue / cancel receipts | `domain/subagent_mcp/mod.rs:621-648` |
| `licoup.subagents.v3` | `lico_subagents_list` | `domain/subagent_mcp/production.rs:390` |
| `licoup.subagent.readiness.v2` | `lico_subagent_probe` | `domain/subagent_mcp/mod.rs:429` |

Claim state strings (serialized on the wire and stored):
`claimed`, `running`, `cancel-requested`, `reconciliation-required`,
`completed`, `failed`, `cancelled`
(`crates/licoup-conversation/src/client_conversation/mod.rs:445-457`).

### 2.4 Transport invariants

The subagent service binds loopback only, requires an exact numeric `Host`, no
`Origin`, and a bearer token minted per admitted caller
(`platform/subagent_mcp_supervisor.rs:500-544`). Tokens are the adapter
registry's caller set, so the published token map **is** the membership set.
Bounds: 32 connections, 64 sessions, 8 tool workers
(`platform/subagent_mcp_supervisor.rs:26-28`).

## 3. Identity semantics

Two actor kinds exist, and they are deliberately different. The refactor must
keep both.

| | Local-admin actor | Membership actor |
| --- | --- | --- |
| Reached by | in-process CLI / desktop | MCP tool call |
| Identity source | caller-supplied `authorMembershipId` / `ownerMembershipId` | authenticated `CallerContext` from the loopback service |
| Verification | `ensure_local_owner` for owner-typed operations only | `effect_scope` + `verify_caller` + `verified_assistant` |
| Binding check | owner + active + human | active + agent + `agent_id == provider_id` + same conversation |

There is no `local-admin` enum variant anywhere; the distinction is behavioural
and is enforced by which gates each entry point runs.

| Gate | Location |
| --- | --- |
| Local owner | `crates/licoup-conversation/src/store/mod.rs:5561-5580` |
| Subagent caller and target membership | `crates/licoup-conversation/src/store/dispatches.rs:69-86` |
| Assistant eligibility | `crates/licoup-conversation/src/store/mod.rs:1931-1944` |
| MCP caller binding | `domain/subagent_mcp/production.rs:44-64` |
| MCP assistant binding | `domain/subagent_mcp/production.rs:66-92` |
| Single-use registration approval | `crates/licoup-agent-runtime/src/lib.rs:408-455` |
| Message author binding | `domain/client_conversation/service.rs:553-573` — **not** checked; the CLI path trusts the author id by design |

The last row is the asymmetry to preserve: the CLI path trusts a supplied
author id for ordinary posting, while the MCP path additionally requires an
authenticated, conversation-bound agent membership.

## 4. Persistent conversation host

| Item | Value | Location |
| --- | --- | --- |
| Endpoint name | `licoup-conversation-{token}-{generation}` | `platform/conversation_host_transport.rs:89-100` |
| Token file | `<root>/client-state/conversation-runtime/endpoint-token` | `platform/conversation_host_transport.rs:105-115` |
| Token form | 32 lowercase hex, `create_new` + sync + harden | `platform/conversation_host_transport.rs:119-138` |
| Generation | SHA-256 of executable file metadata, first 8 bytes → 16 hex | `platform/conversation_host_transport.rs:19-67` |
| Host record | `generation\nhost_pid\n[client_pid]` | `bin/licoup/conversation_host.rs:39-101` |
| Owner env | `LICOUP_CLIENT_PID` | `bin/licoup/conversation_host.rs:32-37` |
| Constants | 80 connect attempts, 25 ms retry, 2 s stale wait, 500 ms owner check, 300 s idle grace | `bin/licoup/conversation_host.rs:32-37` |
| Owner-death exit | checkpoint then break the accept loop | `bin/licoup/conversation_host.rs:497-503` |
| Idle exit (no owner) | after the 300 s grace, only when attendance is idle | `bin/licoup/conversation_host.rs:504-514` |

Authentication on this channel is **possession of the socket name**, which
requires reading the hardened token file. No caller identity crosses the wire.

### 4.1 Exit behaviour today

| Entry | Behaviour |
| --- | --- |
| GUI dies | host notices within 500 ms, checkpoints, exits; in-flight turn threads die with the process |
| stdio lane pipe closes | the lane joins until every Agent turn reaches terminal (`bin/licoup/stdio_rpc/server.rs:92-99`) |
| proxy lane | drains the host after stdout disappears so the desktop can reconnect (`bin/licoup/conversation_host.rs:282-313`) |
| attendance worker | detached on owner exit, never awaited (`bin/licoup/conversation_host.rs:443-449`) |

### 4.2 Update behaviour today

| Step | Location |
| --- | --- |
| Apply script quits the GUI and waits for its pid to vanish | `domain/client_update/native_runner/script.rs:93-148` |
| Pre-handoff written `pending` | `domain/client_state_migration.rs:414-484` |
| Candidate claims before state admission | `domain/client_state_migration.rs:371-403`, invoked from `domain/client_state_migration.rs:178-186` |
| Endpoint generation prevents a new binary attaching to an old host | `platform/conversation_host_transport.rs:44-48, 89-100` |

### 4.3 Handoff verification map

Every phase and fault the refactor must cover already has a code location and at
least one test. Cover these, not new abstractions.

| Phase / fault | Code | Existing test |
| --- | --- | --- |
| Host start from a desktop lane | `bin/licoup/conversation_host.rs:255-280` | `native-client-smoke`, `subagent_mcp_startup` |
| Host restart after unexpected exit | supervisor | `platform/subagent_mcp_supervisor.rs:1595-1638` |
| Owner death while work is in flight | `bin/licoup/conversation_host.rs:497-503` | `bin/licoup/conversation_host.rs:787-951` |
| Idle exit | `bin/licoup/conversation_host.rs:504-514` | `bin/licoup/conversation_host.rs:531-542` |
| Endpoint generation isolation | `platform/conversation_host_transport.rs:89-100` | `platform/conversation_host_transport.rs:174-197` |
| Generation record integrity | `bin/licoup/conversation_host.rs:39-101` | `bin/licoup/conversation_host.rs:556-577` |
| Update handoff pending → claimed | `domain/client_state_migration.rs:371-403` | `domain/client_state_migration.rs:1631-1649` |
| Handoff mismatch / rejection | `domain/client_state_migration.rs:486-503` | `domain/client_state_migration.rs:1531-1562` |
| Crash before the store step | `claim_update_handoff` entry `domain/client_state_migration.rs:178-186`; failpoint `domain/client_state_migration.rs:267` | `domain/client_state_migration.rs:1513` |
| Crash after the store step, before the ledger write | failpoint `domain/client_state_migration.rs:274` | `domain/client_state_migration.rs:1479` |
| Crash after the ledger write | failpoint `domain/client_state_migration.rs:277` | `domain/client_state_migration.rs:1513` |
| Kill mid-turn cold recovery | `crates/licoup-conversation/tests/cold_recovery.rs:9`, `crates/licoup-conversation/tests/cold_recovery.rs:76`, `crates/licoup-conversation/tests/cold_recovery.rs:149`, `crates/licoup-conversation/tests/cold_recovery.rs:212` |
| Post-claim cleanup failure must not roll back | `client_update/native_runner/script.rs` | `domain/client_state_migration.rs:1562` |

## 5. Data frontier and format boundary

### 5.1 State root

`portable_data_dir()` (`platform/paths.rs:24`) resolves the root. Children the
product writes:

| Path | Owner | Format |
| --- | --- | --- |
| `client-state/` | `platform/client_state/paths.rs:13` | collections JSON, SQLite stores |
| `client-state/conversations/conversations.sqlite3` | `crates/licoup-conversation/src/store/mod.rs:46` | SQLite, schema **12** |
| `client-state/adaptive-flywheel/strategies.sqlite3` | `domain/adaptive_flywheel/store.rs:17` | SQLite, schema **2** |
| `client-state/migrations/` | `domain/client_state_migration.rs:20-22` | ledger, domain markers, update handoff |
| `llm-gateway/` | `platform/llm_gateway_service.rs:44` | service state, autostart, client token |
| `agent-workspace/` | `platform/agent_workspace.rs:15` | default turn cwd |
| `opencode-serve/` | `platform/opencode_serve/policy.rs:19` | state, pid, lock |
| `telegram-gateway/` | `platform/gateway_runtime/channels/telegram/binding.rs:18` | bindings, bot token |
| `gateway/` | `platform/gateway_runtime/service.rs:12` | gateway runtime state |
| `client-autostart/` | `platform/client_autostart.rs:16` | autostart marker |
| `catalog-cache/` | `platform/catalog_cache_store.rs:7` | catalog cache |
| `mcp-transfer-plans/` | `platform/mcp_approval_plan_store.rs:16` | approval plans |
| `openclaw-gateway/` | `platform/openclaw_gateway/policy.rs:5` | config + runtime |
| `licoup/secure-mesh/command-replay.sqlite` | `domain/secure_mesh_command_runtime.rs:19` | replay ledger |
| `.licoup-workspace.json` | `domain/client_state_migration.rs:737-741` | workspace manifest |

### 5.2 Versioned documents

Every document the migration frontier covers carries an explicit version, and
the versions below are the ones that must not change. Versioned and unversioned
documents are distinguished explicitly, because not all persisted state is
versioned (see the note after the numeric table).

| Constant | Value | Written to |
| --- | --- | --- |
| `FRONTIER_SCHEMA` | `v0.0.1:client-state-migration-frontier-1` | resource, read-only |
| `LEDGER_SCHEMA` | `v0.0.1:client-state-migration-ledger-1` | `client-state/migrations/ledger.json` |
| `DOMAIN_MARKER_SCHEMA` | `v0.0.1:client-state-domain-marker-1` | `client-state/migrations/domain-state/<domain>.json` |
| `UPDATE_HANDOFF_SCHEMA` | `v0.0.1:client-update-handoff-1` | `client-state/migrations/update-handoff.json` |
| `STATE_SCHEMA_VERSION` | `v0.0.1:schema:definition-1` | `client-state/<collection>.json` |
| `TARGET_DISCOVERY_CACHE_SCHEMA` | `licoup.target-discovery-cache.v1` | `client-state/target-discovery-cache.json` |
| (inline, handoff rejection) | `v0.0.1:client-update-handoff-rejection-1` | `client-state/migrations/update-handoff.json.rejected` |

Numeric-version JSON documents admitted during migration
(`domain/client_state_migration.rs:1050-1055`). Two have dedicated handlers, the
rest share `migrate_json_schema` (`domain/client_state_migration.rs:1130`):

| Document | Version | Handler |
| --- | --- | --- |
| `.licoup-workspace.json` | 1 | `migrate_json_schema` |
| `client-state/appearance-preferences.json` | 1 | `migrate_json_schema` |
| `client-state/agent-tab-order.json` | 1 | `migrate_agent_tab_order` (`domain/client_state_migration.rs:1102`) |
| `client-state/agent-tool-allowlists.json` | 1 | `migrate_json_schema` |
| `client-state/current-client-view.json` | 1 | `migrate_json_schema` |
| `client-state/mobile-home-layout.json` | 2 | `migrate_json_schema` |
| `client-state/skill-hub-preferences.json` | 1 | `migrate_json_schema` |
| `client-state/mobile-relay/config.json` | 2 | `migrate_mobile_relay` (`domain/client_state_migration.rs:1117`) |

Not every persisted document is versioned: `telegram-gateway/channel.ready` holds
only `channelId`, `state`, and `botUsername`
(`platform/gateway_runtime/channels/telegram/mod.rs:44-53`). Versioned documents
are the ones listed above and in the preceding table.

### 5.3 What the migration tool reuses vs adds

Reuse as-is:

- the frontier resource and its validation (contiguous edges, unique ids, one
  compiled handler per edge) — `domain/client_state_migration.rs:545-598`
- the ledger and per-domain markers as the durable progress record
- `ConversationStore::open_for_migration` and
  `AdaptiveFlywheelStore::open_for_migration` as the only writers during a step
- the domain routing already present at `domain/client_state_migration.rs:723` and `domain/client_state_migration.rs:1007`
- the exclusive `admission.lock` flock at `domain/client_state_migration.rs:165-173`

New in the tool (does not exist today):

- the pipeline stages `Checking → WaitingForQuiescence → Snapshotting →
  Migrating → Verifying → Ready`. **None of these names exist in the tree**; the
  current implementation is one synchronous `admit()` returning
  `AdmissionResult`
- a `doctor` / `recover` repair mode with enumerated actions
- rollback. Migration is forward-only today: once a higher product version is
  admitted, an older binary is permanently refused
  (`reject_older_binary` at `domain/client_state_migration.rs:623`, code
  `state_newer_than_binary`)

Trigger today is implicit: the desktop runs admission as the second lifecycle
step before storage load
(`apps/desktop/lib/src/application/controller/client_lifecycle_facade.dart:75-78`,
ordering pinned by `tests/contract/client/client-state-migration.test.mjs`).
`licoup state admit <data-root>` (`ffi/commands/state.rs:32-37`) is the explicit
form the installer already uses.

## 6. Module ownership declaration

Each task owns the paths below exclusively while it runs. A task that needs a
change in another task's paths must land that change first, on its own branch.

| Task | Exclusive write ownership |
| --- | --- |
| #285 | this document; `docs/README.md` entry |
| #286 | new `crates/licoup-application/**`; workspace member list |
| #287 | `crates/licoup-native/src/domain/**`; `crates/licoup-agent-runtime/**` |
| #288 | `crates/licoup-native/src/bin/licoup/**`; `crates/licoup-native/src/ffi/commands/**` |
| #289 | new `crates/licoup-mcp/**`; `crates/licoup-native/src/core/mcp/**`; `crates/licoup-native/src/bin/lico-subagent-mcp.rs`; `crates/licoup-native/src/bin/lico-conversation-mcp.rs` |
| #290 | `tests/contract/**`; new parity test roots; `tools/regression/**` |
| #291 | `crates/licoup-native/src/ffi/**` composition roots; `crates/licoup-native/src/bin/**` roots |
| #292 | `schemas/**`; `apps/desktop/packaging.modules.json`; `docs/**` (excluding this file); removal of superseded MCP paths |
| #293 | no source paths; evidence only |
| #294 | `crates/licoup-native/src/platform/**` supervision; desktop lifecycle paths |
| #295 | `crates/licoup-native/src/domain/client_update/**`; `crates/licoup-native/src/domain/client_state_migration.rs` handoff section |
| #296 | new migration-tool crate; `crates/licoup-native/src/domain/client_state_migration.rs` only after #295 lands |

Three surfaces are shared and must be serialized, never edited concurrently:

1. **`crates/licoup-native/Cargo.toml`** — every crate-splitting task adds a
   member. Land one at a time.
2. **`crates/licoup-native/src/ffi/commands/mod.rs`** — the 162-entry registry.
   #288 owns it; #289 and #291 read it only.
3. **`apps/desktop/packaging.modules.json`** — #292 owns it; every task that
   renames or adds a binary must land before #292, not during it.

## 7. What is frozen

Preserved exactly, verified by existing tests:

- the 162 registered command paths and their admitted option sets
- the 29 RPC methods, the four envelope shapes, and the 45 error codes
- both MCP catalogues (10 and 5 tools), both identity triples, both compatible
  revision sets, and the `licoup.mcp.error.v1` body
- the receipt schemas `licoup.subagent.receipt.v3`, `licoup.subagents.v3`,
  `licoup.subagent.readiness.v2`
- the seven binary names and the five packaging mappings
- the loopback-only, Host-pinned, Origin-less, bearer-authenticated MCP
  transport and its 32/64/8 bounds
- the local-admin vs membership actor split, including the deliberate
  author-id trust on the CLI posting path
- the endpoint naming scheme, the 500 ms owner check, the 300 s idle grace, and
  the forward-only migration stance
- every schema-version string in §5, and the unversioned documents named there

Changing any of the above is a product decision, not a refactor step.
