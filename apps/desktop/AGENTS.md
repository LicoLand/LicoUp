# Desktop Client Agent Entry

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

- Owns the Flutter desktop client under `apps/desktop/`.
- Keep GUI changes inside `apps/desktop/` unless the task explicitly changes the
  Rust CLI, server API, packaging, or shared docs contract.

## First Reads

- Start with root `AGENTS.md`, then this file.
- Read `README.md` for local setup and `docs/ARCHITECTURE.md` for the product
  boundary.
- Inspect `apps/desktop/pubspec.yaml` before changing dependencies.
- Use `apps/desktop/lib/main.dart` and `apps/desktop/lib/app.dart` to enter the app
  tree, then open only the relevant feature files.

## Directory Routing

- `lib/`: Flutter application code.
- `test/`: widget, service, state, and contract tests.
- `scripts/`: packaging and client architecture verifiers.
- Platform folders (`macos/`, `windows/`, `linux/`, `android/`, `ios/`) are only
  for native shell, packaging, or platform-specific behavior.

## Verification

- Use `npm run client:analyze` for Flutter static analysis.
- Use `npm run client:regression -- --module <module-id>` for the smallest
  affected Flutter slice.
- Use `npm run client:test` once after targeted checks when a complete Flutter
  regression is required.
- Use `npm run client:test:coverage` when LCOV output is needed; the report is
  written to `build/coverage/apps/desktop/lcov.info`.
- Use `npm run client:verify:architecture` when architecture rules or module
  boundaries change.

## Context Budget

- Do not load `build/apps/desktop/`, `apps/desktop/build/`, `.dart_tool/`, coverage
  output, or generated platform artifacts.
- Avoid reading CLI code unless the GUI task depends on a native CLI contract.
