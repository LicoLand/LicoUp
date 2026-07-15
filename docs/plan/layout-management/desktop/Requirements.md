# Desktop Layout Profiles Requirements

## Product problem

For the desktop runtime surface, every one of the `N` registered semantic profiles needs a complete presentation bundle that consumes the same parent-owned semantics while remaining independently developable, reviewable, and testable. The desktop renderer child must not encode a fixed profile count.

The current desktop worktree rendering is the no-redesign baseline recorded in `Evidence.md`. Isolation may move implementation into the correct owner but shall not alter current appearance, arrangement, labels, focus, semantics, animation, or interactions.

## Users and workflows

- Desktop users receive the selected profile's full desktop presentation for the same destinations, actions, drafts, sessions, and running operations.
- Keyboard and pointer users retain predictable navigation, focus, text scaling, contrast, and reduced-motion behavior across the desktop surface's registered viewport policy.
- A maintainer can change one desktop bundle's shell, components, adapters, assets, tests, or goldens without changing any other profile.
- Adding a profile adds one independent desktop directory/bundle plus composition registration; it does not change existing profiles or layout-management algorithms.

## Requirements

- **REQ-001 — Complete registration-derived desktop bundle set.** For every one of the `N` profiles in parent composition, the desktop child shall export exactly one immutable desktop `LayoutSurfaceBundle` below `frontend/layout/profiles/<profile>/desktop/`, with corresponding profile-owned test and asset roots. Each bundle carries the same semantic ID/label metadata, all desktop viewport variants, exact destinations, shell, styled chrome/metrics, components, tokens, preview, and restoration namespace. Missing, extra, duplicate, or scattered desktop bundles fail before integration.
- **REQ-002 — Frozen whole-presentation fidelity.** Every bundle shall preserve its current complete desktop presentation, not merely a top bar or navigation rail. Privatization shall retain byte-equivalent constants/metrics and pixel-, semantics-, focus-, animation-, and interaction-equivalent output against the current baseline. Protected current profile-specific controls are enumerated in `Evidence.md` and exact-current tests.
- **REQ-003 — Exact desktop capability parity.** Every desktop bundle shall implement the exact parent-declared desktop destination and action set, including representative Home/control, Agents/conversations, and Settings content, without copying business logic or substituting a sibling renderer.
- **REQ-004 — Switch-ready narrow renderer contract.** Each bundle shall be side-effect-free, expose deterministic preview and semantic focus/restoration landmarks, and render correctly when the parent host replaces it with any other registered profile. Shell chrome shall consume only the narrow semantic `LayoutShellPort`; no bundle may import `ClientController`, controller scope, repositories, platform objects, or styled widget injection. A renderer shall not read, write, confirm, cancel, or reset layout preferences.
- **REQ-005 — Layout-neutral state consumption.** Bundles shall consume only immutable layout-neutral feature state and command ports. Destination, selected session, drafts, permissions, capability decisions, and active operations remain above renderer widgets; bundle-local pane, scroll, expansion, tab, and focus state uses bounded, bundle-qualified namespaces.
- **REQ-006 — Constraint-driven desktop adaptation.** Every bundle shall provide the complete parent-declared desktop viewport set and preserve its visual identity across supported constraints and input capabilities. Resize shall not mutate profile identity, persist preferences, borrow another surface's chrome, or introduce overflow.
- **REQ-007 — Desktop accessibility and per-bundle proof.** Every registered desktop bundle shall have independent behavior, adaptive, semantic, golden, and source-manifest coverage. Tests shall prove keyboard, pointer, semantics, focus order, text scale, contrast, reduced motion, appearance composition, exact capability parity, and frozen visual/interaction fidelity with representative Home, Agents, and Settings fixtures.
- **REQ-008 — Renderer-only integration handoff and extensibility.** The child shall deliver the `N` registration-derived desktop bundle entries and profile-owned evidence. It shall not edit central manager/resolver/host/Settings algorithms, preference wiring, or another profile. The parent join alone adds composition registrations and owns app cutover, complete-migration deletion, build, and launch. Adding profile `N + 1` follows the same path without changing this contract or existing bundle code.
- **REQ-009 — Independent bundle isolation and complete migration.** Each profile exclusively owns its desktop source, shell, styled chrome/metrics, destination presentation, components, tokens, preview, assets, restoration namespace, fixtures, tests, source manifest, and goldens inside its canonical profile root. Concrete desktop style, components, metrics, chrome, and destination presentation shall not live in shared feature UI or shell paths. Bundles shall not import each other, the full controller, shared shell, backend/platform implementations, shared styled chrome/metrics, or sibling state/assets/tests. The shared chrome and controller bridge shall be deleted after equivalent privatization, with no compatibility wrapper. Static gates and a directed `N(N − 1)` desktop change-impact matrix shall prove that changing one bundle cannot alter any other bundle's source, output, golden baseline, or state.

## Scope

- One independently owned desktop bundle for every profile at `frontend/layout/profiles/<profile>/desktop/`, with mirrored profile-owned test and asset roots.
- Profile-private shell/chrome/components, destination adapters, tokens, previews, assets, restoration namespaces, tests, source manifests, and goldens.
- Renderer verification and a parent-consumable handoff that remains unchanged as `N` grows.

## Non-goals

- Fixing the number or names of supported profiles in renderer or management algorithms.
- Editing the central registry/composition implementation, application/controller wiring, host, Settings, or preference authority.
- Redesigning current desktop layouts or removing current interactions.
- Forking domain controllers, backend services, authorization, capability policy, or native desktop implementations by profile.
- Preserving old IDs, aliases, wrappers, shared visually opinionated widgets, or fallback from one profile to another.

## Acceptance target

The child is accepted when composition-derived cardinality yields exactly `N` independently owned desktop bundles; every bundle preserves its frozen presentation through narrow semantic ports; all per-bundle behavior/adaptive/semantic/golden/source-manifest suites and Home/Agents/Settings fixtures pass; shared styled chrome and controller access are gone; the `N(N − 1)` impact matrix proves pairwise independence; and adding a profile requires only its own desktop bundle/evidence plus parent composition registration.
