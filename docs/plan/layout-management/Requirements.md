# Layout Management Foundation Requirements

## Product problem

Lico Arc currently exposes two desktop shell strings, but the user needs to switch between complete presentation systems whose navigation, page composition, component chrome, density, typography, spacing, motion, and visual hierarchy are intentionally different. The choice must remain a presentation concern: it cannot duplicate business state, alter client capabilities, or hide a reachable workflow.

## Users and workflows

- Desktop users choose a layout from Settings, preview it without restarting, keep or cancel the preview, and return to their current task without losing navigation, conversation, draft, focus, or long-running operation state.
- Mobile users choose the same semantic layout identity and receive a compact variant designed for the available space rather than a desktop widget tree squeezed onto a phone.
- Maintainers add a built-in layout through one typed registration boundary and receive deterministic failures when identifiers, destination coverage, adaptive variants, or visual contracts are incomplete.

## Requirements

- **REQ-001 — Semantic layout profiles.** The client shall expose stable, semantically named layout profiles. The initial current profiles are `workbench` and `studio`; numbered, versioned, legacy, and compatibility identities are not allowed.
- **REQ-002 — Whole-presentation ownership.** Each profile shall own shell/navigation composition, destination composition, component recipes, non-color visual tokens, preview metadata, and every required `(runtime surface, viewport class)` variant. The required surface policy is `desktop = {medium, expanded}` and `mobile = {compact, medium}`; `desktop/medium` and `mobile/medium` are distinct variants even though they share a viewport name. Changing only a top bar or rail is insufficient.
- **REQ-003 — Exact capability coverage.** Every selectable profile shall cover the exact set of semantic destinations reachable for each declared runtime surface. Registration validates the complete `(profile, surface, viewport, destination)` product and rejects missing or extra coverage; a feature page may not silently fall back to another profile or surface.
- **REQ-004 — One layout-neutral state authority.** Business data, commands, navigation identity, selected conversations, drafts, active operations, and permission behavior shall live above layout widgets and remain unchanged by a presentation switch.
- **REQ-005 — Surface-aware adaptive resolution.** The selected profile identity shall remain stable while its variant is resolved from an explicit runtime surface (`desktop` or `mobile`), local layout constraints, and input/accessibility capabilities. Surface is a registry-key dimension, not a second profile identity. Desktop constraints resolve only to `medium` or `expanded`; mobile constraints resolve only to `compact` or `medium`, so a narrow desktop never borrows mobile chrome and a large mobile device never borrows desktop chrome. Window size, device names, and orientation shall not silently rewrite the user's selection.
- **REQ-006 — Orthogonal appearance composition.** Appearance presets continue to own palette and light/dark selection. Layout profiles own structure, typography scale, density, shape, elevation, motion, and component recipes. The client shall compose the two axes deterministically without maintaining a layout-by-theme Cartesian product or resetting appearance during a layout switch.
- **REQ-007 — Transactional preferences.** Layout, appearance, and locale selections shall be loaded and saved through one typed presentation-preferences authority with serialized, atomic writes. Rapid updates cannot overwrite each other, and the first meaningful shell paint shall wait for preference hydration.
- **REQ-008 — Preview, commit, cancel, reset, and recovery.** A user can preview a valid profile, confirm it, cancel it, or reset to the unique default. Only a confirmed selection is persisted. Invalid stored identifiers and unavailable profiles resolve deterministically to the default with a user-safe diagnostic; persistence failure restores the prior committed layout.
- **REQ-009 — State and focus continuity.** Switching layouts shall preserve semantic navigation, selected agent/session, editable drafts, running work, and restorable scroll/expansion/focus state. The implementation shall not keep every complete layout tree alive or move the entire tree with a global key.
- **REQ-010 — Accessibility and input parity.** Every profile shall expose equivalent semantic actions, predictable focus order, keyboard and pointer access on desktop, touch targets on mobile, text scaling, contrast, and reduced-motion behavior.
- **REQ-011 — Bounded and deterministic runtime.** Registry lookup by `(profile, surface, viewport)` and active-profile resolution shall be O(1). Resolution caching is bounded by the active selection/environment/catalog revision; only the current profile is built, rapid transitions are coalesced or serialized, and rebuilds stay below the presentation boundary.
- **REQ-012 — Hard profile isolation.** Every layout owns its source, shell, destination composition, styled components, visual tokens, assets, preview, restoration namespace, and tests below one profile boundary. A profile may depend only on shared presentation contracts, layout-neutral feature state/command ports, localization, and explicitly style-free primitives; it may not import another profile, the complete `ClientController`, legacy shell code, backend/platform implementations, or a shared visually opinionated component kit. Each profile exports one immutable typed bundle to a single integration-owned composition root, cannot mutate registry state after startup, and cannot observe or mutate an inactive profile's state. Static ownership/import gates and isolated render/golden tests shall prove that changing one profile cannot change another profile's output or state. Layouts remain package-owned typed Dart definitions and factories; remote code, arbitrary JSON widget trees, and third-party executable layout plugins are outside this contract. Existing external appearance presets remain data-only color inputs.
- **REQ-013 — Complete migration.** `ShellLayoutIds`, `shellLayoutId`, numbered labels, direct profile-ID checks outside the layout runtime, the old preference key/read-write path, obsolete tests, and contradictory documentation shall be removed when the new authority is adopted. No compatibility shim or parallel renderer remains.
- **REQ-014 — Verifiable delivery.** Contract, manager, store, widget, adaptive, state-continuity, accessibility, golden, integration, architecture, build, and launch checks shall prove the same requirements on desktop and mobile child plans.

## Scope

- Platform-neutral contracts, catalog, resolver, selection state machine, preference repository, presentation host, visual-token composition, semantic destination registry, state-restoration policy, architecture verifier, and child-plan contracts.
- Two current semantic profiles with desktop and mobile variants delivered by child plans.
- Settings discovery, preview, commit/cancel/reset, error feedback, and complete removal of the current string branch.

## Non-goals

- Changing server policy, native-agent readiness, authorization, relay protocol, or feature availability.
- Loading executable layouts from portable data, a network service, or an arbitrary widget DSL.
- Preserving old layout identifiers or old preference readers after convergence.
- Treating packaging, GitHub Release, or any store publication as proof of layout correctness.
- Keeping every profile mounted in an `IndexedStack` or using a whole-tree `GlobalKey` as the state model.

## Final acceptance target

The plan family is accepted when the typed layout authority and switch transaction are the only presentation-selection path, every registered `(profile, surface, viewport, destination)` combination is exact-set validated, appearance composition and state ownership are documented and tested, desktop and mobile children implement disjoint renderer bundles against the same stable interfaces, one parent integration join exclusively owns registry composition and app cutover, architecture gates reject every cross-profile or forbidden dependency, profile-isolation tests prove that changing one layout cannot alter another layout's output or state, and the complete plan family proves two materially different layouts without changing product semantics.
