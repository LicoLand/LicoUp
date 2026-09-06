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

## Assistant-temporary runs

An Assistant-authored Graph is a request-local immutable run object, not an
imported catalog strategy. It may bind only exact active Agent Memberships
from the same Conversation and may not contain script or runtime assets. The
Assistant facade derives Profile facts from their existing owners, hard-filters
and orders candidates deterministically, completes every locally knowable
check, and revalidates store-owned Membership and Profile revisions before
durable admission under the idempotency key.

A rejected request returns an ordered `diagnostics` list. Every item has a
stable code and stage; when available it also carries a safe JSON Pointer, the
affected Membership id, and numeric actual/limit facts. The Assistant can
therefore repair workflow shape, limits, bindings, model, readiness,
environment, Skill, and Authority problems without parsing prose or repeating
effects.

Once admitted, actor effects use the same persistent Membership turns and
Conversation Event/Part timeline as direct and group chat. An Assistant-run
effect or drive failure settles one typed terminal result and cancels
unstarted commands; it does not enter the generic retry, Fallback, or failure
edge path. The run has no elapsed-time terminal rule and is never rewritten.
The same Assistant may continue directly or submit a later Graph.

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

Each transition also declares a node handoff mode: `flow` or `callback`. A
missing `mode` defaults to `flow`, and any other value is rejected at
validation. Fork fan-out edges are structural and must stay `flow`.

A `flow` edge enters its target as soon as the source settles. Because no
master agent intervenes on that path, a flow-entered state — the initial
state or the target of any `flow` edge — may not leave the key fields its
kind executes with empty: actor states declare `binding`, workset states
declare `binding` and `workset`, and script states declare `runtime` and
`entry`. Import and validation reject an under-declared flow target with
`workflow_flow_target_incomplete`.

A `callback` edge parks the run instead: the settled state is completed, the
run durably waits, and the master agent — the originating Assistant
membership — receives the pending callback through the same
Membership-scoped conversation projection that effect outputs use. The run
resumes only when the master's decision arrives as a run input, and the
callback request names that answer channel: `strategy.run.resume` for an
imported run, or the same idempotent `lico_assistant_workflow_execute` call
for a master agent driving an Assistant-run graph through the Subagent MCP
surface. `advance`
enters the declared target, `return` re-enters the completed state, and
`terminate` cancels the run. A decision binds one exact wait by state id and
visit, so a replayed or foreign decision is stale and settles nothing.
Multiple callback waits queue in the order they were entered and are decided
in that order. A target reached only through `callback` edges may defer its
actor binding to the master decision; if the binding is still undeclared when
the effect runs, the ordinary failure fallback applies.

The failure fallback holds under both modes. An Assistant-run effect or drive
failure settles one typed terminal outcome back to the originating Assistant
turn. For an imported run, the terminal failure outcome — failed, blocked, or
in-doubt — is reported to the bound Conversation's designated Assistant
Membership as a typed Membership event, so the master agent decides what
happens next; only identifier-level facts cross that seam.

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

Opening the editor hydrates selected workflow-role and Assistant model catalogs
through one target batch. Rust reuses bounded discovery workers, one shared
process/environment snapshot, and one discovery-cache commit; the client does
not start a scanner or async runtime per role.

## Group Conversation start

Only a group Conversation shows the strategy capsule. A one-to-one
Conversation does not.

The capsule above the composer defaults to **Automatic adaptation**. This is
the Assistant's default mode, not a built-in strategy. Selecting an
authorized revision shows the strategy name and places an `@` capsule for the
entry-slot candidate in front of the input. Selection admits every bound Agent
as a group Membership. It does not start a run.

While Assistant mode is active, a user send always addresses the designated
Assistant through the same Membership-scoped native lane as a one-to-one
conversation. The Assistant may answer directly or use a workflow; that choice
does not replace the dialogue lane. Native steer, resume, cancellation, event,
and safe-boundary behavior remain those of the selected adapter.

The first send is still a Conversation Event. Native addressing starts
`strategy.run.start` on the persistent conversation sidecar (the Graph does not
own a send process). Later sends stay Events: an in-flight Membership
PersistentTurn is steered; a Waiting run is resumed — except a callback wait,
which only the master agent's explicit `advance` / `return` / `terminate`
decision settles. Clearing the capsule exits
strategy mode and does not cancel a run that is already executing.

An `@mention` only selects Memberships. It uses the same PersistentTurn stream
as strategy, Assistant, and subagent effects — not a second I/O stack. Graph actor
and workset effects land as structured Events on the matching Membership through
the shared conversation display.

Imported package contents, bindings, authorizations, and native run state
remain in local client state. Do not publish raw strategy inputs, local paths,
process output, or agent history as diagnostics.
