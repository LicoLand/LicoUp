---
name: lico-arc-orchestration
description: Preview, submit, wait on, message, approve, or cancel governed workflows through the local Lico Arc control plane.
---

# Lico Arc orchestration

Use this skill when work should be delegated through a user-configured Lico Arc workflow. Lico Arc remains the workflow and dispatch authority; this plugin only submits control-plane commands and reads privacy-minimal receipts.

1. Inspect readiness with `lico_agent_capabilities`.
2. Use `lico_strategy_preview` before submitting when the selected policy needs confirmation.
3. Submit an opaque, digest-bound input artifact with `lico_workflow_submit`.
4. Suspend on `lico_workflow_wait` with the last returned cursor. It wakes on bounded child progress, message delivery, or terminal state; use `lico_workflow_status` to reconnect or page the durable journal.
5. While the child is active, send an already-authorized, digest-bound message artifact with `lico_workflow_message`. `native_steer` means the native protocol acknowledged in-turn guidance. `bridge_interrupt_resume` means Lico Arc interrupted through the agent's supervised native control and will resume the exact session. `bridge_follow_up` is the explicit fail-safe for the next safe boundary when no active binding or interrupt acknowledgement is available.
6. Resolve an approval with `lico_workflow_approve`, or stop the workflow with `lico_workflow_cancel`.

Independent workflows may wait and dispatch concurrently. Keep messages for one workflow ordered, advance cursors monotonically, and never treat a wait timeout as workflow failure.

Never infer or embed agent selection in the plugin. Never treat MCP disconnect as workflow cancellation. Do not ask the tool for private transcripts or provider output; only opaque artifacts and redacted workflow receipts cross this boundary.
