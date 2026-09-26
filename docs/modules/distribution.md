# Distribution developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

Public packages are immutable and resolved from declared capabilities. Source, package bytes and acceptance evidence are distinct facts. Building locally does not authorize signing or publication.

[Deployment Profiles](../architecture/DEPLOYMENT-PROFILES.md)

## Role responsibilities

**Design:** inspect package contracts and included resources. If a shared contract changes,
include its producer and consumers; consult [extension-platform](extension-platform.md) or
[development](development.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:distribution` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `tests/contract/distribution/`, `tools/architecture-graph/test/`,
`tools/release/tests/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
