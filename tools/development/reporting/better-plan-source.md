# Better Plan report reuse

Updated: 2026-10-01

The shared `page.mjs`, `graph.mjs`, `graph-layout.mjs`, `style.css` and
`interaction.js` provide cards, dependency graphs and detail drawers for permanent
reports and the optional Better Plan projection.

The page opens with the programme title, goal and success list, then the delivery
dependency graph from each delivery's `requires` edges. Requires ids that are not
deliveries are listed as a warning line and their edges are ignored. Every delivery
also appears in a list carrying its delivery-state badge (Planned, Unrecorded,
Recorded, Needs review, Missing, Error), execution status and any
`report.ready` ("Ready to execute") or `report.ready_to_design` ("Ready to design")
marker. Milestones share one continuous page in programme order; the maintainer
selects the authorized milestone and the page does not schedule work.

Requirement coverage follows the overview. It shows catalogue totals by status,
in-scope entries grouped by id prefix, an Uncovered list, excluded entries collapsed
with their reasons and any unknown references. Entries open a drawer with the
English statement, acceptance, scope note, exclusion and owning deliveries and
tasks; bilingual fields always render their `en` text. A Metrics card appears when
the export records any metric and shows one row per metric name with values per
delivery in programme order, with the check id in the row drawer.

Open decisions are read from the Tree's `open_decisions` list, using a string or
an object's `statement` or `question` field. Planned deliveries use the outline
supplied by the tool. Authors keep that list current and remove resolved
questions. Missing or empty lists show no open decisions. Scope prose and
verification commands remain detail content and do not determine decision state.

Worker and node drawers retain the source design, owned files, output guarantees,
acceptance oracles and verification commands. Commands are displayed, never run.
Requirement ids carried as `source_ids` are shown beside the Tree, Task and Node
requirement statements they cover. Checks appear under their declared owner and
covered Nodes, with readiness supplied by the tool. The projection creates no
Task, Node or execution receipt.

Workflow steps, module boundaries and state transitions use the same node and
arrow rendering. [Dagre](https://github.com/dagrejs/dagre/wiki) supplies directed
layout for these graphs, including cycles and self-loops that execution DAG
layering cannot represent. Parallel transitions with identical endpoints share a
line while retaining every event and condition in its detail drawer. State-machine
authorities remain unchanged. `edge-routing.mjs` retains Better Plan's centered
ports and cubic curves, with continuous splines for obstacle routes. Arrowheads
attach to the same SVG path with the marker's automatic orientation
(`orient="auto"`).
Node positions, curves and arrowheads are generated from source relationships;
never patch coordinates into individual reports or edit the generated HTML.

All layout code and assets required to generate reports reside in this repository;
layout requires no network service. The optional plan projection invokes the installed
Better Plan tool once per generation, using `LICOUP_BETTER_PLAN_TOOL` when configured.
These read-only projections do not initialize, authorize, repair or execute a Better
Plan workspace. Node completion counts describe recorded plan progress.

`adapters/better-plan.mjs` is an optional read-only boundary to the Skill's current
programme workspace. It makes exactly one `programme export <root>` call, where
`<root>` is the directory of the given `Programme.json`, and renders only the
returned projection. Normal report generation does not read any plan. An explicit
`--better-plan` argument adds the temporary projection and its navigation entry;
omitting it removes both. Private programme and Tree data is never stored in
renderer source, and the adapter writes no Skill state or repository plan format.

A Tree delivery renders the existing Task-lane Node graph plus the delivery-state
badge. A planned delivery renders an outline card (goal, success list, requirements
with their `source_ids` badges, open decisions, requires and blocked_by) without a
Node graph. A delivery whose export failed renders an error card with the tool's
message; one broken delivery never stops the page from rendering. If the installed
tool does not implement `programme export`, generation fails with an English error
telling the operator to update the Better Plan skill; there is no silent fallback.
The adapter invokes the tool's read-only export view; it does not read archives.
Node completion and pending review are independent: a dashed outline marks review
needed while the existing completion colour remains visible. Checks are displayed
with their tool-derived readiness and recorded result. Task lanes group all Nodes
that contribute to that outcome, rather than mirroring one lane per Node.
