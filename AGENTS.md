# LicoArc Agent Instructions

<!-- lico-dev:shared-rules:start -->
## Shared rules

- **parallel-work** — Delegate independent, bounded work to subagents when parallel execution materially improves speed or quality. Prefer fast models for simple text or code work and deep models for complex work; record any fallback when the requested class is unavailable.
- **privacy** — Never disclose machine identity, personal data, secrets, ciphertext, protected backend data, raw runtime data, or sensitive command output. Emit only redacted, minimum-necessary evidence.
- **public-release-boundary** — Keep development, ordinary verification, packaging, GitHub Release, and every platform store or channel as separate claims. Missing publisher accounts, store credentials, signing or notarization identities, listings, or channel access are non-blocking guidance outside an explicitly requested release to that specific store or channel. Public release metadata is limited to artifact name, version, platform, byte size, cryptographic digest, detached signature, verification algorithm or key identifier, only the public verification key or certificate-chain fields required to validate that signature, and cryptographically bound provenance or attestation when it is itself part of verification. Omit publisher, account, team, tenant, device, profile, credential, private-channel, and internal release metadata.
- **complete-migration** — Complete refactors and migrations in one pass. Remove superseded implementations, names, paths, compatibility layers, tests, and documentation unless the user explicitly requires coexistence.
- **retired-state-reset** — Persistent user state owned by a retired product name is reset, not migrated. The current product must initialize fresh current-name state and must never discover, import, rename, copy, translate, or prompt for a retired-name data root or preference namespace; do not preserve legacy-state fixtures or compatibility gates.
- **algorithm-quality** — For algorithmic or data-structure work, compare relevant primary or open-source implementations, choose appropriate structures and caching, avoid repeated computation, and optimize scheduling, memory, and concurrency.
- **retired-artifacts** — Removed code and documentation must not remain as permanent tests, fixtures, compatibility checks, or release gates.
<!-- lico-dev:shared-rules:end -->

<!-- lico-dev:repository-scope:start -->
## Repository scope

- Own desktop and mobile client behavior, client configuration, native bridges, client-facing UI, and the Lico Arc custom end-to-end encryption protocol (Secure Client Mesh).
- Encrypted communication is a native Lico Arc capability and does not depend on a relay or gateway server implementation; keep server policy, authorization, gateway fabric, and non-encryption protocol authority in the core repository.
- Keep public client documentation small, plain, and bilingual with English as the default entry. Use clear diagrams for complex flows, treat README.md as the public product page, express diversity, connection, openness, and integration, and omit commercial framing.
- Formal project documentation records only implemented capabilities and the design rationale for those capabilities. Maintain requirements, proposals, unfinished designs, implementation checkpoints, progress, and blockers with the better-plan skill in the local ignored Better Plan workspace, and never publish those process artifacts.
- Limit privacy claims to client-controlled behavior: do not upload sensitive runtime data or plaintext user content; encrypt approved peer content before egress; state what the client sends rather than what a relay receives; treat relays as untrusted; and never promise relay storage, retention, or operating behavior.
- Keep a small mandatory and reviewed Secure Client Mesh wire profile. Select verified platform security providers by role through opaque key handles; never treat algorithm count as a security level, and never accept executable crypto code from a relay, service, message, script, or ordinary plugin.
- Require direct user approval and platform-native authentication before trusting, installing, enabling, or updating a local security provider or using a protected long-term key. Do not expose an unauthenticated local key-operation API.
- Keep detailed platform and custody facts on the client and expose only the minimum reviewed protocol profile needed by a peer. A new algorithm, public-key format, or combination rule requires a downgrade-safe protocol change activated only for new sessions or re-pairing.
- Keep plans, drafts, temporary scripts, local-only skills, raw runtime evidence, and unsanitized fixtures outside the public file set; public tests must use synthetic, redacted data.
- Keep development, ordinary client verification, packaging, and GitHub Release independent from platform-store identity, credentials, signing, notarization, listing, and channel access; expose only the canonical consumer-verification manifest.
- Use `lico-dev workflow plan client` before selecting validation tasks.
<!-- lico-dev:repository-scope:end -->

## Client Delivery Rules

1. For all client development work, rebuild the client and open it after the
   deployment or deliverable changes are complete. Report any build or launch
   failure before handoff.
2. After Android client code changes, start an independent verification
   subagent to run the build flow and, when an authorized phone is connected,
   push/install the freshly built client onto the device. Report build, device
   discovery, authorization, install, or launch failures before handoff.
3. When key or credential storage is involved, the client must request user permission and invoke platform-native biometrics (Face ID, Touch ID, Passkey) or secure key tools. Authentication should be unified in a single flow, authorizing all associated capabilities at once to minimize manual password entry prompts.
4. **回归测试** — 涉及回归测试，应尽可能采取较快闭环的路线，减少回归测试的范围。完整的回归测试必须在所有的改动确认有效之后才可以执行，严禁项目过程中多次执行全量回归，导致影响其它智能体的并行开发工作。
5. Build-producing tests must use the repository artifact lifecycle. Share the
   canonical managed target instead of creating per-agent Cargo target
   directories. A test holds a lease while running and marks its compiler
   output reclaimable on every terminal path. `client:artifacts:prune` may
   remove only marked, inactive compiler output; it must never remove Cargo,
   Pub, Gradle, SDK, or toolchain download caches.
This repository is the open-source official client product layer. Encrypted
communication is a native Lico Arc capability and does not depend on a relay or
gateway server implementation; the custom encryption protocol authority is in
this repository. Gateway fabric and non-encryption protocol work belong in
`LicoLite/LicoLite` unless the task explicitly changes the official client.
