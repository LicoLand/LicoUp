# Design Decisions

[Documentation](../README.md)

This directory is the long-term archive of design decisions that are project
assets in their own right. A decision record here remains authoritative
whether or not it has been implemented, and it is never deleted because its
implementation status changed.

## Boundary with other documentation

- `docs/adrs/` holds implemented and verified long-lived decisions only.
  In-progress designs do not belong there.
- `docs/plans/` holds structured execution plans and `docs/reports/` holds
  temporary proposals and one-off documents. Both are local only.
- This directory holds decisions that must stay in the documentation as
  long-term assets, including designs that are not yet implemented or
  verified. Status is recorded per record, not enforced by location.

## Record format

Each record is one file named `NNNN-short-kebab-name.md` with a stable
numeric identifier.

- `context` — the situation and constraints that raised the decision
- `decision` — the chosen direction in concrete terms
- `rationale` — why this direction over the alternatives
- `alternatives` — considered options and why they were rejected
- `consequences` — expected positive and negative effects
- `status` — current lifecycle state (draft, decided, implementing, verified,
  superseded) plus the date of the last change
- `evidence` — optional links to implementation, tests, or verification
  artifacts

New records are added to the implemented list in the [documentation index](../README.md).
