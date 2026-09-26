# Better Plan report reuse

Updated: 2026-09-26

The maintainer selected the installed Better Plan Skill's `web/plan-report.html`
as the execution-graph reference. `graph-layout.mjs` extracts its dependency-depth
layout and adapts the lane placement and curved SVG edges for cross-Agent joins.
`style.css` retains its light palette and node treatment. The shared `page.mjs`,
`graph.mjs` and `interaction.js` provide cards, SVG graphs and detail drawers for
permanent reports and the optional plan projection. The superseded standalone template is removed.

Milestones share one continuous page: dependency overview first, then one card per
milestone in source order. Each card shows a short outcome, acceptance bullets and
horizontal Agent lanes. The Better Plan source records Task-local prerequisites explicitly; parallel
branches share a dependency column and a join follows every declared predecessor.
The current Skill has no executable inter-Plan dependency field. Its explicit
`Milestone prerequisites: <sibling directories>.` architecture-note declaration
supplies design dependencies for the overview; manifest order never implies an
edge. The native main must still select the approved milestone. No milestone
selector hides the remaining plan.

Worker and node drawers retain the source design, owned files, output guarantees,
acceptance oracles and verification commands. Commands are displayed, never run.
The declared full-regression stage appears as a shared integration join after the
Task terminal nodes; it creates no new Task or execution receipt.

Workflow steps, module boundaries and state transitions use the same node and
arrow rendering. [Dagre](https://github.com/dagrejs/dagre/wiki) supplies directed
layout for these graphs, including cycles and self-loops that execution DAG
layering cannot represent. Parallel transitions with identical endpoints share a
line while retaining every event and condition in its detail drawer. State-machine
authorities remain unchanged. `edge-routing.mjs` retains Better Plan's centered
ports and cubic curves, with continuous splines for obstacle routes. Arrowheads
attach to the same SVG path using [automatic marker orientation](https://developer.mozilla.org/en-US/docs/Web/SVG/Reference/Attribute/orient).
Node positions, curves and arrowheads are generated from source relationships;
never patch coordinates into individual reports or edit the generated HTML.

All layout code and assets required to generate reports reside in this repository;
regeneration does not depend on an installed Skill or a network service. These
read-only projections do not initialize, authorize, repair or execute a Better
Plan workspace. A proposal label indicates pending plan decisions, not that
existing product functionality is zero percent implemented.

`adapters/better-plan.mjs` is an optional read-only boundary to the Skill's current
semantic JSON files. Normal report generation does not read any plan. An explicit
`--better-plan` argument adds the temporary projection and its navigation entry;
omitting it removes both. Private Plan/Manifest/Checkpoint data is never stored in
renderer source, and the adapter writes no Skill state or repository plan format.
