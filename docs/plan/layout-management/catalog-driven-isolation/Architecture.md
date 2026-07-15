# Catalog-Driven Layout Isolation Architecture

## Cardinality model

```text
registered profile definitions = composition entries          // cardinality N; runtime authority
discovered profile roots = frontend/layout/profiles/<id>       // verifier ownership view
assert ids(roots) == ids(definitions)                           // exact set equality
runtime surfaces = typed surface declaration                   // cardinality M
required bundles = definitions × surfaces                      // cardinality N × M
required variants = bundles × each surface's viewport policy
required destinations = variants × semantic destination set
```

No consumer stores a profile count or duplicates profile metadata. The composition root is the only production file that imports profile entry points and is the runtime profile-identity authority. It supplies immutable `LayoutDefinition` values; the catalog and registry validate the full product and derive Settings order and previews. The verifier enumerates canonical profile roots only to prove ownership and exact equality with the registered identities. It must not persist that enumeration as another identity list.

Adding a profile creates one private profile root with one bundle per declared surface, then adds one typed definition at the composition root. Manager, host, Settings, state, tests, and verifier algorithms remain unchanged. Adding a surface extends the typed surface policy and requires every registered profile to provide the new bundle before composition can succeed.

## Canonical directory model

```text
frontend/layout/
├── contracts and neutral ports
├── composition, registry, host, scope, state/focus infrastructure
└── profiles/
    └── <profile>/
        └── <surface>/               // repeated for every declared surface
            ├── bundle entry
            ├── shell and chrome
            ├── destinations
            ├── components and tokens
            └── preview
```

Every concrete layout implementation lives below `frontend/layout/profiles`. The generic directory model contains no fixed surface names or count; concrete names are members of the typed surface declaration observed by a run. Shared `frontend/layout` files are limited to cardinality-independent management, contracts, host infrastructure, and style-free semantic ports. Profile assets and tests use mirrored `<profile>/<surface>` roots. Shared feature and shell directories may own business state and neutral adapters only; they cannot own styled chrome, profile presentation policy, complete controllers exposed to profiles, or profile-ID branches.

## Dependency direction

```text
business/application state and commands
        ↓ narrow adapter
immutable semantic snapshots + callbacks + neutral palette input
        ↓
LayoutHost → active LayoutDefinition → active LayoutSurfaceBundle
        ↓
profile-private shell / chrome / destination presentation / components
```

Profiles cannot see a complete controller, widget-producing shared presentation surface, services, backend/platform implementations, other profiles, or shared styled UI. Semantic ports carry status, allowance, pairing, navigation, Agents, and Settings data/actions without supplying layout or chrome. Profile-private adapters decide composition and styling without identity checks in shared feature code. A layout-neutral palette snapshot separates appearance input from the global theme implementation.

### Destination-port lifecycle

Each surface policy declares a semantic destination set. For every member, the application layer registers one typed contract keyed only by `(surface, destination)`; profile identity is intentionally absent. A contract exposes an immutable, bounded snapshot and a narrow action interface. It cannot expose `Widget`, `BuildContext`, `WidgetBuilder`, a complete controller, service, repository, platform object, mutable collection, or untyped payload map.

`LayoutHost` resolves only the active destination contract. A typed lease is acquired when the active profile-owned destination tree mounts and is released when that tree is replaced or unmounted. The resolver rejects unknown keys, snapshot-type mismatches, duplicate registrations, foreign or repeated release, and shutdown with active leases. Polling and application lifecycle remain behind the adapter and are reference-counted by acquire/release; profiles cannot start backend timers.

The profile-facing snapshot contains business facts, not presentation recipes. Drafts, selected conversations, permissions, and running work stay in application adapters; hover, scroll, pane extent, overlay, and other renderer state stay in the profile/surface-qualified state store. Dialogs, sheets, text controllers, QR painting, typography, spacing, and motion are owned by the active private renderer.

Layout selection uses the same rule. A `LayoutSelectionPort` exposes dynamic catalog options and preview/confirm/cancel/reset actions without exposing `LayoutManager`, `LayoutRegistry`, or a preview `Widget`. Preview content is a bounded immutable asset or raster handle owned by the candidate bundle; the active profile privately renders its selector frame. Profile ID remains option data and an action parameter, never a style or behavior discriminator.

## State, defaults, and switching

One `LayoutManager` owns the transactional state machine. The preferred default is injected once and used by hydration, resolver, reset, and recovery. `LayoutHost` resolves one `(profile, surface, viewport)` key in O(1), mounts only that bundle, and passes profile/surface-scoped state. Focus restoration is semantic; inactive trees are not retained.

## Isolation and migration

Every profile owns all visually meaningful source and evidence. Existing shared chrome is copied exactly into the relevant profile roots, wired through neutral ports, compared against the frozen baseline, and then removed. There is no compatibility wrapper. Profile identity is data at registration and lookup boundaries only: no switch, conditional, map, factory, or controller branch may select behavior or styling from a known profile ID.

The verifier discovers registered definitions, canonical profile roots, and typed surfaces, requires exact directory/registration equality, and validates exactly the definition/surface Cartesian product. It builds transitive import closures and permits closure intersections only for an explicit style-free neutral allowlist. It rejects fixed count constants, second identity inventories, sibling imports, styled shared dependencies, complete-controller/backend/platform access, and behavioral or styling identity branches. Source, fixture, asset, and golden digests are generated for every discovered profile/surface pair; pairwise checks cover every ordered profile pair.

### Single final cutover

The migration has one final architecture and no compatibility mode:

1. Freeze deterministic render, semantics, keys, focus, and interaction evidence for every discovered bundle. Any nondeterministic fixture input must be made explicit before ownership moves; a failing comparison cannot be hidden by refreshing a baseline.
2. Introduce pure snapshot/action contracts, controller projection adapters, typed resolver leases, and adapter-equivalence tests for every destination discovered from the surface policy.
3. For every discovered `<profile>/<surface>` owner, copy its currently reachable styled destination tree and helpers into that private subtree, preserve the frozen behavior, and replace controller/service access with its semantic port. Reuse is permitted only inside the same owner.
4. Atomically switch `LayoutHost` from the shared content injection to one `(surface, destination)` lease and make every bundle build its own complete destination presentation.
5. In the same cutover, delete the widget-producing content port, shared destination-presentation scope and recipes, shared styled feature/shell implementations, context-bearing chrome actions, old forwarding fixtures, and their verifier allowlist entries. No production fallback remains.
6. Dynamically mount every discovered bundle/destination against fake ports, compare frozen pixels/semantics/keys/interactions, verify transitive and pairwise isolation, then run client delivery checks.

These steps are execution order only; they are not separately supported product modes. A partial state cannot close the correction checkpoint.

## Complexity

- Catalog construction and exact-product validation: `O(N × M × V × D)` per immutable revision.
- Profile, bundle, variant, and destination lookup: `O(1)` immutable maps.
- Pairwise isolation verification: `O(N² + E)` over profile pairs and import edges, executed only in validation.
- Runtime rendering: one active tree; no catalog scan in widget build.
- Preference updates: one serialized mutation tail and atomic current-schema replacement.
