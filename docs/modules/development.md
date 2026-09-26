# Development tools and documentation developer guide

Updated: 2026-09-26

[Developer entry](../RUNBOOK.md)

Public guidance routes contributors to one module owner and fixed commands. Registries own executable checks; reports record actual outcomes. Default closure performs no real Agent conversations or paid service validation.
Official public-source metadata refresh is separate from live product acceptance.

## Role responsibilities

**Design:** inspect registry owners and contributor command contracts. If a shared contract changes,
include its producer and consumers; consult [distribution](distribution.md) or
[agent-runtime](agent-runtime.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:development` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

The privacy command uses the public [Lico-Auditor](https://github.com/LicoLand/Lico-Auditor).
Put its `lico-auditor` executable on `PATH`, or set `LICO_AUDITOR_PATH` to its checkout
root. Missing tooling blocks this check. `npm run repo:local-info-hygiene` checks
staged, unstaged and nonignored new files once. Use `-- --base <ref>` to include
committed changes since that ref, or add `--head <ref>` to inspect only the committed
range. `-- --all-candidates` explicitly scans the whole source candidate. Missing
comparison data is an execution error; it does not widen the scan to history.
Local closure invokes this check once; CI's dedicated Auditor job checks the
submitted range. The source-policy lane does not repeat that scan.
Each invocation creates a fresh local HTML draft, scan snapshot and Agent review
assignment under ignored `build/reports/privacy-audit/`. The JSON result gives their
relative paths. The local developer report includes original matched content;
public command output remains redacted. The reviewing Agent examines every match and
all semantic categories, including applicable documents without format matches.
After writing the conclusion JSON described by the assignment, run:

```sh
npm run repo:local-info-hygiene -- --complete-review <scan.json> --review-result <review.json>
```

This validates conclusions for that exact scan and generates `.reviewed.html` without
rescanning. The final report separates category, rule, file, line, original content,
verdict, evidence, impact and action. Its other view lists the rules. A successful
scan or generated assignment cannot be delivered as a completed audit. The Agent
workflow must complete contextual review and this command for every requested audit.
For an explicitly requested history review, use
`npm run repo:local-info-hygiene -- --scope history --all-refs --full-history`.
This applies current rules to all locally reachable historical file versions;
it does not fetch remotes or scan other worktrees' uncommitted files. Use `--ref`
instead of `--all-refs` for one branch or range. `--full-history` selects every
commit tree; by itself it does not add other branches. The scan snapshot identifies
shallow or commit-limited coverage. Normal closure continues to use changed scope.
Risk levels are review prompts. Explain each finding's context, disclosure or
false-positive basis, and any narrowly justified whitelist. A completed scan is
not a disclosure verdict; report unavailable evidence separately.
Public configuration paths, reference hosts and reviewed exact-value exceptions
are declared in `.lico-auditor/policy.json`; use the Auditor's documented policy
format. Maintain entries when those public assets change. An exception applies
only to its declared rule and scope; surrounding content still needs review.
Resolve findings in one review and repair pass; inspect the repair diff without
repeating an unchanged scan. Historical cleanup is a separate, explicitly selected
task and is not part of routine contribution checks.

Test directories: `tools/development/tests/`, `tests/contract/client/`,
`crates/licoup-state-machine-codegen/tests/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.

## Workflow and report projections

Maintain contributor workflows in `tools/development/workflows/`, one structured
file per workflow. The [source format](../../tools/development/workflows/README.md)
defines the responsibility and entry/exit fields. These definitions document the
process; they do not start Agents or client operations.

Run `node tools/development/reports.mjs` to refresh the local HTML navigation at
`build/reports/index.html`. It includes workflow views, registered state machines, component dependencies
and links to available evidence. Temporary Better Plan workspaces are separate:
`--better-plan <local-source>` explicitly adds a read-only projection from the
Skill's current `Plan.json` or `Manifest.json`. Without that option, omit the plan
page and navigation entry, including stale generated output. Do not maintain a
repository-specific persisted plan format or scan for private workspaces.
Existing authorities supply states and dependencies; do not duplicate them in
workflow prose. The renderer neither runs checks nor treats old receipts as current
success. Privacy content remains in its separately reviewed local report.

Use the shared light cards, graph nodes, arrow lines and detail drawer for every
report view. The plan is a continuous sequence of milestone cards beneath its
dependency overview. Workflow and state diagrams render actual directed edges;
state graphs preserve events, cycles and self-loops. Supporting details belong in
the drawer rather than repeated explanatory prose.

The existing pre-commit entry refreshes these projections after its candidate
checks. Engineering closure and release-readiness preparation also refresh them.
Reports remain ignored local output and do not replace any review or test result.

Governance commands: `npm run repo:artifacts` checks candidate/index artifacts,
`npm run repo:impact` selects checks and warnings, and `npm run repo:state-machines`
checks registered authorities. `npm run repo:upstream` observes public official-source
metadata and keeps changed/unavailable observations visible. These reports remain
local and cannot certify protocol compatibility or exhaustive semantic coverage.

State compiler changes affect every registered consumer. Rust builds consume the
definitions directly; the Dart generator refreshes and checks generated tables.
Keep runtime effects and data guards with their module executor.
