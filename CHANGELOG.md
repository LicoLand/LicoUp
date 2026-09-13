# Changelog

This file records notable public changes to LicoUp. Product and package
versions are owned by `tools/client-version.json` and the synchronized package
manifests.

## 0.3.0 — 2026-09-14

- Added the Orbital theme style in Dark and Light on a deep-black, silver and
  electric-yellow palette. Existing selections are preserved, the motion-scale
  token now scales animation durations, and macOS Reduce Motion and the manual
  switch resolve through one scope.
- Desktop navigation now shows four floating apps: Agent Hub, Token Usage,
  Model Gateway and Mobile Pairing. Plugin Management and Skill Hub moved into
  the Agent detail page, and Chat Channels moved into Mobile Pairing.
- Added an Execution process viewer opened from the ellipsis menu at an Agent
  bubble's upper-right corner, with search, copy, step-through and live follow.
  Thinking and tool activity are no longer inline process cards in the
  transcript.
- An accepted dispatch now creates its reply bubble immediately and shows three
  points in elastic equal-mass collision until the first real reply text
  replaces it.
- Loading animation is now a setting with three options: a simple spinner (the
  new default), a static indicator, and the previous conversation particles.
  The first two skip anchor measurement, brand-mark glyph sampling and
  decorative frame scheduling entirely.
- `licoup` is now the documented local CLI facade (`licoup help`,
  `licoup commands`, `licoup rpc call`, `licoup rpc conversation`).
  `conversation execute` and `strategy execute` route through the persistent
  native host, so work continues after the CLI exits.
- The `lico-up-subagents` MCP server moved to 0.14.0 with its allowlist cut from
  nine tools to five, so Assistant profiles and workflows are local-CLI only for
  MCP clients. The separate `lico-conversation-mcp` server was removed, and MCP
  now autostarts with the desktop host, opt-out via `LICOUP_MCP_AUTOSTART=0`.
- Bundled `LicoUpCustody.app` as the CLI's Keychain custodian, so one biometric
  authorization covers all selected Gateway keys instead of per-item prompts.
  `Contents/MacOS/licoup-cli` remains as a permanent relative symlink, the
  client no longer falls back to an external `licoup-cli`, and bundle
  verification fails the build when the helper is missing.
- Added **Migrate legacy keys** to the Model Gateway credentials card, shown
  only while migration is pending. It copies each key to the Data Protection
  Keychain, reads it back, verifies equality, then removes the classic source,
  so API keys do not need to be re-entered.
- DeepSeek Harness is a first-class agent: it appears in Agent Center, in model
  pickers with the installed adapter's names and efforts, and in Statistics
  from its own session store. Its conversations open and send turns, and
  assistant messages publish as they complete.
- Claude Code pickers now list the real model catalog (`opus`, `opus[1m]`,
  `sonnet`, `sonnet[1m]`, `haiku`, `opusplan`, `default`) and honour
  `availableModels` from Claude settings.
- Model rows in Token Usage open a hover card with a source header, one
  colour-swatched row per effort or speed variant, and an
  `Included · N requests` footer. Agent charts use fixed per-Agent brand hues,
  model charts use shades within the model developer's family, the Total bar is
  pure white, and the model picker lists names only in a virtualized list.
- Reasoning-effort labels are English-only in both locales and ascend from Auto
  through Low, Medium, High, Extra High to Max.
- The update check no longer reports a failed network request or a failed
  integrity verification as up to date, and a release without update material
  shows a neutral message. A stale cache can no longer mask a failed
  verification.
- Corrected native token accounting: placeholder selectors such as `default`,
  `auto`, `unknown` and `Others` no longer appear as model names, complete and
  JSON-string-wrapped selectors decode to their effort and speed row, a record
  with a different explicit provider no longer inherits the request's reasoning
  effort, and retained reports are re-projected onto the currently supported
  agent set.
- Group conversations now bind to their own recorded history (store schema
  14 → 15) instead of intersecting group members' browse catalogs, so missing
  metadata no longer invents relationships and unrelated browse changes no
  longer rebuild the group collection.
- Removed the Kimi Desktop target. It no longer appears in Agent Center and its
  tokens drop out of Statistics totals; Kimi Code CLI (`kimi-code`) is
  unaffected and nothing on disk is deleted.
- Pull-to-refresh dispatches one refresh and springs back instead of holding the
  list, and authorizing the Gateway no longer re-seals every selected credential
  on each call. The 120-second timeout on the macOS authorization prompt was
  removed.
- Startup now stages around the Local conversation: it warms immediately after
  native state admission and before storage, preferences, target-cache
  hydration, Agent discovery and service warmups, and update checks and
  optional warmups no longer hold the ready state.
- `conversation.list` returns one snapshot instead of two, replies of 256 KiB or
  more decode off the UI isolate, each stdio RPC envelope is parsed once, and
  `targets scan` and `llm-gateway credentials migrate` run on a bounded worker
  pool so they no longer freeze the client.

## 0.2.1 — 2026-09-11

- Replaced the macOS frosted visual-effect backdrop with a clear see-through
  color veil, kept structural glass rims one alpha around the full frame, and
  removed the Token Usage back title and Communication section header.
- Continuing a Cursor IDE-listed conversation from LicoUp now opens a new Agent
  CLI session and injects a one-time handoff (composer id, `state.vscdb`
  key prefixes, and the last IDE assistant return) instead of resuming the IDE
  composer id on `cursor-agent`.
- Lico group Current Conversation now walks the Adaptive Flywheel Daily
  Conversation priority list after quota, credit, rate-limit, or provider-capacity
  failures, and persists Current Conversation to the capsule that succeeds
  without reordering the list.
- Codex model pickers now merge `~/.codex/models_cache.json` and
  `model-catalogs` with App Server `model/list`, so the Adaptive Flywheel and
  composer show the full local Codex directory (plus custom providers) instead
  of a sparse config-only fallback. Cache documents prefer the nested `models`
  array so metadata such as etag / fetched_at never appears as model ids.
- Cursor Agent CLI (`cursor-agent`) is bound for Adaptive Flywheel and runtime
  relay even when the short capability probe fails, so a detected Cursor install
  is no longer missing from Designer / Worker / Reviewer pickers.
- The client-owned local-agent fallback workspace is now the shared
  `.lico-up/agent-workspace` directory (no per-agent subdirectory). The
  composer workspace capsule stays clickable on local desktop so the user can
  rebind a project directory instead of remaining locked on the fallback.
- The Lico group flywheel section is labeled **Current Conversation**; when its
  agent differs from the first Daily Conversation capsule, that selection is the
  live dispatch owner without reordering the Daily Conversation list. The
  flywheel capsule shows agent · model · reasoning effort · Fast when set.
- Adaptive Flywheel Daily Conversation replaces the Main Agent card: a circular
  plus expands into a search capsule and three floating cards (agent, model,
  reasoning effort + Fast); the first capsule is the dispatch owner, and
  selections persist in `adaptive-flywheel.toml`.
- Adaptive Flywheel Code Engineering Designer, Worker, and Reviewer use the same
  multi-capsule picker (without Fast). Worker/Reviewer list order projects to
  backend then frontend lanes for Subagent MCP.
- Documented the tuned Messaging Agents desktop surface in
  `docs/functionality/DESIGN-SYSTEM.md` and the user guides: shared main-content
  glass card, overlay header/composer capsules, hover-anchored conversation and
  notification cards, neutral transcript chrome, circular send, and the runtime
  capsule’s parallel Model / Reasoning Effort rows with Auto as the native
  default.
- Added the Kilo Gateway as a third LLM API-key provider in desktop settings;
  the local LLM Gateway routes claude-sonnet-4-6, claude-opus-4-7, and
  claude-haiku-4-5 to the matching anthropic/claude-* upstream models across all
  three client protocols.

## 0.2.0 — 2026-09-10

- Added a durable Continuous Assistant flow that gives each long-running request
  one child Conversation, keeps one parent timeline card at its creation point,
  and preserves membership-scoped continue, steering, cancellation, recovery,
  and completion notices.
- Added persisted adoption policy and evaluation receipts with explicit
  fail-closed boundaries for unqualified live or paid model execution.

## 0.1.1 — 2026-08-14

- Restored the current conversation selection, cached history pagination,
  activity indicators, canonical Local group, collapsed Agent metadata, group
  member scrolling, and the requested product logo across the desktop client.
- Bound macOS delivery to arm64-only packages and an exact verified runnable
  that installs and launches without rebuilding.
- Synchronized the client, native crate, Flutter bundle, compatibility matrix,
  and release-governance version sources at `0.1.1`.

## 0.1.0-alpha — 2026-07-25

- Added exact native conversation continuation for all eleven packaged
  local-agent adapters.
- Added a bounded local Subagent MCP so one selected main agent can discover,
  delegate to, continue, and cancel every other runnable agent.
- Added fail-closed release readiness that requires every packaged conversation
  adapter to have current release-UI evidence before GitHub Release builds.
- Split source, Flutter, Rust, Android, dependency, and release-policy checks
  into independently selected client gates.
- Made GitHub Release targets independently buildable while serializing only
  same-tag manifest publication.
- Organized formal project documentation by architecture, functionality,
  protocol, example, compatibility, configuration, decision, and runbook
  ownership.
- Separated ignored plans and reports from the public documentation set.

## [0.0.1-alpha]

- Recorded the existing prerelease version baseline for governed future
  releases. This entry is not a stable-release or distribution claim.
