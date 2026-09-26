# LicoUp developer guide

Updated: 2026-09-26

[简体中文](RUNBOOK.zh-CN.md) · [Documentation](README.md)

Read the affected module below before editing it. These guides explain LicoUp's
boundaries and design trade-offs; tests and configuration own executable behavior.
Git/GitHub procedure belongs to [Contributing](../CONTRIBUTING.md).

## Investigation before design

Investigation is a prerequisite for planning, Designer dispatch, informed requirements
discussion and project edits. Bound it to the requested outcome and its actual
dependencies. Inspect the applicable rules and historical requirements, trace current
production producers and consumers, and review existing contracts and engineering
coverage. Verify claims of completion against current source; distinguish shipped
capabilities, partial implementations, absent wiring, unverified behavior and retired
proposals. Resolve contradictions and discoverable questions before proposing work.

The lead may parallelize independent read-only investigations, but must consolidate
their evidence before design begins. The Designer receives the requested outcome,
source-grounded baseline, requirement provenance, dependency boundaries and remaining
maintainer decisions together. Do not ask the maintainer to approve guessed groupings
or repeat facts available in the repository or supplied history. Until discovery is
complete, questions are limited to missing access or information needed to investigate.
Unavailable evidence remains explicit and dependent design stays pending.

Record the findings in the existing private work record, without another permanent
report or enforcement mechanism. After consolidation, discuss consequential choices,
design the selected scope and obtain any required approval before implementation.
New contradictory evidence reopens the affected investigation before revising its
design; it does not authorize extending the delivery scope.

## Requirements and milestone boundaries

After completing investigation, discuss requirements before implementation. Resolve consequential questions about
scope, design, contracts, authority, dependencies and completion with the maintainer;
record the decision and its rationale in the local work record. Investigate first
and present concrete options. Do not infer approval from a plan or from silence.
Routine in-scope implementation decisions and repairs need no renewed approval.

Select one approved milestone with a finite outcome and stopping condition. Resolve
its inherited defects and superseded paths before extending it. Give independent
ready tasks within the milestone separate owners and run them in parallel. Preserve
dependency order and exclusive ownership of shared integration files. Later milestones
remain inactive until the approved progression condition is met. Stop at the selected
milestone's engineering handoff; do not automatically execute the entire roadmap.

Static source review must examine the complete production path, affected contracts,
data ownership, state transitions and failure/recovery behavior. Resolve its findings
alongside focused tests before final deterministic regression. Passing tests alone
cannot replace this review, and static review alone cannot prove runtime behavior.
Report missing implementation, failed checks and live-only unknowns separately.

Client packaging, installation, real-data transition, launch and live acceptance are
centralized on the integrated candidate by the assigned delivery owner. Module Agents
do not perform these actions during implementation. Necessary compilation and
synthetic unit, contract and isolated integration tests remain engineering work.

## Agent collaboration

These role rules apply to Agents; human contributors need not simulate Agent teams.

- Designers start from the lead's consolidated investigation and identify every
  affected module and boundary before assigning work. Give
  each module a distinct owner and explicit create/edit/delete scope. A contract
  change includes its producer and consumers, with one owner for shared files.
- Module implementers read their own guide, stay in their assigned scope, and notify
  the designer when a neighboring contract must change. Do not edit another owner’s
  files or revert their work. Independent module work may run in parallel.
- Reviewers integrate the module commits, inspect both sides of changed boundaries,
  then verify the complete feature. The lead prepares the integrated PR. Corrections
  may be later commits; each affected module needs an attributable commit.

Use `npm run repo:impact -- --path <repository-relative-path>` to inspect the
registered checks and affected module routes before assigning work. An unmapped path
needs ownership review; a plan is never evidence that the dependency is covered.

## Start

Use the Node, Rust and Flutter versions declared by the package/toolchain manifests.
Run `npm ci` and `npm run client:get` when preparing a checkout. The explicitly
assigned client operation uses `npm run client:run:macos` (or the corresponding
Android/iOS command); repository setup does not authorize launching the client.

## Design boundaries

Keep domain decisions, host effects, transport and presentation in separate modules.
Interfaces belong to their consumers; a UI projects domain state instead of owning a
second lifecycle. Name modules by responsibility. Preserve documented support
obligations for published contracts when reorganizing implementation. Apply the
[development-state policy](../AGENTS.md#development-state-and-corrections) to
unpublished project-owned code: correct defective contracts and their producers,
consumers, tests and documentation together. Existing implementation is not evidence
that its behavior is required. Resolve inherited defects in the selected feature
before adding behavior; remove the replaced path instead of versioning the mistake.

A state machine's transition configuration is its authority; its local executor
loads that configuration. Do not maintain a second transition table in prose or
handwritten branching code. Tests assert behavior against the configuration.
Register each machine with its configuration, executor and module command in the
state registry. `npm run repo:state-machines -- --list` lists individual machines;
`npm run repo:state-machines` validates registered authorities. Source candidates
reported as unreviewed are coverage gaps, not compliant machines.
Rust builds compile the definitions into tables; Dart tables are generated with
`npm run repo:state-machines -- --refresh` and checked for drift by the same command
without `--refresh`. Edit the configuration, never the generated table. New
configuration files must register before verification can pass.

## Module guides

| Module | Responsibility |
| --- | --- |
| [Workflow](modules/workflow.md) | Pure definitions and transitions, execution ports and transactional persistence remain separate. |
| [Conversation](modules/conversation.md) | Canonical Conversation owns membership, events and durable lifecycle. |
| [Presentation packages](modules/presentation.md) | Immutable contracts have no Flutter or runtime dependencies. |
| [Endpoint and collaboration](modules/endpoint-collaboration.md) | Endpoint-owned ports separate key custody and trust decisions from fixed protocol bindings and relay transport. |
| [Extension platform](modules/extension-platform.md) | Contracts describe capabilities; the native host owns admission, isolated processes and package lifecycle. |
| [Client UI](modules/client-ui.md) | Composition assembles features; application controllers own use cases; projections feed rendering. |
| [Agent runtime and MCP](modules/agent-runtime.md) | Runtime supervises sessions and adapters translate vendor protocols. |
| [Native bridge](modules/native-bridge.md) | Generated DTO contracts define the Rust/Dart boundary. |
| [Models, usage and local Skills](modules/catalogs.md) | Catalog owners provide capability, price and usage facts to projections. |
| [Model gateway](modules/gateway.md) | The local gateway mediates admitted provider calls. |
| [Data migration](modules/data-migration.md) | Read-only inspection is separate from explicit maintenance. |
| [Distribution](modules/distribution.md) | Public packages are immutable and resolved from declared capabilities. |
| [Development tools and documentation](modules/development.md) | Public guidance routes contributors to one module owner and fixed commands. |

## Development and verification

Use the owning guide's fixed `npm run verify:<module>` command and test directory.
For a narrower existing suite, discover it with `npm run client:regression:list`.
During development run only affected suites. Shared semantic or transport changes
include their dependent consumers; adapter-specific changes stay with that adapter. Use synthetic, redacted test data.
Do not launch real Agents or live services without an explicit request.

Before handoff, map every requirement in the approved delivery scope to its production
implementation and engineering evidence. Complete missing behavior and wiring; do
not reduce the scope to one successful demonstration. Distinguish an implementation
gap from a completed implementation whose external behavior still needs live confirmation.

Verify DSL parsing and semantics, configured transitions and guards, scheduling,
cancellation, storage and recovery through the actual owners with deterministic
inputs, synthetic events and isolated integration fixtures. Mock external boundaries,
not the production logic being verified. Include the affected production composition
so that a passing pure core does not conceal missing application wiring.

Real Agent conversations and development tasks belong to a separate user-assigned
acceptance workflow. The implementation owner must finish all verification that can
be performed without those calls before delivering the buildable, locally runnable
client. Identify the specific live-only claims at handoff and leave them unverified;
do not invoke Agents or create live acceptance tasks to substitute for that work.
Authorized building, installation, data migration and application launch do not
authorize Computer Use or reading and exercising the live client interface. Stop
at the requested launch and report the tool results; do not initiate UI acceptance
under the name of a startup check.

Keep each change independently verifiable. Before final checks read
[Closure](CLOSURE.md), resolve findings in the changed scope, and finish source review.
All writers must finish before global regression. Unavailable checks stay unverified.

## Documentation

Keep only external contributor/user knowledge: necessary design choices, module
boundaries, usage and fixed commands. Link the owner instead of copying assertions,
state tables, command internals or volatile acceptance results. Module guides name
test directories; commands remain stable when test files move.
Describe implemented capabilities and rules currently in force. Remove instructions
when their implementation is removed; do not present proposals as current behavior.

Every maintained Markdown document has `Updated: YYYY-MM-DD`. Update it when editing
content; generated documents retain their content date until their sources change.
A date is not evidence of correctness. `npm run repo:docs` checks dates, routes and
links. Review meaning and freshness during closure; never bulk-stamp dates to claim
verification.

Local plans and reports remain ignored under `docs/plans/` and `docs/reports/`;
personal development-environment files stay untracked. Bundled user Skills contain public guidance
only. The LicoUp operation guide is provided by the product; other bundled Skills
are explicitly selected and must not enter default Agent context.
