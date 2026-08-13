# LicoUp Subagent MCP

English (normative) · [简体中文](subagent-mcp.zh-CN.md) · [Architecture](../architecture/README.md)

Authority: `crates/licoup-native/src/bin/lico-subagent-mcp.rs`,
`domain/delivery_workflow.rs`, and `platform/delivery_workflow_runtime.rs`.
This document describes the current native delivery contract; it does not
define a second scheduler.

## Delivery lifecycle

The MCP is a thin caller surface. Delivery exposes only four operations:

- `lico_delivery_start` creates or resumes a persisted Plan.
- `lico_delivery_authorize` authorizes the current Plan digest.
- `lico_delivery_status` reads persisted status and the Plan next action.
- `lico_delivery_cancel` explicitly cancels the workflow and relays native
  cancellation to active conversations.

The caller cannot submit a frontier, bind a Worker, select a route, accept a
Task, or open a Reviewer. The native scheduler obtains the complete eligible
frontier from the current `DeliveryPlanEngine`, orders it stably, and dispatches
through bounded native lanes. Independent workflows may run concurrently;
dispatches for one workflow, Task attempt, and native session remain ordered.
Waiting for a terminal event does not consume a message lane.

Each dispatch follows one persisted sequence:

1. Adaptive Flywheel selects the role and difficulty route.
2. LicoUp freezes the agent, model, reasoning-effort, and route authority in a
   receipt.
3. The workflow ledger records the token baseline and conversation binding.
4. The exact Plan brief and the admitted native conversation location are sent
   through the native lane.
5. A conclusive terminal event settles usage; silence or elapsed time remains
   pending.
6. The terminal callback is idempotent and advances the Plan checkpoint once.

The Plan and Checkpoints remain the only lifecycle authority. Plugin readiness
can change how an adapter is prepared, but it never changes delivery ownership,
the eligible frontier, or route selection.

## Direct one-off operations

`lico_subagents_list`, `lico_subagent_delegate`, `lico_subagent_continue`, and
`lico_subagent_cancel` are for non-delivery, one-off subordinate turns only.
They do not create delivery roles, Plan checkpoints, or an alternate delivery
scheduler. A continuation requires the exact admitted native conversation
location created by the catalog admission step.

## Conversation admission

Every delivery conversation is admitted through the exact catalog entry exposed
by the native target. A location must be canonical, absolute, bounded, inside
the catalog entry, and outside the filesystem root, home directory, and the
client workspace. Relative, missing, outside, ambiguous, and unbounded
locations are distinct pre-dispatch errors. There is no inherited or relative
working-directory fallback.

The only context-bearing handoff value is the admitted native conversation
location. Briefs contain stable control facts, repository-relative references,
and native location references; they do not contain subordinate output or
generated summaries.

## Receipts and failures

Public receipts are path-free and content-free. They expose only a schema or
operation, a bounded identifier, stage, component, retryability, recovery
action, and safe lifecycle state. Raw commands, prompts, replies, paths,
runtime rows, and exceptions are private. An uncertain native effect is
reported as `in_doubt`; the exact conversation is reconciled before retrying.
An unrelated branch continues when one dispatch reaches a typed terminal
failure.

Delivery ownership is always `licoup`. Route selection is always
`adaptive-flywheel`. These authorities are independent of whether an optional
adapter plugin is ready.

## Bounded contract

| Boundary | Bound |
| --- | --- |
| MCP input frame | 64 KiB |
| Brief or one-off prompt | 48 KiB |
| Conversation location | 4 KiB |
| Working directory | 4 KiB |
| MCP workers | 8 |
| Pending tool calls | 32 |

The native scheduler persists dispatch intent before sending. Restart recovery
reconciles any pending conversation and never creates a duplicate dispatch.
