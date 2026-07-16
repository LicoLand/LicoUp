# Native Client Agent Entry

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

## Scope

- Owns the Rust CLI under `crates/lico-client-native/`.
- Keep native CLI changes inside `crates/lico-client-native/` and directly related CLI smoke
  tests unless the task changes a server or GUI contract.

## First Reads

- Start with root `AGENTS.md`, then this file.
- Inspect `crates/lico-client-native/Cargo.toml` before adding dependencies or changing test
  targets.
- Use `crates/lico-client-native/src/lib.rs` as the module map, then open only the relevant
  module.
- Use `docs/ARCHITECTURE.md` only when the CLI boundary with the desktop client or
  runtime model is unclear.

## Directory Routing

- `src/bin/lico-client.rs`: public CLI entry and command dispatch.
- `src/domain/targets.rs` and `src/domain/targets/`: concurrent local-agent
  discovery, metadata, executable binding, and cache projection.
- `src/domain/conversations.rs`, `src/domain/conversation/`, and
  `src/domain/conversation_archive_jobs.rs`: native history and local backup jobs.
- `src/domain/skill_hub.rs` and `src/domain/agent_usage.rs`: local skill and usage
  management.
- `src/platform/client_state.rs` and `src/platform/paths.rs`: local state and path handling;
  keep operating-system and runtime integration in `src/platform/`.
- `src/core/task_queue.rs`: bounded lightweight Rust task queue.
- `src/core/mcp.rs`: service-neutral MCP envelope and response-forward adapter.
- `src/core/secure_mesh*`: Secure Client Mesh protocol and cryptographic behavior.
- `src/ffi/`: Android, iOS, and desktop bridge commands; keep feature rules in `src/domain/`
  or `src/core/` rather than duplicating them here.

## Verification

- Use `npm run client:native:test` for broad CLI tests from the repository
  root. It owns the canonical Cargo target lease and marks compiler output
  reclaimable when the test ends. Do not create per-agent Cargo target roots.
- Use `npm run client:regression -- --module <module-id>` for the smallest
  affected native slice, then `npm run client:verify:architecture` for changed
  module or platform boundaries.
- Use `npm run client:artifacts:status` to inspect lifecycle state and
  `npm run client:artifacts:prune -- --dry-run` before an explicit reclaim.
  These commands never manage dependency download caches.

## Context Budget

- Do not load `build/crates/lico-client-native/target/`.
- Avoid reading GUI code unless the CLI/GUI contract is the task.
