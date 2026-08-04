# LicoUp Desktop Client

English (normative) · [简体中文](README.zh-CN.md)

LicoUp is a local-first open-source desktop and mobile client. Its product
boundary is owned by [`PRODUCT.md`](../../PRODUCT.md) and
[`CLIENT-DESKTOP.md`](../../docs/functionality/CLIENT-DESKTOP.md). Default use
does not depend on a Meshrix server.

## Default Product Scope

The client includes four foundation capabilities:

- a lightweight local Rust task queue;
- ACP adaptation for local-agent execution and protected remote carriage;
- MCP request and response adaptation; and
- platform adaptation for macOS, Windows, Ubuntu, Android, and iOS.

The default interface contains only these user scenarios:

- `Agents`: concurrently discover local agents and create, list, or continue
  native conversations with local or explicitly configured OpenClaw or Hermes
  virtual-machine targets;
- `Conversations`: search, manage, and back up all native conversations or
  those matching a keyword;
- `Skill Hub`: manage skills per agent, update them from an explicit mirror or
  GitHub source, remove them, and inspect usage frequency;
- `Usage`: report token use by agent or model, with the most recent 30 days as
  the default window;
- `Mobile Relay`: carry end-to-end protected opaque envelopes between desktop
  and mobile clients; and
- `Settings`: manage local settings, platform authorization, and approval for
  external transfers.

ACP and MCP are built-in protocol-adaptation foundations, not separate
navigation entries. Optional Meshrix collaboration enters only through the
default-disabled external plugin described below.

`Mobile Relay` currently executes the
[current retiring endpoint-protection Preview](../../docs/STATUS.md) and
carries it through the implemented candidate `licoarc.relay.v1` outer adapter.
That preview is not a Lico Arc Profile and has no future compatibility promise.
A stable client will execute a pinned Lico Arc Protocol Line for
wire-observable Pairwise Protection, Generic Message, Reliable Exchange,
negotiation, and Transport Profile semantics while continuing to own its
private keys, Provider configuration, plaintext, history, backups, trust
decisions, approvals, and local effects.

Packaged targets currently include Antigravity, Claude Code, Codex, Cursor,
Copilot, Hermes, Kilo Code, Kimi Code, OpenClaw, OpenCode, and Pi Agent.
Discovery, readable history, or a synthetic check does not establish
conversation support. Send remains enabled only for an adapter that passes
native-conversation parity acceptance. Native drivers and the readiness
catalog own current adapter state and project it into
[`docs/COMPATIBILITY.md`](../../docs/COMPATIBILITY.md); an unready adapter
fails closed.

## Optional Meshrix Collaboration Plugin

Meshrix collaboration is not loaded or shown in the default startup path. The
user must enable it manually and install the optional plugin from a
user-selected GitHub source. The plugin may provide only:

1. a user-initiated download of Meshrix for a private local deployment, with
   server capabilities and plugins selected before installation; and
2. a user-initiated installation of selected Meshrix MCP plugins into one or
   more local agents.

Installation, startup, a schedule, or an agent request never authorizes local
data egress. Each local file requires a separate preview of destination,
purpose, scope, and digest plus direct approval for that operation. A changed
destination, scope, or content invalidates approval; cancellation, expiry, or
unverifiable binding fails closed.

## Local Data Boundary

Local paths, configuration, conversations, usage, diagnostics, device facts,
and files remain in client-owned local storage by default. Any transfer beyond
the current device must be initiated or directly approved for that single
operation, remain cancellable before commit, and never reuse historical
approval.

Pressing Send for one explicitly addressed end-to-end protected message
authorizes only that message and destination. For a manually configured
virtual-machine target, the conversation view continues to show the SSH
destination; pressing Send authorizes only delivery of that prompt to the
selected agent inside the virtual machine.

## Agent Conversations

Conversations use an agent's official protocol, SDK, or structured CLI to
create and continue the same native session. An adapter preserves native
session identity, effective model and permission settings, event order, final
result, and error semantics. If the native interface cannot accept guidance
during a turn, the client may project live progress but waits for that turn to
finish before starting the next one.

Each user message is followed by one turn lifecycle that merges with contiguous
reasoning and tool activity. Generic provider bookkeeping is grouped into a
quiet runtime-log row instead of appearing as another process card. Expanded
details still contain only redacted summaries, never raw chain-of-thought,
tool arguments, credentials, native identifiers, or local paths.

The desktop client can add OpenClaw or Hermes virtual-machine targets over
SSH. It stores only the host, optional port and user, in-VM executable, and
absolute in-VM working directory; passwords and private keys are rejected.
Rust invokes the fixed `openclaw acp` or `hermes acp` command through system
OpenSSH with strict host verification and non-interactive authentication, then
lists, loads, and continues sessions through ACP. It neither reads nor copies
the VM history database and does not forward local MCP service descriptions
into the VM.

## Development

```bash
npm run client:get
npm run client:analyze
npm run client:test
npm run client:native:test
```

Run a desktop or mobile client:

```bash
npm run client:run:macos
npm run client:run:android -- --debug
npm run client:run:ios -- --debug
```

Dependency, Gradle, and Flutter caches stay outside the source tree. When a
cache location must be overridden, use the supported `LICO_CLIENT_*_CACHE`
environment variables and placeholder paths such as `<cache-root>`; never put
a workstation path in documentation, logs, or evidence.

## Minimum Regression Closure

Select the affected module during development:

```bash
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
npm run client:regression -- --module <module-id>
```

After all targeted checks and acceptance work pass, run the required source
policy once and only the affected technology lane:

```bash
npm run client:gate:source
npm run client:gate:flutter         # Flutter changes only
npm run client:gate:rust            # Rust changes only
npm run client:gate:android         # Android changes only
npm run client:gate:dependencies    # dependency changes only
npm run client:gate:release-policy  # release-policy changes only
```

The source policy requires only Node and does not install Flutter, Rust, or
Android toolchains. Technology lanes are independent and may run in parallel;
do not chain unaffected platforms. Architecture, ACP/MCP, conversation, skill,
usage, backup, endpoint protection, and platform adapters use their registered
module-specific regression entry points.

## Build And Packaging

```bash
npm run client:package:plan
npm run client:build:macos
npm run client:build:windows
npm run client:build:linux
npm run client:build:android
```

Builds for macOS, Windows, Ubuntu, Android, and iOS; ordinary verification;
GitHub Release; and each platform store are independent claims. Missing
publisher identity or signing conditions for one store block only that
channel, not source development, ordinary builds, or another verified
platform.

Public artifacts contain only the minimum digest, signature or proof, and
public verification material needed by consumers; they exclude user and
client runtime information. Each GitHub Release dispatch selects one supported
target. Different targets may build concurrently; only the same-tag asset
manifest update is briefly serialized.
