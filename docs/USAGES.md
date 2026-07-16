# Lico Arc Usage

## Metadata / 元数据

- Last updated: 2026-07-15
- Status: Current maintained usage document
- Scope: Local client development, desktop/mobile launch, supported local workflows, optional collaboration plugins, module regression, and platform builds.
- Staleness check: Reconciled with `package.json`, `apps/desktop/README.md`, the Rust client command surface, product scope, and the client module-regression catalog on 2026-07-15.

## Local Development

```bash
npm run client:get
npm run client:analyze
npm run client:test
npm run client:native:test
```

Launch a client surface:

```bash
npm run client:run:macos
npm run client:run:android -- --debug
npm run client:run:ios -- --debug
```

Generated dependencies, Flutter metadata, Gradle state, build products, and
runtime diagnostics stay outside source control. Examples use placeholders such
as `<cache-root>`, `<destination-dir>`, and `<mcp-endpoint>`; never place a real
workstation path, device identifier, credential, or runtime payload in docs or
evidence.

## Agent Discovery

Run the native multi-source scan when diagnosing the desktop discovery surface:

```bash
lico-client targets scan
```

The scan concurrently queries platform-owned application/package/executable
sources with bounded work and updates only the local target cache. Its inventory,
paths, versions, and configuration are never sent outside the device.

## Agent Conversations

List locally available native histories:

```bash
lico-client conversations list --agent <agent-id>
```

Normal conversation creation and continuation should use the GUI so readiness,
exact-session behavior, streaming, and safe rendering remain visible. A target
may enable sending only after native-to-Arc and Arc-to-native continuation pass
the parity reducer. The current reducer summary is
`0 ready / 0 failed / 2 blocked / 9 unverified`.

Targeted adapter acceptance:

```bash
npm run client:verify:agent-conversation-parity
node tools/scripts/client-acp-conversation-parity.mjs --print-live-gate
node tools/scripts/client-acp-conversation-parity.mjs --agent <agent-id> --strict
```

A release-UI run is an explicit operator action and must not copy prompts,
responses, session identifiers, paths, or process output into evidence.

## Skill Management

Read and preview a GitHub-hosted skill:

```bash
lico-client skill list --agent <agent-id>
lico-client skill get <skill-id> --agent <agent-id> --json
lico-client skill install plan --agent <agent-id> --url <github-skill-url>
```

After reviewing the target, destination, package digest, and affected files, the
user may apply or roll back the local write:

```bash
lico-client skill install apply --agent <agent-id> --url <github-skill-url>
lico-client skill install rollback --agent <agent-id> --snapshot-id <snapshot-id>
```

The GUI owns multi-agent delete, configured-source update, and skill invocation
frequency by time window. Each mutating action shows all selected agents and file
effects before confirmation. Preview and installation never execute skill code.

## Conversation Backup

Use the GUI to choose all conversations or one exact keyword and a local
destination directory. Preview returns a digest binding the local source,
selection/query, destination, selected count, and conflict state. Apply only
that exact preview:

```bash
lico-client snapshots archive jobs preview \
  --selection-mode exact-keyword \
  --query <exact-keyword> \
  --path <destination-dir>
lico-client snapshots archive jobs create \
  --selection-mode exact-keyword \
  --query <exact-keyword> \
  --path <destination-dir> \
  --plan-binding <preview-binding>
```

Use `--selection-mode all` without `--query` for every conversation in the
selected local source.

The destination remains local. The client shows source agents, exact keyword
scope, item count, destination, and conflict policy before writing. Cancellation,
scope drift, source errors, or verification failure must not be reported as a
successful backup.

## Token Usage

The default time window is the latest thirty days:

```bash
lico-client agent-usage scan --agent <agent-id> --history-days 30
lico-client agent-usage report --agent <agent-id> --limit 10
```

Use the GUI for a custom time range and agent/model dimension selection. Reports
contain aggregates and attribution quality only; raw conversations, accounts,
native identifiers, and local paths are excluded.

## MCP Adaptation

The service-neutral MCP adapter is an internal protocol boundary used by current
client workflows. It validates bounded JSON-RPC messages for stdio or HTTP and
sends a request or forwards a response only after one-shot approval is bound to
the direction, destination, and exact message digest. It does not install or
configure agent plugins from the default client.

Optional LicoLite MCP plugin installation becomes available only after the user
installs and enables the separate GitHub collaboration plugin. Any operation
that would transfer a local file shows its destination, purpose, exact file, and
digest and requires direct approval for that single file. Missing, cancelled,
expired, or changed approval fails closed.

## Secure Client Mesh and Mobile Relay

Production relay paths carry only authenticated encrypted envelopes. The Rust
core owns encryption, trust, replay protection, and key lifecycle; Android and
iOS supply platform authorization and secure custody without reimplementing the
protocol.

Useful bounded checks:

```bash
npm run client:verify:secure-client-relay-mock-e2e
npm run client:verify:secure-mesh
npm run client:test:android:native
```

Physical install or device verification is a separate authorized operator action.
Reports must contain only redacted status and digests, never device identity,
plaintext, ciphertext, credentials, or runtime payloads.

## Optional LicoLite Collaboration

LicoLite collaboration is disabled and absent from the default startup path. To
use it, the user must explicitly enable collaboration, choose a GitHub source,
review the plugin digest and capabilities, and install the optional plugin.

The plugin may then offer:

- a manual local LicoLite deployment workflow with a user-selected server
  feature/plugin composition;
- a manual LicoLite MCP plugin installation workflow for explicitly selected
  local agents.

These workflows never run at startup or on a schedule. Installing or enabling the
plugin does not authorize any user or client data transfer. Each local file sent
outside the device requires a new, file-bound approval and remains cancellable
until commit.

## Module-Scoped Regression

List modules and preview the selection before running the smallest closure:

```bash
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
npm run client:regression -- --module <module-id>
npm run client:regression -- --changed-from <ref>
```

Run `npm run client:verify` exactly once only after all changed modules and their
integration edges pass. Do not repeat the full regression during development or
consume resources required by parallel work.

## Platform Builds

```bash
npm run client:package:plan
npm run client:build:macos
npm run client:build:windows
npm run client:build:linux
npm run client:build:android
```

macOS, Windows, Ubuntu, Android, and iOS development, ordinary verification,
packaging, GitHub Release, and each platform store/channel are separate claims.
Public artifacts expose only minimum consumer-verification metadata and no user
or client runtime information.
