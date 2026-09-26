# Native bridge developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

Generated DTO contracts define the Rust/Dart boundary. Update schema and generated sides together. Transport carries typed operations and errors without owning domain decisions.

[Client Native Interaction](../architecture/CLIENT-NATIVE-INTERACTION.md) · [Native Cli](../architecture/NATIVE-CLI.md)

## Role responsibilities

**Design:** inspect schema generators and both Rust/Dart consumers. If a shared contract changes,
include its producer and consumers; consult [conversation](conversation.md) or
[client-ui](client-ui.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:native-bridge` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `tests/contract/client/`, `apps/desktop/test/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
