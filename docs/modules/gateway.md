# Model gateway developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

The local gateway mediates admitted provider calls. Preserve typed failures and accounting, and never publish credentials, prompts or backend payloads. Routing metadata does not grant permission to spend or transfer data.

[Model Registry](../architecture/MODEL-REGISTRY.md)

## Role responsibilities

**Design:** inspect provider calls and admitted conversation consumers. If a shared contract changes,
include its producer and consumers; consult [agent-runtime](agent-runtime.md) or
[catalogs](catalogs.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:gateway` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Rust unit tests are colocated in `crates/licoup-native/src/domain/` and
`sdk/model-provider/src/`; provider integration tests are under
`tests/integration/model_providers/`. The fixed command covers both the
gateway and its provider runtime.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
