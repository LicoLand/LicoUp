# Changelog

This file records notable public changes to LicoUp. Product and package
versions are owned by `tools/client-version.json` and the synchronized package
manifests.

## Unreleased

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
