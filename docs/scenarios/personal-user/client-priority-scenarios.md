# Personal User Client Scenarios

## Metadata / 元数据

- Last updated: 2026-07-15
- Status: Current scenario authority
- Scope: Default desktop/mobile scenarios and separately enabled LicoLite collaboration plugins.
- Staleness check: Reconciled with `PRODUCT.md`, client functionality, target adapters, usage metering, backup, skills, and Secure Client Mesh on 2026-07-15.

## Shared Rules

The default client has exactly six user scenarios. They reuse the bounded Rust
queue, ACP/MCP adapters, platform adapters, local state, and Secure Client Mesh
defined in `shared-client-substrate.md`.

Local data stays local by default. Any file, conversation content, configuration,
diagnostic, path, device fact, history, or usage record leaving the current device
requires a direct approval bound to one destination, purpose, exact scope, and
content digest. It remains cancellable until commit. Missing, cancelled, expired,
changed, or unverifiable approval fails closed.

## Priority Order

| Rank | Scenario | User outcome |
| --- | --- | --- |
| 1 | `agent-discovery` | Concurrently discover and cache local agents without exposing the local inventory. |
| 2 | `agent-conversation` | Create or exactly continue a native local-agent conversation. |
| 3 | `skill-management` | Install, update, delete, and measure skills across selected local agents. |
| 4 | `conversation-backup` | Back up all or keyword-selected native conversations to a local directory. |
| 5 | `agent-usage-metering` | Report token usage by agent or model over the latest thirty days or a selected window. |
| 6 | `encrypted-mobile-relay` | Exchange end-to-end encrypted desktop/mobile messages through an opaque relay. |

## Agent Discovery

- Probe application registries, package managers, executable paths, and other
  platform-owned application locations concurrently with explicit bounds.
- Normalize by stable target identity and keep source-level success/failure so one
  unavailable source does not erase valid results.
- Cache path/configuration references locally for fast launch; never send the
  inventory, paths, versions, or configuration outside the device.
- Accept with per-source fixtures, bounded-concurrency stress, deduplication,
  cancellation, stale-cache refresh, and platform contract tests.

## Agent Conversation

- Prefer an official protocol, SDK, ACP surface, or structured command for new
  conversations and continuation.
- Preserve native session identity, effective settings, event order, final
  response, observable effects, and errors in both native-to-Arc and Arc-to-native
  directions.
- If mid-turn injection is unsupported, stream the active turn for display and
  wait for completion before beginning the next turn. Never modify private agent
  databases or scrape terminal UI to simulate continuation.
- The packaged set is Antigravity, Claude Code, Codex, Cursor, Copilot, Hermes,
  Kilo Code, Kimi Code, OpenClaw, OpenCode, and Pi Agent. Current readiness is
  `0 ready / 0 failed / 2 blocked / 9 unverified`; only `ready` adapters may send.
- Accept each adapter independently with exact-session, streaming, cancellation,
  cleanup, privacy, and release-UI parity tests.

## Skill Management

- List skills by agent; install or update from a user-configured mirror or GitHub
  repository; delete from one or more selected agents; aggregate invocations by
  time window.
- Show selected agents, destination roots, package digest, and affected files
  before every write. Preview and installation never execute skill code.
- Reject path/symlink escape, digest drift, unsupported destinations, partial
  multi-agent writes, and missing confirmation; retain a bounded rollback receipt.
- Accept with target-specific install/update/delete, multi-agent atomicity,
  rollback, visible refresh, and usage-window aggregation tests.

## Conversation Backup

- Read supported native histories without writing back to provider stores.
- Let the user select all conversations or exact keywords and a local destination.
  Keep different keywords as independent selection boundaries.
- Preview agents, query, destination, item count, and conflict policy before the
  local write; cancellation or verification failure cannot produce success.
- Accept with all/keyword filtering, adapter coverage, deterministic indices,
  destination boundary, conflict, cancellation, and read-back validation tests.

## Agent Usage Metering

- Default to the latest thirty days and support a custom time window.
- Aggregate locally recorded token counts by agent or model and identify the
  authoritative local-history source and deduplication quality.
- Exclude raw prompts, replies, accounts, native identifiers, and local paths.
- Accept with time-window, timezone transition, deduplication, cache invalidation,
  redaction, and partial local-source tests.

## Encrypted Mobile Relay

- Desktop and mobile clients encrypt application payloads locally before relay.
  Relay infrastructure receives only bounded routing facts and opaque ciphertext.
- Use the shared Rust Secure Client Mesh core on all platforms. Android and iOS
  provide authorization and secure custody without duplicating algorithms.
- Wrong recipient, revoked trust, stale keys, replay, expiration, tampering,
  unapproved local effects, and plaintext relay attempts fail closed.
- Accept with cryptographic vectors, trust/revocation UX, cross-platform bridge
  tests, opaque-wire negative controls, and authorized physical-device tests.

## Optional LicoLite Collaboration Plugins

LicoLite collaboration is not part of the default startup or navigation. The user
must explicitly enable it, choose a GitHub source, review the plugin digest and
capabilities, and install it.

The plugin host is declarative and non-executable. Status checks do not read or
load plugin files; the installed workflow catalog is read only after an explicit
user action. Source credentials, arbitrary hosts, links, executable files, shell
directives, automatic feature selection, changed digests, and reused plans fail
closed.

The plugin may provide only:

1. manual download and local deployment of LicoLite with a user-selected server
   feature/plugin composition;
2. manual installation of selected LicoLite MCP plugins into selected local
   agents.

Neither workflow runs automatically. Plugin enablement is not data-transfer
consent. Every file sent outside the current device requires a new file-bound
approval; scope or digest changes invalidate it.

## Acceptance Closure

Run the dedicated regression module for each changed scenario and its shared
integration edges. Run the complete client regression once, only after all
targeted closures pass. Optional collaboration acceptance is separate and cannot
change the default product verdict.
