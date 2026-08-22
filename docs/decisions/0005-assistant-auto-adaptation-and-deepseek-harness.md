# Decision 0005: Assistant auto-adaptation, diagnostics, and DeepSeek Harness

- `context` — Decision 0004 made the long-lived Assistant the group-chat
  owner, but the default label still describes a strategy choice, workflow
  failures are too coarse to repair in one pass, opening Adaptive Flywheel
  repeats target scans, and DeepSeek Harness is visible without a native
  conversation adapter.
- `decision` —
  - The collapsed default state is **Automatic adaptation** (`自动适配`). It
    describes Assistant behavior, not a built-in strategy. Imported strategies
    remain optional workflow tools controlled by the Assistant.
  - Assistant Graph rejection uses one closed diagnostic envelope. Each item
    contains a stable code and stage, plus an allowlisted JSON Pointer,
    Membership id, and numeric actual/limit facts when applicable. All locally
    knowable checks complete before durable admission or an effect.
  - Adaptive Flywheel and Assistant configuration hydrate model catalogs with
    one selected-target batch. Rust reuses the existing bounded worker pool and
    one shared discovery snapshot/cache commit. A Tokio runtime is not created
    per editor open because it would duplicate scheduling and cold-start work.
  - Assistant-addressed group messages use the same Membership-scoped native
    lane as one-to-one messages. Direct and temporary-Graph work differ only in
    who initiates the Membership turn. Codex and Claude Code retain native
    active-turn steer; Cursor and OpenCode retain native safe-boundary behavior.
  - DeepSeek Harness is adapted through its official SDK JSON-RPC stdio carrier
    (`dsh-jsonrpc-agent`). Session prompts, caller-supplied session continuity,
    structured streaming events, and explicit model selection are supported.
    Cancel, active-prompt steer, history readback, reasoning override, and
    multimodal input remain unsupported until the official protocol exposes
    them. Release readiness remains unverified until evidence is recorded.
- `rationale` — This preserves the existing Conversation, Profile, Adaptive
  Flywheel, discovery-cache, and runtime-adapter authorities. One batch removes
  repeated startup, diagnostics make requests repairable, and DeepSeek uses the
  vendor protocol instead of wrapping a human-oriented CLI.
- `alternatives` —
  - Add an automatic built-in strategy: rejected because the Assistant, not a
    Graph, owns dialogue and goal completion.
  - Start a Tokio runtime per configuration load: rejected because the Rust
    scanner already provides bounded concurrency and shared snapshots.
  - Adapt ordinary `dsh` output or emulate missing capabilities: rejected
    because neither is the official native conversation contract.
- `consequences` — The old optional-strategy wording is removed. Diagnostic
  consumers read `diagnostics`, selected model refreshes use the batch scan
  contract, and the inventory gains DeepSeek Harness with unverified readiness.
- `status` — implemented, 2026-08-22.

Official DeepSeek Harness references:

- <https://github.com/deepseek-ai/deepseek-harness>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/sdk/server/README.md>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/sdk/protocol/README.md>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/python/sdk-runtime/README.md>
