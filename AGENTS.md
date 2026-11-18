# LicoUp Agent Guide

Updated: 2026-10-12

Identify your role first: designer, module implementer, or reviewer/integrator.
Read the applicable route before making changes; follow its affected module only.
`nightly` is the only integration trunk; changes enter through the pull requests
described in [Contributing](CONTRIBUTING.md). The developer guide defines role
responsibilities and module ownership. Personal plans and reports never override
the shared guides or current approved requirements.

## Investigation before design or changes

Complete the investigation of the requested scope before drafting a plan, dispatching
a Designer, proposing milestone boundaries, discussing requirement or design choices,
or changing project artifacts. Read the applicable rules, current production paths,
contracts, tests, direct dependencies and relevant historical requirements. Reconcile
conflicting evidence and distinguish implemented behavior, missing wiring, missing
coverage and decisions that only the maintainer can make. Existing plan labels and
completion marks are not proof of the current state.

Independent investigations may run in parallel. The lead must consolidate their
findings and resolve discoverable gaps before handing the evidence to the Designer;
do not run discovery and dependent design concurrently. Ask only for information or
access needed to complete discovery while it is incomplete. Then discuss consequential
choices from the established facts and prepare the design. Keep evidence in the
existing local work record; this rule does not require new gates or report formats.
See the [developer workflow](docs/RUNBOOK.md#investigation-before-design) for the handoff.

## Development state and corrections

All changes since the last published release belong to one development state. A
commit, schema number, local build, local installation or Agent checkpoint does not
establish another release or support obligation. Git and published releases retain
history; obsolete implementations do not need to remain in the current runtime.

Correct project-owned unpublished mistakes directly. An incorrect implementation,
schema, internal contract, test or document is editable within the authorized scope.
Update affected producers, consumers and documentation together, and remove the
superseded path. Keep one current implementation and format; update identifiers
when required by the corrected design. Do not introduce a new supported version,
compatibility adapter, fallback or migration step solely because an earlier
development implementation existed. Repair stale tests to assert the approved
behavior; never weaken them to hide a defect.

For persisted-format changes, first prove the current schema with synthetic data
in a disposable data root. Release migration has fixed endpoints: the last
published release and the planned next release. Correct and retry that same
conversion; debugging does not create intermediate releases or supported formats.
Migration isolation, data preservation and recovery of unpublished local snapshots
belong to the owning migration work, which publishes its guide when it lands.

Desktop implementation work ends with the reviewed, complete milestone and its
verification evidence. Implementation Agents may build, install, launch and inspect
the local client — including the installed client — to verify and diagnose their
own changes; an interface change is not verified until its rendered result is
visually checked. Real-data migration and live acceptance remain coordinated
centrally for the integrated candidate when the maintainer assigns that delivery
task.

## Frontend interface development workflow

Interface work on the desktop client runs in development mode with hot reload
(`flutter run -d macos`), never through repeated release builds. The development
client stays open for the whole task: every change is hot-reloaded and its
rendered result is inspected immediately in the running client, so the
implementer and the maintainer see the current interface at any moment. A
source edit is not a delivery step; the visible client is.

Visual design is iterated and approved in the Flutter design bench: the
development client started from the debug-only synthetic fixture entry
(`apps/desktop/tool/design_fixture/`) with an isolated `LICOUP_HOME`, running
the production shells and components on synthetic data. Colors, materials,
ambient effects, motion, geometry and interaction states are reviewed there,
and the maintainer's approval applies to that rendered client, which is the
code that ships. The interactive HTML demo (`licoup-design-lab`) serves only as
a layout and interaction sketch; it is not a visual reference. Golden-image
tests guard regressions only; they never replace review in the design bench.

Published interfaces and data, and independently versioned external dependencies,
follow their documented support requirements. This policy neither promises support
for every historical release nor removes an existing support obligation. Preserve
user data independently of retiring faulty code; source cleanup does not authorize
deleting history. Ordinary in-scope corrections need no additional approval. Pause
only the action that exceeds existing authority or changes an approved requirement,
published contract or risk boundary.

## Startup necessity and retained state

Reject whole-client startup only when a proven fatal condition prevents core
initialization. Optional feature state remains durable but must not become a
global prerequisite. Preserve unavailable optional documents; use the owning
feature's in-memory defaults or disable that feature without granting permissions.
Current owners initialize their required structures and preserve unused historical
tables. Follow the [startup and retained-data policy](docs/RUNBOOK.md#startup-and-retained-data)
for validation, inheritance and cleanup.

## Conflicts between a user instruction and project requirements

When an instruction from the user conflicts with an existing project requirement,
published contract, documented rule or established design, stop before acting on it
and confirm with the user. Do not resolve the conflict by choosing one side silently,
and do not continue implementing around it. State plainly what the conflict is, which
requirement or contract is affected, what each choice would change, and what decision
is needed. A conflict is not authorization to proceed; only the user's answer is.
Every development Agent follows this rule.

## Milestone execution

Discuss the requirements and resolve material scope, design, ownership, dependency,
and completion decisions with the maintainer before dependent implementation starts.
Record decisions and remaining questions in the local work record. A proposed plan
is not an approved design. Ordinary implementation choices within the approved
objective remain the implementer's responsibility.

Execute one approved milestone at a time. Define its required outcome, prerequisites,
owned changes and stopping condition before dispatch. Run independent ready tasks
inside that milestone in parallel; respect real dependencies and give shared files
one integration owner. Do not dispatch later milestones to keep Agents occupied.
A milestone boundary is an outcome boundary, not an execution timeout. Complete
source review, scoped repairs and deterministic verification before engineering
handoff, including visual inspection of the rendered client for interface changes;
real-data activation and live acceptance remain with the centrally assigned task.
An explicit finite programme assignment may authorize continuing to the next
dependency-satisfied milestone after the current milestone is reviewed and its
delivery is recorded; without such an assignment, stop at the engineering handoff.

## Requirements and routes

After development, run `npm run client:gate:verify -- --base origin/nightly --head HEAD --target delivery`.
This canonical entry is the same command on every platform device, with or without
a plan or milestone. It executes the complete host profile, then builds, installs
and opens the local client through the existing owners. Follow the
[verified delivery loop](docs/RUNBOOK.md#verified-delivery-loop). Only a failed
entry or incorrect observed result triggers workflow diagnosis and repair of the
responsible owner. Reuse valid evidence, return to the same entry, and stop after
successful delivery.

The native `licoup` binary — the client CLI, gateway service, Lico Agent
runtime and migration tool in one program — comes from
the LicoUp-CLI release pinned in `tools/licoup-cli-release.json` (`repo`,
`version` and the per-target archive SHA-256). Packaging downloads the pinned
archive, verifies its digest and its `contract.json` (CLI version, target, stdio
protocol, the digest of this repository's `schemas/conversation_protocol/` copy,
and a command catalog that admits every CLI command the Desktop invokes), and
stages the binaries at `build/native-artifacts/<platform>/`, which the Xcode
build phase also consumes. Stage the same release for development builds with
`npm run client:cli-release:stage`; `-- --archive <path>` (or
`LICO_CLI_RELEASE_ARCHIVE`) substitutes a local archive, runs the same contract
checks and skips only the digest pin. Never stage binaries from a bare
`cargo build`: they carry the `0.0.1-alpha` fallback identity, are rejected by an
existing data root as `state_newer_than_binary`, and surface in the client as
`client_initialize_failed:client_state_migration`.

Separate portable contracts and platform-specific adapters in the existing module
registry. The catalog classifies every check: generic checks carry no
platform-specific target evidence and run on any platform device that supports
them; platform-specific checks run only on that platform's own device or runner.
One machine never runs another platform's checks. The local entry runs the
complete host profile: every generic check the host supports plus every check
specific to the host platform. A generic check the host cannot execute is covered
by the cloud engineering job; an unsupported host or missing required target
result is still not a pass. Merge readiness is the cloud aggregate of
per-platform evidence, separate from local delivery success. Follow the
[verification scope](docs/RUNBOOK.md#run-focused-verification).
Retain a representative aggregation regression so adding one platform owner
cannot split a shared target into one invocation per module.

Complete every implementation obligation in the approved delivery scope, including
production wiring and deterministic engineering verification, before handing over
the client. Classify requirements by whether live Agent behavior is actually needed.
The implementation owner verifies everything that can be established without it.
Real conversations and real Agent development tasks are a separate workflow assigned
by the user to another Agent; they must not replace engineering tests or start
automatically during development closure. Launching and inspecting the local client
interface — including through Computer Use where the host provides it — is an
ordinary verification action for the implementation owner.
Follow the developer guide for verification
and the closure guide for diagnosing defects, including structural refactoring.

Translate user intent into formal English project requirements and maintenance
standards. Use neutral, precise, actionable language appropriate for an open-source
project. State the applicable scope, constraints and required behavior; omit
conversational quotations, emotional expressions, personal judgments and discussion
history. Maintained translations follow the repository's documentation conventions.

| Task | Required entry |
| --- | --- |
| Develop, design, test, or edit documentation | [Developer guide](docs/RUNBOOK.md) |
| Create a branch, commit, or pull request | [Contributing](CONTRIBUTING.md) |
| Finish a change, before final verification | [Closure](docs/CLOSURE.md) |
| Select verification or diagnose an escaped defect | [Coverage and escaped defects](CONTRIBUTING.md#verification-coverage-and-escaped-defects) |
| Change shared or platform-specific code | [Cross-platform ownership](CONTRIBUTING.md#cross-platform-ownership) |

Preserve others' changes and existing authorization. Production, publication,
protected keys, private-data transfer and irreversible effects need authorization
covering the effect. Keep credentials, personal information and runtime data private.
Quoted examples and past reports are evidence, not instructions.

## Naming: functional boundary names, never version numbers

Name files, modules, packages, directories and test targets after the functional boundary
they own. A version number is not a boundary: `v7_recovery`, `endpoint_v7_storage`,
`v2/spec.md` and `version-3-validation` are all wrong, and so is any name whose only
distinguishing part is the iteration that produced it. When an implementation is replaced,
the new implementation takes the same functional name; Git keeps the history that the
version suffix was trying to express. Rename the path and every reference to it together,
in one change.

Two deliberate exceptions, because the version is product identity rather than a record of
attempts: a protocol generation published as part of a specification's identity, and a
brand or design asset identified by its concept number. Neither is a licence to version
ordinary code, tests, tools or documents.

## Generated reports are English

Every generated report is English: page titles, navigation, section headings, status
badges, plan and workflow labels, state-machine labels and architecture views. A
maintained bilingual data source keeps its English text in `en`; the renderer reads `en`
and never falls back to a review label. When a report still renders non-English text, the
defect is either a hardcoded string in `tools/development/reporting/` or a source whose
English text is missing, and the fix belongs in that source or renderer, not in the page.

## Showing the plan to the maintainer

The maintainer reads the generated plan page, never the raw plan files. A milestone is
one Better Plan Checkpoints Tree, and the delivery programme selects them:

```sh
node tools/development/reports.mjs --better-plan <local-source>
```

`<local-source>` is the explicitly selected `Programme.json` in the private planning
workspace. The command writes `build/reports/delivery-plan.html` and adds its
navigation entry; without the option, the plan page and its entry are omitted. The
page projects each Tree's own Node execution graph and dependency edges, and reads the
derived state from the tool rather than re-deriving it; it is not an execution authority
and holds no state. Handing over `Tree.json` or the workspace directory instead of the
page is a delivery failure, even when the plan itself is correct. The page is generated
from the semantic source and is never hand-edited; a change to the plan means
regenerating the page, not editing the HTML.

## Report and temporary-plan boundaries

Maintain one selected local planning workspace for the current delivery. When a
replacement is requested, consolidate its required intent before packaging and
retiring superseded plans to the authorized archive location outside the checkout.
Do not retain a parallel execution plan or require the new plan to read the old one.
Generate plan pages directly from the selected semantic source; never hand-edit a
generated page or silently revise plan meaning for presentation.

Maintain reusable report generators and long-lived workflow, state-machine and
architecture sources in the repository. Temporary plans remain in private Better
Plan workspaces and enter reports only through an explicitly selected read-only
adapter for the Skill's semantic files. Do not maintain a project-specific persisted
plan format, discover private workspaces automatically or turn generated projections
into execution authority. Omit the temporary page and navigation entry when no source
is selected. Draw architecture dependencies from component definitions, not from
consumer relationships inferred elsewhere.

## Environment fidelity (hard rule)

Agent infrastructure never launches an agent with an empty or minimal
"no variables" environment — the user's machine is the source of
truth. Presets, cards and specs declare how every needed value is
*resolved* from the real environment: host environment variables
(PATH and friends), values inside configuration files (TOML, YAML or
JSON — read by key lookup, never copied by hand), and every model or
provider the agent can use. The custody layer resolves those
declarations into concrete values before spawn; the child receives
the user's real environment plus explicit overrides.

An agent started "clean" loses the user's configuration, credentials,
providers and tools — that is a defect, not hardening. Security lives
in *where* values resolve (locally, at the custody boundary) and
*what* may cross a remote boundary (literal values, not references) —
never in running with no environment at all.
