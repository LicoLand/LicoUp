# Mobile Layout Renderer Architecture

## Parent contract and cardinality boundary

The mobile child consumes parent presentation contracts, semantic destinations, narrow state/command and shell ports, mobile environment policy, token/component roles, restoration interfaces, fixture host, and `LayoutSurfaceBundle`. It does not redefine or mutate them.

For `N` registered profiles, the child produces exactly `N` artifacts:

```text
<profile-1>/mobile/<profile-1>_mobile_bundle.dart -> one immutable mobile bundle
…
<profile-N>/mobile/<profile-N>_mobile_bundle.dart -> one immutable mobile bundle
```

Bundles never register themselves. Parent composition imports their public entries once and derives catalog, registry, Settings metadata, and expected test/manifest product. Adding a profile creates one independent mobile root and one composition entry; it changes no existing profile or manager/resolver/host/Settings algorithm.

## Module and ownership pattern

The canonical production root is `frontend/layout/profiles/<profile>/mobile/`; tests and optional assets mirror it under `test/layout/profiles/<profile>/mobile/` and `assets/layout-profiles/<profile>/mobile/`. Shared layout infrastructure is limited to contracts, composition/registry, host/scope/focus, and neutral ports. Concrete mobile shell/chrome, style, metrics, components, and destination presentation may not be placed in shared feature UI or `frontend/shell`.

```text
apps/desktop/lib/src/frontend/layout/profiles/<profile>/mobile/
├── <profile>_mobile_bundle.dart      # only public entry
├── <profile>_mobile_shell.dart       # private shell/navigation/chrome
├── <profile>_mobile_components.dart  # private styled recipes
├── <profile>_mobile_tokens.dart      # private metrics/non-color tokens
├── <profile>_mobile_preview.dart     # deterministic preview
└── destinations/                     # profile-owned adapters

apps/desktop/test/layout/profiles/<profile>/mobile/
├── behavior/interaction coverage
├── adaptive/lifecycle coverage
├── semantic/accessibility coverage
├── golden coverage
└── normalized source-manifest coverage
```

Each root exclusively owns shell, chrome, metrics, components, adapters, preview, assets, restoration IDs, tests, source manifest, and goldens. No renderer node owns central composition algorithms, application/controller wiring, host, Settings, preferences, native projects, command aggregation, or shared product documentation.

## Dependency direction and ports

```text
bundle entry
├── destination adapters -> semantic destinations + narrow feature ports
├── shell/preview         -> LayoutShellPort + private components + environment
└── private components    -> private tokens/metrics + appearance colors
                              -> presentation contracts/style-free primitives
```

Adapters translate immutable state/callbacks into profile-private composition. They do not make capability/readiness decisions, import controllers, call backend/platform services, persist selection, or infer identity. Home, Agents, and Settings are mandatory production fixtures; every other declared mobile destination participates in the same exact-set product.

`LayoutShellPort` exposes semantic navigation/search/status/capability facts and callbacks only. It has no controller, domain service, repository, platform object, styled widget, color, spacing, or profile metric. Each bundle owns placement, hierarchy, navigation mode, icons, focus behavior, animation, and status rendering. No renderer/shared feature branches on profile IDs; typed registry lookup selects the bundle.

The public entry assembles immutable compact/medium builders in O(1)-lookup maps and exports no shell/component/adapter/state internals or mutable registration handle.

## Frozen presentation ownership

Currently registered mobile bundles retain the exact worktree appearance and behavior captured in `Evidence.md`. Shared styled chrome and metrics are migration inputs, not a permanent reuse layer. Each bundle receives a private copy of constants, geometry, icons, focus behavior, semantics, animations, and callbacks it currently renders. Full-controller reads are replaced with semantically equivalent port values/actions.

Privatization passes only with byte-equivalent constants/metrics and pixel-, semantics-, focus-, and interaction-equivalent output. Parent integration then deletes shared chrome/metrics, controller scope/bridge, duplicate shell authority, and superseded tests in the same cutover. No forwarding export, fallback, wrapper, or compatibility import survives.

## Destination, state, and adaptation

Every bundle declares the exact parent mobile destination set and one profile-owned adapter per destination. Missing/extra keys fail bundle tests. Pairing/relay remains a semantic action governed above the renderer.

Bundles receive immutable agent/session/conversation/draft/operation/permission/lifecycle snapshots and commands. Domain state remains above rendering. Scroll, pane, overlay, expansion, and focus use bounded `(profile, mobile, destination, surfaceId)` namespaces. Rebuilding from identical supplied state reproduces semantic selection without retaining inactive trees.

The parent selects the mobile viewport variant from registered policy and local environment facts. Within a variant, the bundle responds to safe/keyboard insets, text scale, reduced motion, and input facts. Device class/name, OS name, and orientation never select profile identity. Navigation remains clear of active composer geometry.

## Data structures and complexity

- **Strategy** is one complete mobile presentation bundle per registered profile.
- **Adapter** maps stable feature ports into profile-specific destinations.
- **Factory plus immutable bundle** provides one public handoff without mutation or ID branches.
- Immutable maps provide O(1) variant/destination lookup after finite exact-set validation.
- Adding profile `N + 1` increases only registration data and one independent root; no management algorithm changes.

There is no service locator, plugin loader, widget DSL, code-generation layer, shared styled component kit, compatibility wrapper, or mobile-specific layout manager.

## Isolation and verification invariants

- Profile source, asset, restoration, fixture, test, source-manifest, and golden roots never overlap.
- Each public entry exposes exactly one immutable mobile bundle; internals stay private.
- Equivalent fake-port scenarios assert semantic parity; profile-owned landmarks and current-baseline goldens assert fidelity.
- The verifier derives expected mobile entries from composition, enforces canonical production/test/asset roots, rejects concrete presentation in shared feature/shell paths, cross-profile imports, full-controller access, shared chrome/metrics, backend/platform/native imports, mutable registration, ownership overlap, and imports of entries outside composition.
- For each of `N` mobile bundles, one deterministic fixture mutation leaves the other `N − 1` source manifests and golden digests unchanged: `N(N − 1)` directed assertions.
- Renderer evidence authorizes parent integration only; it does not claim selection cutover, native build/install/launch, packaging, or release.
