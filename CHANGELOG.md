# Changelog

This file records notable public changes to LicoUp. Product and package
versions are owned by `tools/client-version.json` and the synchronized package
manifests.

## Unreleased

## 0.1.0 — 2026-08-08

- Added signed GitHub update discovery, Wi-Fi background download, digest and
  dual-role Ed25519 verification, safe macOS app replacement, rollback, and
  restart.
- Published the first stable macOS ARM64 GitHub distribution under AGPL-3.0-or-later.

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
