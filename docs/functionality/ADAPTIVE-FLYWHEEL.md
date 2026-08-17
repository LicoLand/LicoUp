# Adaptive Flywheel Strategies

English (normative) · [简体中文](ADAPTIVE-FLYWHEEL.zh-CN.md) · [Functionality](README.md)

Adaptive Flywheel is LicoUp's local strategy catalog and Graph execution
runtime. A strategy is a user-imported JSON state-machine Graph plus an ordered
candidate chain for each actor slot. The Graph alone decides whether one run is
a one-shot pipeline, a branching workflow, or an Agent Loop with back-edges.
The engine infers no topology from a strategy name and ships no built-in
strategy.

## Strategy sources

The catalog starts empty. A strategy becomes available only after the user
imports one bounded ZIP package:

```text
workflow.json
scripts/
  optional helper files
```

`workflow.json` must be at the package root. Auxiliary files are accepted only
under `scripts/`. Import prepares and validates the archive, then commits one
immutable revision. A committed revision does not depend on the original ZIP
or its original filesystem path.

The engine does not auto-register a package, reserve a strategy identity, or
keep a product roster of vendor Agents. Neutral slot identifiers such as
`entry` and `worker-a` are valid; a user's personal Agent lineup stays in
their imported configuration, not in the product tree.

## Graph and execution

The workflow document declares metadata, resource limits, actor/runtime/
workspace binding slots, optional worksets, the initial state, states, and
transitions. Exactly one actor slot must set `entry: true`. The engine does
not hard-code a scheduler slot name. Supported state families cover routing,
authorization, actor and script effects, dependency-aware worksets, and
explicit terminal outcomes. A transition back to an earlier state forms a
loop; an acyclic Graph remains a pipeline.

Before a run can execute effects, each required slot must be bound and the
exact immutable strategy semantics must be authorized. Adaptive Flywheel owns
import, ordered capsule bindings, and authorization. A group Conversation
picker lists only authorized revisions.

Python and Node helper scripts use only a verified runtime already available
on the device; strategy packages do not carry interpreters. Authorization can
be revoked. A changed revision requires its own bindings and authorization.

Each actor slot may declare a Fallback policy. Quota, credit, rate-limit,
capacity, or exhaustion failures switch to the next ordinal candidate
immediately. Transient failures retry the same candidate up to the configured
count (default two) and then switch. A switch always opens a new native
session and injects only a predecessor locator: an admitted absolute store
path, native session id, source kind, and adapter-recorded table or key
prefixes. The engine does not inject transcript body or resume across vendors.
Public receipts expose `fallbackFrom`, `fallbackTo`, failure class, and
attempt count; they contain no path.

Actor JSON output may merge `worksets.*` and `context` into the run input.
Guards still inspect the current payload. Actor execution uses the run working
directory; relative paths are rejected.

Runs are reduced into durable local state. The client projects current and
neighbor states, available operations, effect history, retries, cancellation,
Fallback receipts, and visible blocked or in-doubt outcomes. Ready
dependency-frontier work may run concurrently within the Graph's declared and
engine-enforced bounds.

LicoUp persists Graph, bindings, run, and locator summaries. Each Agent keeps
its native conversation. A group Conversation is the human entry and
membership-event projection, not a second transcript store. The retired
ordinal Conversation Flywheel model is not read or translated.

## Desktop flow

Open **Agents**, then open **Adaptive Flywheel**.

1. Import a strategy ZIP. An empty catalog shows an import-first surface.
2. Bind each actor slot as an ordered capsule list, including Fallback
   candidates.
3. Open **Workflow** when a directed transition diagram is needed. The editor
   does not replace the diagram with a grid of state cards.
4. Save the bindings and authorize that exact immutable revision.

Python and Node runtimes are detected and bound in the background. They are
not user-selectable fields. Agent pickers contain only detected targets with a
usable conversation driver; unsupported or merely known targets are omitted.
Session-policy implementation details are not shown as role labels.

## Group Conversation start

Only a group Conversation shows the strategy capsule. A one-to-one
Conversation does not.

The capsule above the composer defaults to **Optional strategy**. Selecting an
authorized revision shows the strategy name and places an `@` capsule for the
entry-slot candidate in front of the input. Selection admits every bound Agent
as a group Membership. It does not start a run.

The first send hands the message to the entry slot and starts
`strategy.run.start` with the group workspace as working directory. Later
sends go to the sticky entry session only while the run needs human input;
otherwise they are ordinary group messages. Clearing the `@` capsule exits
strategy mode and does not cancel a run that is already executing.

An `@mention` outside strategy mode remains a DirectTurn and does not start a
Graph. Graph actor and workset effects land as structured Events on the
matching Membership through the shared conversation display.

Imported package contents, bindings, authorizations, and native run state
remain in local client state. Do not publish raw strategy inputs, local paths,
process output, or agent history as diagnostics.
