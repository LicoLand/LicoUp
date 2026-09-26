# Workflow implementation boundaries

Updated: 2026-09-25

[简体中文](ASSISTANT-WORKFLOW-CONTROL.zh-CN.md) · [Workflow module](../modules/workflow.md)

Keep three owners separate: [pure core](../../crates/licoup-workflow/src/) compiles
and reduces definitions; [runtime](../../crates/licoup-workflow-runtime/src/) admits
and drives work through ports; [store](../../crates/licoup-workflow-store/src/)
persists transactions. The core does not perform process, network or database IO.

User Graph definitions are runtime data. Register their schema/provider and executor,
not private instances or a second documentation graph. Observation and tool callbacks
carry runtime facts; silence and elapsed time do not prove completion. Natural Agent
replies remain unconstrained. Durable state changes precede downstream notifications.

Pause, cancel, detach and delete have different effects. Preserve explicit authority,
single-writer admission and idempotent recovery across those boundaries. Changes to
an execution port must include its callers and implementers in the same complete PR.

Executable [IR](../../crates/licoup-workflow/src/ir.rs) and
[reducer](../../crates/licoup-workflow/src/machine.rs) own current behavior.
[Adaptive Flywheel](../functionality/ADAPTIVE-FLYWHEEL.md) explains user configuration.
Run `npm run verify:workflow`; use `npm run repo:state-machines -- --list` for the
machine registry and review any reported configuration migration gaps.
