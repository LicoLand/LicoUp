# Agent Conversation Dispatch Parity — Validation Matrix

## Validation Rules

- A requirement is complete only when every mapped check in this matrix passes (or its declared fixture counterpart passes on CI).
- Validation plugs into the existing CL-06 evidence chain (`drivers` → `evidence` → readiness reducer). Do not invent a parallel readiness vocabulary.
- Synthetic harnesses and unit tests may prove implementation progress; they cannot alone set reducer `ready` or close P-10.
- Environment-dependent live checks require an installed agent binary. Each such check declares a deterministic fixture-based counterpart that CI can run without that binary.
- Evidence artifacts must stay redacted: booleans, counts, digests, redacted version/source classes, and error codes only.
- Fail-closed is mandatory: without current schema-valid evidence, `sendEnabled` stays 0 / false for that adapter.

## Delivering Nodes

| Node id | Role | Delivers |
| --- | --- | --- |
| `04a69e89-5242-4881-a233-80cfdfcc34e2` | architecture_scaffold | Module map, lane interfaces, evidence-flow contracts used by later checks |
| `850437e2-dc3d-4a0e-a010-922128b237cc` | implementation | Unified Dart dispatch lane contract + Dart contract tests |
| `8b22e4bb-59c4-4fc1-bada-77da9b597e5c` | implementation | Per-protocol Rust lane executors + driver unit tests |
| `5d34af8d-dccf-4aef-9be4-4dca81aa1455` | implementation | Parity probe harness + evidence → reducer wiring |
| `0565bc71-3d97-4d45-86dc-53aedef72f85` | implementation | Conversation workspace disclosure UX + widget tests |
| `f5b1477a-9279-4c02-bc41-b1ed0ebeba1b` | final_validation | End-to-end run of this matrix |

## Requirement Mapping

| Requirement | Named checks | Delivering node | Environment |
| --- | --- | --- | --- |
| REQ-ACD-001 | **V-DART-001** Dart dispatch contract unit/contract tests: all conversation send callers (direct, orchestrated, mobile-relay) invoke one dispatch API; no production `runCliWithStdin` conversation fork remains. Target files: `apps/desktop/test/agent_dispatch_lane_contract_test.dart` (to be added by Dart implementation node) plus architecture gate in `npm run client:verify:architecture` asserting single send path. | `850437e2-…` (+ arch gate from `04a69e89-…`) | CI / fixture |
| REQ-ACD-001 | **V-ARCH-001** `npm run client:verify:architecture` — conversation send boundary and module ownership match Architecture.md. | `04a69e89-…` defines; enforced continuously; final node re-runs | CI / fixture |
| REQ-ACD-002 | **V-RUST-001** Rust driver unit tests per protocol family: ACP (`opencode_driver` / wrappers), app-server (`codex_app_server`), stream-json (`claude_code_driver`), blocked transport (`antigravity_driver`) — cover new-session, exact resume fail-closed, cancel/timeout codes, capability matrix fields. Command: `CARGO_TARGET_DIR=build/crates/lico-client-native/target cargo test --manifest-path crates/lico-client-native/Cargo.toml -- driver` (or module-filtered equivalents delivered by the Rust node). | `8b22e4bb-…` | CI / fixture |
| REQ-ACD-002 | **V-LIVE-001** Authorized live ACP/core A/B for ready-candidate agents when installed: `node tools/scripts/client-acp-conversation-parity.mjs --agent <id> --strict` and Codex core lane `npm run client:verify:codex-conversation:live`. These prove lane semantics but **do not** alone promote readiness / P-10. | `5d34af8d-…` / final | **Env-dependent** |
| REQ-ACD-002 | **V-FIX-001** Fixture counterpart for V-LIVE-001: `node tools/scripts/client-acp-conversation-parity.mjs --self-test` (already in `npm run client:verify:agent-conversation-parity`) plus synthetic driver fixtures under Rust tests; must report `cl06Ready: false` / non-ready and never write live evidence. | `5d34af8d-…` | CI / fixture |
| REQ-ACD-003 | **V-RED-001** `npm run client:verify:agent-conversation-parity` — reducer contract tests (`tests/contract/client/agent-conversation-parity-reducer.test.mjs`), `--check` against checked-in readiness, ACP self-test. Asserts forged `ready` / `sendEnabled` rejected. | `5d34af8d-…` | CI / fixture |
| REQ-ACD-003 | **V-RED-002** Empty or incomplete evidence → `sendEnabled == 0` for all adapters (current baseline assertion). After harness exists: only digest-bound complete evidence can flip an adapter; fixture evidence rows in tests prove promotion rules without live agents. | `5d34af8d-…` | CI / fixture |
| REQ-ACD-003 | **V-LIVE-002** Release-UI consecutive paired runs (P-10) producing versioned rows in `agent-conversation-evidence.json` consumed by the reducer. | `5d34af8d-…` / final | **Env-dependent** |
| REQ-ACD-003 | **V-FIX-002** Fixture counterpart for V-LIVE-002: synthetic evidence fixtures in reducer tests that exercise pass/fail/`consecutivePasses` rules without a release `.app` or installed agent; packaging `--check` still rejects forged ready. | `5d34af8d-…` | CI / fixture |
| REQ-ACD-004 | **V-BOUND-001** Source/architecture assertions that conversation dispatch launch specs do not place prompts or native session ids in argv; antigravity/claude resume remain fail-closed with recorded codes (`antigravity_public_transport_unavailable`, `official_native_lane_missing` / `claude_code_secure_resume_unavailable`). Covered by Rust driver tests + `npm run client:verify:architecture` privacy/argv canaries where present. | `8b22e4bb-…` | CI / fixture |
| REQ-ACD-004 | **V-BOUND-002** Static scan / test that no dispatch path invokes ptrace, input injection, or private-database mutation APIs for conversation send. Delivered as a named assertion in architecture verifier or dedicated test `apps/desktop/scripts` / Rust test added by lane executor node. | `8b22e4bb-…` / `04a69e89-…` | CI / fixture |
| REQ-ACD-005 | **V-UI-001** Flutter widget/controller tests: workspace shows readiness, capability matrix, evidence age/missing, blocked summary codes; send-gate messages include actionable cause. Target: extend `apps/desktop/test/agents_workspace_layout_test.dart` and/or new `agent_conversation_parity_disclosure_test.dart`. | `0565bc71-…` | CI / fixture |
| REQ-ACD-006 | **V-E2E-001** Final validation node runs the End-to-End Acceptance Run below and records pass/fail per check id. | `f5b1477a-…` | Mixed (see run) |

## Named Check Catalog

| Check id | Command / artifact | Pass condition |
| --- | --- | --- |
| V-DART-001 | `flutter test` (or `npm run client:test` filtered) on dispatch contract tests | Single dispatch API used by all callers; legacy conversation stdin fork absent |
| V-ARCH-001 | `npm run client:verify:architecture` | Architecture rules for conversation send / readiness gate pass |
| V-RUST-001 | Cargo test filter for platform drivers / app-server | Per-protocol resume/cancel/capability unit tests green |
| V-LIVE-001 | `client-acp-conversation-parity.mjs --agent <id> --strict`; `npm run client:verify:codex-conversation:live` | Live lane semantics pass for installed ready-candidates; still not readiness alone |
| V-FIX-001 | `client-acp-conversation-parity.mjs --self-test` via `npm run client:verify:agent-conversation-parity` | Self-test green; explicitly non-ready |
| V-RED-001 | `npm run client:verify:agent-conversation-parity` | Reducer contract + `--check` + self-test green |
| V-RED-002 | Same suite + readiness resource inspection | Without current evidence, summary `sendEnabled` is 0 |
| V-LIVE-002 | Release-UI parity producer (harness delivered by probe node) | Versioned evidence rows written; reducer may promote only when complete |
| V-FIX-002 | Reducer unit fixtures in `agent-conversation-parity-reducer.test.mjs` | Promotion/rejection rules proven with fixtures |
| V-BOUND-001 | Rust driver tests + architecture argv/privacy checks | Blocked adapters keep structural codes; no argv session-id resume path enabled |
| V-BOUND-002 | Architecture/static assertion for prohibited techniques | No ptrace / input injection / private DB mutation in dispatch paths |
| V-UI-001 | Flutter widget tests for disclosure | Readiness, capabilities, evidence age, blocked causes, actionable send-gate copy |
| V-E2E-001 | Final matrix execution | All CI checks green; env-dependent checks either pass on authorized host or remain explicitly blocked with fixture counterpart green |

## Environment-Dependent Checks and Fixture Counterparts

| Env-dependent check | Requires | Fixture counterpart (CI) |
| --- | --- | --- |
| V-LIVE-001 | Installed agent binary + authorized credentials/profile | V-FIX-001 ACP `--self-test` + Rust synthetic driver fixtures |
| V-LIVE-002 | Release `.app` sidecar + installed agent + UI automation host | V-FIX-002 reducer evidence fixtures + `parity-reducer.mjs --check` |

If an env-dependent check cannot run, final validation must still pass the fixture counterpart and record the live check as `blocked-host` / `not-installed` without treating that as adapter `ready`.

## End-to-End Acceptance Run

Executed by final-validation node `f5b1477a-9279-4c02-bc41-b1ed0ebeba1b`.

### Sequence

1. `python3 …/manifest_tool.py validate docs/plan` — Better Plan state valid.
2. Confirm Requirements.md / Evidence.md / Architecture.md / this Validation.md present and REQ-ACD-001..006 mapped.
3. `npm run client:verify:architecture` (V-ARCH-001, contributes to V-BOUND-*).
4. `npm run client:verify:agent-conversation-parity` (V-RED-001, V-FIX-001, V-RED-002 baseline).
5. Rust driver tests (V-RUST-001, V-BOUND-001).
6. Dart dispatch contract + disclosure tests (V-DART-001, V-UI-001) via `npm run client:test` or filtered flutter test.
7. On authorized hosts only: V-LIVE-001 / V-LIVE-002 for ready-candidate agents that are installed; otherwise skip with `not-installed` and rely on fixtures.
8. Inspect `agent-conversation-readiness.json`: assert fail-closed — any adapter without current evidence has `sendEnabled: false`; summary `sendEnabled` counts only reducer-ready adapters.

### Pass condition

- All CI/fixture checks (V-DART-001, V-ARCH-001, V-RUST-001, V-FIX-001, V-RED-001, V-RED-002, V-FIX-002, V-BOUND-001, V-BOUND-002, V-UI-001) pass.
- Fail-closed reducer assertion holds: no adapter is `ready` / `sendEnabled: true` without current digest-bound evidence.
- Env-dependent live checks either pass on an authorized host or are explicitly recorded as not run with fixture counterparts green.
- REQ-ACD-001..006 each have at least one passing mapped check (live or fixture as allowed above).
- Product must not claim native-conversation parity for any non-ready adapter.

### Fail condition

- Any CI/fixture check fails.
- Readiness resource shows `sendEnabled > 0` without matching evidence rows.
- A check invents readiness without going through the reducer.
- Official-lane boundary violated (prohibited techniques used or argv session-id resume enabled as production path).

## Acceptance Run Record (final-validation node)

Recorded by `f5b1477a-9279-4c02-bc41-b1ed0ebeba1b`. Host date: 2026-07-11. Live promotion not authorized in this session; fixture counterparts used for env-dependent checks.

| Check id | REQ | Result | Notes |
| --- | --- | --- | --- |
| Better Plan validate | — | **pass** | `manifest_tool.py validate docs/plan` OK |
| Foundation docs present | — | **pass** | Requirements/Evidence/Architecture/Validation present; REQ-ACD-001..006 mapped |
| V-ARCH-001 | REQ-ACD-001/004 | **pass** | `npm run client:verify:architecture` ok |
| V-DART-001 | REQ-ACD-001 | **pass** | `agent_conversation_service_test.dart` dispatch lane contract + readiness reject + open/stream/cancel/capabilities |
| V-RUST-001 | REQ-ACD-002 | **pass** | `conversation_lane` 7/7; `runtime_adapters::tests` 12/12 |
| V-FIX-001 | REQ-ACD-002 | **pass** | ACP `--self-test` status=passed; `cl06Ready:false`; `dispatchLaneContract:true`; lane families covered |
| V-RED-001 | REQ-ACD-003 | **pass** | Reducer contract 11/11; `--check` ok |
| V-RED-002 | REQ-ACD-003 | **pass** | readiness summary `ready:0` `sendEnabled:0`; evidence `adapters:[]` |
| V-FIX-002 | REQ-ACD-003 | **pass** | Reducer fixtures prove forged ready rejected; empty evidence never promotes |
| V-BOUND-001 | REQ-ACD-004 | **pass** | Resume fail-closed for claude/cursor; antigravity structurally blocked; architecture argv/privacy gates green |
| V-BOUND-002 | REQ-ACD-004 | **pass** | Static scan of dispatch/lane/driver sources: no ptrace / input-injection / private-DB mutation APIs |
| V-UI-001 | REQ-ACD-005 | **pass** | `agent_conversation_parity_disclosure_test.dart` 2/2 |
| V-LIVE-001 | REQ-ACD-002 | **blocked-host** | Agents present on PATH for some ready-candidates; authorized live A/B not run this session; V-FIX-001 green |
| V-LIVE-002 | REQ-ACD-003 | **blocked-host** | Release-UI P-10 evidence promotion not run; V-FIX-002 + fail-closed readiness green |
| V-E2E-001 | REQ-ACD-006 | **pass** | All CI/fixture checks green; live checks explicitly blocked-host with fixtures green |
| Client rebuild/launch | delivery rule | **pass-with-note** | `npm run client:run:macos` built Arc.app and `open` succeeded (exit 0). Sidecar target-scan step reported failure with empty detail during packaging; app executable present and launched. Earlier `kLSNoExecutableErr` not reproduced on this rebuild. |

### Delivered adapter tiers (current evidence)

From checked-in readiness with empty evidence adapters: **0 ready**, **3 blocked**, **7 unverified**, **sendEnabled 0**. No adapter claims native-conversation parity.

## Traceability to Evidence Scope

Evidence.md locks implementation priority: ready-candidates get harness/evidence work; lane-upgrade-candidates stay blocked until official resume gaps close; antigravity stays structurally blocked. Validation must not require antigravity live pass for plan completion — V-BOUND-001 fail-closed codes are sufficient for that adapter under REQ-ACD-004.
