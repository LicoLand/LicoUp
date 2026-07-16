# Isolated Renderer Completion Requirements

Upper constraint: [`../../product-scope/Requirements.md`](../../product-scope/Requirements.md). Renderer isolation cannot preserve or introduce a destination outside the canonical product scope.

## Contract

This child Plan closes the remaining layout-management work discovered after the earlier catalog plan. The current visual designs are immutable inputs. Architecture work may move ownership and dependencies, but it may not change pixels, component styling, geometry, typography, color, motion, semantics, keys, focus behavior, or interactions.

- **REQ-001 — Canonical profile ownership.** Every concrete layout source lives below `frontend/layout/profiles/<profile>/<surface>/`; mirrored tests and assets use the same owner.
- **REQ-002 — Complete renderer privacy.** Each profile owns its complete shell, chrome, destinations, components, tokens, preview, focus/restoration, and presentation. A profile cannot import another profile or shared styled presentation.
- **REQ-003 — Neutral business ports.** Shared boundaries contain only bounded immutable semantic snapshots and narrow actions keyed by surface and destination; they expose no Widget, BuildContext, complete controller, service, platform object, mutable collection, untyped payload, or profile identity.
- **REQ-004 — Typed lease lifecycle.** LayoutHost acquires and releases one typed destination lease for the active profile/surface/destination and rejects duplicate, foreign, repeated, mismatched, or leaked leases.
- **REQ-005 — One active private tree.** Only the selected bundle is mounted; switching preserves business state and semantic focus while profile/surface presentation state remains disjoint and bounded.
- **REQ-006 — Transactional selection.** One LayoutManager retains hydration, preview, confirm, cancel, reset, preferred-default, recovery, serialized persistence, and appearance orthogonality.
- **REQ-007 — Frozen design equality.** Every current production bundle matches its pre-correction comparison baseline. A failing baseline, golden, or visual manifest cannot be refreshed to accept drift.
- **REQ-008 — Declaration-derived coverage.** Verification derives registered profiles, typed surfaces, variants, destinations, directories, tests, assets, and ordered profile pairs without fixed identities or counts and validates the exact Cartesian product.
- **REQ-009 — Hard transitive isolation.** Transitive imports intersect only at an explicit style-free neutral allowlist; pairwise change-impact checks prove a profile-local change cannot alter a sibling digest.
- **REQ-010 — Complete cutover.** Widget-producing content ports, shared destination-presentation scopes/recipes, shared styled Agents/Settings implementation, profile-ID behavior/style branches, duplicate shells, stale fixtures, and compatibility paths are removed in the same delivery.
- **REQ-011 — Independent development.** Each profile renderer is implemented, tested, and committed in a disjoint Node after neutral ports stabilize; sibling Nodes have no file overlap.
- **REQ-012 — Bounded complexity.** Catalog validation is `O(N×M×V×D)`, lookup is expected `O(1)`, pairwise validation is `O(N²+E)`, runtime mounts one tree, and state/leases/caches are bounded by declarations.
- **REQ-013 — Verifiable client delivery.** Focused and aggregate layout/client gates, comparison-only evidence, Better Plan checks, rebuild/open, and independent Android verification prove the result.
- **REQ-014 — Commit discipline.** Every implementation Node is committed separately on the local branch and records its delivering commit before the next dependent Node begins.

## Final acceptance

Acceptance requires complete private renderers for every discovered profile/surface, no shared styled content path, exact frozen visual/semantic/interaction equality, dynamic isolation and mutation gates, safe switching/state/focus behavior, separate local commits, and successful client rebuild/open plus required Android verification. No current layout design may change.
