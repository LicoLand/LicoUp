# Entity Configuration Layout

[Documentation](README.md)

This document maps configuration responsibilities to their canonical repository
owners. It does not record deployment values, workstation paths, credentials,
private addresses, or runtime data. The `crates/` and `tests/product-e2e/` paths
below live in the LicoUp-CLI repository, which owns the Rust workspace.

| Entity | Canonical authority | Projection or consumer |
| --- | --- | --- |
| Product version | `tools/client-version.json` and synchronized package manifests | `package.json`, Cargo and Flutter package metadata |
| Release targets | `tools/client-release-targets.json` | packaging and release verification tools |
| Platform capability status | `tools/client-support-matrix.json` | generated `COMPATIBILITY.md` and `COMPATIBILITY.zh-CN.md` |
| Desktop package composition | `apps/desktop/packaging.modules.json` | platform packagers and architecture checks |
| Agent conversation drivers | `crates/licoup/resources/agent-conversation-drivers.json` (LicoUp-CLI) | generated compatibility adapter table and desktop projections |
| Agent readiness | `crates/licoup/resources/agent-conversation-readiness.json` (LicoUp-CLI) and its reducer | composer availability and verification summaries |
| Subagent MCP direct-verification evidence | `tests/product-e2e/cli/subagent-mcp/interop-manifest.yaml` (LicoUp-CLI), atomically written by the explicit live downstream route | latest App Version, one privacy-safe record per target Agent |
| Public client DTOs | JSON Schemas under `packages/contracts/client/` | generated or validated Rust, Flutter, fixture, and protocol consumers |
| Native client protocol DTOs | schemas under `packages/protocols/native-client/` | Rust/Flutter/mobile bridge consumers |
| [Retiring endpoint-protection Preview verification policy](STATUS.md) | reviewed JSON definitions under `tools/scripts/config/` plus current native implementation code | bounded verification and redacted report schemas for the current preview only; Lico Arc remains the authority for stable endpoint wire profiles |
| Appearance presets | `apps/desktop/assets/appearance-presets/` and the Flutter appearance contract | desktop theme projections |
| Local persisted state roots | `crates/licoup-foundation/src/platform/paths.rs` and `crates/licoup/src/platform/client_state/` (both LicoUp-CLI) | platform-specific resolved locations at runtime |

## Generated projections

`docs/COMPATIBILITY.md` and `docs/COMPATIBILITY.zh-CN.md` are generated from the
version, release-target, support, and native driver catalogs:

```bash
npm run client:support-matrix:sync
npm run client:support-matrix:check
```

Do not edit those files by hand.

## Runtime values

Runtime configuration belongs to the client-owned platform state selected by
the path and state implementations above. Documentation and examples use
placeholders only. No real endpoint, identity, secret, local path, history,
diagnostic record, or user data belongs in Git or a release artifact.
