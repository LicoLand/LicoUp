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

## Graph contract

Every workflow is compiled before import against one typed transition
contract. Transitions may carry only `complete`, `success`, or `failure`
events; arbitrary event identifiers are rejected. Effect states
(authorization, actor, script, workset) must declare total `success` and
`failure` routing and may declare no other event family; terminal states have
no outgoing edges. Actor and workset states reference required actor bindings,
and every script runtime has one required runtime binding. `pass` and `join`
states take one unguarded `complete` edge, a `choice` routes `complete` with an
unguarded fallback, and a `fork` fans out through at least two unguarded
`complete` edges to distinct targets.

Guard routing must select exactly one edge for every bounded payload. A state
may declare one arbitrary guard with an unguarded fallback, or multiple
equality guards on the same payload path whose canonical values are distinct,
again with an unguarded fallback. Mixed guard paths, `exists` guards combined
with equality guards, and missing fallbacks are rejected before import.

Parallel regions are a structured subset: each `fork` has exactly one matching
`join`; every branch is acyclic, single-entry, single-exit, node-disjoint, and
free of nested fork/join and terminal states; each branch has one distinct
final predecessor into the join; and no edge crosses region boundaries. Loops
containing effects outside a structured parallel region remain valid. A join
outside such a region must have exactly one guaranteed predecessor; an initial
join or a multi-predecessor merge fed by exclusive choice paths is rejected.

A workset visit emits `success` for both empty and non-empty worksets with one
canonical aggregate payload. On the final item failure, the run stops admitting
dependent items, lets already-running fenced commands settle, then takes
`failure` exactly once using the lowest stable item/command identity. Because
an empty workset has no effect boundary, a workset `success` path may not form
an automatic cycle; failure loops and loops that pass through an actor,
authorization, or script effect remain valid.

Limits are enforced on durable admission: a run never exceeds its declared
`maxParallelism`, the engine-wide active-effect ceiling applies across runs,
and `maxAttempts` counts the full lineage across retries and fallback
candidates for one state visit or workset item. Candidate ordinals reset on a
new visit. An eligible failed candidate remains in that visit until its durable
fallback command is recorded; restart recovery finds the persisted failure and
records that command once. Immediately before a one-shot effect permit is
issued, the store revalidates the current authorization digest, lease owner,
and unexpired running lease in one write transaction. Reduction is
deterministic: commands carry stable
identities, concurrent outcomes are consumed in sorted order, and overlapping
`context.*`, `worksets.*`, or candidate-scoped resumable-session contributions
are resolved by the greatest stable command identity. Equal inputs and outcome
sets therefore reach the same canonical snapshot.

In the synthetic entry/worker fixture, the authorization, actor, and workset
states each declare one `success` and one `failure` edge; `complete` and
`blocked` are terminal states with no outgoing edges.

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

The first send is still a Conversation Event. Native addressing starts
`strategy.run.start` on the persistent conversation sidecar (the Graph does not
own a send process). Later sends stay Events: an in-flight Membership
PersistentTurn is steered; a Waiting run is resumed. Clearing the capsule exits
strategy mode and does not cancel a run that is already executing.

An `@mention` only selects Memberships. It uses the same PersistentTurn stream
as strategy, delivery, and subagent effects — not a second I/O stack. Graph actor
and workset effects land as structured Events on the matching Membership through
the shared conversation display.

Imported package contents, bindings, authorizations, and native run state
remain in local client state. Do not publish raw strategy inputs, local paths,
process output, or agent history as diagnostics.
