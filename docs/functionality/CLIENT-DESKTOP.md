# LicoUp Client Functionality

## Metadata

- Last updated: 2026-07-30
- Status: Implemented capability overview
- Scope: Desktop, mobile, Rust sidecar, ACP, MCP, platform adapters, local-agent workflows, the current retiring endpoint-protection Preview, and optional user-enabled Meshrix collaboration plugins.
- Staleness check: Reconciled with `PRODUCT.md`, `docs/STATUS.md`, client application boundaries, the native sidecar, packaging manifests, target adapters, current endpoint-protection Preview contracts, and module-scoped regression catalog on 2026-07-30.

## Product Boundary

[`PRODUCT.md`](../../PRODUCT.md) owns the public product boundary. Detailed
behavior is owned by the Rust and Flutter modules, public schemas, catalogs, and
regression entries named below; this document is an acceptance-oriented
projection of those authorities.

LicoUp is a local-first client. Flutter owns presentation and application
coordination; Rust owns bounded local execution, protocol adaptation, local state,
and cryptographic substrate. The default client does not require or start a
Meshrix server.

Built-in capabilities are limited to:

1. a lightweight Rust local task queue;
2. ACP adaptation for local agents and encrypted remote relay;
3. MCP request and response adaptation;
4. macOS, Windows, Ubuntu, Android, and iOS platform adaptation;
5. the six product scenarios defined below.

Capabilities outside this scope are not built into the client, registered as
commands, or shown in navigation. The default UI modules are **Agents**, **Token
Usage**, **Skill Hub**, **Mobile Relay**, and **Settings**. Optional collaboration
begins only after the user installs and enables the separate GitHub plugin.

## Mandatory External-Transfer Contract

Local files, conversation content, configuration, diagnostics, paths, device
facts, agent history, and usage records remain on the current device by default.
An operation that transfers any of that information outside the device is valid
only when all of the following hold:

- the user initiated or directly approved this single operation;
- the UI shows destination, purpose, exact data/file scope, and affected agents;
- the user can cancel until commit;
- approval is bound to operation kind, destination, scope, and content digest;
- any changed, missing, cancelled, expired, or unverifiable approval fails closed;
- startup, plugin enablement, schedules, prior approvals, and agent requests never
  imply consent.

Pressing Send for one explicitly addressed end-to-end encrypted message authorizes
only that message and recipient. Background or agent-originated file movement
requires a separate direct approval for each file.

## Independently Acceptable Architecture Boundaries

| Boundary | Ownership and dependency rule |
| --- | --- |
| Flutter contracts | Defines ports, values, and cross-layer messages without depending on application, frontend, backend, or platform implementations. |
| Flutter application | Owns use cases and narrow controllers; one feature must not reach another feature's storage or UI implementation. |
| Flutter frontend | Consumes application/contracts only and contains no native process, filesystem, network, or protocol implementation. |
| Flutter platform/backend | Implements narrow contracts and returns bounded business projections rather than raw process output. |
| Rust local queue | Owns bounded admission, FIFO handoff, backpressure, and single-consumer ownership; it contains no UI or feature-specific policy. |
| Rust ACP adapter | Owns ACP framing and capability translation; per-agent semantics stay in target-specific leaves. |
| Rust MCP adapter | Owns strict bounded JSON-RPC request/notification/response codecs plus a short-lived one-shot direction/destination/purpose/digest-bound transfer gate; optional Meshrix behavior is not embedded here. |
| Platform adapters | Own OS discovery, secure storage, authorization, paths, process launch, and packaging behind platform-neutral ports. |
| [Endpoint-protection Preview](../STATUS.md) | Owns the current LicoUp implementation, private-key/Provider custody, user trust and approval, and local effects. This retiring implementation is not a Lico Arc Profile and has no future compatibility promise. |
| Lico Arc Protocol Line | Owns stable wire-observable Pairwise Protection, Generic Message, Reliable Exchange, negotiation, and Transport Profile semantics. LicoUp executes one pinned line; it does not redefine one. |

The architecture gate rejects cross-layer reverse dependencies, duplicate protocol
implementations, unbounded lifecycle resources, and feature behavior hidden in a
shared facade.

## Foundation F-01 — Lightweight Rust Task Queue

| Item | Contract |
| --- | --- |
| Objective | Schedule short-lived local client work without a general server queue. |
| Input | A typed in-memory task submitted through a cloneable producer. |
| Processing | A positive fixed capacity applies backpressure; multiple producers feed one exclusive FIFO consumer without an async-runtime dependency. |
| Output | Ownership of the accepted task moves to the worker; rejected tasks are returned intact to the caller. |
| Rejection | Zero capacity, full non-blocking admission, worker shutdown, or channel disconnection fails closed. |
| Persistence | None. The lightweight queue stores no durable task record or copied user content. |
| Regression | Rust FIFO/depth, full-queue ownership, cloned-producer, disconnect, and invalid-capacity unit tests. |

## Foundation F-02 — ACP Adaptation

| Item | Contract |
| --- | --- |
| Objective | Use ACP for supported local-agent conversations and carry ACP-derived application messages inside encrypted client relay payloads. |
| Processing | Parse and emit bounded frames, preserve request/session correlation, order events, propagate cancellation, and map capabilities without target-specific branching in the shared codec. |
| Rejection | Oversized, malformed, out-of-order, unknown-session, untrusted, or plaintext relay payloads fail closed. |
| Regression | Codec vectors, malformed-frame property tests, exact-session conversation parity, cancellation, and endpoint-protection Preview ACP relay tests. |

## Foundation F-03 — MCP Adaptation

| Item | Contract |
| --- | --- |
| Objective | Let LicoUp issue MCP requests or forward MCP responses through a narrow protocol adapter. |
| Processing | Validate JSON-RPC/MCP shape, correlate requests, bound payloads, sanitize errors, and bind any external request or response transfer to a one-shot approval over direction, destination, and exact message digest. |
| Rejection | Invalid id, malformed response, changed destination or message, missing/cancelled approval, replay, or payload overflow fails closed. |
| Regression | MCP codec/ID tests, bounded stdio/HTTP bodies, request-send and response-forward direction/destination/purpose/digest binding, cancellation, expiry, replay, mutation, and approval negative tests. |

## Foundation F-04 — Platform Adaptation

| Platform | Required acceptance |
| --- | --- |
| macOS | App discovery, executable launch, sandbox/path boundaries, Keychain/LocalAuthentication, packaging, build, and launch. |
| Windows | Registry/application discovery, process/path boundaries, owner-only secret storage, x64/arm64 packaging, build, and launch. |
| Ubuntu | Desktop/package/binary discovery, process/path boundaries, Secret Service or memory-only custody, package build, and launch. |
| Android | Secure storage and biometric authorization through the shared Rust cryptographic core, lifecycle-safe relay, build, install when an authorized device is present, and launch. |
| iOS | Keychain/LocalAuthentication through the shared Rust cryptographic core, lifecycle-safe relay, build, simulator or authorized-device installation, and launch. |

Platform code may implement OS mechanics only. ACP, MCP, queue semantics, target
business rules, and encryption algorithms remain platform-neutral.

## Scenario S-01 — Desktop Agent Discovery

The client probes application stores, package managers, executable search paths,
and other common platform-owned application locations asynchronously with bounded
concurrency. Results are normalized and deduplicated by stable target identity,
then registered in a local cache with configuration references needed for fast
subsequent launch.

On macOS, the accessible-environment scan also enumerates running local OrbStack
machines and checks a fixed set of documented or common OpenClaw and Hermes
executable locations. Guest probes have bounded time, output, machine count, and
concurrency. They read no configuration or conversation store. A validated
automatic VM route is transient and is never written to the discovery cache.

Discovery never sends the inventory, paths, versions, configuration, or probe
output outside the device. A timeout or permission failure yields a bounded source
status and does not invalidate successful sources.

Regression: per-source discovery fixtures, concurrency-bound tests, canonical
deduplication, stale-cache refresh, permission denial, cancellation, and platform
adapter contract tests.

## Scenario S-02 — Desktop Agent Conversations

The client creates and continues local native-agent conversations. It also
accepts an automatically discovered or explicitly configured OpenClaw or Hermes
runtime in a user-owned VM.
An adapter first uses an official protocol, SDK, or structured command surface.
Exact native continuation must preserve the native session identity, effective
model and permission settings, event order, final response, observable effects,
and error semantics.

The VM path uses the system OpenSSH client as a bounded native-protocol stdio
transport.
The target shape contains only host, optional port/user, guest executable, and
absolute guest working directory; passwords, private keys, and command fragments
are rejected. Strict host verification and noninteractive system authentication
are required. The exact SSH destination remains visible in the conversation
header. OpenClaw uses ACP. Automatically discovered Hermes uses ACP when its
optional package is available, otherwise its official TUI Gateway JSON-RPC.
History uses the selected protocol's session list/load operations rather than
guest filesystem access, and local MCP server descriptors are not forwarded
into the VM.

When official mid-turn injection is unavailable, LicoUp may stream the active
turn for display and start the next user message only after the native reply is
complete. It must not emulate mid-turn injection by editing private databases,
scraping a terminal UI, or starting a replacement conversation.

The packaged adapter set is Antigravity, Claude Code, Codex, Cursor, GitHub
Copilot, Hermes Agent, Kilo Code, Kimi Code, OpenClaw, OpenCode, and Pi Agent.
Adapter readiness remains a release-evidence claim and is disclosed separately
from source runtime resolution. A target is usable only when the client resolves
its packaged driver plus a valid local executable or discovered/explicit VM
connection; unresolvable transports fail closed without blocking unrelated
client functions.

Regression: target-specific new/continue tests, both native-to-Arc and
Arc-to-native continuation, VM connection validation and private-stdin binding,
ACP/Gateway session list/load, SSH command confinement, stream ordering, cancellation,
restart/cleanup, safe rendering, privacy projection, and release-UI parity
reducer.

## Scenario S-03 — Desktop Skill Management

The client lists skills by agent, installs a selected GitHub-hosted skill, updates
from a user-configured mirror or GitHub repository, deletes a skill from one or
more selected agents, and aggregates skill invocation counts by time window.

Every write is previewed with target agents, destination roots, package digest,
and affected files. Installation and update do not execute package code. Path
escape, symlink escape, digest changes after preview, unsupported target roots,
and partial multi-agent writes fail closed and retain a rollback record.

Regression: list/install/update/delete per target adapter, multi-agent atomicity,
digest and path negative cases, rollback, refresh visibility, and time-window usage
aggregation.

## Scenario S-04 — Desktop Conversation Management and Backup

The client indexes supported agents' native conversations read-only, filters them,
and backs up all conversations or keyword-matched conversations to a directory
selected by the user. Each keyword remains an independent selection criterion;
the client does not merge unrelated project identities.

Backup writes locally and never changes native history. The preview shows agents,
query, destination, item count, and conflict policy. Path escape, inaccessible
source, unsupported format, changed selection, cancellation, or incomplete
verification fails closed without reporting success.

Regression: all/keyword selection, exact keyword boundaries, source adapters,
deterministic index generation, local destination boundary, conflict handling,
cancellation, and round-trip restore-read validation where supported.

## Scenario S-05 — Desktop Token Usage

Usage reporting defaults to the latest thirty days and supports a manually chosen
time window. Reports aggregate locally recorded token counts by agent or model
from supported agents' authoritative local histories, with explicit source and
deduplication boundaries.

No raw prompt, response, account, local path, or native identifier enters the
report. Missing history, timezone changes, overlapping records, counter resets,
or unknown model attribution remain explicit rather than silently fabricated.

Regression: agent/model dimensions, default and custom windows, timezone
transitions, deduplication, cache invalidation, redaction, and empty/partial local
source handling.

## Preview Scenario S-06 — End-to-End Encryption and Mobile Relay

Desktop and mobile clients establish authenticated trust and encrypt application
payloads before relay. The relay receives only bounded routing metadata and opaque
ciphertext. A compromised relay must be unable to decrypt messages, commands,
results, approvals, or explicitly approved files.

Current source paths use the shared Rust endpoint-protection core. Android and iOS
bridges provide platform authorization and secret custody but do not reimplement
cryptographic algorithms. Replay, wrong recipient, revoked endpoint, stale key,
expired payload, modified ciphertext, unapproved local effect, and plaintext relay
attempts fail closed.

Those current mechanisms form a LicoUp preview implementation, not a Lico Arc
Profile or future compatibility contract. They are to be retired directly when
a complete pinned Lico Arc Protocol Line replaces them. Lico Arc owns the
observable Pairwise Protection, Generic Message, Reliable Exchange,
negotiation, and Transport Profile contract; LicoUp retains private keys,
Provider configuration, plaintext, history, backups, user trust, approval,
and local-effect handling.

This scenario remains `preview` in the compatibility matrix. The direct
client-owned Lico Arc candidate adapter has completed one bounded exchange
between two freshly initialized endpoints through an actual BadTower candidate,
as recorded in [`../STATUS.md`](../STATUS.md) and the
[station-adapter contract](../protocols/licoarc-station-adapter.md). That local
candidate evidence does not establish stable neutral-station support,
physical-device acceptance, release, or hosted operation.

Regression: pairwise/group codec vectors, cross-platform bridge tests, trust and
revocation UX, wrong-recipient/tamper/replay controls, opaque-relay conformance,
message/result round trips, and physical-device verification when authorized.

## Optional Plugin P-01 — Local Meshrix Deployment

This capability is absent from the default startup and navigation. The user must
enable collaboration, select a GitHub source, install the plugin, choose a local
destination, and select the Meshrix server feature/plugin composition before the
plugin may download and build it. Disable/uninstall removes the plugin-owned
integration without changing the built-in client.

The built-in host stores only a disabled capability flag and the declarative
plugin contract. `collaboration status` never reads plugin files. A user must
run `collaboration enable`, then create a GitHub-only `collaboration install
plan`, review its source and SHA-256 package digest, and confirm the exact plan
with `collaboration install apply`. Packages are bounded, reject links and
executable files or directives, and expose their workflow catalog only through
an explicit `collaboration workflow catalog` action. Disable and digest-bound
uninstall remain separate manual actions.

The workflow is local deployment only. It does not grant permission to transfer
client or user information to the deployed service.

Regression: disabled-by-default boundary, explicit enable/install, source and
digest preview, selectable composition, cancellation, fail-closed source change,
non-executable package validation, plugin disable/uninstall, and absence from
default navigation.

## Optional Plugin P-02 — Meshrix MCP Plugin Installation

The user manually chooses one or more local agents and one or more Meshrix MCP
plugins, reviews target configuration changes, and confirms the installation.
No background, scheduled, startup, or agent-initiated installation is allowed.

If an MCP operation would transfer a local file, the user must approve that exact
file, destination, purpose, and digest for that operation. Batch or remembered
approval is invalid.

Regression: disabled-by-default boundary, manual target selection, plan/apply/
rollback, multi-agent consistency, no automatic trigger, per-file approval,
changed-digest rejection, cancellation, and fail-closed missing approval.

## Regression Closure

`tools/regression/client-module-catalog.mjs` is the authority for independently
acceptable modules and their dedicated commands. During development:

```bash
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
npm run client:regression -- --module <module-id>
```

Run the smallest affected module set first. After all changed modules and
integration edges pass, run `npm run client:gate:source` exactly once and run
only the affected Flutter, Rust, Android, dependency, or release-policy lane.
The lanes are independent and may run in parallel. The source policy never
installs platform toolchains, and the commit gate never builds or publishes
every platform.
