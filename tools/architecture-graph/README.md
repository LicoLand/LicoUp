# Local graph analysis

Updated: 2026-09-25

Current repository module routes and dependency checks use `npm run repo:impact`.
The [developer guide](../../docs/RUNBOOK.md) owns contributor responsibilities.

This reusable analysis harness reads an explicitly supplied local project graph;
it never treats a personal plan as repository policy. Invoke
`node tools/architecture-graph/cli.mjs --help` for input options. Every command
requires `--project <local-project.json>`. Structural validation consumes the
schemas beside that input; synthetic tests run without any developer's local plan.

Rendered diagrams and projections default to ignored `build/reports/`. Do not
commit them as an alternative architecture specification. The historical command
name `publish` produces a local projection; it performs no external publication.
