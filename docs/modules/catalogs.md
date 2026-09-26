# Models, usage and local Skills developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

Catalog owners provide capability, price and usage facts to projections. A source catalog is not proof of successful live execution. Local user Skills and bundled public Skills never import maintainer knowledge.

[Model Registry](../architecture/MODEL-REGISTRY.md)

## Role responsibilities

**Design:** inspect catalog ownership and usage/model consumers. If a shared contract changes,
include its producer and consumers; consult [agent-runtime](agent-runtime.md) or
[client-ui](client-ui.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:catalogs` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `crates/licoup-native/src/domain/skill_hub/tests/`, `tests/contract/client/`,
`tests/integration/usage_sources/`; analytics and usage SDK unit tests are
colocated under `components/analytics/src/` and `sdk/usage-source/src/`.
Agent Hub and usage ledger unit tests live with their modules under
`crates/licoup-native/src/domain/agent_hub/` and `crates/licoup-native/src/domain/agent_usage/`.
Provider quota parsing tests live under `crates/licoup-native/src/domain/provider_quota/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.

The optional [refactoring Skill](../../crates/licoup-native/resources/licoup-refactor/SKILL.md)
ships as a resource under `modules/user-skills/licoup-refactor/` in desktop bundles.
Select its SKILL.md explicitly when needed; it is not appended to conversation
prompts or installed into an Agent's default context. The operation guide remains
the default product guidance.
