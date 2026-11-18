# Native Client Protocol Boundary

Updated: 2026-09-30

English (normative) · [简体中文](README.zh-CN.md)

This directory documents the client-internal adaptation boundary among the
LicoUp Flutter client, Rust native library, and local agents. “Stable” here
does not apply to retired protocol previews; see
[docs/STATUS.md](../../../docs/STATUS.md).

## Implementation Entry Points

The Rust workspace lives in the LicoUp-CLI repository, which owns these
implementation entry points:

- `crates/licoup-foundation/src/core/task_queue.rs` (LicoUp-CLI): bounded
  local task queue.
- `crates/licoup/src/platform/runtime_adapters.rs` (LicoUp-CLI):
  native agent-session adapter registry.
- `crates/licoup/src/core/mcp.rs` (LicoUp-CLI): service-neutral MCP
  JSON-RPC message adaptation.

## Protocol Scope

- Concurrent discovery of local agents and their native configuration.
- Creation, continuation, and projection of conversations through the agent's
  official ACP, app-server, RPC, or CLI interface.
- Construction, validation, and encoding of one MCP request, notification, or
  response. Forwarding a response consumes one-time user approval bound to the
  exact request and destination.
- Platform bridges for macOS, Windows, and Ubuntu implement only their
  platform responsibilities and do not duplicate product protocols.

## Boundary Principles

- CLI and Flutter reuse the same Rust protocol models instead of creating
  message variants.
- Stable wire-observable Pairwise Protection, Generic Message, Reliable
  Exchange, negotiation, and Transport Profile semantics belong to a pinned
  Lico Arc Protocol Line. The retired endpoint-protection preview was not a
  Lico Arc Profile and carries no compatibility promise.
- LicoUp retains private keys, Provider configuration, plaintext, history,
  backups, user trust, approvals, and local effects.
- Local paths, configuration, conversations, and statistics stay in
  client-owned storage.
- Sending user information or files beyond the device requires direct
  approval bound to that operation's destination, purpose, and exact scope.
  Cancellation, a scope mismatch, or missing approval fails closed.
