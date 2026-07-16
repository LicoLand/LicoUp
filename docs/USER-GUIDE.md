# Lico Arc User Guide

English · [简体中文](USER-GUIDE.zh-CN.md) · [Home](../README.md)

Lico Arc is an early alpha client. Check the
[support matrix](releases/client-support-matrix.md) before using a platform or
feature for important work.

## Start the client

Install Node.js 22 or 24, Flutter stable, and Rust stable. Then run:

```bash
npm ci
npm run client:get
```

Common launch and build commands are:

```bash
npm run client:run:macos
npm run client:run:android
npm run client:run:ios
npm run client:build:macos
npm run client:build:linux
npm run client:build:windows
npm run client:build:android
```

A command being present does not mean that its platform is fully supported.

## Work with local agents

1. Open **Agents**.
2. Let Lico Arc find supported agents installed on the device.
3. Choose an agent.
4. Start a new conversation or continue an existing one when the adapter
   supports it.

Agent history, settings, and process details stay local. Lico Arc shows safe
summaries in the interface instead of exposing raw tool input, credentials, or
local paths.

Discovery checks the application sources appropriate to the current platform,
including package managers and common executable/configuration locations. The
probes run concurrently with a fixed bound. Normalized paths and configuration
references are cached only in the client so later launches do not need a full
scan.

When continuing a conversation, Lico Arc prefers the agent's native attach or
resume operation. If an adapter cannot accept input during a running turn, the
client keeps projecting its live output and starts the next turn only after the
agent has completed its reply.

## Manage local data

- Skills are installed and managed on the device. Updates use only a source the
  user configured, such as a mirror or GitHub repository. Automatic checks run
  only after that schedule is explicitly enabled. Deletion always names one or
  more target agents.
- Skill usage counts come from actual local invocation events and can be viewed
  by time window; browsing or installing a skill does not count as use.
- Conversation backups go to a directory chosen by the user. Choose all
  conversations or an exact keyword filter before previewing and starting the
  local backup job.
- Token usage views are calculated from local records. The default window is
  the latest 30 days; choose the agent or model dimension and a custom window
  when needed.
- Logs and diagnostics stay local unless the user saves an explicit, redacted
  copy.

Do not attach raw logs, histories, paths, or device details to a public issue.

## Enable optional collaboration

LicoLite collaboration is a separate plugin. The default client does not load
or query it.

1. Open **Settings** and choose the optional collaboration area.
2. Choose a GitHub repository and an exact immutable commit.
3. In a separate action, import and authenticate the expected signing key.
4. Review the signed runner, complete package inventory, components, and local
   target; then install and enable the plugin manually.
5. For a local deployment, assemble the selected components and start the fixed
   signed external runner with a separate manual action. Assembly does not start
   the server automatically. Stop or remove it from the same area.
6. For MCP installation, select one or more plugins and one or more local
   agents, then review the exact local changes before applying them.

The Lico Arc source tree does not contain the LicoLite server runner. A client
build therefore proves neither that a server artifact was obtained nor that a
deployment was started.

Installation or enablement never grants continuing transfer permission. If an
MCP operation would reach an external service, its bridge first creates a
non-transmitting preview. Review the destination, purpose, exact request, and
each selected file in Lico Arc, complete the platform authentication prompt,
and approve only that operation. The matching preview can be claimed exactly
once. Changing the file, destination, purpose, request body, or session makes
the digest mismatch; cancellation, expiry, or reuse also fails closed. If
protected platform authentication is unavailable, external transfer remains
disabled.

## Send to another client

Only use the protected peer flow for user content:

1. Choose the receiving Lico Arc client.
2. Review the exact message or file and its destination.
3. Approve that one transfer.
4. Lico Arc encrypts the content on the sending device.
5. The receiving client verifies and decrypts it.

The relay is not trusted with plaintext. Lico Arc sends it only encrypted
content and the minimum routing data needed for the transfer. Changing the peer
or content requires a new approval.

## Verify a release file

Use only files attached to the project's release page. Compare the file digest
and signature with the public verification data supplied for that release. A
build result is not a release claim by itself.

For a deeper view of the client, read the [architecture guide](ARCHITECTURE.md).
