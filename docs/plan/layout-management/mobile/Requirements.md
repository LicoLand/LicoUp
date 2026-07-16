# Mobile Layout Renderer Requirements

Upper constraint: [`../../product-scope/Requirements.md`](../../product-scope/Requirements.md). Mobile profiles expose Secure Client Mesh communication and settings only within the canonical product scope.

## Product problem

For the mobile runtime surface, every one of the `N` registered semantic profiles needs a complete compact/medium presentation bundle that consumes the same parent semantics while remaining independently developable and testable. The mobile renderer child must not encode a fixed profile count.

The current mobile worktree rendering is the no-redesign baseline recorded in `Evidence.md`. Isolation may move implementation into the correct owner but shall not alter current appearance, arrangement, labels, focus, semantics, animation, or interactions.

## Users and workflows

- Mobile users receive the selected semantic profile's mobile presentation after the parent resolves the active surface and viewport policy.
- Users reach the same allowed mobile destinations and semantic actions in every profile without learning controller, relay, platform, or persistence implementation details.
- A maintainer can change one mobile bundle's shell, adapters, components, assets, restoration namespace, tests, or goldens without affecting another bundle.
- Adding a profile adds one independent mobile directory/bundle plus composition registration; it does not change existing profiles or layout-management algorithms.

## Requirements

- **REQ-001 — Registration-derived mobile bundle set.** For every one of the `N` parent-registered profiles, mobile shall export exactly one immutable `LayoutSurfaceBundle` below `frontend/layout/profiles/<profile>/mobile/`, with corresponding profile-owned test and asset roots, using the same semantic ID/label metadata, mobile surface policy, destination catalog, environment, appearance input, and narrow state/command ports. Missing, extra, duplicate, or scattered mobile entries fail before integration; no bundle defines a second identity, preference authority, manager, mutable registry, or metadata list.
- **REQ-002 — Frozen whole-presentation fidelity.** Every bundle shall preserve its current complete mobile shell, navigation, component recipes, density, hierarchy, metrics, motion, preview, and compact/medium behavior. Privatization shall retain byte-equivalent constants/metrics and pixel-, semantics-, focus-, animation-, and interaction-equivalent output against the current baseline.
- **REQ-003 — Private styled composition.** Each bundle shall own navigation, cards, fields, dialogs, status, composer-adjacent chrome, tokens, and visual metrics. It shall not import or select another profile's implementation, share visually opinionated chrome/metrics, or branch on profile IDs. Semantic parity does not authorize structural or styled reuse.
- **REQ-004 — Exact mobile destination adapters.** Every bundle shall implement the exact parent-declared mobile destination/action set through profile-owned adapters, including representative Home, Agents, and Settings content and any declared pairing/relay entry. Adapters consume narrow immutable state/callback ports, preserve parent capability decisions, and never fall back to a sibling adapter.
- **REQ-005 — Layout-neutral state and lifecycle rendering.** Bundles render parent-owned navigation, selected agent/session, drafts, operations, permissions, capabilities, and lifecycle state without copying authority. Bundle-local scroll, expansion, pane, overlay, and semantic-focus state uses bounded bundle-qualified namespaces and is reconstructible when the parent replaces the active tree.
- **REQ-006 — Constraint-driven mobile variants.** Every bundle responds to the registered mobile viewport policy, local constraints, safe/keyboard insets, text scale, reduced motion, and input capabilities. Orientation, device marketing name, and operating-system name do not choose or persist profile identity, and no bundle borrows another runtime surface's chrome.
- **REQ-007 — Mobile accessibility and per-bundle proof.** Every registered mobile bundle shall have independent behavior, adaptive, semantic, golden, and source-manifest coverage. Tests prove equivalent actions, touch targets, traversal, visible focus, text scaling, contrast, safe-area and composer clearance, reduced motion, overflow resistance, and frozen visual/interaction fidelity with Home, Agents, and Settings fixtures.
- **REQ-008 — Renderer-only delivery and extensibility.** Mobile implementation owns only composition-derived profile roots and their evidence. It does not edit central manager/resolver/host/Settings algorithms, preference storage, another profile, native projects, or product-wide integration. Adding profile `N + 1` follows the same bundle/test pattern; parent integration alone adds composition registration and owns current-only cutover.
- **REQ-009 — Renderer verification receipt.** The child finishes with source-scoped format/analysis, every bundle's behavior/adaptive/semantic/golden/source-manifest suites, exact registration-manifest checks, hard-boundary verification, pairwise impact proof, and scoped Better Plan validation. Native builds, devices, aggregate app tests, packaging, release, and store claims remain parent-owned.
- **REQ-010 — Independent bundle isolation and complete migration.** Each profile exclusively owns mobile source, shell, styled chrome/metrics, destination presentation, components, tokens, preview, assets, restoration namespace, fixtures, tests, source manifest, and goldens inside its canonical profile root. Concrete mobile style, components, metrics, chrome, and destination presentation shall not live in shared feature UI or shell paths. Bundles may depend only on presentation contracts, narrow semantic ports, localization, appearance colors, and style-free primitives. Shared styled chrome/metrics and full-controller bridges shall be deleted after equivalent privatization, with no compatibility wrapper. A directed `N(N − 1)` mobile change-impact matrix shall prove that changing one bundle leaves every other bundle's source, output, golden, and state unchanged.

## Scope

- One independently owned mobile bundle for every profile at `frontend/layout/profiles/<profile>/mobile/`, with mirrored profile-owned test and asset roots.
- Profile-private shell/chrome/components, destination adapters, tokens, previews, assets, restoration namespaces, tests, source manifests, and goldens.
- Renderer verification and a parent-consumable handoff unchanged as `N` grows.

## Non-goals

- Fixing the number or names of supported profiles in renderer or management algorithms.
- Editing the central registry/composition implementation, application/controller wiring, host, Settings, preference persistence, or native projects.
- Redesigning current mobile layouts or preserving fallback/shared styled implementations.
- Proving whole-app selection transactions, native build/install/launch, packaging, release, or store publication as renderer evidence.

## Final acceptance target

The child is accepted when composition-derived cardinality yields exactly `N` independently owned mobile bundles; every bundle preserves its frozen presentation through narrow semantic ports; all behavior/adaptive/semantic/golden/source-manifest suites and Home/Agents/Settings fixtures pass; shared styled chrome and controller access are gone; the `N(N − 1)` impact matrix proves pairwise independence; and adding a profile requires only its own mobile bundle/evidence plus parent composition registration.
