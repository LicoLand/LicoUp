# Mobile Layout Renderer Requirements

## Product problem

The parent layout runtime needs two complete mobile presentation systems for the same semantic `workbench` and `studio` identities. The current client has one fixed phone shell and one fixed bottom-navigation composition, so it cannot supply independently developed mobile renderer bundles whose structure, component recipes, density, navigation, and visual hierarchy are materially different. This child plan delivers those renderer bundles only; the parent integration join owns registration, Settings, app cutover, retired-shell removal, and platform build or launch claims.

## Users and workflows

- Mobile users receive a conversation-first `workbench` or `studio` presentation after the parent runtime resolves the selected identity to the `mobile` surface and a compact or medium viewport.
- Users can reach the same allowed mobile destinations and semantic actions in either profile without learning relay, platform, or controller implementation details.
- Maintainers can change one mobile profile's shell, adapters, components, tests, assets, restoration namespace, or goldens without changing or invalidating the other profile.
- The parent integration owner can consume one immutable `LayoutSurfaceBundle` entry point from each profile without editing profile internals or reconstructing profile metadata.

## Requirements

- **REQ-001 — Shared semantic identity and bundle contract.** Mobile shall use the parent `workbench` and `studio` profile identities, `mobile` surface identity, semantic destination catalog, layout environment, appearance palette input, and layout-neutral state/command ports. Each profile shall expose exactly one immutable mobile `LayoutSurfaceBundle`; it shall not define a phone-only identity, preference authority, layout manager, central registry mutation, or second metadata list.
- **REQ-002 — Workbench mobile presentation.** The workbench bundle shall provide compact and medium variants with a spacious card-and-stack hierarchy, contextual navigation, clearly separated work areas, and a conversation composer that remains unobstructed by persistent navigation.
- **REQ-003 — Studio mobile presentation.** The studio bundle shall provide compact and medium variants with a denser edge-to-edge hierarchy, contextual drawer or overlay behavior on compact widths, rail or dock behavior on medium widths, and component recipes visibly and structurally distinct from workbench while preserving the same semantic actions.
- **REQ-004 — Exact mobile destination adapters.** Each bundle shall implement the exact parent-declared mobile destination set through profile-owned adapters for agent selection and conversation, feed, pairing or relay entry, and Settings. Adapters shall consume only narrow immutable state and command ports, shall preserve parent capability and readiness decisions, and shall neither add an undeclared destination nor fall back to another profile's adapter.
- **REQ-005 — Layout-neutral state and lifecycle rendering.** Profile widgets shall render parent-owned navigation, selected device or agent or session, draft, active-operation, permission, and lifecycle state without copying it into a profile authority. Profile-owned scroll, expansion, pane, and semantic-focus state shall use a bounded, profile-specific restoration namespace and remain reconstructible from supplied state when the parent replaces the active tree.
- **REQ-006 — Constraint-driven mobile variants.** Compact or medium selection and local composition shall respond to available constraints, safe insets, keyboard insets, text scale, reduced-motion preference, and input capabilities. Orientation, device marketing name, and operating-system name shall not choose or persist a profile identity, and neither bundle shall assume desktop chrome.
- **REQ-007 — Mobile accessibility and visual proof.** Each profile shall provide equivalent semantics, touch targets, predictable traversal, visible focus, text scaling, contrast-compatible token usage, safe-area handling, keyboard/composer clearance, reduced-motion behavior, overflow resistance, and deterministic profile-owned goldens for representative appearance inputs.
- **REQ-008 — Renderer-only delivery boundary.** Mobile implementation Nodes shall own only their declared profile source, destination adapters, profile tests, and profile goldens. They shall not edit the built-in composition root, central registry, `app.dart`, `ClientShell`, Settings, controller composition, preference storage, legacy shell files, package-wide integration tests, native projects, or product documentation. Fixed mobile shell deletion, selector wiring, complete migration, and app state-continuity proof belong exclusively to the parent integration join.
- **REQ-009 — Renderer bundle verification receipt.** The child plan shall finish with source-scoped format and analysis evidence, profile-only widget/semantics/golden tests, exact bundle-manifest checks, hard-boundary verification, and scoped Better Plan validation. Android and iOS builds, simulator or physical-device install and launch, desktop rebuild or launch, aggregate app tests, packaging, release, and store claims are not part of this receipt and remain parent-owned.
- **REQ-010 — Independent profile isolation.** Workbench and studio shall have disjoint source, destination, asset, restoration, test, fixture, and golden ownership. Neither profile may import, inspect, mutate, mount, register, or reuse styled implementations or state from the other; both may depend only on parent presentation contracts, declared layout-neutral feature ports, localization, appearance color input, and explicitly style-free primitives. Static import and owned-path gates plus isolated fake-port render and golden tests shall prove that changing one profile cannot change the other profile's source manifest, output, or state.

## Scope

- `workbench/mobile` and `studio/mobile` shells, component recipes, non-color tokens, previews, restoration namespaces, and compact/medium behavior.
- Profile-owned destination adapters that translate parent semantic destinations and narrow feature ports into each profile's composition.
- One immutable mobile `LayoutSurfaceBundle` export per profile.
- Disjoint profile-only widget, semantics, adaptive, restoration, isolation, and golden tests.
- A renderer-bundle validation receipt suitable for the parent integration join.

## Non-goals

- Editing the central layout registry or built-in composition root.
- Editing `app.dart`, `ClientShell`, Settings, controller composition, preference persistence, or package-wide integration tests.
- Deleting the fixed mobile shell, old navigation, old preference paths, or contradictory application documentation in this child plan.
- Proving preview/confirm/cancel/reset UI, mounted cross-profile switching, cold-start hydration, or whole-app state continuity before parent integration.
- Running Android or iOS builds, simulators, physical devices, packaging, release, or store publication as mobile renderer evidence.
- Sharing a visually opinionated component implementation between profiles or preserving a fallback to either the fixed shell or the sibling profile.

## Final acceptance target

The child plan is accepted when workbench and studio each expose one independently tested immutable mobile `LayoutSurfaceBundle`, both cover the exact compact/medium mobile destination product through narrow parent ports, their presentation systems are materially different and accessible, all owned paths and imports are disjoint, profile-only tests and goldens pass, and a privacy-minimal renderer receipt is ready for the parent integration join without any central composition, cutover, migration, build, or launch change in this child.
