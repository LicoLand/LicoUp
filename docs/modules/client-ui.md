# Client UI developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

Composition assembles features; application controllers own use cases; projections feed rendering. UI does not call native RPC directly or duplicate authoritative business state. UI interaction models describe observable behavior.

[Client Native Interaction](../architecture/CLIENT-NATIVE-INTERACTION.md)

## Role responsibilities

**Design:** inspect projected contracts and application use cases. If a shared contract changes,
include its producer and consumers; consult [presentation](presentation.md) or
[native-bridge](native-bridge.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:client-ui` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `apps/desktop/test/`, `apps/desktop/test/ui_state_machine/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
