# Desktop Layout Profiles Requirements

## Product problem

The desktop client currently varies selected shell chrome while reusing a central destination body. The desktop renderer child must instead deliver two complete presentation systems that consume the same parent-owned semantics but can be developed, reviewed, and tested without editing or depending on the other profile's implementation.

## Users and workflows

- Desktop users receive a spacious `workbench` or dense `studio` projection for the same destinations, actions, drafts, sessions, and running operations.
- Keyboard and pointer users keep predictable navigation, focus, text scaling, contrast, and reduced-motion behavior at medium and expanded desktop sizes.
- Profile maintainers can change one profile's shell, components, adapters, assets, tests, or goldens without changing the sibling profile or a central composition file.
- The parent integration join consumes two verified desktop bundles and alone wires them into the registry, application shell, Settings transaction, migration, build, and launch flow.

## Requirements

- **REQ-001 — Complete workbench desktop bundle.** `workbench` shall export one immutable desktop `LayoutSurfaceBundle` whose horizontal command/search shell, floating task surfaces, generous spacing, card-oriented components, tokens, preview, and medium/expanded variants form one coherent presentation system.
- **REQ-002 — Complete studio desktop bundle.** `studio` shall export one immutable desktop `LayoutSurfaceBundle` whose contextual side navigation, docked or edge-to-edge work areas, dense hierarchy, distinct components, tokens, preview, and medium/expanded variants form one coherent presentation system.
- **REQ-003 — Exact desktop capability parity.** Both bundles shall implement the exact parent-declared desktop semantic destination and action set, including Home/control, Agents and conversations, Feed, usage/monitoring, Extensions and skills, Runtime, Mobile Relay entry, and Settings content, without copying business logic or substituting a sibling renderer.
- **REQ-004 — Switch-ready renderer contract.** Each bundle shall be side-effect-free, expose deterministic preview metadata and semantic focus/restoration landmarks, and render correctly when a parent-owned host replaces one bundle with the other. A renderer shall not read, write, confirm, cancel, or reset layout preferences.
- **REQ-005 — Layout-neutral state consumption.** Bundles shall consume only immutable layout-neutral feature state and command ports. Destination, selected session, drafts, permissions, and active operations remain above renderer widgets; profile-local pane, scroll, expansion, tab, and focus state uses bounded, profile-qualified namespaces.
- **REQ-006 — Constraint-driven desktop adaptation.** Both profiles shall provide the complete parent-declared desktop viewport set and preserve their own visual identity across supported narrow, medium, and expanded constraints. Resize or input-capability changes shall not mutate profile identity, persist preferences, or introduce overflow.
- **REQ-007 — Desktop accessibility and visual proof.** Profile-owned tests and deterministic goldens shall prove keyboard, pointer, semantics, focus order, text scale, contrast, reduced motion, appearance-token composition, capability parity, and material structural difference.
- **REQ-008 — Renderer-only integration handoff.** The desktop child shall deliver exactly the two verified desktop `LayoutSurfaceBundle` entry points and their profile-owned evidence. It shall not edit the central registry/composition root, `app.dart`, `ClientShell`, Settings, preference/manager wiring, retired-shell removal, product documentation, or build/launch flow; those converge atomically in the parent integration join.
- **REQ-009 — Independent profile isolation.** Each profile shall exclusively own its desktop source, shell, destination adapters, styled components, tokens, preview, optional assets, restoration namespace, fixtures, tests, and goldens. Profiles shall not import each other, the complete controller, legacy shell code, backend/platform implementations, shared styled components, or sibling state/assets/tests. Static ownership/import checks, identical fake-port suites, and change-impact digest checks shall prove that a change to one profile cannot alter the other profile's source, output, golden baseline, or state.

## Scope

- `workbench/desktop` and `studio/desktop` renderer implementations below their profile boundaries.
- Profile-local shell/component systems, destination adapters, tokens, previews, optional assets, tests, fixtures, and goldens.
- Renderer-only verification and a parent-consumable handoff receipt.

## Non-goals

- Editing the built-in registry or composition root, application/controller wiring, `ClientShell`, or Settings.
- Implementing selection persistence, preview confirmation, migration, old-shell removal, client rebuild/open, packaging, release, or store delivery.
- Forking domain controllers, backend services, authorization, capability policy, or native desktop implementations by profile.
- Preserving old IDs, aliases, wrappers, shared visually opinionated widgets, or a fallback from one profile to the other.

## Acceptance target

The child plan is accepted when two isolated desktop bundles render the exact same semantic capabilities through materially different component trees, pass their own deterministic behavior/accessibility/golden suites and hard-isolation gates, and can be imported by the parent integration join without any renderer-child edit to central application files. Wired switching, complete migration, rebuild, and launch are accepted only by the parent plan.
