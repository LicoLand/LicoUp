# Workflow and report sources

Updated: 2026-09-26

Each JSON file describes one contributor workflow: `id`, `title`, `purpose`,
`owner`, `entry`, ordered `steps`, `exit`, `failure` and `boundary`. Text objects
contain canonical English (`en`) and the maintained Chinese review label (`zh`).
These files describe responsibilities; they do not execute Agents or client tasks.

Run `node tools/development/reports.mjs` to regenerate the offline HTML navigation,
workflow, state-machine and architecture pages in `build/reports/`.
Reusable renderer source lives in `tools/development/reporting/`; only generated
output belongs under an ignored `reports/` directory.
The renderer reads state-machine authorities and component manifests from their
existing owners. It never runs their verification commands. Change those authorities rather
than editing generated HTML or copying transition definitions here.

The existing pre-commit entry, engineering closure and release-readiness workflow
refresh these projections automatically. Repository hook installation continues
to use the existing contribution procedure; no additional hook is installed.

Temporary plans belong to the maintainer's Better Plan workspace. The optional
read-only adapter accepts the Skill's current `Plan.json` or `Manifest.json`:

```sh
node tools/development/reports.mjs --better-plan <local-source>
```

The default command generates only the permanent navigation, workflow,
state-machine and architecture pages. It does not discover local workspaces or
read a fixed repository plan path. Supplying a source adds the temporary plan page
and navigation entry; running without it removes that generated page and entry.
No Skill lifecycle command runs, and no Plan or Checkpoint file is written.
The adapter projects semantic fields directly; it does not introduce a second
persisted plan format. Keep private inputs and generated pages outside Git.

The current Better Plan format records Task-local Node dependencies, but no
executable inter-Plan dependency field. The optional adapter also projects the
Skill's explicit architecture-note declaration, `Milestone prerequisites:
<comma-separated sibling directories>.` or `Milestone prerequisites: none.`.
These are design constraints from the semantic Plan, not scheduling authority.
Preserve declared edges without inferring them from manifest order. A displayed
plan never activates work. Reuse the
[Better Plan execution graph](../reporting/better-plan-source.md) for the projection.

Architecture view definitions in `tools/development/architecture-views.json` select
small component groups and display labels, not edges. The renderer reads runtime
path dependencies from the selected Cargo and Flutter package manifests, including
workspace and target-specific declarations. Exclude test/build dependencies and
change-impact consumer relationships. This is a component dependency projection;
the architecture guides retain responsibility for layering and runtime contracts.

Use one light card, SVG node/arrow and detail-drawer presentation across report
navigation, plans, workflows, state machines and architecture. Place the milestone
dependency overview above all milestone cards in source order; retain horizontal
Agent lanes inside each card. Do not require milestone switching. Keep only titles,
short outcomes and a few acceptance bullets visible; put supporting detail in the
drawer. Generate positions and smooth curves from the source graph, with consistent
side-center ports and path-attached arrowheads. Do not manually place individual
nodes, wire report-specific edges or patch generated HTML.
State diagrams must render actual directed transitions, including events,
return paths and self-loops, rather than state counts or step lists.

Report navigation records availability and file timestamps, not current success.
Saved evidence still requires source and scope review. Privacy reports are linked
locally without copying matched content into other pages. Keep generated pages,
local plans and private evidence out of the public candidate.
