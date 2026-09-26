# LicoUp Agent Guide

Updated: 2026-09-26

Identify your role first: designer, module implementer, or reviewer/integrator.
Read the applicable route before making changes; follow its affected module only.
The developer guide defines role responsibilities and module ownership. Personal
plans and reports never override the shared module guide or current approved requirements.

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
Follow the [data migration guide](docs/modules/data-migration.md) for isolation,
data preservation and recovery of unpublished local snapshots.

Desktop implementation work ends with the reviewed, complete milestone and its
non-live engineering evidence. Build, installation, real-data migration, application
launch and live acceptance are coordinated centrally for the integrated candidate
when the maintainer assigns that delivery task. Individual implementation Agents
must not rebuild, replace or open the installed client to discover defects. A scoped
compile or synthetic test is engineering verification, not installed-client acceptance.

Published interfaces and data, and independently versioned external dependencies,
follow their documented support requirements. This policy neither promises support
for every historical release nor removes an existing support obligation. Preserve
user data independently of retiring faulty code; source cleanup does not authorize
deleting history. Ordinary in-scope corrections need no additional approval. Pause
only the action that exceeds existing authority or changes an approved requirement,
published contract or risk boundary.

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
handoff; leave installed delivery and live acceptance to the centrally assigned task.

## Requirements and routes

Complete every implementation obligation in the approved delivery scope, including
production wiring and deterministic engineering verification, before handing over
the client. Classify requirements by whether live Agent behavior is actually needed.
The implementation owner verifies everything that can be established without it.
Real conversations and real Agent development tasks are a separate workflow assigned
by the user to another Agent; they must not replace engineering tests or start
automatically during development closure. An explicit local installation or launch
request does not authorize Computer Use, reading the live interface or running user
scenarios. Stop at the assigned delivery boundary.
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

The maintainer reads the generated plan page, never the raw plan files. Whenever a
local plan is created, revised or re-selected, regenerate the projection and give the
maintainer the page:

```sh
node tools/development/reports.mjs --better-plan <workspace>/Manifest.json
```

The command writes `build/reports/delivery-plan.html` and adds its navigation entry.
Handing over `Design.md`, `Plan.json` or the workspace directory instead of the page is
a delivery failure, even when the plan itself is correct. The page is generated from the
semantic source and is never hand-edited; a change to the plan means regenerating the
page, not editing the HTML.

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
change-impact consumer relationships.
