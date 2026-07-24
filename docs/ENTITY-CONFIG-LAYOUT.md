# Entity Configuration Layout

[Documentation](README.md)

This document maps configuration responsibilities to their canonical repository
owners. It does not record deployment values, workstation paths, credentials,
private addresses, or runtime data.

| Entity | Canonical authority | Projection or consumer |
| --- | --- | --- |
| Product version | `tools/client-version.json` and synchronized package manifests | `package.json`, Cargo and Flutter package metadata |
| Release targets | `tools/client-release-targets.json` | packaging and release verification tools |
| Platform capability status | `tools/client-support-matrix.json` | generated `COMPATIBILITY.md` and `COMPATIBILITY.zh-CN.md` |
| Desktop package composition | `apps/desktop/packaging.modules.json` | platform packagers and architecture checks |
| Agent conversation drivers | `crates/licoup-native/resources/agent-conversation-drivers.json` | generated compatibility adapter table and desktop projections |
| Agent readiness | `crates/licoup-native/resources/agent-conversation-readiness.json` and its reducer | composer availability and verification summaries |
| Public client DTOs | JSON Schemas under `packages/contracts/client/` | generated or validated Rust, Flutter, fixture, and protocol consumers |
| Native client protocol DTOs | schemas under `packages/protocols/native-client/` | Rust/Flutter/mobile bridge consumers |
| Secure Client Mesh verification policy | reviewed JSON definitions under `tools/scripts/config/` plus native protocol code | bounded verification and redacted report schemas |
| Appearance presets | `apps/desktop/assets/appearance-presets/` and the Flutter appearance contract | desktop theme projections |
| Local persisted state roots | `crates/licoup-native/src/platform/paths.rs` and `client_state.rs` | platform-specific resolved locations at runtime |

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
