# Agent runtime and MCP developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

Runtime supervises sessions and adapters translate vendor protocols. Relay the Agent’s natural output faithfully; do not impose a reply schema. Conversation identity and permissions remain with the caller’s admitted membership.

[Agent Adapters Architecture](../architecture/AGENT-ADAPTERS-ARCHITECTURE.md)

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
