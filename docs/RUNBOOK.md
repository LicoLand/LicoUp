# Lico-Arc Development Runbook

## Scope

Lico-Arc contains the proprietary official LicoLite client product layer. Keep
gateway fabric, self-hosted deployment, protocol specs for third-party
integration, SDKs, and minimal debug/operator surfaces in `LicoLite/LicoLite`.

## Rules

- Client changes must be complete across source, tests, docs, packaging, and
  gates before they are treated as ready.
- Do not introduce legacy, fallback, compatibility, or parallel old client
  paths.
- Do not commit local machine paths, personal data, backend runtime data,
  tokens, credentials, or production endpoints.
- Engineering docs are written in English unless the file is explicitly a
  localized user-facing artifact.
- Flutter UI calls the native sidecar or documented HTTP protocol boundaries;
  it does not directly reach into server runtime state.

## Local Gate

Run the smallest focused command while developing, then run the full local merge
gate before a commit or PR:

```bash
npm run client:verify
```

The full gate includes:

| Scope | Command |
| --- | --- |
| Boundary hygiene | `npm run repo:client-boundary` |
| Dart format | `npm run client:format:check` |
| Rust format | `npm run client:native:fmt:check` |
| Rust clippy | `npm run client:native:clippy` |
| Dependency audit | `npm run client:deps:audit` |
| Flutter dependencies | `npm run client:get` |
| Flutter UI analysis | `npm run client:analyze` |
| Flutter UI tests | `npm run client:test` |
| Rust sidecar tests | `npm run client:native:test` |
| Native smoke | `npm run client:native:smoke` |
| Client contracts | `npm run client:contracts:test` |
| Client Architecture | `npm run client:verify:architecture` |
| Client Plan Gates | `npm run client:verify:plan` |
| Portable State Store | `npm run client:verify:state-store` |
| Target Adaptation | `npm run client:verify:targets` |
| Config Writes | `npm run client:verify:config-writes` |
| Skill Hub Pairing | `npm run client:verify:pairing-skill-cli` |
| Skill Installer | `npm run client:verify:skill-installer` |
| MCP Plugins | `npm run client:verify:mcp-plugins` |
| Thin Forwarding | `npm run client:verify:thin-forwarding` |
| Agent Usage Metering | `npm run client:verify:agent-usage` |
| Client Update Release | `npm run client:verify:update-release` |
| Windows file security | `npm run client:verify:windows-file-security` |
| Full Client | `npm run client:verify` |

If a platform-specific check cannot run locally, record the platform/toolchain
gap and the exact command that must be run later.

The initial Clippy gate denies Rust compiler warnings and keeps Clippy
correctness/suspicious checks active while allowing existing style, complexity,
and perf findings. Tighten that ratchet after the migration settles.

## Temporary Security Waivers

`client:deps:audit` has explicit temporary ignores for `RUSTSEC-2026-0124` and
`RUSTSEC-2026-0173`, both currently pulled through the OpenMLS provider chain.
Do not add broad audit ignores. Remove these waivers when the OpenMLS/HPKE stack
ships a compatible release that no longer resolves the affected crates.
