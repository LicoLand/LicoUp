# LicoArc End-to-End Release Evidence

## Evidence policy

The blocker audit was performed before reading the old plan tree. Accepted evidence is current source, canonical configuration, fresh command exit status, focused behavior tests, and primary specifications. Existing reports, readiness JSON as a completion claim, progress documents, checked criteria, and historical receipts were excluded. Readiness resources are used only to observe their current fail-closed state.

All evidence below is minimum-necessary and omits machine identity, account data, device identifiers, secrets, ciphertext, personal paths, and raw runtime output.

## Confirmed blockers

| ID | Severity | Requirement | Fresh evidence and release impact |
| --- | --- | --- | --- |
| BLK-001 | Critical | REQ-REL-001 | The release workflow, target/version/support catalogs, acceptance and receipt configs, and distribution helpers are currently untracked while tracked callers already depend on them. A clean checkout cannot reproduce the current release closure. Verify with a path-scoped `git status --short`. |
| BLK-002 | Critical | REQ-REL-002, REQ-REL-003 | `npm run client:verify` stops at `client:verify:architecture`: the verifier still hard-codes an older seven-section shell and scans only the main MCP panel file while current capability checks live in its `part` file. CI is red until implementation, behavior tests, and the architecture gate agree. |
| BLK-003 | Critical | REQ-REL-005 | `npm run client:verify:client-release-acceptance:self-test` exits 1. The macOS acceptance config names a distribution ZIP, the receipt config still names `Arc.app`, and the dispatcher only recognizes the app-bundle kind. All current CI and release jobs call this failing default gate before packaging. |
| BLK-004 | High | REQ-REL-005 | `client-macos-local-identity-install.mjs --self-test` exits 1 because its positive input fixture omits fields that `validateInputPackageManifest` requires. The default gate would fail again even after the earlier architecture and acceptance failures are fixed. |
| BLK-005 | High | REQ-REL-005 | Linux acceptance uses the direct distribution archive while the receipt uses a VM archive; the producer writes `manifest.json` while acceptance requests another manifest name. The validation key id is also coupled to a VM-specific value. These are different artifact lineages. |
| BLK-006 | High | REQ-REL-004, REQ-REL-005 | The Android release job runs on macOS and does not set `LICO_CLIENT_RELEASE_TARGETS=android-arm64`, so acceptance infers macOS. It also requires physical install evidence and a same-source desktop CLI that the workflow does not build. |
| BLK-007 | Critical | REQ-REL-004 | The support reducer marks `client-shell` and `secure-mesh-pairwise` release-blocking, but the three current release-authority targets still contain `preview` rather than `supported` values. All three reduce to not release-ready. |
| BLK-008 | Critical | REQ-REL-005 | Current acceptance fixes `publicationReady` false and requires production identity, update continuity, and store publication false. The workflow has read-only contents permission and uploads transient CI artifacts only. Current `releaseReady` is therefore a local artifact closure, not real publication. |
| BLK-009 | High | REQ-REL-002 | `npm run client:format:check` exits 1 for 12 Dart files; `cargo fmt --all -- --check` also exits 1. Both are default release gates. |
| BLK-010 | High | REQ-REL-002, REQ-PROD-001 | `npm run client:analyze` exits 1 because two search tests omit the new required `ShellCenterSearch.width`; four additional infos remain. Production-only analysis passes, which narrows but does not remove the release blocker. |
| BLK-011 | High | REQ-REL-002, REQ-PROD-001 | `npm run client:test` reports 458 pass, 1 skip, and 13 fail. Failures cover search compilation, usage UI, status indicators, theme expectations, top-bar goldens, target cache behavior, removed tab-bar assumptions, and two mobile timing flows. |
| BLK-012 | Critical | REQ-REL-002, REQ-REL-006 | Default controller tests construct the real portable-data root and scanned-target cache. Test results depend on machine state and can mutate real client cache data. Every such test needs an isolated temporary root and in-memory or no-op cache. |
| BLK-013 | High | REQ-PROD-001, REQ-ROUTE-001 | The agent-usage verifier is bound to an old top-bar/inline layout, and the usage timeline ignores an existing model summary when daily buckets are absent, displaying a false empty state. Routing allowance cannot be trusted until the reducer and UI agree. |
| BLK-014 | Critical | REQ-PROD-002 | Feed assigns one dispatch id to all mentioned targets. `_completedDispatchIds` records that id after the first success, so later targets return early but are still recorded as successful. Per-target outcomes are not durable; attachments are synchronously read without a size or content contract. |
| BLK-015 | High | REQ-PROD-004, REQ-REL-006 | Android production initialization appends account, relay, auth-source, credential-presence, and pairing metadata to a fixed external JSONL diagnostic without consent, protection, rotation, or bound. Repeated cold starts grow it indefinitely. |
| BLK-016 | High | REQ-PROD-004, REQ-SEC-001 | Custom relay gateway configuration is persisted before strict URI parsing. Native HTTPS validation accepts a string prefix and does not reject userinfo, deceptive authority, fragment, or incomplete URL; failure is delayed until network use. |
| BLK-017 | Critical | REQ-E2EE-001 | `cargo test` reports 732 pass and 40 fail. Thirty-four failures share one cause: the v2 serializer emits delivery and mailbox tokens plus encrypted header/ciphertext, while the production open path still reads removed envelope/message/time fields and fails every seal-to-open flow. |
| BLK-018 | Critical | REQ-SEC-001 | A paired remote can request `provider.credential.export`; command policy classifies it as a safe write with no default local confirmation, and forwarding returns raw API-key or OAuth credential material. Encrypted transport does not replace local user authorization. |
| BLK-019 | Critical | REQ-SEC-001 | macOS secret storage falls back from a LocalAuthentication user-presence session to ordinary keyring storage while runtime state still reports the store available. The project rule requires permission and OS authentication; absence must fail closed or become explicit memory-only custody. |
| BLK-020 | High | REQ-SEC-001, REQ-E2EE-005 | Android key policy generates a persistent Keystore candidate with authentication mode `NONE`, and tests make that behavior intentional when no lock screen exists. Non-exportability alone does not satisfy this client's user-authorization contract. |
| BLK-021 | High | REQ-SEC-002 | The Rust safe extractor rejects archive-entry links but can follow a pre-existing symlink in the destination's parent path before creating a new output file. Current tests do not cover this escape. Two traversal tests also panic while constructing the tar and never exercise the extractor. |
| BLK-022 | High | REQ-E2EE-002, REQ-E2EE-004, REQ-E2EE-008 | Production Secure Mesh status is constructed from `missing_evidence`; MLS remains hard-coded not production-ready; KT and MLS FFI tests lack newly required trust and gossip/witness state. Product availability and claim reducers are therefore explicitly blocked. |
| BLK-023 | High | REQ-REL-002 | Clippy with warnings denied fails on a `drop_non_drop` finding. Native smoke, release Cargo check/build, capability-native verification, and the configured dependency audit pass, but those passes cannot override formatting, Clippy, or 40 failing tests. |
| BLK-024 | Medium | REQ-E2EE-005 | iOS Swift implements Keychain callbacks, but the Rust callback store reports supported without capability facts, so the protocol capability model projects memory-only custody. Native iOS tests remain a template and do not cover the bridge, LocalAuthentication, or Keychain callbacks. |
| BLK-025 | Critical | REQ-AGENT-001, REQ-AGENT-002 | All ten packaged adapter readiness entries currently disable sending and lack fresh official-lane proof. Fail-closed gating is correct infrastructure, but it does not satisfy native parity or the core agent workflow. Each adapter needs current proof or honest exclusion. |
| BLK-036 | Critical | REQ-AGENT-001, REQ-AGENT-002 | Specified-conversation continue + progressive `--stream-events` NDJSON are implemented with native-first transports: Codex long-lived app-server unix/proxy attach (stdio fallback); Cursor CLI `--resume`/`create-chat` print stream-json (ACP fallback). Live proof uses `gpt-5.3-codex-spark` and Cursor `Auto`. Full Codex parity may still time out at history read. Cursor validation now executes real turns and reports cleanup separately; official scripted deletion remains unavailable/manual-required. `sendEnabled` stays 0 until consecutive release-UI evidence. |
| BLK-037 | High | REQ-AGENT-002 | Claude Code is structurally blocked for exact resume: readiness `official_native_lane_missing`; driver fails closed with `claude_code_secure_resume_unavailable` because public resume is argv-bound. History-only / new-session-only until a non-argv official lane exists. |
| BLK-038 | High | REQ-AGENT-002 | Antigravity is structurally blocked for send/resume: readiness `antigravity_public_transport_unavailable`; no safe public local conversation transport. History-only until a public lane ships. |
| BLK-039 | Medium | REQ-AGENT-001 | Mid-run interrupt/steer (CL-06 C-05) is unavailable by product design: one-shot dispatch has no supervised in-flight turn; routing never interrupts streams. Do not treat this as an adapter parity gap under the current contract. |
| BLK-026 | High | REQ-ROUTE-002 | Only the routing-excluded compile branch is proven. No same-source included/excluded release artifacts, physical absence proof, real controller unload/re-enable, direct-dispatch smoke, or five-run startup/RSS evidence exists. |
| BLK-027 | Critical | REQ-REL-007 | The old Better Plan workspace is structurally invalid: one root checkpoint file contains three simultaneous in-progress Nodes and five platform files store `evidence_refs` at an unsupported Node level. Historical completion states and evidence cannot be release inputs. |
| BLK-028 | Critical | REQ-SEC-002 | Skill rollback accepts an unchecked snapshot id and trusts the snapshot's absolute install directory before recursive deletion and restore. Traversal, cross-agent ownership, approval, containment, and symlink invariants are not enforced, so a crafted snapshot can delete or replace a directory outside the skill roots. |
| BLK-029 | High | REQ-SEC-002, REQ-REL-006 | Client log export follows source or destination symlinks, can truncate when source and destination resolve to the same file, writes directly rather than through an atomic replacement, and has no export-size bound. |
| BLK-030 | High | REQ-SEC-002 | The skill-install journal uses ordinary reads and writes with unvalidated absolute paths, no no-follow or private-mode guarantee, no durable atomic commit, and incomplete recovery after the second rename fails. Its temporary cleanup pattern is also a literal wildcard rather than a matched path. |
| BLK-031 | High | REQ-SEC-002 | The shared file replacement helper treats every rename error as a cross-device case, moves the destination aside, and copies into place. A concurrent destination symlink can be followed and parent checks do not close ancestor-link races, so the fallback is neither atomic nor containment-safe. |
| BLK-032 | High | REQ-PROD-004, REQ-SEC-001 | Desktop provider-credential deletion returns a synthetic successful response without invoking a native delete path. Account metadata can disappear while the keyring record remains, violating account-scoped lifecycle and truthful UI behavior. |
| BLK-033 | Critical | REQ-AGENT-001, REQ-REL-004 | The package conversation reducer verifies that its output matches the current readiness resources but does not require any ready or send-enabled adapter. Ten packaged targets with zero ready lanes can therefore pass package validation; the New Conversation entry also does not consume this fail-closed state. |
| BLK-034 | High | REQ-REL-003, REQ-PROD-001 | Current source, tests, and packaging labels still expose retired `Future client` product wording and removed shell assumptions. These leftovers make architecture gates disagree with the current UI and violate the required one-pass product-contract migration. |
| BLK-035 | Critical | REQ-REL-002, REQ-REL-003, REQ-PROD-001 | A fresh canonical macOS release build fails during Flutter kernel compilation: `ShellTopBar` and `ShellTrailingTools` now require a `controller`, but current production call sites in `ClientShell` and the trailing-tools composition omit it. Packaging produces no fresh runnable, so launch acceptance cannot start. |

## Specified-conversation capability snapshot

Observable from `agent-conversation-drivers.json` and `agent-conversation-readiness.json` (`ready: 0`, `sendEnabled: 0`) plus live CLI probes on 2026-07-13:

| Agent | History list | Declared exactResume | Readiness | Exact-session send today | Streaming echo | Plan posture |
| --- | --- | --- | --- | --- | --- | --- |
| Codex | yes | true | unverified / evidence_missing | Native-first: long-lived `app-server` attach via unix control socket + `proxy --sock` (stdio fallback). Live CLI exact continue on `gpt-5.3-codex-spark` + `reasoningEffort=low`: `sameSession` + dual canaries. | yes — both turns emit progressive NDJSON chunks | Capability proven; vendor `daemon start` needs standalone install; Arc-managed unix listen used when available |
| Cursor | yes | true | unverified / evidence_missing | Native-first: CLI `create-chat` / `--resume <chatId>` / print `stream-json` (ACP `session/load` demoted to fallback). Live exact continue proven with dual canaries. | yes — stream-json assistant deltas mapped to `agent.message.chunk` | Capability proven post-login; `agent ls` is TUI-only (not automation); `--strict` cleanup gate remains |
| OpenCode | yes | true | unverified / evidence_missing | no | n/a this node | Doable after shared harness |
| Copilot | yes | true | unverified / evidence_missing | Native research: prefer SDK session-state + CLI `--resume=<id>` over ACP investment; `--continue` is newest-only (reject for Arc). ACP load/stream identity proven with `authenticate`, but driver still lacks auth step; CLI `-p` non-zero (model-class). | ACP chunks watchable when auth+prompt path works; CLI `-p` not proven streaming | See `copilot-exact-continue-evidence.md`; keep fail-closed |
| OpenClaw | yes | true | unverified / evidence_missing | Gateway-native attach landed: probe/reuse vendor `18789` first (never bind/steal); else Arc-owned uncommon `24189+` with conflict detection; ACP `--url` attaches for stream + exact `session/load`. Live send still blocked until Gateway binary/health + consecutive evidence. | transport wired (`stdio_ndjson_on_send` + Gateway attach) | Prefer `openclaw-gateway ensure` / vendor status-install reuse; readiness stays fail-closed |
| Hermes | yes | true | unverified / evidence_missing | Fixture exact continue proven (`session/load` + identical native id). Live CLI blocked: Hermes Agent executable unavailable on host. | Fixture yes — progressive `agent.message.chunk` / `agent.message.completed` via turn-event sink | Driver emit + exact-resume tests landed; see `hermes-exact-continue-evidence.md`; readiness still fail-closed |
| Kilo Code | yes | true | unverified / evidence_missing | native serve/attach wired; sendEnabled still false | transport wired (`kilo-code-serve-http-v1`, ports 4097–4116); live consecutive evidence pending | Primary lane is `kilo serve` HTTP attach (OpenCode mirror); ACP secondary; `--continue` newest-session rejected |
| Kimi Code | yes | true | unverified / evidence_missing | no | n/a this node | Doable after shared harness |
| Claude Code | yes | false | blocked | no | n/a | Blocked leaf: argv resume / missing secure lane |
| Antigravity | yes | false | blocked | no | n/a | Blocked leaf: no public transport |

### Live verification commands (redacted receipts)

- Codex Spark stream + exact continue (native-first attach): `lico-client agent conversation send --stdin-json true --stream-events true` with `model=gpt-5.3-codex-spark`, `reasoningEffort=low`, then second turn with captured `sessionId` — `exactContinue=true`, `streamingSeen=true`.
- Cursor CLI stream + exact continue (native-first): same send path with `agent=cursor` after login — uses `create-chat`/`--resume` print stream-json; `exactContinue=true`, `streamingSeen=true`.
- Cursor harness: native CLI turns execute before cleanup policy is evaluated; cleanup is reported as `cursor_cleanup_manual_required` and does not erase request/session results.
- Sibling port notes (do not steal): OpenCode `:24173`, OpenClaw `:18789`, Kimi `:58627`, Codex WS reserved `:24174`, Kilo serve like OpenCode, Pi=`--mode rpc`.
- Hermes fixture exact continue + streaming: `cargo test … hermes_driver` — 8/8 passed. Live Hermes Agent executable unavailable — fail-closed (`hermes-exact-continue-evidence.md`).
- Copilot native-first research: CLI `--continue` = newest (not exact); `--resume=<id>` exact but argv-bound with `-p`; SDK session-state is preferred identity/cleanup; ACP `session/load` works after `authenticate` with progressive chunks — do not expand ACP surface. Details in `copilot-exact-continue-evidence.md`.
- Kilo Code native-first: `kilo serve` HTTP attach (ports 4097–4116) is primary; ACP secondary; `--continue` newest rejected. Health + exact `GET /session/{id}` smoke passed; see `kilo-exact-continue-evidence.md`. `sendEnabled` remains false.

Readiness remains fail-closed (`sendEnabled: 0`). Do not mark adapters ready until consecutive release-UI evidence is written and reduced.

### Canonical verifier run — 2026-07-13

`npm run client:verify:agent-conversations:release-ui` ran the repository-owned
verifier and wrote the redacted report at
`build/reports/agent-conversation-verification.json`. The run used the canonical
model policy: Codex `gpt-5.3-codex-spark`, Cursor `Auto`, Kilo Code
`Kilo Auto Free`, and agent defaults elsewhere.

| Adapter | Live result | Current reason | Plan effect |
| --- | --- | --- | --- |
| Kimi Code | live harness passed | reducer reports `conditional_check_failed`; readiness has zero consecutive passes | Keep pending; diagnose the failed conditional and do not enable send |
| Codex | failed | `process_timeout` | Keep pending for harness/runtime diagnosis |
| OpenCode | failed | `acp_invalid_json` | Keep pending for native serve protocol diagnosis |
| Copilot | failed | final response parity fact failed | Keep pending for final-message normalization diagnosis |
| Cursor | conversation validation executes; release cleanup incomplete | latest strict run: 5 sessions, 10 requests, 9 successful (90%); official scripted cleanup unavailable | Keep release readiness fail-closed; diagnose the third-round request and require manual cleanup |
| OpenClaw | blocked | `agent_executable_unavailable` | Blocked leaf in this environment |
| Kilo Code | blocked | `agent_executable_unavailable` | Blocked leaf until canonical executable discovery succeeds |
| Hermes | blocked | `agent_executable_unavailable` | Blocked leaf in this environment |
| Pi | not run | `live_harness_unavailable` | Keep pending; add the RPC live harness |
| Claude Code | blocked | `official_native_lane_missing` | Existing structural blocker remains |
| Antigravity | blocked | `antigravity_public_transport_unavailable` | Existing structural blocker remains |

The verifier's native-platform aggregate failed during this combined live run,
while the reducer contract, readiness contract, and harness self-test passed.
This aggregate failure and every adapter result remain fail-closed. The run
produced `releaseReady: 0`; no readiness or packaging claim was promoted. After
the authoritative reducer write, the readiness summary is `failed: 1`,
`blocked: 2`, `unverified: 8`, `sendEnabled: 0`; Kimi Code owns the failed row
with `conditional_check_failed`.

### Codex / Cursor promotion gate (honest; no fake-ready)

Live CLI receipts (`exactContinue=true`, `streamingSeen=true`) are prerequisite capability proofs only. They are **not** written into `agent-conversation-evidence.json` and do **not** advance `consecutivePasses`, `releaseUiPassed`, P-10, or `sendEnabled`.

| Adapter | Current readiness | Structural blockers | Remaining commands (minimum) |
| --- | --- | --- | --- |
| Codex | `unverified` / `evidence_missing` | none structural; cleanup lane ready | 1) `npm run client:run:macos` (fresh release `.app` sidecar for P-10)<br>2) `lico-dev workflow run` with side-effects authorized, then<br>`node tools/scripts/client-acp-conversation-parity.mjs --agent codex --strict --release-ui`<br>3) Repeat until receipt `consecutivePasses=3` and `status=release-ui-passed` (producer upserts evidence)<br>4) Extend harness / re-run so supported conditionals `C-01`/`C-02` are `pass` (not `unverified`)<br>5) `node tools/scripts/client-agent-conversation-parity-reducer.mjs --write`<br>6) `npm run client:verify:agent-conversation-parity` |
| Cursor | `unverified` / `evidence_missing` | Public Cursor Agent CLI has `create-chat` / `--resume` / `ls` but no scripted delete/reclaim API. The harness uses `manual-required`, still executes all conversation requests, and reports cleanup separately. | Resolve the remaining third-round request failure; cleanup remains a release-policy blocker until an official API exists. |

Never alone establishes ready / sendEnabled:

- `npm run client:verify:agent-conversation-parity` (fixture/self-test)
- `npm run client:verify:codex-conversation:live` or ad-hoc CLI exactContinue/streamingSeen smokes
- core-only `--strict` without `--release-ui`

Evidence producer behavior (2026-07-13): `--release-ui` upserts a sanitized adapter row only when `status=release-ui-passed`; self-test refreshes harness metadata without wiping live rows; CLI-only receipts are never promoted.


## Current passes that remain useful baselines

- Repository ownership and client/server boundary checks pass.
- Local-info hygiene and workspace-cache boundary checks pass with no disclosed finding.
- Version synchronization and structural support-matrix checks pass.
- `flutter analyze --no-pub lib` passes; the full analysis failure is currently in tests and lint integration.
- Release Cargo check and build, native smoke, proxy-bridge verification, capability-native verification, package dry-run, JavaScript syntax checks, release JSON parsing, and the configured dependency audit pass.
- Android acceptance and receipt agree on artifact kind, path, and signature-policy fields; the workflow target selection and evidence prerequisites remain broken.
- Routing-excluded compilation passes; this is only a compile boundary, not optional-package acceptance.

## Unverified release boundaries

No current evidence proves a real Developer ID and notarized macOS distribution, Linux arm64 publisher identity and clean-machine install, Android production-signed APK on an authorized physical phone, iOS or Windows release artifact, cross-target native build, public channel upload/download, update continuity, rollback, real Secret Service/Keychain/Keystore user-presence flow, hostile production relay, or independent cryptographic audit. Each remains fail-closed in its owning child plan.

## Primary design references

- [Signal Double Ratchet specification](https://signal.org/docs/specifications/doubleratchet/) grounds unique message keys, deleted chain state, out-of-order handling, DH ratchet updates, and header encryption.
- [RFC 9420, Messaging Layer Security](https://www.rfc-editor.org/rfc/rfc9420.html) grounds authenticated group framing, proposals, commits, credentials, and private application messages.
- [RFC 9162, Certificate Transparency v2](https://www.rfc-editor.org/rfc/rfc9162.html) grounds Merkle inclusion and consistency proofs, signed tree heads, and auditability used by the Key Transparency design.
- [Telegram Secret Chats](https://core.telegram.org/api/end-to-end) and its [sequence-number rules](https://core.telegram.org/api/end-to-end/seq_no) ground endpoint-only keys, re-keying, encrypted file keys, ordering, replay and omission defense, and the meaning of the comparison claim.
- [Apple Keychain user presence](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence) and [restricted keychain accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility) ground fail-closed user-presence policy and reusable OS authentication context.
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore) grounds non-exportable keys and per-use or time-bounded user-authentication authorization through BiometricPrompt.
- [GitHub artifact attestations](https://docs.github.com/en/enterprise-cloud@latest/actions/concepts/security/artifact-attestations) and [deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments) ground source/build provenance, protected release secrets, and approval-bound publication.

These references constrain architecture and negative tests. They do not prove that the current implementation conforms.

## Superseded-plan migration map

The prior semantic-archive, mobile-account, agent-dispatch, routing, routing-package, Secure Mesh, adaptive-hardening, fresh-blocker, and five platform-closure plans are folded into the requirement groups in `Requirements.md`. Their product invariants and owner decisions are retained; their statuses, checked criteria, evidence hashes, stale source observations, duplicated platform prose, artifact aliases, and destructive clean-tree commands are not. The old Secure Mesh set contained 49 Nodes and 87 checked criteria, but 29 of 50 file evidence digests no longer matched current files, 31 command records were historical rather than source-bound, and 19 checked parent criteria had no evidence reference. That is evidence of non-transferability, not evidence of implementation completion.
