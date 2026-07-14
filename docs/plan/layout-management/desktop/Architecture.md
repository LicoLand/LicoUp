# Desktop Layout Profiles Architecture

## Parent contract and child boundary

The desktop child consumes the parent-owned immutable presentation contracts, semantic destination catalog, layout-neutral feature state/command ports, surface environment, visual-token/component-role interfaces, fixture host, and `LayoutSurfaceBundle` type. It does not redefine or mutate them.

The only production outputs are:

```text
workbench/desktop/workbench_desktop.dart -> one desktop LayoutSurfaceBundle
studio/desktop/studio_desktop.dart       -> one desktop LayoutSurfaceBundle
```

Neither profile registers itself. Only the parent integration join imports these entry points and edits the built-in composition root, `app.dart`, controller/application wiring, `ClientShell`, Settings, preference transaction, migration, documentation, build, or launch flow.

## Module and ownership map

```text
apps/desktop/lib/src/frontend/layout/profiles/
├── workbench/desktop/
│   ├── workbench_desktop.dart                 # bundle assembly; only public entry
│   ├── shell/                                 # command/search and responsive shell
│   ├── components/                            # workbench-styled recipes
│   ├── tokens/                                # non-color desktop tokens
│   ├── preview/                               # deterministic preview factory
│   └── destinations/                          # one adapter file per feature domain
└── studio/desktop/
    ├── studio_desktop.dart                    # bundle assembly; only public entry
    ├── shell/                                 # contextual rail/dock shell
    ├── components/                            # studio-styled recipes
    ├── tokens/                                # non-color desktop tokens
    ├── preview/                               # deterministic preview factory
    └── destinations/                          # one adapter file per feature domain

apps/desktop/test/layout/profiles/
├── workbench/desktop/                         # workbench-only fixtures and tests
└── studio/desktop/                            # studio-only fixtures and tests

apps/desktop/test/goldens/layout/
├── workbench/desktop/
└── studio/desktop/

apps/desktop/assets/layout-profiles/
├── workbench/desktop/                         # optional profile-owned assets
└── studio/desktop/
```

Implementation ownership is intentionally disjoint:

| Node responsibility | Exclusive owned paths |
| --- | --- |
| Workbench shell/components | `workbench/desktop/{shell,components,tokens,preview}/**` and `assets/layout-profiles/workbench/desktop/**` |
| Workbench destination adapters | `workbench/desktop/destinations/**` |
| Workbench bundle tests/goldens | `workbench/desktop/workbench_desktop.dart`, `test/layout/profiles/workbench/desktop/**`, `test/goldens/layout/workbench/desktop/**` |
| Studio shell/components | `studio/desktop/{shell,components,tokens,preview}/**` and `assets/layout-profiles/studio/desktop/**` |
| Studio destination adapters | `studio/desktop/destinations/**` |
| Studio bundle tests/goldens | `studio/desktop/studio_desktop.dart`, `test/layout/profiles/studio/desktop/**`, `test/goldens/layout/studio/desktop/**` |

No implementation Node owns `layout_registry.dart`, `built_in_layout_composition.dart`, `app.dart`, `frontend/shell/**`, Settings, `package.json`, or shared product documentation. If asset registration or command aggregation needs a central edit, the parent join owns it.

## Dependency direction and interfaces

Dependencies point inward from a profile entry to its private shell/components and destination adapters, then to parent layout interfaces and layout-neutral feature ports. Profile code never imports another profile, the complete controller, a service locator, legacy shell code, backend/platform implementations, or shared styled widgets.

Destination adapters are split by feature responsibility: Home/control, Agents/conversations, Feed, monitoring/usage, Extensions/skills, Runtime, Mobile Relay entry, and Settings content. Each adapter maps typed immutable view state and callbacks into profile-local components. It does not resolve destination identity, query services, persist selection, or enforce capability policy.

The entry file creates an immutable coverage manifest and bundle from already implemented private factories. It exports no shell class, component class, adapter, mutable registry handle, or profile state. Parent validation rejects missing/extra destination or viewport builders before integration.

## Profile systems

### Workbench

Workbench uses a horizontal command/search region, generous spatial rhythm, floating task surfaces, and card-oriented components. Narrow constraints condense the command region while retaining the same identity. Its shell, tokens, preview, components, adapters, restoration IDs, assets, tests, and goldens remain inside the workbench namespaces.

### Studio

Studio uses contextual side navigation, docked/edge-to-edge work areas, denser typography and spacing, compact shapes, and integrated split surfaces. Narrow constraints collapse contextual navigation without adopting workbench chrome. Its corresponding artifacts remain inside studio namespaces.

## State, switching, and adaptation

Profiles receive semantic destination, immutable display state, commands, environment facts, appearance palette, and profile-qualified presentation-state access from the parent interfaces. They do not own selected layout, persistence, preview transaction, domain state, permissions, or long-running operations.

Pane width, local tabs, scroll, expansion, and focus use bounded `(profile, desktop, destination, surfaceId)` namespaces. A fixture host can replace one bundle with the other while retaining fake semantic state; it does not keep both trees mounted. Constraint and input changes select a bundle-local variant but never write preferences.

## Deliberate patterns and data structures

- **Strategy** is limited to the two complete desktop presentation systems; it earns its cost because shell, components, and destination composition all vary together.
- **Adapter** is used per feature destination to translate stable parent ports into profile-specific widgets without moving business logic into the renderer.
- **Factory plus immutable bundle** provides one narrow handoff and exact builder manifests without registry mutation or ID conditionals.
- Immutable maps keyed by parent `LayoutVariantKey` and semantic destination provide deterministic O(1) lookup after the parent performs one exact-set validation.
- Plain widgets and value objects remain pattern-free when no boundary or variation exists. There is no plugin loader, widget DSL, service locator, compatibility wrapper, or shared styled component hierarchy.

## Isolation and verification invariants

- Profile source, asset, restoration, fixture, test, and golden roots never overlap.
- Only a profile's entry file exposes its immutable desktop bundle; internals remain private to that profile root.
- Identical fake-port scenarios assert semantic parity, while distinct landmarks and golden digests assert structural difference.
- The boundary verifier rejects cross-profile imports, forbidden dependencies, extra public exports, mutable registry access, owned-path overlap, and imports of bundle entries outside the parent composition root.
- A deterministic fixture modifies one profile manifest and proves the sibling source manifest and golden digest do not change.
- Renderer final validation produces a bundle receipt only. The parent join owns mounted application behavior, complete migration, build, and launch.
