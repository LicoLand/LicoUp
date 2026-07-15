# Isolated Renderer Completion Validation

| Requirements | Evidence |
| --- | --- |
| REQ-001, REQ-002, REQ-009, REQ-011 | Canonical directory discovery, transitive import closure, sibling-file ownership, pairwise digest impact, and per-profile suites |
| REQ-003, REQ-004 | Snapshot/action contract tests, forbidden-type scans, resolver lease lifecycle, adapter equivalence, and shutdown leak checks |
| REQ-005, REQ-006 | Host/manager integration for one active tree, preview/confirm/cancel/reset, persistence failure, state/focus continuity, and appearance orthogonality |
| REQ-007 | Comparison-only pixels, semantics, keys, focus, interactions, and reviewed current visual manifests without baseline refresh |
| REQ-008, REQ-012 | Synthetic add/remove profile and surface mutations, exact Cartesian product, complexity/lookup assertions, and bounded state tests |
| REQ-010 | Retired-path scans for Widget content port, shared styled presentation, profile-ID branches, duplicate shells, stale fixtures, and compatibility code |
| REQ-013, REQ-014 | Layout/client verification, Better Plan validation/labels, per-Node delivering commits, rebuild/open, and independent Android report |

Final validation must rerun discovery after all changes. Observed profile/surface counts are evidence only and never acceptance constants. Any visual comparison failure keeps the Plan incomplete; updating a golden or baseline to silence it is not evidence.
