# Desktop Layout Profiles Architecture

## Parent contract and cardinality boundary

The desktop child consumes the parent immutable presentation contracts, semantic destination catalog, narrow state/command and shell ports, desktop environment policy, visual-token/component-role interfaces, fixture host, and `LayoutSurfaceBundle` type. It does not redefine or mutate them.

For `N` registered profiles, the child produces exactly `N` artifacts:

```text
<profile-1>/desktop/<profile-1>_desktop.dart -> one immutable desktop bundle
…
<profile-N>/desktop/<profile-N>_desktop.dart -> one immutable desktop bundle
```

Bundles never register themselves. The parent composition imports their public entries once and derives catalog, registry, Settings metadata, and the expected test/manifest product. Adding a profile creates one new independent desktop root and one composition entry; it changes no existing profile or manager/resolver/host/Settings algorithm.

## Module and ownership pattern

The canonical production root is `frontend/layout/profiles/<profile>/desktop/`; tests and optional assets mirror that ownership under `test/layout/profiles/<profile>/desktop/` and `assets/layout-profiles/<profile>/desktop/`. Shared layout infrastructure is limited to contracts, composition/registry, host/scope/focus, and neutral ports. Concrete desktop shell/chrome, style, metrics, components, and destination presentation may not be placed in shared feature UI or `frontend/shell`.

```text
apps/desktop/lib/src/frontend/layout/profiles/
├── <profile-1>/desktop/
│   ├── <profile-1>_desktop.dart        # only public bundle entry
│   ├── shell/                          # profile-private shell and styled chrome
│   ├── components/                     # profile-private styled recipes
│   ├── tokens/                         # profile-private metrics/non-color tokens
│   ├── preview/                        # deterministic preview
│   └── destinations/                   # profile-owned adapters
├── …
└── <profile-N>/desktop/...

apps/desktop/test/layout/profiles/<profile>/desktop/
├── behavior/interaction coverage
├── adaptive coverage
├── semantic/accessibility coverage
├── golden coverage
└── normalized source-manifest coverage
```

Every profile root exclusively owns its shell, chrome, metrics, components, adapters, preview, assets, restoration IDs, tests, source manifest, and goldens. No implementation node owns the central registry, composition algorithm, application/controller wiring, host, Settings, package command aggregation, or shared product documentation.

## Dependency direction and interfaces

```text
bundle entry
├── destination adapters -> semantic destinations + narrow feature ports
├── shell/preview         -> LayoutShellPort + private components + environment
└── private components    -> private tokens/metrics + appearance colors
                              -> presentation contracts/style-free primitives
```

Destination adapters map immutable semantic state and callbacks into profile-private widgets. They do not resolve identity, query services, persist selection, or enforce capability policy. Home/control, Agents/conversations, and Settings are mandatory production fixtures; other parent-declared desktop destinations participate in the same exact-set product.

`LayoutShellPort` exposes semantic destination/search/status/capability facts and callbacks only. It has no `ClientController`, domain service, repository, platform object, styled widget, color, spacing, or profile-specific metric. The profile owns how those facts are placed and styled. No renderer or shared feature may branch on profile IDs; typed registry lookup selects the bundle.

The public entry creates one immutable manifest and builder map. It exports no shell class, component, adapter, mutable registry handle, or profile state. Parent validation rejects missing/extra destinations and viewport builders before integration.

## Frozen presentation ownership

The currently registered desktop bundles retain the exact worktree appearance and behavior captured in `Evidence.md`. Shared styled chrome and metrics are not a legitimate reuse layer; they are migration input. Each profile receives a private copy of the constants, geometry, icons, focus behavior, semantics, animations, and callbacks it currently renders. Full-controller reads are replaced with semantically equivalent port values/actions.

Privatization is accepted only after byte-equivalent constants/metrics and pixel-, semantics-, focus-, and interaction-equivalent outputs pass. The parent then deletes shared chrome, shared visual metrics, controller scope/bridge, duplicate shell authority, and superseded tests in the same cutover. No forwarding export, fallback, wrapper, or compatibility import survives.

## State, switching, and adaptation

Bundles receive semantic destination, immutable display state, commands, environment facts, appearance palette, and bundle-qualified presentation-state access. They do not own selected layout, persistence, preview transaction, domain state, permissions, or operations.

Pane width, local tabs, scroll, expansion, and focus use bounded `(profile, desktop, destination, surfaceId)` namespaces. A fixture host replaces any active bundle with another while retaining fake semantic state; it never keeps all bundles mounted. Desktop constraints and input facts select a bundle-local registered viewport variant but never persist identity.

## Data structures and complexity

- **Strategy** is one complete desktop presentation bundle per registered profile.
- **Adapter** maps parent feature ports into profile-specific destinations.
- **Factory plus immutable bundle** provides one narrow public handoff without registry mutation or ID branches.
- Immutable maps keyed by typed variant and destination provide O(1) runtime lookup after one finite exact-set validation.
- The desktop child contains no profile-count branches. Adding profile `N + 1` increases only registration data and one independent bundle/test root.

There is no plugin loader, widget DSL, service locator, compatibility wrapper, shared styled component hierarchy, or profile-specific manager.

## Isolation and verification invariants

- Profile source, asset, restoration, fixture, test, source-manifest, and golden roots never overlap.
- Only each profile's public entry exposes its immutable desktop bundle; internals remain private.
- Equivalent fake-port scenarios assert semantic parity; profile-owned landmarks and current-baseline goldens assert presentation fidelity.
- The boundary verifier derives expected desktop entries from composition, enforces canonical production/test/asset roots, rejects concrete presentation in shared feature/shell paths, cross-profile imports, full-controller access, shared chrome/metrics, backend/platform imports, mutable registration, ownership overlap, and imports of entries outside composition.
- For each of `N` desktop bundles, a deterministic fixture mutation leaves the other `N − 1` source manifests and golden digests unchanged: `N(N − 1)` directed assertions.
- Renderer validation produces bundle receipts only. Parent integration owns mounted behavior, current-only state, deletion of superseded authorities, build, and launch.
