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
This repository is the open-source official client product layer. Encrypted
communication is a native Lico Arc capability and does not depend on a relay or
gateway server implementation; the custom encryption protocol authority is in
this repository. Gateway fabric and non-encryption protocol work belong in
`LicoLite/LicoLite` unless the task explicitly changes the official client.
