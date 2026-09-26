# Conversation developer guide

Updated: 2026-09-26

[Developer entry](../RUNBOOK.md)

Canonical Conversation owns membership, events and durable lifecycle. Runtime adapters report facts; presentation and workflow execution cannot become competing conversation authorities. Private held inputs never enter shared events.

[Conversation Domain](../architecture/CONVERSATION-DOMAIN.md)

## Storage and query design

Design tables, constraints and indexes around actual access patterns. Filter, order
and page history in the database instead of loading entire histories for in-memory
merging. Use prepared statements and appropriately scoped transactions for repeated
writes. Justify joins, indexes and caches by the workload; avoid repeated per-row
queries and redundant materialization. Inspect representative SQLite query plans
when changing a costly access path. Keep engine-specific query operations in the
storage owner; use capabilities supported by SQLite rather than introducing stored
procedure infrastructure. Validate changed behavior with representative synthetic
data, without adding a permanent performance gate for every query.

For schema changes, follow the [data migration workflow](data-migration.md#development-and-migration-boundaries).

## Role responsibilities

**Design:** inspect membership, durable events and runtime bindings. If a shared contract changes,
include its producer and consumers; consult [workflow](workflow.md) or
[agent-runtime](agent-runtime.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:conversation` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `crates/licoup-conversation/tests/`, `tests/contract/client/`.
Native history parser and projection tests live under
`crates/licoup-native/src/domain/conversation/history/tests/` and
`crates/licoup-native/src/domain/conversation/history/message_projection/tests/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
