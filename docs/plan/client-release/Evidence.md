# LicoArc End-to-End Release Evidence

## Evidence policy

This ledger is the current evidence authority for the unified client-release plan. It accepts current source, fresh command exit status, focused behavior tests, and primary specifications. Historical plan status, old reports, prose-only completion claims, device identities, account data, secrets, ciphertext, personal paths, and raw runtime output are not evidence.

Status meanings:

- **Closed — source + fresh verification:** the original defect is removed and current focused evidence covers it.
- **Accepted scoped limitation:** the capability is excluded from the supported claim; the client remains fail-closed and discloses the limitation.
- **Remaining external / physical / protocol blocker:** closure requires an authority, device property, protocol participant, or independent reviewer outside the local source tree. A publisher identity or store channel is a blocker only for its separately named platform/store publication decision.
- **Pending local closure:** current source or a fresh local receipt still has a concrete unmet condition. This status cannot be promoted by prose.

## Fresh verification snapshot

| Area | Redacted current receipt |
| --- | --- |
| Release lineage | Receipt 28, target 6, schema 18, acceptance 43, artifact I/O 31, dependency 2, package 17, and closure-writer 14 checks passed. |
| Structure and static analysis | Architecture, Better Plan, and client-boundary gates passed; Flutter analysis reported 0 issues. |
| Native client | Secure Mesh order isolation now uses caller-owned bounded replay guards, concurrent dispatch event sinks are thread-isolated, and the full native library run passes 884/884 tests. |
| Filesystem security | Safe archive 9, skill lifecycle 27, and file-security 5 tests passed. |
| Product correctness | The full Flutter product suite passed 488 tests with one declared skip. |
| Local platform closure | Android Emulator and iOS Simulator canonical receipts passed on the same frozen source. The macOS release bundle was built, locally verified, and launched. Linux build, archive, VM install, GUI launch/shutdown, privacy checks, and release CLI passed; the three-node matrix stopped on an external image-build dependency after bounded retries. No machine or simulator identifier is retained as evidence. |

The current deterministic adapter reduction reports **0 ready / 0 failed / 2 blocked / 9 unverified** with **sendEnabled 0**. Cursor vendor-session cleanup and Antigravity public structured transport are the remaining explicit implementation-blocked leaves. Claude Code no-persistence process-local continuation, Hermes persistent ACP resume/cancel, Kimi canonical ACP, and Pi exact RPC/isolated cleanup are `unverified`; none is promoted without complete live/release-UI evidence. This produces no Agent send claim and keeps every ordinary CLI, GUI and routed send path disabled.

The adapter contribution standard is now machine-gated: the schema contract test passes, and `client:verify:agent-adapter-standard` validates the exact 11-entry packaging/inventory set, closed capability fields, safety blocker rules, no overclaimed cancel support, product-UI evidence, and the minimum three-pass requirement. This standard is an implementation prerequisite, not live readiness evidence.

The bounded Flutter product integration receipt passes two composer turns through the real application shell, observes progressive timeline output, reuses one exact native session identifier for the follow-up, and completes two streamed history readbacks. It runs with a dedicated debug integration flag because Flutter's supported desktop `integration_test` runner is not a release runner. The receipt explicitly rejects `releaseUiPassed` and cannot update canonical adapter evidence or readiness; P-10 and the three consecutive real-adapter release-UI passes remain unmet.

## Current blocker ledger

| ID | Requirement | Current status | Current evidence or remaining boundary |
| --- | --- | --- | --- |
| BLK-001 | REQ-REL-001 | Closed — source + fresh verification | Canonical receipts bind current source state, exact staged artifacts, functional harnesses, and immutable release-artifact identities; mobile canonical runs passed on one frozen source and desktop lineage checks passed. |
| BLK-002 | REQ-REL-002, REQ-REL-003 | Closed — source + fresh verification | The architecture verifier follows the current shell/module ownership; architecture and boundary gates pass. |
| BLK-003 | REQ-REL-005 | Closed — source + fresh verification | macOS acceptance and receipt bind the same distribution archive, reference, and manifest; receipt and acceptance suites pass. |
| BLK-004 | REQ-REL-005 | Closed — source + fresh verification | Local identity-install fixtures satisfy the canonical package-manifest contract; the package suite passes 17 checks. |
| BLK-005 | REQ-REL-005 | Closed — source + fresh verification | Linux acceptance, receipt, manifest, and distribution archive now share one lineage; target, schema, acceptance, and artifact-I/O suites pass. |
| BLK-006 | REQ-REL-004, REQ-REL-005 | Closed — source + fresh verification | Android selection is explicit and its companion CLI is built from the same checkout. The separate Emulator install/launch receipt remains a local validation action, not this lineage defect. |
| BLK-007 | REQ-REL-004 | Accepted scoped limitation | Preview or unsupported target capabilities are excluded from supported claims. Only the selected, evidenced target subset can become GitHub Release-ready. |
| GUIDE-PLATFORM-001 | REQ-REL-005 | Not requested — non-blocking guidance | Production identity, notarization or store signing, protected publication, public store download, update continuity, and rollback are assessed only for an explicitly requested named channel. No channel is currently requested, so these inputs create no development, ordinary-build, client-functionality, or GitHub Release blocker. |
| BLK-009 | REQ-REL-002 | Closed — source + fresh verification | Current formatting and source-shape checks no longer carry the initial drift; fresh structural and native suites pass. |
| BLK-010 | REQ-REL-002, REQ-PROD-001 | Closed — source + fresh verification | Flutter analysis reports 0 issues against the current contracts. |
| BLK-011 | REQ-REL-002, REQ-PROD-001 | Closed — source + fresh verification | The identified product regressions are covered by 52 focused Flutter cases; native library and integration suites are also green. |
| BLK-012 | REQ-REL-002, REQ-REL-006 | Closed — source + fresh verification | Test state is isolated from real portable data and cache authority; the client-boundary gate passes. |
| BLK-013 | REQ-PROD-001, REQ-ROUTE-001 | Closed — source + fresh verification | Usage falls back to the available model summary when daily buckets are absent and still reports daily-detail unavailability; focused product tests pass. |
| BLK-014 | REQ-PROD-002 | Pending — targeted verification required | The Rust local task queue must bind FIFO ordering, bounded capacity, cloned producers, backpressure, ownership-preserving rejection, depth accounting, worker disconnect, and invalid-capacity behavior to a current module receipt. |
| BLK-015 | REQ-PROD-004, REQ-REL-006 | Closed — source + fresh verification | Android diagnostic evidence is redacted, atomic, bounded, and pruned; it does not expose device identity or secret material. |
| BLK-016 | REQ-PROD-004, REQ-SEC-001 | Closed — source + fresh verification | Strict URI validation now precedes persistence and rejects incomplete or deceptive HTTPS authority, userinfo, query-only authority, and fragments; focused product verification passed. |
| BLK-017 | REQ-E2EE-001 | Closed — source + fresh verification | The current serializer/open path, caller-owned replay guards, concurrent order isolation, and exact-session event isolation are covered by the focused Secure Mesh suites and the full 884-test native library run. |
| BLK-019 | REQ-SEC-001 | Closed — source + fresh verification | Interactive macOS custody fails closed when LocalAuthentication is unavailable instead of silently selecting ordinary persistent storage. Real Keychain user-presence proof remains a physical acceptance input. |
| BLK-020 | REQ-SEC-001, REQ-E2EE-005 | Closed — source + fresh verification | Android has no unauthenticated persistent-key candidate; unavailable device credential/strong biometric yields explicit memory-only custody. Real hardware-backed custody remains a physical acceptance input. |
| BLK-021 | REQ-SEC-002 | Closed — source + fresh verification | Handle-relative no-follow extraction rejects destination-root and ancestor symlinks; all 9 safe-archive cases exercise the extractor. |
| BLK-022 | REQ-E2EE-002, REQ-E2EE-004, REQ-E2EE-008 | Remaining external / physical / protocol blocker | Internal trust, MLS, and fail-closed reducers are covered by the fresh Secure Mesh suites. Production availability still requires fresh external KT gossip/witness evidence and cannot be promoted locally. |
| BLK-023 | REQ-REL-002 | Closed — source + fresh verification | The initial native lint defect is removed; current native, CLI, and integration suites pass. |
| BLK-024 | REQ-E2EE-005 | Simulator closure complete; physical blocker remains | The canonical iOS Simulator receipt binds the functional harness separately from the immutable exact release artifact, exercises the FFI lifecycle and simulated authorization outcomes, and passed on frozen source. Real Keychain/Secure Enclave custody and Face ID or Touch ID remain physical-device blockers. |
| BLK-025 | REQ-AGENT-001, REQ-AGENT-002 | Accepted scoped limitation | Adapter readiness remains 0 ready / sendEnabled 0. Newly declared structural blockers require a fresh deterministic reduction before exact blocked/unverified counts are quoted. No adapter is presented as send-capable without fresh official-lane evidence. |
| BLK-026 | REQ-ROUTE-002 | Accepted scoped limitation | Optional routing is excluded from release claims until included/excluded artifact and runtime evidence exists; the routing-excluded client can be packaged without claiming routing support. |
| BLK-027 | REQ-REL-007 | Closed — source + fresh verification | The unified Better Plan workspace is structurally valid and historical plan statuses are not release inputs; the plan gate passes. |
| BLK-028 | REQ-SEC-002 | Closed — source + fresh verification | Rollback validates snapshot identity, ownership, approval, receipt, install-root containment, relative paths, and single-use semantics; the skill suite passes 27 checks. |
| BLK-029 | REQ-SEC-002, REQ-REL-006 | Closed — source + fresh verification | Log export rejects links and same-file targets, enforces a size bound, and commits through an exclusive atomic temporary file; file-security tests pass. |
| BLK-030 | REQ-SEC-002 | Closed — source + fresh verification | The skill journal is private, bounded, no-follow, path-validated, locked, atomic, and recoverable across both rename steps; the skill suite passes. |
| BLK-031 | REQ-SEC-002 | Closed — source + fresh verification | Shared replacement uses cross-device fallback only for the actual cross-device error and copies through a private target-side temporary file before atomic rename. |
| BLK-033 | REQ-AGENT-001, REQ-REL-004 | Accepted scoped limitation | Zero ready adapters intentionally disable Agent send and suppress Agent claims; this does not invalidate unrelated package readiness. |
| BLK-034 | REQ-REL-003, REQ-PROD-001 | Closed — source + fresh verification | Retired product wording and shell assumptions are removed from the current contract; architecture and plan gates pass. |
| BLK-035 | REQ-REL-002, REQ-REL-003, REQ-PROD-001 | Closed — source + fresh verification | Current production call sites satisfy controller-bearing shell contracts; Flutter analysis reports 0 issues. |
| BLK-036 | REQ-AGENT-001, REQ-AGENT-002 | Accepted scoped limitation | Partial native-lane capability does not advance readiness. These adapters remain unverified and send-disabled until repository-owned consecutive release-UI evidence exists. |
| BLK-037 | REQ-AGENT-002 | Remaining external / physical / protocol blocker | Exact secure resume needs a non-argv official Claude Code lane. Until the vendor exposes one, exact-session send is blocked and excluded. |
| BLK-038 | REQ-AGENT-002 | Remaining external / physical / protocol blocker | Antigravity has no safe public local conversation transport. Send/resume stays blocked and excluded until an official lane exists. |
| BLK-039 | REQ-AGENT-001 | Accepted scoped limitation | Mid-run inject/steer is outside the one-shot dispatch contract. Routing occurs only at message boundaries and no in-flight capability is claimed. |

## Remaining physical, external, and delegated boundaries

- Android Emulator and iOS Simulator receipts now bind source, toolchain, exact staged artifact, install, launch, native bridge/FFI, and simulated authorization outcomes on the same frozen source.
- The Linux three-node matrix remains blocked by an external image-build dependency after bounded retries; preceding build, archive, VM install, GUI bounded shutdown, privacy, and release-CLI checks passed.
- Physical Keychain, Android Keystore, Secure Enclave, hardware-backed keys, real biometrics, native Windows host execution, and physical cross-device transfer remain outside local/simulator proof and continue to limit their security claims. Production signing, notarization, store publication/download, and store update/rollback are separately unready channel guidance, not GitHub Release blockers.
- The client-owned Relay Mock now passes its exact five-operation/six-field corpus, negative conformance, replay, stale-lease, ACK, backpressure, and no-plaintext checks. External KT gossip/witness and an independent cryptographic audit remain mandatory before any broad product-line security claim.
- The phone→desktop→phone handoff queue, duplicate-safe resume, receive-before-ACK rule, ciphertext bounds, endpoint isolation, and ACK purge are implemented and locally verified. Physical-device evidence remains external to the repository implementation.
- First-party release report producers now use the bounded atomic no-plaintext writer; digest/reference integrity and dangling-reference checks are enforced by the Better Plan evidence ledger.
- Windows x64 has a target-bound builder, PE32+ architecture verifier, bundle digest binding, Credential Manager custody path, and native lifecycle smoke. Local implementation closure is separate from native Windows-host receipts and from selection as a GitHub Release target. Native host evidence remains external; production signing is channel-only guidance and does not block development, ordinary verification, packaging, or GitHub Release for selected targets. Windows arm64 remains fail-closed because the pinned Flutter toolchain does not provide a native arm64 Windows target.

## Primary design references

- [Signal Double Ratchet](https://signal.org/docs/specifications/doubleratchet/) grounds unique message keys, deleted chain state, out-of-order handling, ratchet updates, and header encryption.
- [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) grounds authenticated MLS group framing, proposals, commits, credentials, and private application messages.
- [RFC 9162](https://www.rfc-editor.org/rfc/rfc9162.html) grounds Merkle inclusion and consistency proofs, signed tree heads, and auditable transparency state.
- [Telegram Secret Chats](https://core.telegram.org/api/end-to-end) grounds the comparison boundary for endpoint-only keys, re-keying, ordering, replay, and omission defense.
- [Apple Keychain user presence](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence) and [Android Keystore](https://developer.android.com/privacy-and-security/keystore) ground fail-closed platform authorization.
- [GitHub artifact attestations](https://docs.github.com/en/enterprise-cloud@latest/actions/concepts/security/artifact-attestations) ground consumer-verifiable source/build provenance for GitHub Release artifacts; they do not establish a separate platform/store publisher identity.
