# Extension platform developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

Contracts describe capabilities; the native host owns admission, isolated processes and package lifecycle. Packages cannot bypass host authorization. Uninstall preserves user data and history.

[Extension Platform](../architecture/EXTENSION-PLATFORM.md)

## Role responsibilities

**Design:** inspect extension contracts, admission and host effects. If a shared contract changes,
include its producer and consumers; consult [agent-runtime](agent-runtime.md) or
[distribution](distribution.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:extension-platform` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `crates/licoup-extension-contracts/tests/`, `tests/integration/agent_sdk/`, `crates/licoup-native/tests/package_lifecycle/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
