# Catalog-Driven Layout Isolation Validation

## Generic evidence matrix

| Requirement | Evidence |
| --- | --- |
| REQ-001, REQ-002 | Composition/catalog tests derive `N`, `M`, `N×M`, viewport, destination, and namespace products from declarations; directory/registration equality and mutation fixtures prove missing, duplicate, and extra values fail. |
| REQ-003, REQ-004 | Profile-owned manifests, transitive import closure, forbidden-import scans, no-second-inventory checks, and dynamically discovered per-profile suites. |
| REQ-005, REQ-006, REQ-007 | Neutral-port adapter tests, manager state-machine/repository tests, dynamic Settings tests, and one injected preferred-default test matrix. |
| REQ-008, REQ-009 | Host/integration tests for one active tree, bounded state/focus continuity, and independent appearance/layout changes. |
| REQ-010 | Frozen pre/post production fixtures, pixel/semantics/interaction comparisons, and reviewed goldens for every registered bundle. |
| REQ-011, REQ-012 | Dynamic verifier self-tests, synthetic profile/surface additions, pairwise change-impact checks, retired/shared path scans, and absence of profile-ID behavior/style branches or manually maintained identity inventories. |
| REQ-013 | Construction and lookup complexity assertions, bounded state/cache tests, and serialized persistence tests. |
| REQ-014 | Scoped client gates, Better Plan checks, macOS rebuild/open, and independent Android verification. |

## Required dynamic checks

- Enumerate the production registration definitions and typed runtime-surface declaration; derive `N`, `M`, and `N × M` at run time and assert the exact bundle product without a numeric literal.
- Enumerate canonical profile directories independently and require exact identity-set equality with the registration definitions. Do not persist either enumeration as a second manual identity inventory.
- For every definition and surface, verify exact viewports, destinations, namespaces, assets, preview, source manifest, behavior, adaptive, semantics, interaction, and golden coverage.
- Verify that every concrete layout source resolves below `frontend/layout/profiles/<profile>/<surface>` and that mirrored asset/test ownership matches the same profile/surface identity; reject styled layout files elsewhere.
- Add one synthetic profile with one private bundle for each discovered surface and prove no management, Settings, host, or verifier algorithm changes; add one synthetic surface and prove every registered profile is required to contribute exactly one new bundle.
- Render the frozen production fixture matrix for every discovered bundle under its declared viewport/input/accessibility policy.
- Compare frozen pre/post pixels, semantics, keys, and interactions without updating the frozen baseline after correction work begins.
- Build each profile's transitive import closure and reject all intersections except an explicit style-free semantic allowlist. Reject shared styled chrome/presentation policy, shared complete-controller access, platform/backend reach-through, and sibling-profile imports.
- Reject every switch, conditional, factory, or lookup table that selects behavior or styling from a known profile ID, plus every hand-maintained profile identity list outside the canonical registration definitions.
- For each profile, mutate a fixture digest and prove every sibling digest remains unchanged.
- Exercise Settings discovery, preview, confirm, cancel, reset, load recovery, persistence failure, rapid updates, and appearance/locale orthogonality from the live catalog.
- Prove only the active bundle is mounted and profile/surface state plus focus remain bounded and disjoint.
- If a receipt reports observed cardinalities, record them with the run timestamp and source declaration hashes as evidence only; no acceptance criterion compares them with a predetermined value.

## Delivery gates

After the correction implementation is complete, rerun the catalog/profile layout verifier and its arbitrary-profile/surface mutation self-tests, targeted and aggregate Flutter tests, frozen comparison-only evidence, scoped analysis/format/architecture/contracts checks, and scoped Better Plan validation and label checks; then rebuild/open macOS. An independent subagent performs the Android debug build and reports authorized-device discovery/install/launch separately. Earlier fixed-inventory or pre-correction receipts cannot satisfy this gate.
