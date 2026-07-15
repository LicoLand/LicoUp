# Layout Management Foundation Architecture

## Registration-product architecture

The runtime is cardinality-independent. An immutable composition registers `N` semantic profiles and `M` runtime surfaces, producing exactly `B = N × M` independently owned `LayoutSurfaceBundle` values.

```text
Layout Management Foundation
├── Surface renderer child 1: N independent profile bundles
├── …
└── Surface renderer child M: N independent profile bundles
```

- Foundation owns contracts, registration-derived catalog/registry metadata, resolution, selection, preferences, bounded state/focus, narrow semantic ports, fixture tests, and the final integration join.
- Each surface child owns one bundle per registered profile, with profile-private styled chrome/metrics, assets, tests, source manifests, and goldens.
- The integration join alone owns composition registration, app/controller wiring, Settings, complete-migration cutover, aggregate verification, rebuild/open, and platform verification.

Foundation code imports no built-in renderer. Adding a profile creates its own directory and one bundle for every registered surface, then adds those entries to composition. It does not edit another profile or change catalog, registry, manager, resolver, host, Settings, persistence, or verification algorithms. Adding a surface follows the dual rule: add one bundle per profile and register the new surface policy without changing existing bundles.

## Identity and default authorities

Each immutable profile registration provides a typed semantic ID, localized label metadata, style identity, and catalog-default flag. Catalog construction requires exactly one default. Separately, integration injects one `LayoutProfileDefaults.preferredForPlatform` value, validated as a registered ID, into first run, reset, loading recovery, manager, and resolver. Catalog default and platform preference have distinct roles and cannot silently substitute for each other. Current concrete registrations and preferred values are inventory evidence in `Evidence.md`, not architecture constants.

## Runtime layers

### Pure presentation contracts

- `layout_profile.dart` owns validated IDs, immutable descriptors, localized metadata keys, unique-default metadata, style identity, and safe validation codes.
- `layout_environment.dart` owns registered surface identities, surface-owned viewport policies, constraints, input capabilities, safe insets, text scale, and reduced-motion facts.
- `layout_variant.dart` owns immutable `(profile, surface, viewport)` keys and destination coverage manifests.
- `layout_state_namespace.dart` owns validated bundle/destination-local presentation-state addresses that cannot carry arbitrary paths or business IDs.
- `layout_selection.dart` owns immutable manager state, resolved values, operation status, and bounded user-safe errors.
- `presentation_preferences.dart` is the one current document containing layout, appearance, and locale preferences.
- `semantic_destination.dart` is the canonical destination identity and surface capability metadata.

Contracts import no application, frontend, platform, or backend implementation.

### Application layer

- `layout_catalog.dart` consumes the immutable registration product and derives ordered profile metadata plus exact coverage maps. Construction validates `N`, `M`, all `N × M` bundles, one catalog default, surface viewport policies, destination products, and deterministic order.
- `layout_resolver.dart` performs O(1) lookup by typed variant key and holds one active resolution cache entry.
- `layout_manager.dart` is the only selection state owner and exposes initialization, preview, confirm, cancel, and reset against the injected preferred default.
- `layout_state_store.dart` owns bounded presentation-only state under catalog-declared namespaces.
- `semantic_destination_catalog.dart` derives surface visibility and semantic aliases before rendering and exposes commands through narrow interfaces.

`ClientController` may compose these authorities and semantic adapters at integration, but no renderer receives, imports, or discovers `ClientController`.

### Platform layer

- `presentation_preferences_repository.dart` owns one serialized mutation tail and canonical atomic storage.
- `appearance_preset_catalog_service.dart` retains only appearance-preset discovery and validation.

There is one current layout key. First run and missing, malformed, or unavailable values recover through the same injected platform-preferred ID used by reset, manager, and resolver. There is no dual reader, migration routine, alias, compatibility wrapper, or parallel store.

### Frontend foundation

- `layout_surface_bundle.dart` is the only renderer entry contract. A bundle contains its manifest, surface identity, exact variant/destination builders, preview factory, tokens, owned asset namespace, and restoration namespace.
- `layout_definition.dart` combines the `M` surface bundles registered for one profile into an immutable aggregate without knowing `M` at implementation time.
- `layout_registry.dart` validates definitions against the catalog and exposes O(1) typed lookup.
- `layout_host.dart` resolves and builds one active bundle.
- `layout_scope.dart` exposes only resolved profile/surface/viewport and scoped restoration access.
- `layout_visual_tokens.dart` and `layout_component_kit.dart` define roles only; concrete metrics and styling are bundle-private.
- `layout_focus_coordinator.dart` restores semantic focus without retaining whole trees.

### Narrow semantic shell port

`LayoutShellPort` is supplied through the bundle build context. It exposes only immutable semantic values and callbacks required by shell chrome, such as current destination, localized labels/search query, safe status/capability facts, navigation/search actions, and pairing-entry intent. It exposes no controller, repository, platform object, business model, backend response, styled widget, color, spacing, or visual metric.

Bundles decide placement, hierarchy, animation, icon treatment, status rendering, focus behavior, and every visual metric. Capability and permission decisions remain above the port. Representative production fixtures exercise Home, Agents, and Settings so a full-controller dependency cannot hide in a less-used destination.

## Bundle ownership pattern

The canonical production root is `frontend/layout/profiles/<profile>/<surface>/`. Tests mirror ownership under `test/layout/profiles/<profile>/<surface>/`; optional assets mirror it under `assets/layout-profiles/<profile>/<surface>/`. The shared `frontend/layout/` root contains only contracts/interfaces, immutable composition/catalog/registry, host/scope/focus infrastructure, and neutral ports. Concrete styling, visual metrics, components, shell chrome, and destination presentation never live in `frontend/shared`, shared feature UI, or `frontend/shell`.

```text
frontend/layout/profiles/
├── <profile-1>/
│   ├── <surface-1>/
│   ├── …
│   └── <surface-M>/
├── …
└── <profile-N>/
    ├── <surface-1>/
    ├── …
    └── <surface-M>/
```

Each surface directory exports exactly one immutable bundle. Its shell, destination adapters, styled chrome, metrics, component recipes, tokens, preview, assets, restoration keys, fixtures, behavior/adaptive/semantic/golden tests, and source manifest remain below that boundary. A bundle imports no sibling profile or surface implementation.

`built_in_layout_composition.dart` is the sole composition root. It imports the `N × M` entry points exactly once, groups them by registered profile and surface, and derives:

1. the descriptor and exact coverage catalog;
2. the immutable widget registry;
3. ordered Settings metadata;
4. the allowed restoration namespaces and verification manifests.

There is no second manual list. Composition fails before shell paint when identity, labels, default role, injected preferred ID, surfaces, variants, destinations, style identities, or registry keys disagree. Typed map lookup chooses a bundle; `if`/`switch` branches on profile IDs are forbidden in profiles, shared features, shell, Settings, manager, resolver, and host code.

## No-redesign privatization sequence

The currently registered product is frozen as the visual, semantic, and interaction baseline documented in `Evidence.md`. Migration is atomic:

1. Capture deterministic source manifests and representative golden/semantics/interaction output for all `B` current bundles, including Home, Agents, and Settings fixtures.
2. Copy currently shared styled chrome and metrics into each owning bundle without changing constants, geometry, focus order, semantics, animation timing, or callbacks.
3. Replace full-controller access with `LayoutShellPort` values and callbacks while retaining equivalent behavior.
4. Prove byte-equivalent constants/metrics and pixel-, semantics-, and interaction-equivalent output against the captured baseline.
5. Delete shared styled chrome, shared visual metrics, controller scope/bridge, duplicate shell authority, and superseded tests in the same migration.

No compatibility export, fallback renderer, wrapper, alternate import path, or second authority survives. Golden updates may record the pre-change current render as baseline; production code may not be redesigned to match a regenerated golden.

## Hard isolation contract

Bundle code may import only presentation contracts, declared narrow semantic ports, localization, appearance color input, layout interfaces, and explicitly style-free leaf primitives. It may not import:

- another bundle's internals;
- `ClientController`, controller scope, service locator, repository, or platform object;
- shared shell, backend/platform/native implementation, or retired renderer;
- shared styled chrome, shared visual metrics, or a visually opinionated widget kit;
- another bundle's assets, restoration IDs, fixtures, tests, source manifest, or goldens.

The verifier derives the expected bundle list from composition, checks canonical production/test/asset ownership and exact entry imports, rejects concrete presentation files outside profile/surface roots, forbidden dependencies, and profile-ID branches, and requires deleted shared-chrome/shell paths to remain absent. Runtime registries and state maps are immutable after startup; inactive bundles are neither mounted nor observable.

For pairwise proof, each of `B = N × M` fixture manifests changes in isolation and all `B − 1` other source manifests and golden digests must remain identical. The directed matrix therefore contains `B(B − 1)` assertions and grows from registration data without algorithm edits.

## Selection, adaptation, appearance, and state

Manager state carries committed ID, optional preview ID, effective ID, status, current surface/viewport, one monotonic epoch, and a bounded safe error. Preview is memory-only; confirm persists before promotion; cancel, timeout, or failure restores committed selection and semantic focus. Reset uses the injected platform preference. A newer epoch invalidates stale completion.

Profile, surface, and viewport are independent axes. The active surface's registered policy classifies local constraints, safe insets, text scale, reduced motion, and input facts. Device names, orientation, and resize never write profile identity, and one surface never falls back to another surface's bundle.

Appearance owns palette and brightness. The active bundle owns non-color tokens and styled recipes. Layout switching preserves appearance and does not create a layout-by-theme class matrix.

Business state, permissions, destination/session selection, drafts, and operations stay above `LayoutHost`. Presentation state uses validated bundle-qualified namespaces. Only the active bundle is built; no all-profile `IndexedStack`, whole-tree `GlobalKey`, or inactive listener is allowed.

## Algorithms and complexity

- Registration validation: `O(N × M × V × D)` for the finite declared product, once per catalog revision.
- Profile, surface, variant, destination, and registry lookup: O(1) immutable maps.
- Active cache: one bounded tuple, invalidated by selection, environment, or catalog revision.
- Preference mutations: one serialized atomic tail; no stale concurrent snapshot.
- Rendering: one active bundle and no catalog scan in `build`.
- Adding a profile or surface increases registration data and construction-time validation only; it does not add conditional branches or change management algorithms.

## Privacy and current-only boundary

Descriptors and previews contain public presentation metadata only. Evidence records minimum redacted status and deterministic artifacts, never local paths, conversations, device identity, accounts, credentials, secrets, ciphertext, or backend runtime data.

Only immutable current registrations are accepted. Retired IDs, fields, namespaces, renderers, shared styled chrome, controller bridges, compatibility tests, and stale documentation remain absent. Startup/recovery never discover, import, rename, copy, translate, alias, or prompt for retired state.
