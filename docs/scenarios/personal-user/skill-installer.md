# Local Agent Skill Management

## Metadata / 元数据

- Last updated: 2026-07-15
- Status: Current scenario contract
- Scope: Local skill list, GitHub/mirror install and update, multi-agent delete, usage statistics, and rollback.
- Staleness check: Reconciled with the Skill Hub target adapters and product scope on 2026-07-15.

## User Flow

1. Select one or more local agents.
2. Select an installed skill or enter an explicitly chosen GitHub/mirror source.
3. Preview source revision, package digest, target roots, affected files, overwrite
   behavior, and rollback availability.
4. Confirm install, update, or delete.
5. Refresh every selected agent and display an atomic result or per-target failure
   with rollback action.

The client also aggregates skill invocation counts by agent, skill, and selected
time window. Aggregates remain local and exclude prompts, replies, tool arguments,
credentials, native identifiers, and local paths.

## Safety

- A package must have a valid skill manifest; path traversal, symlink escape,
  absolute writes, and undeclared executable hooks are rejected.
- Preview and installation never execute package code or install dependencies.
- The content digest and destination set are pinned between preview and apply.
- A multi-agent write cannot report complete success when any selected target was
  skipped or failed; rollback receipts remain bounded and target-bound.
- Automatic update may check only sources the user explicitly configured. It may
  prepare a preview but cannot apply a write without the user's current approval.
- No skill inventory, package, usage record, or local path leaves the device as
  part of this built-in workflow.

## Optional LicoLite MCP Plugins

Installing LicoLite MCP plugins is a separate optional collaboration-plugin flow.
It is unavailable until the user enables collaboration and installs that plugin
from a selected GitHub source. The user then manually chooses the LicoLite MCP
plugins and local agents and reviews the exact config/file changes.

If an MCP operation sends a local file outside the device, that exact file,
destination, purpose, and digest require a new direct approval. Batch, remembered,
startup, scheduled, or agent-inferred approval is invalid.

## Acceptance

- target-specific list/install/update/delete tests;
- multi-agent atomicity and rollback tests;
- digest drift, path escape, symlink, unsupported root, and partial-write negatives;
- automatic-check/manual-apply separation;
- time-window invocation aggregation and privacy projection;
- optional-plugin disabled-by-default, manual installation, and per-file approval
  negative tests.
