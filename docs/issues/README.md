# Design Issues

[Documentation](../README.md)

This directory tracks open design problems and known gaps that are project
assets in their own right. Each record states one problem, the affected area,
its impact, and any related decision or plan. Records are never deleted while
the problem is open; they are closed only by linking the resolving change.

## Boundary with other documentation

- `docs/decisions/` holds the chosen directions (including design decisions
  that are not yet implemented).
- `docs/adrs/` holds implemented and verified long-lived decisions only.
- This directory holds the problems that a decision or implementation is
  expected to resolve, including problems with no fix yet.

## Record format

Each record is one file named `NNNN-short-kebab-name.md` with a stable
numeric identifier.

- `problem` — the concrete issue in user-observable terms
- `affected-area` — the modules and interaction paths involved
- `impact` — why the problem matters
- `evidence` — code locations, files, or observations that confirm the problem
- `related` — links to the decision or plan that addresses it, if any
- `status` — current state (open, investigating, decided, fixed) plus the
  date of the last change

New records are added to the index in the [documentation index](../README.md).
