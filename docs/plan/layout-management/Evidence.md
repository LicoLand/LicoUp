# Layout Management Foundation Evidence

## Declaration-derived inventory

The plan intentionally does not duplicate a numeric layout count. The production composition is the inventory authority: let `N` be its registered profile definitions and `M` the declared runtime surfaces. The required renderer product is exactly `B = N × M` bundles.

| Evidence | Current behavior | Status |
| --- | --- | --- |
| Profile, environment, variant, and preference contracts | Typed declarations define identities, surface policy, viewport policy, destinations, and bounded presentation namespaces. | Catalog and composition tests derive the product without a numeric cardinality assumption. |
| Composition, catalog, registry, resolver, and manager | One immutable composition feeds the catalog, registry, Settings metadata, exact lookup, selection transactions, and active renderer. | Exact-product, arbitrary-catalog, injected-default, recovery, and serialized-state tests pass. |
| Canonical renderer ownership | Every concrete renderer is discovered below `frontend/layout/profiles/<profile>/<surface>/`. | The dynamic boundary verifier rejects missing, duplicate, stale, cross-profile, cross-surface, and scattered ownership. |
| Neutral runtime boundary | Profiles consume immutable chrome snapshots/actions, neutral palette input, and destination-presentation contracts. | Complete controller scope, backend/platform reach-through, shared styled chrome, and profile-ID feature branches are absent from renderer dependency closures. |
| Frozen visual evidence | Catalog-enumerated production Home, Agents, and Settings fixtures cover every registered bundle. | The aggregate layout suite and production baselines pass without refreshing post-freeze goldens. |
| Change isolation | Source manifests and transitive dependency closures are generated from composition data. | Pairwise checks and verifier mutation fixtures prove sibling ownership remains disjoint as `N` and `M` vary. |

## Frozen no-redesign baseline

The current worktree—not a historical fixed subset—is the authority for layout appearance, arrangement, semantics, focus order, motion, and interactions. Baseline tests enumerate the live composition and declared surfaces, then render representative Home, Agents, and Settings content. Existing controls and interaction geometry are part of that baseline.

Migration moved styled implementations into their owning profile/surface roots without using a post-freeze golden update. The superseded shared chrome, full-controller bridge, duplicate renderer paths, compatibility wrappers, and stale fixed SHA manifests were removed in the same cutover.

## Historical audit and correction

The pre-correction audit found contradictory fixed-subset documentation, no catalog-complete coverage command, shared styled chrome/controller reach-through, uneven profile evidence, and a dirty worktree that also contained unrelated user changes. It also recorded seven pre-existing sibling-plan validation issues without reclassifying them as layout work. Those observations explain the correction; they are not current product cardinality or current layout failures.

The resulting design follows primary Flutter patterns already used by the client: constraint-driven adaptation, explicit state ownership/restoration, keyed tree replacement, `ThemeExtension`-style appearance composition, and bounded widget work. The layout layer adds typed immutable registration and narrow presentation ports rather than a remote widget language, mutable service locator, or runtime layout code loading.

## Executable evidence

- Aggregate layout tests enumerate the registered product and cover contracts, behavior, adaptation, semantics, interaction, state, and goldens.
- Production baselines enumerate every registered bundle and representative destination directly from composition data.
- The visual-manifest verifier discovers profiles and surfaces, requires the exact `N × M` manifest product, and has mutation self-tests for cardinality drift.
- The boundary verifier discovers the same product, validates canonical/transitive ownership, and rejects forbidden dependencies, profile-ID branches, fixed-count assumptions, and retired paths.
- Settings, host, manager, resolver, and repository tests cover arbitrary catalogs, one active bundle, preview/confirm/cancel/reset/recovery, bounded state/focus, one injected preferred default, and appearance/locale orthogonality.
- For `B = N × M`, pairwise verification is generated from declarations rather than a handwritten current-inventory matrix.

## Current-only boundary

Retired layout naming is not an input. Missing, malformed, or unavailable current preferences recover directly through the injected platform preference used by manager and resolver. No reader, alias, translation, prompt, migration routine, competing default, renderer fallback, shared-chrome compatibility wrapper, or stale fixed-count acceptance path remains.

## Evidence limits

Repository-level layout evidence does not itself claim packaging, GitHub Release publication, store publication, or device installation. Desktop rebuild/open and independent Android delivery are recorded separately by the final catalog-driven node. Receipts remain privacy-minimal and exclude local paths, user content, device identity, accounts, credentials, secrets, ciphertext, and backend runtime data.
