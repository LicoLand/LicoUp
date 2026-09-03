# LicoUp Subagent MCP

English · [简体中文](subagent-mcp.zh-CN.md) · [Agent adapter architecture](../architecture/AGENT-ADAPTERS-ARCHITECTURE.md)

The implemented authority is `domain/subagent_mcp`, the parameterized
`core/mcp` engine, `licoup-agent-runtime`, `licoup-agent-adapters`, and the
private Canonical Conversation store. The public contract is frozen by
`schemas/subagent_mcp/subagent_mcp.schema.json`.

## Common contract

- Primary protocol revision: `2025-06-18`; compatible inbound revision:
  `2025-11-25`
- Server: `lico-up-subagents` `0.11.0`
- Transport: a desktop-owned authenticated loopback Streamable HTTP service
- Provider entry: one tool-free stdio connector
- Providers in this mesh: Codex, Cursor, and Antigravity

The exact ordered tool catalog is:

1. `lico_assistant_profiles`
2. `lico_assistant_workflow_execute`
3. `lico_assistant_workflow_inspect`
4. `lico_assistant_workflow_cancel`
5. `lico_subagents_list`
6. `lico_subagent_probe`
7. `lico_subagent_delegate`
8. `lico_subagent_continue`
9. `lico_subagent_cancel`

All input schemas are closed. The connector contains no catalog or provider
logic and performs one HTTP attempt for each stdio frame.

## Assistant Profiles and temporary workflows

The first four tools preserve the designated-Assistant contract. Only the
exact active Agent Membership currently designated as the Conversation's
Assistant may read ranked Membership Profiles or execute, inspect, and cancel
an Assistant-authored temporary workflow. Inspect and cancel recover the
stored Conversation and Assistant Membership from the run before authorizing
the caller; a caller cannot select a different authority through tool input.

Workflow execution accepts closed workflow, binding, filter, input, and
idempotency fields. Every referenced binding must resolve to an active target
Membership with an installed executable `runtime.message.send` route before
the persistent host is asked to admit the run. The persistent Conversation host remains the sole
workflow and turn owner; the MCP service does not create a second scheduler,
history, or terminal-output store. Native identities, paths, prompts, and Agent
output remain outside Profile and workflow receipts.

## Authority and lineage

Every effect is bound to an authenticated caller Membership and an exact target
Membership in the same Canonical Conversation. Both must be active Agent
Memberships. The store commits a durable dispatch claim before target runtime
work starts. It rejects self-calls, duplicate active edges, cross-Conversation
calls, repeated ancestors, cycles, and depth above four without starting an
Agent effect.

Inbound `tools/call` for `lico_subagent_delegate`, `lico_subagent_continue`,
and `lico_subagent_cancel` is recorded on Canonical Conversation as
`subagent_mcp_inbound`. Mesh proof reads those rows together with
`subagent_dispatch_claims` and the target Membership PersistentTurn. It does
not scrape the caller Agent's conversation or projected `tool-call` parts.

Delegation always opens a Membership-scoped PersistentTurn. Continue resolves
the adapter-owned native identity from the private runtime binding; callers do
not submit or receive a native session or path. Cancel addresses only an active
claim. An uncertain native cancellation becomes `reconciliation-required` and
is never reported as completed.

## Registry, admission, and readiness

`McpCallerIntegration` owns provider registration, install, identity,
readiness, removal, and fresh-session behavior. `SubagentRuntimeAdapter` owns
capabilities, exact native identity, send, continue, observe, active cancel,
cleanup, and transition projection. One registry joins both ports. The MCP
application has no provider branch.

Execution admission is separate from conversation-readiness observation. It
requires an exact provider identity, a registered adapter, the requested
operation capability, and an installed executable `runtime.message.send`
route. The authenticated direct MCP caller, same-Conversation active non-self
Memberships, durable claim rules, selected model, and service health remain
independent fail-closed gates. Once admitted, the first discovery, binding,
authentication, permission, launch, protocol, session, model, dispatch, or
readback failure keeps its typed stage contract.

Conversation readiness never synthesizes transport or permission and never
vetoes execution. It remains observational input only for
`lico_subagent_probe` and other inventory projections.

`lico_subagents_list` and `lico_subagent_probe` are read-only inventory and
readiness surfaces. They inspect the exact Codex, Cursor, and Antigravity
targets without launching a provider, refreshing history, opening a model
owner, or persisting discovery state. Their projection is limited to safe
provider, status, driver, readiness, capability, and blocker facts.

## Provider behavior

| Provider | Caller registration | Target lane | Guidance | Active control |
| --- | --- | --- | --- | --- |
| Codex | External `lico-up-codex` package `0.2.0` | App Server stdio JSON-RPC | native `developerInstructions` | native steer and interrupt |
| Cursor | namespaced user MCP entry | create-chat/resume CLI over PTY | one ordinary unmarked ephemeral prefix | supervised active cancel, then exact resume |
| Antigravity | namespaced user MCP entry | OAuth/permission preflight, Hook receipt, CLI over PTY | one ordinary unmarked ephemeral prefix | supervised active cancel, then Hook-bound resume |

Cursor and Antigravity never receive `privateInstructions`. Generated guidance
is removed before driver invocation and is not stored in visible Event/Part.
Exact user Event text remains canonical.

## Local security and privacy

The HTTP listener binds only to loopback. Private discovery contains an
ephemeral per-provider bearer token and is hardened under client state. MCP
sessions and connection counts are bounded. Shutdown removes only the discovery
generation owned by that supervisor.

Registration changes require one digest-bound, single-use approval. Cursor and
Antigravity mutate only the namespaced LicoUp-owned entry; a foreign entry,
multiple Antigravity config candidates, or a changed config fails closed.
The same approval delivers the embedded `lico-up-subagents` Skill through the
provider's user Skill Hub root; foreign Skill content also fails closed.
Public responses omit config bodies, credentials, endpoints, native sessions,
paths, prompts, and Agent output.

## Independent verification routes

`tests/product-e2e/cli/subagent-mcp/upstream.mjs` verifies startup recognition.
It first initializes the desktop-owned service and checks the exact ordered
tool catalog. It then runs the standalone Codex, Cursor, and Antigravity
startup probes concurrently. Each probe reads only the provider's standard MCP
startup/list/registry surface: it sends no turn, opens no conversation, and
does not install, remove, or rewrite configuration. This verification does not
depend on a Codex custom plugin. Codex receives one process-local standard MCP
declaration through its configuration override and the override is never
persisted. Cursor and Antigravity use their supported read-only `mcp list`
commands; if the owned registration is absent, they report
`installer_configuration_required` without changing provider configuration.

`tests/product-e2e/cli/subagent-mcp/downstream.mjs` is a separate direct-effect
route. Its default is a zero-effect preflight. Only explicit `--live` execution
may prepare a local verification Conversation and send one authenticated
`lico_subagent_delegate` request directly to the Streamable HTTP service for
each unverified target. No Caller Agent process or Caller Agent conversation is
started. Pass requires the matching inbound delegate record, durable dispatch
claim, selected target Membership, and its PersistentTurn dispatch state; Agent
output is neither read nor retained.

Preflight resolves the three installed Agent versions, executable
`runtime.message.send` routes, and reported model inventories through the
existing LicoUp target and Agent Hub surfaces. Agent Hub invokes the existing
bounded `--version` recipe against the exact target-discovery executable
binding, including Cursor's bound `cursor-agent`; it never rescans `PATH` or
projects the binding into a card or receipt. Conversation readiness is not an
admission input. The verifier then validates the MCP service with each non-self
caller identity that would be used. Missing or unsafe versions, a missing
executable route, an unavailable approved model, or unhealthy service state
therefore stops before Conversation creation or paid work.

Live selection admits only the first available approved low-cost model: Codex
uses `gpt-5.3-codex-spark`, then `gpt-5.4-mini`; Cursor uses `composer-2.5`;
Antigravity uses the configured Gemini 3.7 Flash alias. There is no Auto or
expensive fallback. The primary candidate for each Agent comes from the shared
conversation-verification model authority; only the Codex Mini fallback is
added at this route boundary. The live route holds one exclusive untracked
lease while it performs the final Manifest reread and target record write. It
skips an exact passing App Version, Target Agent, and Target Agent Version
credential before Conversation creation or payment, performs at most one
`tools/call` per remaining target, never retries internally, and never breaks
another live lease by timeout. A structured `licoup.mcp.error.v1` result is
retained only when its code, stage, retryability, and recovery are in the closed
safe sets; only its allowlisted reason code may enter Notes.

The latest-App-Version Manifest is
`tests/product-e2e/cli/subagent-mcp/interop-manifest.yaml`. Its key is App
Version plus Target Agent, with at most one Codex, Cursor, and Antigravity row.
Skip also requires the current Target Agent Version and `Results: passed`.
Rows have exactly App Version, Caller Agent, Caller Agent Version, Target Agent,
Target Agent Version, Results, and Notes, in that order. Caller fields identify
the authenticated non-self Membership. Results is `passed` or `failed`; Notes
is empty or an allowlisted reason code. Writes are atomic, and the closed parser
rejects duplicate, extra, reordered, or unsafe values. Endpoints, tokens,
prompts, local identifiers, paths, native identities, models, and runtime
content never enter the Manifest or console receipt.
