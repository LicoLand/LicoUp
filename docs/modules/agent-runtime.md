# Agent runtime and MCP developer guide

Updated: 2026-09-28

[Developer entry](../RUNBOOK.md)

Runtime supervises sessions and adapters translate vendor protocols. Relay the Agent’s natural output faithfully; do not impose a reply schema. Conversation identity and permissions remain with the caller’s admitted membership.

**One Agent is one program and one crate.** All of a specific Agent’s adapter code — launch, framing, protocol parsing, failure and approval mapping, and its own declaration — lives in the crate that produces that Agent’s executable, and that crate depends only on the extension contract. The host keeps discovery, the declarations as data, the registry, the work-context seam, the carrier and the local service control plane, and **no vendor protocol branch**. Removing an Agent’s package removes the Agent: the capability is reported unavailable with a recovery and the client starts normally. See [Agent adapter boundaries](../architecture/AGENT-ADAPTERS-ARCHITECTURE.md#the-program-boundary).

[Agent Adapters Architecture](../architecture/AGENT-ADAPTERS-ARCHITECTURE.md)

**What every adapter program shares lives in `licoup-agent-adapter-sdk`.** The byte-line
ingress contract (its `adapters::NativeLineParser`), the adapter declaration each parser
reports, the closed transition vocabulary and its arrival-ordered reducer, the
delta/cumulative text reconciliation, the process-local driver registry, the registry
lookup and the replay harness are one crate, and that crate names no Agent. Which parsers
exist is composition's answer: this host composes its thirteen per-Agent parsers — still
under `platform/native_agent_parser/`, one subtree per Agent, until each Agent's own crate
exists — into the port the SDK declares. The two protocol-agnostic queries an Agent answers
about itself, the normalized transitions of one execution outcome and the validity of a
durable native session identity, are declared by the SDK and answered by that Agent's own
parser; nothing above the SDK reaches into `licoup-native` for them.

**How the host reaches an Agent lives in `licoup-agent-drivers`.** The work-context
binding contract, the adapter transport, the production host driver and the C01 effect port
are one crate, and that crate names no Agent either: the Agent's protocol adapter, its
driver execution and the host's own lane reach arrive through the port the crate declares,
and composition answers it. This host composes the port today with the Codex and Pi
protocol adapters and their driver executions under `platform/work_context_ports/`, and
with `platform::dispatch_lane_operation`; each Agent's half travels to that Agent's own
crate when it exists. The former `platform::work_context_ports` paths stay reachable
through the host's composition module, so no caller of the seam changes when the seam moves
down.

## Role responsibilities

**Design:** inspect semantic operations and vendor transport translation. If a shared contract changes,
include its producer and consumers; consult [conversation](conversation.md) or
[extension-platform](extension-platform.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:agent-runtime` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `crates/licoup-agent-runtime/tests/`, `tests/contract/client/`, `tests/product-e2e/cli/subagent-mcp/`, `crates/licoup-mcp/tests/`, `crates/licoup-mcp/src/tests/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
