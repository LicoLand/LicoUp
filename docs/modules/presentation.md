# Presentation packages developer guide

Updated: 2026-09-25

[Developer entry](../RUNBOOK.md)

Immutable contracts have no Flutter or runtime dependencies. Runtime prepares and caches display resources; widgets render them. Host RPC and business state remain outside the rendering packages.

[Conversation Vertical Contract](../architecture/CONVERSATION-VERTICAL-CONTRACT.md)

## Role responsibilities

**Design:** inspect immutable view contracts and renderer ownership. If a shared contract changes,
include its producer and consumers; consult [client-ui](client-ui.md) or
[extension-platform](extension-platform.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:presentation` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `packages/presentation_contract/test/`, `packages/presentation_runtime/test/`, `packages/presentation_flutter/test/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
