# Issue 0001: Client-server interaction includes non-RPC paths

- `problem` — Flutter and Rust currently interact through several transport
  shapes. Only a subset is method-level RPC; the rest carry CLI argument
  arrays and are re-parsed by the native side, or spawn one-shot CLI
  processes. The interaction boundary is therefore inconsistent.
- `affected-area` — desktop client to native host interaction:
  `apps/desktop/lib/src/platform/native_client/` (transport),
  `apps/desktop/lib/src/backend/features/agents/services/` (CLI shape
  builders), and `crates/licoup-native/src/bin/licoup/stdio_rpc/` (native
  frame routing).
- `impact` — callers must know the per-command transport shape, the native
  side must re-parse CLI semantics for a large class of commands, and the
  one-shot path cannot carry persistent turn state.
- `evidence` — known non-RPC interaction points (list is extended as they are
  confirmed):
  1. Plain commands arrive as `method: "execute"` with a CLI argument array
     (`args`), and the native host re-runs them through the CLI parser:
     `crates/licoup-native/src/bin/licoup/stdio_rpc/server.rs:481`
     (`execute(args, portable_data_dir)`). Examples include browsing an
     Agent's session catalog (`conversations stream --agent <id>`,
     `apps/desktop/lib/src/backend/features/agents/services/agent_conversation_service.dart:427`),
     catalog, and targets commands.
  2. One-shot mode (persistent stdio-RPC disabled, e.g. injected executors or
     tests) starts a fresh `licoup-cli <args>` process per request:
     `apps/desktop/lib/src/platform/native_client/agent_service_process_io.dart:103-168`
     and `201-268`.
  3. LLM credential create/update use a private stdin argument rewrite
     instead of a structured method:
     `apps/desktop/lib/src/platform/native_client/agent_service_process_io.dart:271-291`.
  4. The unified `licoup.stdio.v1` frame carries both semantics, but only the
     structured methods (for example `agent.conversation.send`,
     `client.conversation.execute`, `state.get/set`) are method-level RPC;
     `execute` with `args` is not.
- `related` — [Decision 0001](../decisions/0001-flutter-rust-rpc-interface.md)
  records the target direction: Flutter-Rust interaction should use method
  level RPC rather than CLI tool invocation.
- `status` — open; inventory of non-RPC points is being listed one by one and
  extended here as they are confirmed.
