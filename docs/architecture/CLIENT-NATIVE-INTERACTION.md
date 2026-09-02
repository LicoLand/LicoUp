# Bridging Contract Layer — Client-Native Interaction Boundary

[Documentation](../README.md) · [Architecture](README.md) · [Architecture (zh-CN)](README.zh-CN.md)

This document defines the technical specification for **Tier 2: Bridging Contract / RPC Protocol Layer**, isolating **Tier 1: Flutter Presentation Layer** from **Tier 3: Rust Functional Core Layer**.

## Communication Contracts

1. **Desktop stdio RPC**:
   - Flutter reaches the persistent Rust native host through the `licoup.stdio.v1` bidirectional frame.
   - Stateful conversation operations (`conversation.message.post`, `conversation.dispatch.after-post`, `agent.conversation.send`, `attach`, `steer`, `cancel`) use explicit structured RPC methods with typed parameters and results.
   - Stateful operations **strictly never use a CLI argument array** as their client-to-native transport.
2. **Mobile Platform FFI**:
   - On Android and iOS, communication passes through C-ABI FFI command boundaries (`android_ffi.rs`, `ios_ffi.rs`), invoking Rust functional core services in-process without shell processes.
3. **Stateless Commands**:
   - The same RPC frame carries bounded stateless queries as `method: "execute"` with an argument array (e.g., catalog and target queries parsed via the public CLI command model).
   - One-shot execution exists only for injected executors and tests when the persistent host is unavailable; it is never the product transport for a stateful turn.
4. **Security & Secrets**:
   - Credential create and update requests rewrite private input onto stdin before process launch.
   - Secret values never enter command-line arguments, reports, or the public frame projection.

## Implementation Authorities

The implementation authorities for the Bridging Contract Layer are:
- **Client Native Transport**: `apps/desktop/lib/src/platform/native_client/`
- **Client Agent Services**: `apps/desktop/lib/src/backend/features/agents/services/`
- **Native Frame Router**: `crates/licoup-native/src/bin/licoup/stdio_rpc/`
- **Mobile FFI Bridges**: `crates/licoup-native/src/ffi/` (`android_ffi.rs`, `ios_ffi.rs`)
