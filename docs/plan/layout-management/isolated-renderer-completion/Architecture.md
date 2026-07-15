# Isolated Renderer Completion Architecture

```text
business state and commands
        ↓ projection adapters
immutable snapshot + narrow actions keyed by surface/destination
        ↓ typed lease resolver
LayoutHost → active catalog bundle
        ↓
profiles/<profile>/<surface> complete private renderer
```

## Shared modules

- Layout contracts declare semantic snapshots/actions and typed lease keys only.
- Application adapters project the existing controller into immutable destination facts and callbacks.
- A resolver owns O(1) `(surface,destination)` lookup, typed acquire/release, reference-counted lifecycle, and bounded notifications.
- LayoutHost owns the active lease, active bundle, state namespace, and semantic focus restoration.
- Catalog, manager, preference repository, appearance input, localization, and declaration-derived verification remain cardinality independent and style free.

## Private modules

Each discovered `profiles/<profile>/<surface>/` subtree owns its full renderer: shell, chrome, navigation, destinations including Agents and Settings, components, tokens, preview, focus/restoration presentation, and all layout-specific styling. Reuse is allowed only inside the same profile owner. Mirrored tests/assets remain private to that owner.

## Dependency rules

Profiles may depend on Flutter/Dart, localization, neutral appearance input, layout contracts, and semantic ports. They may not depend on siblings, Widget-producing shared feature presentation, shared styled scope/recipe, complete controllers, backend/platform services, or profile-ID style/behavior dispatch.

## Cutover

Neutral contracts land first. Four profile-private renderer Nodes then operate on disjoint owner trees. After every profile is complete, one atomic host cutover removes the old Widget content port and shared styled presentation in the same commit. Dynamic verification and frozen comparison run afterward; there is no compatibility mode or partial supported state.

Patterns are deliberately limited to Ports and Adapters for the business/presentation boundary, a typed lease for lifecycle ownership, immutable registries for O(1) lookup, and Strategy-like private bundles already present in the layout catalog. Profile UI composition stays ordinary Flutter code.
