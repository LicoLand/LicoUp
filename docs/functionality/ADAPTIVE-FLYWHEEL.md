# Adaptive Flywheel Strategies

English (normative) · [简体中文](ADAPTIVE-FLYWHEEL.zh-CN.md) · [Functionality](README.md)

Adaptive Flywheel is LicoUp's local strategy generator and execution runtime.
A strategy is a JSON state-machine Graph. The Graph alone decides whether one
run is a one-shot pipeline, a branching workflow, or an Agent Loop with
back-edges. The engine does not infer a loop from a strategy name or a built-in
role sequence.

## Strategy sources

LicoUp contains one small built-in strategy so that the strategy surface is
usable without importing a package. It is named **LicoUp Basic Strategy** and
evolves as a LicoUp-owned strategy. There is no separate strategy installation
step.

Additional strategies are imported as one bounded ZIP package:

```text
workflow.json
scripts/
  optional helper files
```

`workflow.json` must be at the package root. Auxiliary files are accepted only
under `scripts/`. Import prepares and validates the archive, then commits one
immutable revision. A committed revision does not depend on the original ZIP
or its original filesystem path.

## Graph and execution

The workflow document declares metadata, resource limits, actor/runtime/
workspace binding slots, optional worksets, the initial state, states, and
transitions. Supported state families cover routing, authorization, actor and
script effects, dependency-aware worksets, and explicit terminal outcomes.
A transition back to an earlier state forms a loop; an acyclic Graph remains a
pipeline.

Before a run can execute effects, each required slot must be bound and the
exact immutable strategy semantics must be authorized. Python and Node helper
scripts use only a verified runtime already available on the device; strategy
packages do not carry interpreters. Authorization can be revoked. A changed
revision requires its own bindings and authorization.

Runs are reduced into durable local state. The client projects current and
neighbor states, available operations, effect history, retries, cancellation,
and visible blocked or in-doubt outcomes. Ready dependency-frontier work may
run concurrently within the Graph's declared and engine-enforced bounds.

Strategy definitions and run state are independent from Conversation history.
The retired ordinal Conversation Flywheel model is not read or translated.

## Desktop flow

Open **Agents**, then open **Adaptive Flywheel Strategies**.

1. Select the built-in strategy or import a strategy ZIP from the first row.
2. Configure each Agent role with the restored capsule editor: Agent, model,
   and reasoning effort.
3. Open **Workflow** when a directed transition diagram is needed. The editor
   does not replace the diagram with a grid of state cards.
4. Save the role bindings and authorize that exact immutable revision.

Python and Node runtimes are detected and bound in the background. They are
not user-selectable fields. Agent pickers contain only detected targets with a
usable conversation driver; unsupported or merely known targets are omitted.
Session-policy implementation details are not shown as role labels.

The desktop strategy surface does not collect a separate delivery goal or
expose manual run controls. Task intent belongs in the Conversation flow, not
in a second command field beside the Graph configuration.

Imported package contents, bindings, authorizations, and native run state
remain in local client state. Do not publish raw strategy inputs, local paths,
process output, or agent history as diagnostics.
