# Shared Client Substrate

## Metadata / 元数据

- Last updated: 2026-07-15
- Status: Current shared scenario contract
- Scope: Rust queue, ACP/MCP adaptation, platform ports, local state, direct approval, and Secure Client Mesh.
- Staleness check: Reconciled with `PRODUCT.md` and the canonical product-scope plan on 2026-07-15.

## Substrate

| Boundary | Shared contract |
| --- | --- |
| Local task queue | Rust-owned fixed-capacity FIFO admission, cloneable producers, one exclusive consumer, blocking backpressure, non-blocking ownership-preserving rejection, bounded depth accounting, and fail-closed disconnect. Scheduling policy and task history stay outside the primitive. |
| ACP | Bounded framing, capability mapping, request/session correlation, ordered events, cancellation, and encrypted relay payload integration. |
| MCP | Bounded JSON-RPC/MCP validation, strict request-ID preservation, sanitized errors, and short-lived one-shot direction/destination/purpose/digest approval for every outbound request or forwarded response. |
| Platform | macOS, Windows, Ubuntu, Android, and iOS implement discovery, paths, process launch, authorization, secure storage, and packaging behind neutral ports. |
| Local state | Atomic current-product state stores only the minimum required cache, configuration, aggregate statistics, and redacted receipts. |
| Trust and encryption | Secure Client Mesh owns authenticated endpoints, pairwise/group keys, replay protection, revocation, opaque envelopes, and ACK lifecycle. |
| Conversation targeting | A detected adapter may expose a read-only index, but it may enable sending only after the native-conversation parity reducer marks it `ready`. |
| External effects | Every external transfer of local data is directly approved once for an exact destination, purpose, scope, and digest and remains cancellable until commit. |

## Lifecycle Rules

- Startup work is local, bounded, cancellable, and cannot open an authorization
  prompt or imply consent to an external effect.
- Shared controllers expose typed state; they do not own feature data or duplicate
  feature lifecycle state.
- A target/config revision is pinned for one operation. Revision drift cancels or
  fails the operation rather than changing behavior mid-flight.
- Queue records, logs, diagnostics, and evidence exclude raw content, credentials,
  local paths, native identifiers, device facts, and ciphertext.
- A changed destination, scope, content digest, trust state, or target revision
  invalidates approval and fails closed.

## Acceptance

Each scenario runs its feature module regression plus only the shared modules it
actually touches. Queue, ACP, MCP, platform, approval, and encryption negative
tests must be independently selectable. The complete client regression runs once
after all targeted closures pass.
