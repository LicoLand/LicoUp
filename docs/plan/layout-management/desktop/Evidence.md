# Desktop Layout Profiles Evidence

## Declaration-derived desktop product

The desktop plan does not prescribe a profile count. For the `N` profiles registered by the production composition, the desktop surface requires exactly one private desktop bundle per profile. Public entries and evidence roots are discovered from the same typed definitions used by the catalog.

Adding a profile adds its own `profiles/<profile>/desktop/` implementation and one composition registration. Existing profiles and layout-management algorithms do not change.

## Frozen no-redesign evidence

The current worktree render is authoritative for appearance, arrangement, semantics, focus order, motion, and interactions. Existing controls retain their geometry, labels, focus/semantics, animation, and activation behavior after privatization.

Catalog-enumerated production fixtures cover Home, Agents, and Settings for every registered desktop bundle. Profile-owned behavior, adaptive, semantic, interaction, golden, and source-manifest suites pass without a post-freeze golden refresh.

## Isolation closure

- shell chrome, navigation, metrics, destination presentation, previews, tests, and goldens are profile-private;
- profiles consume only neutral contracts, palette input, and immutable semantic ports;
- the shared styled chrome and complete controller scope are deleted;
- the dynamic verifier rejects sibling imports, backend/platform/shell implementations, shared styled metrics, profile-ID branches, compatibility fallbacks, and ownership outside the canonical root;
- per-surface pairwise verification is generated as `N(N − 1)` directed sibling assertions rather than a fixed current matrix.

## Migration rationale and ownership consequence

The pre-migration desktop audit found styled shell chrome/metrics and complete controller access reachable from multiple profile trees, while profile-owned coverage was uneven. That gap justified disjoint shell/component, destination, preview, test, golden, and manifest ownership. The current closure is renderer-local; central registration, switching, current-state enforcement, build, and launch remain parent responsibilities.

## Evidence limits

Desktop renderer evidence is separate from whole-client build, launch, packaging, release, and store claims. Receipts exclude local paths, user content, device identity, backend runtime data, credentials, secrets, and ciphertext.
