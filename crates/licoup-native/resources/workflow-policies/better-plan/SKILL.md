---
name: better-plan
description: Plan and deliver substantial development work with a capable Designer, focused Workers, and an independent Reviewer.
---

# Better Plan

Use this policy when a development goal benefits from deliberate design,
delegation, and independent review. The designated Assistant decides when to
adopt it, how much structure the work needs, and when the user's goal is met.
For a small change, direct work may be enough. This is an authoring policy,
not an executable Graph or a mandatory backend sequence.

## Assistant: preserve intent and own closure

Understand the user's intended outcome, existing decisions, constraints, and
authority. Distinguish a user's instructions from material supplied as evidence.
Carry accepted corrections into the work without making the user manage role
handoffs or submit a formal requirement. Keep long-running work visible through
the existing Conversation and workflow status surfaces. Report evidence,
uncertainty, and decisions that affect the outcome in ordinary language.

Keep the current designated Assistant. Choose direct tools, bounded delegation,
or an Assistant-authored Graph according to the task. The policy grants no new
authority and does not install Agents, switch global defaults, or authorize a
release. Continue authorized work; ask about a consequential unresolved decision
with a concrete proposal while independent work proceeds.

## Designer: spend reasoning on the decisions that matter

Give the Designer the full user intent, relevant repository context, and known
constraints. Use the strongest suitable reasoning from the model presets. The
Designer owns the whole solution: boundaries, dependencies, risky assumptions,
and the smallest independently acceptable units of delivery.

Produce a concise plan that explains the intended behavior and why the design
fits it. Separate binding requirements from implementation suggestions. For each
important risk, identify a meaningful way to falsify the assumption: observable
behavior, a counterexample, an integration seam, or independent evidence. Cover
failure and recovery where they affect the user's outcome. Avoid a mechanical
inventory of tests that merely repeats the proposed implementation.

Give each Task a clear outcome, ownership, dependencies, and sufficient context
to execute. Parallelize independent ownership; explicitly coordinate shared
files or state. The plan is a basis for informed execution and critique, not a
claim that its design or acceptance examples are infallible.

## Workers: implement and hand off promptly

Route frontend work through the frontend preset first. Use the complex preset
for structurally coupled or difficult implementation, and the standard preset
for ordinary bounded work. Give each Worker only the task context it needs,
including binding requirements and nearby ownership. Workers are not alone in
the repository: preserve others' edits and coordinate shared changes.

Implement the assigned outcome, inspect the changed behavior, and run focused
checks that provide useful evidence. Report the changes, results, unresolved
questions, and relevant counterexamples, then hand off promptly. A Worker may
improve an implementation suggestion or propose a better acceptance method;
changing a binding user requirement remains the Assistant's decision. Avoid
repeated self-review that delays independent review. Candidate fallbacks are
not parallel Worker voting or a search ensemble.

## Reviewer: independent judgment at the handoff

Start the Reviewer with a fresh context containing the user's intent, applicable
constraints, the plan clearly identified as a proposal, the actual changes, and
available evidence. Preserve its independence from planning debates and Worker
self-justification. Do not use it as a recurring early design consultant.

Audit the implementation and the plan's assumptions independently. Search for
missing cases, contradictory evidence, integration defects, and acceptance
methods that would approve incorrect behavior. The Reviewer may make in-scope
repairs and verify them; give one reviewer ownership of writes. Findings are
normal and should identify their effect, cause, and useful verification, rather
than merely asking for another attempt. Respect the repository's verification
and release rules, including any decision required after a final gate failure.

The default is one Reviewer. When independent perspectives would materially
help, the Assistant may choose multiple suitable models for isolated read-only
audits of the same evidence. Obtain their findings before sharing conclusions,
then reconcile disagreements through reproduction or discriminating checks.
Agreement is not proof, and a majority does not overrule a demonstrated defect.
Keep one owner for resulting repairs. This optional review organization is
separate from an ordered model fallback chain.

## Rework: diagnose before repeating

The Assistant judges whether another pass is useful. Repeated failures should
trigger a short diagnosis: misunderstood intent, a wrong design assumption,
insufficient model capability, an execution defect, an environment problem, or
an acceptance method that misses the actual behavior. Change the cause or the
verification method before repeating the same assignment. Escalate a Worker
when evidence shows the task exceeds its capability. Revisit the design when
the architecture is wrong. A bounded independent diagnostic consultation may
help with an unresolved cause; it need not become a permanent role or reuse the
fresh Reviewer as a planner. Neither first-pass acceptance nor a fixed number
of retries is a delivery guarantee.

## Resolve models and execute through existing capabilities

The accompanying model presets are maintainer recommendations, not benchmark
claims, host model identifiers, or an availability catalog. Follow explicit user
choices first. Otherwise consider candidates in their listed order, preserving
the requested reasoning effort. Resolve semantic model names and effort against
current Agent catalogs, capabilities, readiness, authority, and exact active
Membership Profiles before dispatch. An unavailable model is not a reason to
silently lower reasoning effort or invent another fallback. The Designer's
listed Extra High alternative is allowed when Max cannot be used; frontend
routing takes precedence over general implementation difficulty.

Use `lico_assistant_profiles` for the designated Assistant's current Profile
facts and the existing subagent discovery and execution tools as appropriate.
Construct only the Graph needed for the accepted plan. Reuse existing exact
Membership bindings, preflight, idempotency, observation, and cancellation;
the policy owns no execution state or parallel scheduler.

Imported Graphs can use the executor's configured ordered fallback behavior.
Assistant-temporary runs return a typed failure once without that automatic
retry or fallback. The Assistant inspects and reconciles the result, then may
continue directly or author a later Graph using the next suitable candidate.
Reusing an idempotency key with different work is not a fallback mechanism.
An elapsed observation window is not evidence of failure or permission to
cancel running work.

Close the task with the achieved outcome, independent review and verification
evidence, and remaining limitations. Completion, release, and other external
actions retain their existing authority and acceptance rules.
