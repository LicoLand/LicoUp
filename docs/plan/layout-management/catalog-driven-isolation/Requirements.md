# Catalog-Driven Layout Isolation Requirements

Upper constraint: [`../../product-scope/Requirements.md`](../../product-scope/Requirements.md). Every registered renderer exposes only the canonical product destinations and consent boundaries.

## Product contract

The client supports an open-ended set of complete presentation profiles. Let `N` be the number of immutable profile definitions registered at the production composition root and let `M` be the number of members in the typed runtime-surface declaration. The verifier independently discovers the canonical profile directories and requires their identity set to equal the registration set; directory discovery is an ownership check, not a second runtime identity authority. The valid renderer product contains exactly `N × M` `LayoutSurfaceBundle` instances. Neither cardinality is a management constant, acceptance limit, or hand-maintained inventory.

The repository's currently registered profiles and surfaces are delivery evidence only. Their current worktree rendering, semantics, labels, geometry, motion, and interactions are frozen inputs for this migration and must not be redesigned.

At any verification run, the observed values of `N`, `M`, and `N × M` may be emitted only as timestamped evidence from that run. An observed value must never become a source constant, fixture assumption, acceptance target, default policy, or upper bound.

## Requirements

- **REQ-001 — Declaration-derived cardinality without a second inventory.** Composition, registry, Settings, manager, host, tests, and verification shall derive `N`, `M`, and `N × M` from the canonical typed definitions. The verifier shall compare discovered profile directories with registered profile IDs by exact set equality, without introducing a second manual profile list. Adding one profile changes only its private renderer family and the single composition registration.
- **REQ-002 — Exact Cartesian product.** Every registered profile shall provide exactly one bundle for every member of the declared runtime-surface set. Each bundle shall provide exactly the surface-required viewport variants and semantic destinations; missing, duplicate, and extra members fail deterministically. Adding a runtime surface requires one bundle from every registered profile but no count-specific management change.
- **REQ-003 — One canonical layout root with complete profile ownership.** All production layout implementations shall live under `frontend/layout/profiles/<profile>/<surface>/`. Each profile owns its shells, navigation, destination presentation, styled chrome and metrics, components, tokens, previews, restoration namespaces, and bundle entry points below that one private subtree. Profile assets and verification artifacts mirror the same `<profile>/<surface>` ownership under their canonical asset and test roots; no concrete layout implementation may be scattered through shared feature, shell, or utility directories.
- **REQ-004 — Hard independence.** A profile may depend only on Flutter/Dart, presentation contracts, localization, neutral palette input, and narrow semantic state/action ports. It may not import another profile, a shared complete controller, backend/platform/shell implementations, shared styled chrome or presentation policy, or any shared profile-specific branch.
- **REQ-005 — Neutral business boundary.** Business state, commands, permissions, selected destination/conversation, drafts, and running work remain above renderers. Profile-facing ports expose minimum immutable semantic snapshots, bounded notifications, and callbacks only; they do not expose a widget-producing styled surface or a complete controller.
- **REQ-006 — One selection authority.** One `LayoutManager` owns hydration, preview, confirm, cancel, reset, recovery, and persistence. Settings and the host consume it; no second mutable layout field, preference setter, resolver default, or manual profile list exists.
- **REQ-007 — One preferred-default authority.** Catalog default metadata and platform-preferred initial/reset policy remain typed concepts. Manager, resolver, load recovery, reset, and invalid-selection recovery consume the same injected preferred default for the active platform.
- **REQ-008 — State and focus continuity.** Switching profiles preserves business state and semantic focus while profile/surface presentation state remains bounded and disjoint. Only the active bundle is mounted.
- **REQ-009 — Orthogonal appearance.** Appearance owns palette and brightness; profiles own structure and non-color visual decisions. Switching either axis does not reset the other.
- **REQ-010 — Frozen-design migration.** Styled code is copied into private ownership before the shared implementation is deleted. Pre/post renders, semantics, keys, and interactions must match; post-freeze golden refresh cannot hide a change.
- **REQ-011 — Dynamic verification.** Tests and gates enumerate registered definitions, declared runtime surfaces, and canonical profile directories; validate the exact Cartesian product; inspect transitive imports; and generate pairwise change-impact checks without fixed counts, fixed identities, or manually curated profile inventories.
- **REQ-012 — Complete migration.** Superseded shared styled chrome and presentation policy, shared full-controller scopes, duplicate shell/platform paths, every behavioral or styling branch on profile ID, stale fixtures, and compatibility paths are deleted in the same delivery. Profile IDs may remain as immutable declaration data and identity-contract test inputs, never as a switch, conditional, or lookup table that selects behavior or styling.
- **REQ-013 — Bounded complexity.** Composition validation is `O(N × M × V × D)` once per immutable catalog revision; profile/bundle/variant lookup is `O(1)`; persistence is serialized; caches and presentation state are bounded by the catalog.
- **REQ-014 — Verifiable client delivery.** Repository checks, profile/golden suites, macOS rebuild/open, and independent Android build/device handling prove the current catalog product without conflating packaging or store release.

## Scope and non-goals

Scope includes layout contracts, composition, registry, manager, host, neutral ports, profile renderers, Settings, state/focus, verification, documentation, and client build/launch evidence. It excludes server policy, executable remote layouts, arbitrary widget JSON, packaging/publication claims, compatibility with retired state, and any redesign of the current layouts.

## Final acceptance

Acceptance requires one declaration-derived `N × M` product, exact directory/registration equality, exact profile/surface coverage, every concrete implementation concentrated below the canonical profile root, independently owned renderers, no shared styled chrome, no shared complete controller, no profile-ID behavior/style branch, no second profile identity inventory, unchanged current visuals/interactions, safe transactional switching, generated verification for every discovered bundle and pair, and successful client build/launch checks.
