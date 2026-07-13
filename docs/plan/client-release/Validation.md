# LicoArc End-to-End Release Validation

## Proof policy

Validation runs from a clean temporary checkout or CI checkout at the exact source revision. It never executes `git clean`, resets the user's tree, reads an existing report as readiness input, or uses a real portable-data root. Every passing command evidence record is bound to the source revision and, when applicable, the exact artifact digest. Device, signing, publication, and audit stages remain pending until their real authority runs them.

Android and iOS local app-build closure uses fresh repository-selected simulator instances. The
receipt binds source, toolchain, simulator runtime class, artifact digest, install and launch, FFI,
and simulated authorization outcomes without recording simulator identifiers. Physical Keystore,
Keychain/Secure Enclave, biometric, cross-device encryption, signing and store criteria stay
blocked and are never inferred from that receipt.

All emitted evidence is structured, allowlisted, bounded, and privacy-scanned. Raw command output, payloads, credentials, ciphertext, backend data, device identifiers, and personal paths are not retained.

## Foundation and quality gate

| Requirement | Positive proof | Negative or migration proof |
| --- | --- | --- |
| REQ-REL-001 | clean-checkout `npm ci`, canonical generated-contract checks, package dry run, path-scoped tracked-input assertion | remove one required tracked input and prove the gate fails before build |
| REQ-REL-002 | `npm run client:verify`; Flutter analyze/tests; Dart and Rust format; native tests; Clippy warnings denied; dependency, privacy, boundary and architecture checks | run tests with a poisoned real-state sentinel and prove no read/write; inject one stale gate token and prove behavioral ownership check rejects it |
| REQ-REL-003 | source search and compile prove one current shell, schema, bridge, registry and parser | retired names, DTO fields, paths, compatibility branches, fixtures and gate tokens have zero owning-source matches |
| REQ-REL-004 | target catalog and support reducer accept exact known supported selections | empty, duplicate, unknown, preview, unsupported, wrong-host, wrong-architecture and wrong-artifact selections fail closed |
| REQ-REL-005 | canonical acceptance binds source, build, profile, target, digest, signing, install, launch, publication, download, update and rollback | alter any digest, kind, identity, channel or target field and prove the receipt chain fails |
| REQ-REL-006 | final `lico-dev privacy scan` immediately follows the last producer and precedes upload | seeded canaries in paths, args, payloads, logs and diagnostics are rejected in raw and encoded form |
| REQ-REL-007 | final reducer reads every implementation Node and selected child receipt, then emits two named verdicts | missing child, stale evidence, untracked input, projection, skipped mandatory check or unavailable external audit is a blocker code |

The canonical client workflow is selected with `lico-dev workflow plan client`. Changed-file validation is selected only after implementation with `lico-dev workflow plan changed`; catalog tasks are run through `lico-dev regression run`, with side effects declared explicitly.

## Product behavior

| Requirement | Proof set |
| --- | --- |
| REQ-PROD-001 | current shell widget/integration tests, search width and accessibility tests, usage reducer cases with summary-only data, deterministic target scan/cache tests, reviewed goldens, architecture verifier over complete owning units |
| REQ-PROD-002 | two-or-more-target Feed integration tests with partial failure, retry, duplicate request, cancellation, empty selection and missing target; durable restart recovery; bounded text/binary/oversize attachment cases; UI derived from per-target outcomes |
| REQ-PROD-003 | native adapter fixtures and stream events reduce into the five layers; raw/audit are opt-in; archive paths are relative/digest-bound; migration search proves no parallel renderer remains |
| REQ-PROD-004 | multiple accounts for one provider remain independent through send/history/delete/callback/relay echo; native secret deletion is observed; malformed gateway corpus is rejected before persistence; Android production diagnostics are absent by default |

## Agents and routing

The canonical operator entry points are:

- `npm run client:verify:agent-conversations` for deterministic platform,
  reducer, readiness, and harness checks;
- `npm run client:verify:agent-conversations:live` for strict native-session
  continuation against installed runtimes;
- `npm run client:verify:agent-conversations:release-ui` for evidence-producing
  release-UI validation.

All three write a bounded, redacted JSON report. A live adapter pass alone does
not enable send: the release reducer still requires three consecutive,
source-bound release-UI passes plus cleanup and privacy evidence.

The verifier also writes a Markdown table beside the JSON report. Its columns
are agent, success or `Failed: <category>`, request pass rate, tested-session
count, request count, and the bounded sanitized harness return. Runtime prompts,
responses, session identifiers, credentials, personal paths, and raw logs are
never included.

- **REQ-AGENT-001:** contract tests run open/resume/send/stream/cancel/cleanup through direct, routed, and relay-backed calls. Static declaration, runtime capability, and evidence freshness are independently corrupted to prove the reducer fails closed. Zero ready adapters disable the New Conversation send entry and produce no agent-send claim without blocking unrelated package readiness. CLI/UI prove `conversations list|stream` returns exact `nativeSessionId` values; ready adapters prove `agent conversation send` with that id continues the same session and never resumes “newest.” Mid-run inject remains undocumented as a product capability and cancel without an active supervised turn stays fail-closed.
- **REQ-AGENT-002:** each adapter declared supported runs its official local lane against a fresh native session, proves bidirectional content, exact resume, streaming order, cancellation, permission failure, cleanup, history and redaction, then records source-bound evidence. Unsupported adapters are absent from supported packaging and UI claims while remaining truthfully discoverable where useful. Claude Code and Antigravity remain disclosed blocked/excluded for exact-resume send until their official-lane blockers clear; ACP adapters with `exactResume: true` stay `sendEnabled: false` until live consecutive evidence lands.
- **REQ-ROUTE-001:** deterministic fixture ground truth covers tie-breaking, rejection reasons, allowance boundaries, atomic policy reload, message-boundary switching, handoff preservation, stale capability probes and private-history exclusion.
- **REQ-ROUTE-002:** included and excluded artifacts are built from the same source and catalog. Binary/resource inspection proves real absence; direct dispatch works without routing; disable/re-enable releases watchers and caches; five independent runs prove median cold-start ≤50 ms and RSS delta ≤8 MiB.

## Security, protocol and filesystem

- **REQ-SEC-001:** hostile bridge/process-argument/log scans; exact-request local confirmation for credential export; one native authorization session across related operations; denial, cancellation, unavailable biometrics and background access fail closed; delete tests prove the native record is gone.
- **REQ-SEC-002:** hostile archive corpus exercises traversal, absolute paths, all link and special types, deep/wide/bomb inputs, pre-existing root and parent symlinks, concurrent destination replacement and deadline. Log export, skill install/rollback, journal recovery and cross-device rename tests use no-follow sentinels and prove containment plus crash consistency.
- **REQ-E2EE-001:** canonical six-field v2 wire golden and round-trip across every payload class; removed field names fail source migration search; wrong recipient, tamper, malformed, stale, duplicate, expiry and replay fail closed.
- **REQ-E2EE-002/003:** current identity, prekey, trust-record, key-change, revoke, restart, rollback, skipped-key bound, replay, resend, expiry and file-reseal vectors run in the shared Rust owner; verify-before-send is exercised through the UI/native boundary.
- **REQ-E2EE-004:** OpenMLS conformance and product-policy tests cover invitation, credentials, authorization, one-time KeyPackage, commit/epoch, removal and forward secrecy. KT tests require pinned external signatures, inclusion/non-inclusion, RFC 9162 consistency, checkpoint persistence and equivocation detection.
- **REQ-E2EE-005:** cycle, monotonicity, determinism and exact-set property tests cover the capability DAG in `O(V+E)`; platform fact producers prove supported, unavailable and unverified states; no-safe-store cases become memory-only.
- **REQ-E2EE-006:** each ACP payload family is classified and wire-tested; side-effect approval is bound to the encrypted payload digest and policy revision; cancel/deny/close/expiry remove references; reasoning is absent unless explicitly allowed.
- **REQ-E2EE-007:** an adversarial opaque relay captures real serialized bytes for every connected payload family and scans raw/base64/hex/escaped forms; observed timing, direction, buckets and retry volume are reported as residual metadata.
- **REQ-E2EE-008:** the product-line proof machine consumes current source-bound evidence and every five-platform terminal, then an independent audit receipt. The selected-target reducer is tested to prove it cannot set this verdict.

Primary comparison vectors and design constraints come from the Signal Double Ratchet specification, RFC 9420, RFC 9162, platform-native secure-storage documentation, and official artifact provenance guidance listed in `Evidence.md`.

## Cross-plan dependency proof

Each platform child final validation must record:

1. the parent architecture Node id and source digest it consumed;
2. the shared custody/protocol/product Nodes required by that target and their completed status;
3. its exact target tuple, source revision, artifact digest and redacted native receipts;
4. a passing child `check-labels` and Better Plan validation result.

The parent final validation runs Better Plan validation for the entire workspace, verifies every selected target's child final Node is `completed`, and separately verifies all five child finals for the product-line claim. A child UUID named only in prose is insufficient: the reducer input schema stores plan id, terminal Node id, source revision, artifact digest, evidence digest, decision kind and blocker codes, and validates them against the current Manifest and Checkpoints files.

## Final execution order

1. Validate source closure and generate canonical catalogs from a clean checkout.
2. Run the deterministic shared quality gate and focused hostile tests.
3. Build each selected child artifact independently; run install, launch and native authorization evidence on its real target.
4. Sign and publish that same digest through a protected environment, download it through the user channel, and repeat install/launch/update verification.
5. Run the selected-target reducer and final privacy scan immediately before publication evidence upload.
6. Only after all five platform terminals, external KT, trusted-server boundary and feature completeness exist, run the independent cryptographic audit and product-line proof machine.
