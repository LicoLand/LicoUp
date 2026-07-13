# LicoArc End-to-End Release Requirements

## Delivery contract

This plan replaces every previous active plan in `docs/plan`. It is rebuilt from the current working tree, fresh command results, current product source, and primary protocol or platform references. Historical status, generated readiness reports, evidence receipts, and progress summaries are not proof.

The plan emits two independent decisions:

1. **Selected-target release readiness** — a requested subset may publish only when each selected target's exact artifact, support state, custody, install, launch, security, privacy, publication, and update receipts pass. An unselected or explicitly unsupported target does not block that train.
2. **Product-line security claim readiness** — any Telegram Secret Chat-level wording additionally requires Android, iOS, macOS, Windows, and Linux protocol evidence, the shared Secure Mesh reducer, and an independent cryptographic audit after feature completeness.

These decisions must never be collapsed into one boolean.

For the current mobile implementation closure, Android and iOS additionally expose a local
simulator-build verdict. It proves the exact source can build, install and launch on the
repository-selected Android Emulator and iOS Simulator and that native bridges plus simulated
authorization paths execute. It never proves physical-device key custody, hardware-backed
encryption, real biometrics, production signing or distribution; those inputs remain blocked
until their real authorities run.

## Users and workflows

- A user installs LicoArc, discovers installed agents, opens or resumes an exact native conversation, sends and cancels work, reads a semantic archive, and sees truthful readiness or blocked reasons.
- A user posts work to one or more agents through Feed and receives durable per-target success, partial-failure, retry, and attachment outcomes.
- A user manages multiple provider accounts without exposing credentials, pairs devices, verifies peer identity, and sends protected command, result, file, group, and ACP payloads through an opaque relay.
- A release operator selects one or more supported targets, builds from a clean source snapshot, signs and publishes the exact artifacts, downloads them through the public channel, installs and launches them, then verifies digest-bound receipts without disclosing machine or account data.

## Shared release requirements

### REQ-REL-001 — Reproducible source closure

Every workflow, script, configuration, schema, asset, lockfile, generated contract, and source file required by a release must be tracked and present in a clean checkout. Toolchains and dependency resolution must be pinned by current source. The source digest, build invocation, target, module profile, artifact digest, receipt producer, and publication record form one immutable lineage.

### REQ-REL-002 — One deterministic quality gate

Local verification, CI, and release jobs must call the same fail-closed gate. Dart and Rust formatting, Flutter analysis and tests, native tests, Clippy with warnings denied, dependency audit, architecture and boundary checks, plan validation, generated-artifact consistency, packaging self-tests, and privacy checks must pass. Tests must use isolated temporary state and must not read or mutate a real client cache, account store, or device identity.

### REQ-REL-003 — One current architecture and complete migration

Implementation, tests, verifiers, docs, registries, and workflows must converge on the only current module and contract structure. Retired shell mappings, DTOs, envelope formats, provider-keyed records, route resolvers, artifact aliases, compatibility fallbacks, and text-match gates are removed after their replacement is established. A verifier must check behavior or the complete owning source unit, not demand obsolete tokens in one file.

### REQ-REL-004 — Truthful scope and target authority

The target catalog, support matrix, build authority, release reducer, and UI must distinguish supported, preview, deferred, unsupported, and unverified capabilities. Release-blocking services must be `supported` on every selected target. Empty, duplicate, unknown, unsupported, wrong-host, wrong-architecture, or wrong-artifact target selections fail closed. Optional external services and deferred voice input do not become release blockers or supported claims.

### REQ-REL-005 — Exact artifact and real publication

`releaseReady` is true only for the exact artifact that passed build, architecture, signing, custody, installation, launch, runtime, publication, download, and receipt verification. Local ad-hoc or validation-signed artifacts may prove development closure but cannot imply production identity, notarization, store publication, update continuity, or rollback. Publication uses protected environments and verifiable provenance; transient CI artifact upload alone is not publication.

### REQ-REL-006 — Privacy-safe runtime and evidence

Production defaults do not persist account, pairing, credential-presence, conversation, device, path, or runtime diagnostics without explicit user consent and a bounded retention policy. Tests and producers emit structured allowlisted fields, bounded sanitized errors, and digest references. The last producer is followed by a final privacy scan immediately before upload. Reports contain no raw payloads, keys, ciphertext, device identifiers, personal paths, process arguments, or backend runtime data.

## Product and agent requirements

### REQ-PROD-001 — Current shell and UI contract

The current shell, navigation, search, usage panels, settings, accessibility semantics, localization, tests, and architecture checks agree on one product structure. Usage reduction consumes every supported summary source without inventing empty state. Target scanning is incremental, deterministic, cache-isolated in tests, and cannot promote stale observations. Golden updates require an intentional product-contract review.

### REQ-PROD-002 — Atomic Feed dispatch

Feed fan-out uses a durable key per `(dispatch id, target id)`, not one completion bit for all targets. Each addressed target has an explicit pending, running, succeeded, failed, or retryable outcome; aggregate post state is derived from those outcomes. Retries are idempotent, selection and session state are not shared mutable routing authority, and partial failure remains visible. Attachments use a bounded typed content contract with explicit size, file-type, encoding, privacy, and per-target transfer behavior rather than unbounded synchronous file reads or filename-only substitution.

### REQ-PROD-003 — Semantic conversation and archive

One read-only semantic model separates thread, execution, artifacts, audit, and raw layers across native adapters, streaming events, archive materialization, and Flutter rendering. Default views expose human dialogue and safe artifact references; execution is explicit and collapsible; audit and raw evidence require an explicit diagnostic action. No parallel flattened renderer or provider-specific UI model remains. Raw source identity is retained internally by relative reference and digest, never by a default personal path.

### REQ-PROD-004 — Mobile provider accounts and relay configuration

Flutter, native bridges, relay metadata, and chat dispatch share an account model whose account id is independent of provider id. Portable metadata is secret-free; credentials and OAuth attempts use the selected native custody backend; message, history, deletion, callback, relay echo, and assistant grants are account-scoped. Credential sync is explicit. Deferred providers remain fail-closed. Custom gateway values are parsed before persistence, require a valid HTTPS authority or exact loopback HTTP, and reject userinfo, fragments, deceptive hosts, malformed ports, and incomplete URLs.

### REQ-AGENT-001 — Canonical dispatch and readiness

Direct, routed, and relay-backed conversation flows consume one dispatch interface for open, resume, send, stream, cancel, capability discovery, and cleanup. Static driver declarations, runtime capability probes, and source-bound evidence are separate authorities joined by a fail-closed reducer. `partial`, stale, missing, or blocked evidence never enables sending. The transport runner is injected behind the backend adapter instead of leaking through domain calls.

Operators and clients must be able to list native history (`conversations list|stream`) for a packaged agent, select an exact `nativeSessionId` for a finished or interrupted session, and—when that adapter is `sendEnabled`—continue it with `agent conversation send` carrying that same id. Selection never falls back to “newest session.” Mid-run message injection and in-flight steer (CL-06 C-05) remain out of scope for the current one-shot dispatch model; routing still applies only at message boundaries.

### REQ-AGENT-002 — Per-adapter native parity

Every packaged adapter must either prove fresh bidirectional send and receive, exact native session resume, streaming equivalence, cancellation, permission failure, cleanup, history readback, privacy, and error handling through an official local lane, or be excluded honestly from supported packaging. Fixture-only reducer success proves reducer behavior, not adapter parity. UI and the support matrix disclose the exact state and actionable reason per adapter.

Client release is evaluated over the supported adapter subset, not over completion of the full
packaged inventory. Blocked, failed, history-only and unverified adapters may remain installed for
truthful discovery or read-only history, but they never enable send or count as supported. If the
supported subset is empty, the client disables all agent-send entry points and publishes no
agent-conversation support claim; that empty subset does not independently block unrelated client
packaging or release capabilities.

Exact-resume send is required for any adapter that claims conversation support: history may be readable while send stays disabled, but an adapter that cannot resume a selected native session on an official lane must not claim exact-resume capability. Structural blockers (for example Claude Code argv-bound resume, Antigravity missing public transport, or mid-run inject) are recorded as blocked plan leaves with actionable codes until an official unblock exists.

### REQ-ROUTE-001 — Explainable routing and handoff

One validated declarative policy supplies operator intent, roles, priorities, allowance thresholds, and distillation directives; runtime capabilities remain a non-overridable execution constraint. Policy reload is atomic and applies only at message boundaries. One deterministic engine emits selected and rejected candidates with reasons. Cross-agent handoff preserves goals, decisions, and constraints and is validated against fixture ground truth, not merely non-empty fields. Route history stores logical handles or digests, not private native session ids or raw conversation text.

### REQ-ROUTE-002 — Optional routing package

The canonical module catalog defines validated included and excluded release profiles without changing source between builds. An excluded artifact starts and supports direct dispatch while routing code, registration, UI, settings, watchers, caches, and artifact entries are absent. Runtime disable stops owned resources and clears owned state without deleting user policy absent consent. Five bounded same-profile measurements must show median routing cold-start overhead at most 50 ms and median RSS delta at most 8 MiB.

## Security requirements

### REQ-SEC-001 — Native secrets and one user authorization

Secrets never enter process arguments, generic untrusted bridge payloads, logs, reports, or error text. Platform stores persist only opaque handles or platform-protected records. Every credential or key operation that requires authority uses one OS-owned Face ID, Touch ID, BiometricPrompt, passkey, device-credential, or secure-key context for the whole user-initiated workflow; background work never prompts. Unavailable user-presence protection fails closed or uses explicit memory-only custody, never a silent ordinary-store fallback. Remote credential export is a sensitive operation requiring local user confirmation bound to the exact request.

### REQ-SEC-002 — Bounded filesystem and archive safety

Archive extraction is Rust-native, streamed or strictly bounded, rejects absolute paths, traversal, links, devices and special entries, and prevents escape through pre-existing destination symlinks. Entry count, depth, compressed and expanded bytes, per-file bytes, and deadlines are bounded. Copying, hardening, export, and install operations use no-follow metadata, containment, owner checks, journaling, and crash-consistent atomic replacement. Tests construct hostile archives without panicking before the extractor is exercised.

### REQ-E2EE-001 — Canonical opaque envelope and endpoint confidentiality

Command, result, file, service-action, group, and ACP plaintext and content keys are available only to participating endpoints. Pairwise and MLS use one canonical serialized opaque envelope and one serializer/deserializer pair. Schema validation, sealing, opening, routing, and receipts agree on the same fields. Wrong recipient, tamper, malformed, stale, duplicate, expired, and replayed envelopes fail closed.

### REQ-E2EE-002 — Identity, directory, and verify-before-send

Sessions bind authenticated endpoint identities and typed Key Transparency authorization. Pairing, prekey lookup, key change, revoke, and MLS membership require fresh pinned-log evidence with inclusion or non-inclusion, append consistency, persisted checkpoints, monitoring, and gossip or witness anti-equivocation. QR, fingerprint, or 60-digit safety-number observation becomes authority only after a locally signed trust record. Unverified, changed, or revoked peers cannot send or receive protected work.

### REQ-E2EE-003 — Ratchet, replay, lifecycle, and file semantics

Pairwise setup and Double Ratchet state live in the shared Rust core, persist restart-safe monotonic state, consume prekeys once, delete old message keys, bound skipped-key and replay ledgers, and reject clock rollback. AAD binds protocol, endpoints, envelope and message identity, payload kind, expiry, and encrypted routing context. Command, result, file, TTL, delete, screenshot, resend, acknowledgement, confirmation, and endpoint-specific reseal flows preserve the same state machine.

### REQ-E2EE-004 — MLS groups and Key Transparency

MLS follows the current shared Rust implementation of RFC 9420 semantics: authenticated credentials and invitations, exact group, inviter, roster, sender and commit authorization, one-time KeyPackage consumption, removed-member exclusion, and epoch forward secrecy. Product availability comes from current evidence, not constants. The client never owns the production transparency-log signing key or treats a self-derived hash or unsigned chain as directory authority.

### REQ-E2EE-005 — Adaptive custody capability graph

One acyclic capability graph defines mandatory protocol capabilities and optional device hardening. Enabled capabilities are the deterministic O(V+E) dependency closure of measured facts; exact available, enabled, unavailable, and unverified sets are reported without overclaim. Software-backed safe stores are valid when the product contract permits them; additional device-only, user-presence, biometric, enrollment, hardware, TEE, StrongBox, Secure Enclave, or Secret Service properties add only their own proven claims. No safe persistent store means memory-only secrets and explicit re-pair or rekey after restart.

### REQ-E2EE-006 — ACP protected operations and archives

Prompt, update, reasoning, tool, filesystem, terminal, permission, approval, artifact, callback, retry, and archive payload classes are explicitly classified. Protected classes are encrypted and AAD-bound to endpoint, session, turn, sequence, operation, child operation, tool call, permission request, artifact, idempotency key, policy revision, grant, and expiry as applicable. Side effects authorize exactly the encrypted payload digest; denial, cancel, close, and expiry forget sensitive references. Reasoning is absent unless requested and policy-allowed, and then remains protected content.

### REQ-E2EE-007 — Metadata resistance and hostile-relay proof

Production envelopes use bounded padding, encrypted headers, rotating direction-specific opaque mailbox identifiers, and no clear stable endpoint, session, message, file, payload-class, or ACP identifiers beyond the documented transport residual. Hostile-relay capture and redaction scans prove raw and encoded canaries, keys, paths, tokens, payloads, and backend data are absent for every connected payload family. Timing, direction, bucket size, retry volume, and explicitly residual metadata are measured and reported without overclaim.

### REQ-E2EE-008 — Claim reduction and independent audit

The classical security claim is reduced by an independent protocol-proof state machine that binds all requirements and current source evidence. Post-quantum setup or ratchet claims remain separate. After feature completeness, an independent cryptographic audit is mandatory before the product-line claim. A narrower selected-target client release cannot promote the broader claim.

### REQ-REL-007 — Final aggregation

Final validation consumes the same requirements defined here, every non-skipped implementation Node, all five child-plan final decisions, selected-target artifact receipts, the privacy scan, and the independent-audit status. It emits separate selected-target release and product-line claim results with explicit blocker codes. No skipped required check, stale report, missing child receipt, untracked dependency, projection, or prose-only evidence can become a pass.

## Scope and non-goals

In scope: client-owned desktop and mobile behavior, native bridges, local custody, semantic conversations, agent dispatch, routing, accounts, Secure Mesh protocol integration, packaging, release workflows, selected-target publication, and the client contribution to the product-line security claim.

Out of scope: server policy or authorization authority, optional provider integrations that remain deferred, post-quantum claim wording, collecting app-specific passwords, preserving retired implementations, and treating local authentication, static inspection, mocks, or transient CI uploads as sufficient release proof.

## Platform split

The parent contract is platform-neutral. macOS, Android, Linux, iOS, and Windows each own a child plan because toolchains, native stores, artifacts, signing, distribution, and physical acceptance differ. Better Plan currently has no Android or iOS `platform` enum, so those child Nodes use `any` and state the required mobile target explicitly; they are not desktop-neutral work.

## Consolidation coverage

The previous plan labels are not active authorities, but their product semantics are mapped here so that deleting the old directories cannot delete a requirement silently:

| Consolidated source semantics | Current authority |
| --- | --- |
| Secure Mesh `REQ-E2EE-001..004`, `009..011`, `013`, `014`, `018`, `019`, `021` | REQ-E2EE-001..003 and REQ-E2EE-007 |
| Secure Mesh `REQ-E2EE-005`, `006`, `008`, `020` | REQ-E2EE-004, REQ-E2EE-005 and the external-KT/audit gates in REQ-E2EE-008 |
| Secure Mesh `REQ-E2EE-007`, `012`, `022` and platform custody requirements | REQ-SEC-001, REQ-E2EE-005 and each child plan's native-custody requirement |
| Former Secure Mesh E2EE labels 015–017 and ACP/lifecycle classifications | REQ-E2EE-003 and REQ-E2EE-006 |
| Former adaptive-hardening labels 001–015 | REQ-E2EE-004, REQ-E2EE-005, REQ-E2EE-007, REQ-E2EE-008, REQ-REL-004..007 and platform child finals |
| Semantic archive plan | REQ-PROD-003, REQ-SEC-002 and REQ-E2EE-006 |
| Mobile provider account plan | REQ-PROD-004, REQ-SEC-001 and REQ-REL-006 |
| Agent conversation dispatch plan | REQ-AGENT-001, REQ-AGENT-002 and REQ-PROD-003 |
| Multi-agent routing and packaging plans | REQ-ROUTE-001, REQ-ROUTE-002 and REQ-REL-001..005 |
| Fresh blocker and platform closure plans | REQ-REL-001..007, REQ-PROD-001..004, REQ-SEC-001..002 and child requirements |

The formerly external shared requirement 006 for trusted-server and directory authority is now an explicit input of REQ-E2EE-002, REQ-E2EE-004, and REQ-E2EE-008. Client completion cannot manufacture that server-owned evidence; absence blocks the broad claim while leaving an otherwise valid narrower selected-target release independently decidable.
