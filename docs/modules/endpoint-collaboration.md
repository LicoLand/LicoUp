# Endpoint and collaboration developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

Endpoint-owned ports separate key custody and trust decisions from fixed protocol bindings and relay transport. Stations are untrusted transport. Approval comes from the platform, never a caller-supplied boolean.

[Security And Data Boundary](../architecture/SECURITY-AND-DATA-BOUNDARY.md)

## Role responsibilities

**Design:** inspect admission, key custody and protocol bindings. If a shared contract changes,
include its producer and consumers; consult [conversation](conversation.md) or
[native-bridge](native-bridge.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:endpoint-collaboration` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `crates/licoup-protocol-bindings/tests/`, `crates/licoup-native/tests/v7_endpoint_storage/`, `crates/licoup-native/tests/v7_peer_ingress/`, `tests/contract/client/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
