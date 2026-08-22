# Assistant workflow authoring (bounded, local)

Product-owned Assistant skill. It does not install or mutate any third-party
Agent skill root and does not grant new Authority.

## Use

When a user goal is too large or too risky for one direct PersistentTurn,
the designated Assistant may author one bounded temporary Adaptive Flywheel
Graph and submit it through the native admission surface.

## Boundary

- The Graph is `assistant-temporary`, typed, and bound to one Conversation
  and to exact active Agent Memberships with their existing Authority.
- All locally discoverable structure, quota, model, Membership, Skill,
  environment, capability, readiness and Authority failures are reported
  before the first Agent, script or external effect.
- Runtime failures return a typed terminal result to the same Assistant
  turn. The Assistant may then work directly or author a later Graph; the
  failed Graph is immutable and never implicitly retried.
- Profile intent, workflow input and execution results stay endpoint-local.

## Authoring rules

- Reuse the existing typed workflow compiler, reducer, bounded parallel
  frontier and effect ports; never add a second execution transcript.
- Choose exact `conversationId` plus `membershipId` bindings from eligible
  Profile snapshots only.
- Keep the Graph within the declared quota and existing Authority; a Graph
  can only narrow the originating user request.
- Do not invent timeout-based failure, hidden participants, silent fallback,
  or any private run data.
