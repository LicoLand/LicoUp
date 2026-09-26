# Fourth graph: packages, profiles and delivery traceability

Updated: 2026-09-25

This directory is the distribution-owner (M31/V7-U10) addition to the
architecture graph tool (M24). The graph model, relation classes, canonical
digests and rendering primitives are imported from `../lib/`; this module does
not copy or replace them and does not write graph documents.

`fourth-graph.mjs` projects one resolved `Graph` into the fourth typed graph
required by C08:

- nodes: packages, profiles, capabilities/providers, and the modules, contracts
  and delivery tasks a package traces to;
- edges: `requires_package`, `profile_selects_package`, `profile_forbids_package`,
  `package_ships_module`, `package_implementation_task`, `task_delivers_package`,
  `package_provides_capability`, `module_owns_contract`, `module_consumes_contract`.
  Every edge carries `enters_development_dag: false`; only `task.depends_on`
  schedules work;
- per-profile closure, not-selected set and provider coverage against the
  product's capability ownership table;
- a `traceability.packages` index: for each package its modules, those modules'
  contracts, its capabilities and its delivery tasks.

`renderFourthGraph` returns deterministic Mermaid, a layered SVG of the install
closure, a traceability table and the JSON document. Same graph, same bytes.

The command surface is exposed by `tools/distribution/resolve/cli.mjs`
(`fourth-graph`, `render`, `check`); the checks themselves live beside the
capability table in `tools/distribution/catalog/lib/product-capabilities.mjs`.
