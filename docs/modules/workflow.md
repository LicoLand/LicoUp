# Workflow developer guide

Updated: 2026-09-26

[Developer entry](../RUNBOOK.md)

Pure definitions and transitions, execution ports and transactional persistence remain separate. The core cannot perform I/O; runtime cannot own a second history.
Process exit is not lease revocation: recovery holds an unexpired effect claim and records a started effect as unknown only after the exact owner lease has expired or been revoked and that owner is explicitly declared lost.

[Assistant Workflow Control](../architecture/ASSISTANT-WORKFLOW-CONTROL.md)

## Role responsibilities

**Design:** inspect execution ports and transactional effects. If a shared contract changes,
include its producer and consumers; consult [conversation](conversation.md) or
[agent-runtime](agent-runtime.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Use deterministic DSL inputs and the actual compiler, transition configuration,
executor and scheduler to verify the approved semantics before handoff. Exercise
guards, effects, dependency ordering, cancellation and recovery with synthetic
events and controlled clocks or ports where relevant. Keep the pure core in memory;
use temporary storage and local process fixtures for integration boundaries. A
stubbed external Agent may supply protocol events, but must not replace the workflow
logic under test. Verify production wiring separately from pure-core behavior.
Real Agent output quality and vendor behavior remain separately assigned live
acceptance; they are not prerequisites for proving these engine invariants.

Run `npm run verify:workflow` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `crates/licoup-workflow/tests/`, `crates/licoup-workflow-runtime/tests/`, `crates/licoup-workflow-store/tests/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
