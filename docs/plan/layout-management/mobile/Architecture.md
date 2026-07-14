# Mobile Layout Renderer Architecture

## Plan position and delivery boundary

`layout-management/mobile` is a renderer child of the platform-neutral layout-management plan. It starts only after the parent has delivered the immutable presentation contracts, semantic destination catalog, layout-neutral feature ports, `LayoutSurfaceBundle`, token/component role contracts, restoration interfaces, and the self-tested layout-boundary verifier.

This child produces two artifacts:

```text
workbench mobile source -> one immutable LayoutSurfaceBundle
studio mobile source    -> one immutable LayoutSurfaceBundle
```

It does not register them. The parent integration join alone owns `built_in_layout_composition.dart`, the central catalog/registry, `app.dart`, controller composition, `ClientShell`, Settings, preference hydration, old mobile-shell deletion, package-wide integration tests, documentation convergence, builds, simulators, devices, and launches.

## Module map and public interfaces

```text
apps/desktop/lib/src/frontend/layout/profiles/
├── workbench/mobile/
│   ├── workbench_mobile_shell.dart
│   ├── workbench_mobile_components.dart
│   ├── workbench_mobile_tokens.dart
│   ├── workbench_mobile_preview.dart
│   ├── destinations/
│   │   ├── workbench_agents_destination.dart
│   │   ├── workbench_feed_destination.dart
│   │   ├── workbench_pairing_destination.dart
│   │   └── workbench_settings_destination.dart
│   └── workbench_mobile_bundle.dart       # only public entry point
└── studio/mobile/
    ├── studio_mobile_shell.dart
    ├── studio_mobile_components.dart
    ├── studio_mobile_tokens.dart
    ├── studio_mobile_preview.dart
    ├── destinations/
    │   ├── studio_agents_destination.dart
    │   ├── studio_feed_destination.dart
    │   ├── studio_pairing_destination.dart
    │   └── studio_settings_destination.dart
    └── studio_mobile_bundle.dart          # only public entry point

apps/desktop/test/layout/profiles/
├── workbench/mobile/
│   ├── workbench_mobile_bundle_test.dart
│   ├── workbench_mobile_shell_test.dart
│   ├── workbench_mobile_golden_test.dart
│   └── goldens/
└── studio/mobile/
    ├── studio_mobile_bundle_test.dart
    ├── studio_mobile_shell_test.dart
    ├── studio_mobile_golden_test.dart
    └── goldens/
```

`workbench_mobile_bundle.dart` and `studio_mobile_bundle.dart` each expose exactly one immutable typed bundle. All shell, token, component, preview, destination, and restoration details are profile-private. Parent composition imports only those two entry points; tests import only their own profile's entry point.

## Layers and dependency direction

Within each profile, dependency direction is one way:

```text
profile bundle composition
├── destination adapters -> parent semantic destinations + narrow feature ports
├── shell/preview         -> profile components + parent layout environment
└── profile components    -> profile tokens + appearance color input + style-free primitives
                              -> parent presentation contracts
```

- The local bundle entry point assembles immutable compact/medium builder maps in O(1)-lookup form; it never mutates a registry.
- Destination adapters translate immutable parent state and commands into profile composition. They do not make capability/readiness decisions, import controllers, or call backend/platform services.
- Shells choose only structure inside the already resolved mobile variant. They do not persist selection or infer identity from an OS, device name, or orientation.
- Component files own styled navigation, cards, fields, dialogs, status, and composer-adjacent chrome. The parent component kit supplies roles, not a shared styled implementation.
- Tokens own typography scale, density, spacing, radius, elevation, navigation measurements, and motion. Appearance colors remain an orthogonal parent input.

## Profile composition

### Workbench

Workbench uses generous card/stack grouping, clear work-area separation, contextual sheets or overlays, and navigation that vacates the composer region. Its compact and medium builders share workbench recipes but may arrange them differently. The preview is built from public presentation metadata and contains no live feature or backend data.

### Studio

Studio uses dense edge-to-edge surfaces, a compact contextual drawer or overlay, and a medium rail or dock. It owns distinct measurements, hierarchy, motion, navigation, cards, fields, and status recipes. Semantic destinations and actions equal workbench's contract, but neither structure nor styled implementations are shared.

## Destination and state contracts

Each bundle declares the exact parent-provided mobile destination set and has one profile-owned adapter per destination. Missing and extra keys fail bundle tests; there is no sibling or fixed-shell fallback. Pairing or relay remains an entry action according to parent capability policy rather than a new infrastructure authority.

Profiles receive immutable snapshots and command interfaces for agent/session selection, conversation content and composer draft, feed, pairing entry, Settings, active operations, permissions, and lifecycle/restoration facts. Domain state stays above the renderer. Profile-local scroll, pane, expansion, and focus values use a catalog-approved namespace beginning with the profile and `mobile`; no key can address the sibling namespace. Rebuilding a bundle from the same snapshots must reproduce semantic selection without retaining the inactive tree.

## Adaptation and accessibility

The parent resolves `(profile, mobile, compact|medium)` from local constraints and environment facts. Inside a variant, the profile responds to safe insets, keyboard inset, text scale, reduced motion, and touch/pointer facts. Tests cover portrait-like and landscape/split/fold-like constraints without using device classes as identity. Navigation cannot occupy the active composer region. Both profiles provide equivalent semantics, minimum touch targets, deterministic traversal, focus visibility, overflow handling, and contrast-compatible token use.

## Owned-path partition

| Node branch | Exclusive owned paths |
| --- | --- |
| Workbench shell/components | Four named `workbench_mobile_{shell,components,tokens,preview}.dart` files |
| Workbench destinations/bundle | `workbench/mobile/destinations/**` and `workbench_mobile_bundle.dart` |
| Workbench tests/goldens | `test/layout/profiles/workbench/mobile/**` |
| Studio shell/components | Four named `studio_mobile_{shell,components,tokens,preview}.dart` files |
| Studio destinations/bundle | `studio/mobile/destinations/**` and `studio_mobile_bundle.dart` |
| Studio tests/goldens | `test/layout/profiles/studio/mobile/**` |

Foundation document Nodes own one distinct mobile plan document each. Parallel profile branches have no overlapping files. Any required edit outside the table is returned to the parent integration join instead of being absorbed into a child Node.

## Hard isolation

Profile code may import only parent presentation contracts, frontend layout interfaces, declared layout-neutral feature ports, localization, appearance color input, and explicitly style-free leaf primitives. It may not import the sibling profile, `ClientController`, service locators, `frontend/shell`, Settings implementation, backend/platform/native code, central registry/composition, shared styled widgets, sibling assets, sibling restoration IDs, sibling tests, or sibling goldens.

The parent-owned boundary verifier checks owned-path overlap, forbidden imports, the two exact bundle entry points, absence of mutable registration, and exclusive parent ownership of composition. Profile-only tests use the same fake ports but separate fixtures and outputs. A deterministic change-impact check compares normalized source manifests and golden digests so a workbench-only fixture change leaves studio unchanged and vice versa. Only the active bundle will be mounted by the parent; profile code has no inactive-profile listener or shared mutable state.

## Deliberate patterns and complexity

- **Local composition root / Factory** is used only in each bundle entry point because a complete immutable builder family must be exported through one boundary.
- **Adapter** is used per semantic destination because parent feature ports and profile-specific composition must vary independently.
- **Strategy** is the bundle-level shell, preview, tokens, components, and variant behavior selected by the parent runtime.
- Plain immutable records, maps, constructors, and local widget composition remain pattern-free elsewhere. There is no service locator, plugin loader, JSON widget tree, code-generation layer, shared styled component kit, or mobile-specific state manager.

Bundle construction validates a small finite destination/variant product once. Runtime variant and destination lookup use immutable maps; rendering builds one requested tree and performs no catalog scan. Profile-local presentation state is bounded by declared namespaces, and no cache or mutable singleton crosses the profile boundary.

## Integration receipt

The final mobile Node records passing profile-only test/golden commands, static analysis, boundary verification, immutable bundle manifests, disjoint source/golden digests, and scoped Better Plan checks. That terminal evidence authorizes the parent join to import the bundles; it does not claim that they are registered, selectable, migrated, built, installed, or launched.
