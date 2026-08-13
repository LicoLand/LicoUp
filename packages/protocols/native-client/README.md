# Native Client Protocol Boundary

English (normative) · [简体中文](README.zh-CN.md)

This directory documents the client-internal adaptation boundary among the
LicoUp Flutter client, Rust native library, and local agents. “Stable” here
does not apply to the
[current retiring endpoint-protection Preview](../../../docs/STATUS.md).

## Implementation Entry Points

- `../../../crates/licoup-native/src/core/task_queue.rs`: bounded local task
  queue.
- `../../../crates/licoup-native/src/platform/runtime_adapters.rs`: native
  agent-session adapter registry.
- `../../../crates/licoup-native/src/core/mcp.rs`: service-neutral MCP
  JSON-RPC message adaptation.
- `../../../crates/licoup-native/src/core/secure_mesh_acp.rs`: ACP carriage
  over the current endpoint-protection Preview.

## Protocol Scope

- Concurrent discovery of local agents and their native configuration.
- Creation, continuation, and projection of conversations through the agent's
  official ACP, app-server, RPC, or CLI interface.
- Construction, validation, and encoding of one MCP request, notification, or
  response. Forwarding a response consumes one-time user approval bound to the
  exact request and destination.
- ACP command and result carriage inside the current endpoint-protection
  Preview messages.
- Platform bridges for macOS, Windows, Ubuntu, Android, and iOS implement only
  their platform responsibilities and do not duplicate product protocols.

## Boundary Principles

- Default capability binds no Meshrix address, token, discovery file, or
  background service.
- Optional collaboration registers only manual `collaboration` lifecycle
  commands. Default status checks do not load the plugin. A GitHub installation
  plan binds source and SHA-256 digest, and the plugin package contains no
  executable or instruction payload.
- CLI, Flutter, and mobile bridges reuse the same Rust protocol models instead
  of creating message variants.
- Stable wire-observable Pairwise Protection, Generic Message, Reliable
  Exchange, negotiation, and Transport Profile semantics belong to a pinned
  Lico Arc Protocol Line. The current retiring preview is not a Lico Arc
  Profile, has no future compatibility promise, and is to be retired directly
  when that line replaces it.
- LicoUp retains private keys, Provider configuration, plaintext, history,
  backups, user trust, approvals, and local effects.
- Local paths, configuration, conversations, and statistics stay in
  client-owned storage.
- Sending user information or files beyond the device requires direct
  approval bound to that operation's destination, purpose, and exact scope.
  Cancellation, a scope mismatch, or missing approval fails closed.
- Optional collaboration is a user-installed external plugin. It does not
  enter the default package or change these boundaries.
