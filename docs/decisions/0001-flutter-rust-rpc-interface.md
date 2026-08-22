# Decision 0001: Flutter-Rust interaction uses RPC, not CLI tool invocation

- `context` — Flutter drives the native Rust host through the
  `licoup.stdio.v1` frame protocol, but the frame carries two semantics:
  structured methods (for example `agent.conversation.send`,
  `state.get/set`) and plain CLI argument arrays (`method: "execute"`,
  `args: [...]`) that the native side re-parses through the CLI parser
  (`crates/licoup-native/src/bin/licoup/stdio_rpc/server.rs:481`). One-shot
  mode additionally starts a fresh CLI process per request. See
  [Issue 0001](../issues/0001-non-rpc-client-server-interaction.md).
- `decision` — Flutter and Rust interaction uses method-level RPC: each call
  is an explicit method name with typed JSON params (and typed JSON result),
  routed to a dedicated native handler. New client-to-native interaction must
  be added as a structured RPC method. CLI argument arrays are not used as a
  transport for client-to-native calls. The CLI surface remains for human and
  scripted use; the one-shot CLI path remains only as a fallback when a
  persistent host or a structured method is unavailable (for example injected
  test executors).
- `rationale` —
  - A single explicit method surface removes native re-parsing of CLI
    semantics and makes the boundary auditable.
  - Structured methods can carry the persistent turn state needed by
    conversation control, which an argument array or one-shot process cannot.
  - Dispatch-type conversation operations are already fail-closed: CLI-shaped
    `agent conversation send` frames are rejected on the persistent host
    (`crates/licoup-native/src/bin/licoup/stdio_rpc/server.rs:446-461`), so
    the RPC direction is already the enforced path for the stateful surface.
- `alternatives` —
  - Keep the CLI-array `execute` transport for all commands: rejected because
    it couples the protocol to CLI parsing and cannot represent long-running
    attachable turns.
  - One-shot CLI subprocess for everything: rejected because turn state,
    credentials context, and the SQLite/WAL pool would be lost per request.
  - Replace the stdio frames with an external HTTP/gRPC transport: not chosen
    for this decision; the stdio frame protocol already provides method
    routing and process-local boundaries.
- `consequences` —
  - Non-RPC interaction points listed in Issue 0001 are migrated to
    structured methods as they are implemented; the issue inventory is the
    tracking list.
  - The CLI surface stays intact for humans and scripts and is not a client
    transport.
  - One-shot mode remains as a test/injection fallback, not as a product
    transport for stateful operations.
- `status` — decided; migration tracked in Issue 0001.
