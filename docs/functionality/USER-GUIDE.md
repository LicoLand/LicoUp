# LicoUp User Guide

English (normative) · [简体中文](USER-GUIDE.zh-CN.md) · [Documentation](../README.md) · [Project](../../README.md)

LicoUp is an early alpha client. Check the
[compatibility matrix](../COMPATIBILITY.md) before using a platform or
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
2. Let LicoUp find supported agents installed on the device.
3. Choose an agent.
4. Start a new conversation or continue an existing one when the adapter
   supports it.

Agent history, settings, and process details stay local. LicoUp shows safe
summaries in the interface instead of exposing raw tool input, credentials, or
local paths.

On the Messaging desktop Agents surface, the conversation composer keeps
secondary runtime controls in glass capsules above the input:

- **Workspace** — the directory the next turn will use. Prefer the selected
  conversation’s own project path from native history; choose a specific
  project directory when starting fresh. Personal roots such as the home folder
  or media libraries are refused because the agent would index the whole tree.
- **Model / reasoning effort** — open the runtime capsule to set **Model** and
  **Reasoning Effort** as parallel rows. Leaving the model on **Auto** uses the
  agent’s native default. Effort options follow the effective model (the
  selected model, or that native default when Auto is selected).

Hover the top-right conversation, details, or notification controls to open
floating glass cards anchored to those icons; there is no conversation-details
sidebar.

Discovery checks the application sources appropriate to the current platform,
including package managers and common executable/configuration locations. The
probes run concurrently with a fixed bound. Normalized paths and configuration
references are cached only in the client so later launches do not need a full
scan.

When continuing a conversation, LicoUp prefers the agent's native attach or
resume operation. If an adapter cannot accept input during a running turn, the
client keeps projecting its live output and starts the next turn only after the
agent has completed its reply.

**Cursor** send always uses the Agent CLI lane (`cursor-agent`), not the in-app
IDE Agent panel. Cursor IDE chats and CLI chats use separate stores; CLI
`--resume` does not load IDE history. When you continue an IDE-listed Cursor
conversation from LicoUp, the first send opens a **new** CLI session and injects
a one-time handoff: the IDE composer id, `state.vscdb` path/key prefixes, and
the last IDE assistant return, followed by your message. Later sends on that
CLI session resume normally without repeating the handoff.

The top contact **Lico** opens a LicoUp-owned **group Conversation** where each
agent is a peer participant. The composer shows the workspace capsule, a
Flywheel capsule for **Current Conversation**, and a circular edit control.
Hover the Flywheel capsule to pick an agent and that agent's model (Gateway
providers A–Z for Lico Agent; native catalogs for third-party agents). Click the
capsule or the edit control to open the full Adaptive Flywheel editor.

**Lico Agent** is a separate first-party runtime in the agent list (not the
group entry itself). When chatting with it, choose Agent or Plan mode; Plan
mode may only write the bound local plan file under OS sandbox. See
[Lico Agent](../protocols/lico-agent.md).

Open **Adaptive Flywheel** to choose everyday conversation agents and configure
the delivery route table. The flywheel is the only route-selection authority:
each delivery role and difficulty resolves to one agent, model, and reasoning
effort, and LicoUp freezes that decision in the dispatch receipt. Delivery
ownership remains native LicoUp even when an optional adapter plugin is ready.

The native delivery scheduler consumes the persisted Plan and Checkpoints. It
selects the complete eligible frontier, preserves stable order and bounded
native lanes, and advances checkpoints only after terminal settlement. The MCP
caller can start, authorize, inspect, or explicitly cancel a workflow; it cannot
submit tasks, choose routes, bind conversations, or accept a Reviewer. Independent
workflows can run concurrently while each workflow and Task attempt stays
ordered.

Assistant still controls the everyday conversation picker. Its model and
reasoning controls remain separate from delivery role routing. Save Adaptive
Flywheel after changing a route so the native scheduler reads the new persisted
state; the client does not expose the state file or executable paths.

## Connect OpenClaw or Hermes in your VM

This desktop flow is for a VM you control. Install and configure OpenClaw or
Hermes in the VM first. OpenClaw's ACP command must be able to reach its
configured Gateway inside the VM.

Open **Agents** while your local OrbStack machines are running. LicoUp
automatically checks the executable on `PATH` plus these install families:

- OpenClaw: the installer prefix under `~/.openclaw`, the user wrapper under
  `~/.local/bin`, common npm/pnpm/Bun/Volta/Nix user bins, and system bins.
- Hermes: `~/.local/bin`, the installer venv under
  `~/.hermes/hermes-agent/venv`, the Hermes/Nix user bins, and system bins.

These locations follow the
[OpenClaw installer](https://docs.openclaw.ai/install/installer) and
[Hermes installation guide](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/getting-started/installation.md).
For Hermes, LicoUp checks the optional ACP package first. A default Hermes
installer environment without that extra uses Hermes'
[built-in TUI Gateway JSON-RPC](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/programmatic-integration.md)
instead; LicoUp does not install or change anything in the VM. Select the
discovered VM target to list sessions, open an existing session, or create a
new conversation.

For a non-OrbStack VM or a nonstandard install:

1. Configure system OpenSSH key or agent authentication for the VM and add its
   host key to the system `known_hosts` file. LicoUp uses strict host checking
   and noninteractive authentication, so it will not open a password, key, or
   first-connect trust prompt.
2. Choose **Add target**, then select **OpenClaw** or **Hermes**.
3. Set **Runtime location** to **Virtual machine (SSH)**.
4. Enter the VM host, optional SSH port and user, the executable name or
   absolute executable path inside the VM, and an absolute VM working directory
   beginning with `/`.
5. Add and select the target.

The conversation header shows the exact SSH destination before you send.

LicoUp starts `openclaw acp` or `hermes acp` through the system SSH client and
uses ACP `session/list`, `session/load`, and the native new/prompt lifecycle. It
does not read or copy the VM's private history database. Passwords and private
keys are not accepted as target fields, local MCP server descriptors are not
forwarded into the VM, and automatic and manual VM connections are excluded
from the fast discovery cache. Pressing **Send** gives the selected VM agent the
exact prompt over the authenticated SSH transport.

## Manage agent adapter plugins

Open **Plugin Management** from the desktop navigation to inspect every
packaged agent adapter. Native Support and Native ACP lanes need no additional
installation. A LicoUp Adaptive Bridge owns the target-specific adaptation
when neither category applies. Install or uninstall appears only when its
catalog entry declares a real lifecycle action. Each bridge action requires
direct confirmation and changes only LicoUp-owned files or namespaced hooks.
Discovery and installation do not by themselves prove that an agent is ready
for conversation. Plugin readiness is reported separately from the native
delivery and Adaptive Flywheel authorities.

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
  the latest 30 days; choose the Agent, Model, or Workflow dimension and a
  custom window when needed. Workflow shows the native Plan → Task → dispatch
  hierarchy, exact coverage, and the main-versus-subordinate split using
  numeric-only ledger facts. LicoUp owns scheduling, Adaptive Flywheel owns
  route selection, and raw native conversation locations remain a private
  handoff. The view does not expose prompts, replies, tool payloads, summaries,
  compaction, or cache controls; active work plus the newest twenty terminal
  rollups are bounded by the native ledger.
- Logs and diagnostics stay local unless the user saves an explicit, redacted
  copy.

Do not attach raw logs, histories, paths, or device details to a public issue.

## Enable optional collaboration

Meshrix collaboration is a separate plugin. The default client does not load
or query it.

1. Open **Plugin Management** and choose the collaboration plugin area.
2. Choose a GitHub repository and an exact immutable commit.
3. In a separate action, import and authenticate the expected signing key.
4. Review the signed runner, complete package inventory, components, and local
   target; then install and enable the plugin manually.
5. For a local deployment, assemble the selected components and start the fixed
   signed external runner with a separate manual action. Assembly does not start
   the server automatically. Stop or remove it from the same area.
6. For MCP installation, select one or more plugins and one or more local
   agents, then review the exact local changes before applying them.

The LicoUp source tree does not contain the Meshrix server runner. A client
build therefore proves neither that a server artifact was obtained nor that a
deployment was started.

Installation or enablement never grants continuing transfer permission. If an
MCP operation would reach an external service, its bridge first creates a
non-transmitting preview. Review the destination, purpose, exact request, and
each selected file in LicoUp, complete the platform authentication prompt,
and approve only that operation. The matching preview can be claimed exactly
once. Changing the file, destination, purpose, request body, or session makes
the digest mismatch; cancellation, expiry, or reuse also fails closed. If
protected platform authentication is unavailable, external transfer remains
disabled.

## Preview a protected transfer to another client

This flow uses the
[current retiring endpoint-protection Preview](../STATUS.md). It can be
carried through the candidate `licoarc.relay.v1` outer adapter, and one bounded
two-fresh-endpoint scenario has been locally verified through an actual
BadTower candidate. This does not establish a Published Lico Arc Protocol
Line, stable neutral-station support, release, or hosted operation. Only use
the protected peer flow for test or explicitly accepted preview content:

1. Choose the receiving LicoUp client.
2. Review the exact message or file and its destination.
3. Approve that one transfer.
4. LicoUp encrypts the content on the sending device.
5. The receiving client verifies and decrypts it.

The current transport is not trusted with plaintext. LicoUp sends it only
encrypted content and the minimum routing data needed for the transfer.
Changing the peer or content requires a new approval. The current inner
preview is not a Lico Arc Profile and has no future compatibility promise; it
is to be retired directly when a complete pinned Lico Arc Protocol Line
replaces it.

## Verify a release file

Use only files attached to the project's release page. Compare the file digest
and signature with the public verification data supplied for that release. A
build result is not a release claim by itself.

For a deeper view of the client, read the [architecture guide](../architecture/README.md).
