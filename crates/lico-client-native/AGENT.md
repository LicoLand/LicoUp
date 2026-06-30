# Native Client Agent Entry

## Scope

- Owns the Rust CLI under `crates/lico-client-native/`.
- Keep native CLI changes inside `crates/lico-client-native/` and directly related CLI smoke
  tests unless the task changes a server or GUI contract.

## First Reads

- Start with root `AGENT.md`, then this file.
- Inspect `crates/lico-client-native/Cargo.toml` before adding dependencies or changing test
  targets.
- Use `crates/lico-client-native/src/lib.rs` as the module map, then open only the relevant
  module.
- Use `docs/functionality/CLIENT-DESKTOP.md` only when the CLI boundary with the desktop
  client or runtime model is unclear.

## Directory Routing

- `src/targets.rs`: target discovery and target metadata.
- `src/forwarding.rs`: forwarding behavior.
- `src/client_state.rs` and `src/paths.rs`: local state
  and path handling.
- `src/mcp_plugins.rs` and `src/mcp_trust.rs`: MCP plugin
  integration and trust handling.
- `src/checkpoints.rs`: checkpoint-facing CLI behavior.

## Verification

- Use `CARGO_TARGET_DIR=build/crates/lico-client-native/target cargo test --manifest-path crates/lico-client-native/Cargo.toml`
  for broad CLI tests from the repository root.
- Prefer targeted package scripts such as `npm run client:verify:targets` or
  `npm run client:verify:config-writes` when the task maps to one behavior.

## Context Budget

- Do not load `build/crates/lico-client-native/target/`.
- Avoid reading GUI code unless the CLI/GUI contract is the task.
