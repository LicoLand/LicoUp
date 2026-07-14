# Layout Management Foundation Validation

## Validation principles

- Validation follows requirement labels from `Requirements.md`.
- Profile registration and persistence are proven with deterministic unit tests; layout difference and parity are proven by parameterized widget, semantics, golden, and integration tests.
- The foundation plan proves shared contracts. Desktop and mobile children own platform renderer, build, launch, and device evidence.
- Raw runtime data, local paths, user content, device identity, and secrets are excluded from evidence.

## Requirement matrix

| Requirement | Foundation evidence | Renderer/integration evidence |
| --- | --- | --- |
| REQ-001 | Catalog rejects numbered/versioned/duplicate IDs and proves one semantic default. | Renderer bundles export only `workbench` / `studio`; integration Settings exposes those identities. |
| REQ-002 | Bundle contract requires shell, destination builders, styled components, tokens, preview, and exact `desktop={medium,expanded}` / `mobile={compact,medium}` variants without importing implementations. | Desktop/mobile isolated bundle tests and goldens prove complete, materially different component trees. |
| REQ-003 | Composition validator proves the exact `(profile, surface, viewport, destination)` product and rejects missing/extra builders. | Every reachable destination opens in every registered profile/surface/viewport matrix after integration. |
| REQ-004 | Narrow presentation-port tests keep domain state and commands outside profile widgets. | Integration live-switch tests retain destination, session, draft, operations, and permission behavior. |
| REQ-005 | Resolver tests distinguish `desktop/medium` from `mobile/medium`, clamp classification to the declared surface policy, use constraints/capabilities, and never persist a resize. | Desktop/mobile constraint matrices prove surface-correct variants and stable selected identity, including narrow desktop and large mobile bounds. |
| REQ-006 | Theme composition contract proves appearance palette and layout tokens remain separate. | Per-profile tests and representative goldens cover every built-in appearance/profile pair, contrast, and text scaling. |
| REQ-007 | Repository atomicity, serialization, corruption, and concurrent-update tests. | Integration cold-start tests prove first meaningful paint waits for typed preference hydration. |
| REQ-008 | Manager state-machine tests prove preview, confirm, cancel, reset, timeout, unknown ID, unavailable profile, and save failure. | Integration Settings tests prove controls and localized safe error feedback on desktop and mobile. |
| REQ-009 | State-store bounds and focus-coordinator contracts are fixture-tested. | Integration tests prove scroll, pane, expansion, focus, draft, and selected-conversation continuity. |
| REQ-010 | Semantics and reduced-motion contracts are fixture-tested. | Desktop keyboard/pointer and mobile touch/text-scale matrices prove equivalent semantic actions. |
| REQ-011 | Immutable-map complexity tests, one-entry resolution cache assertions, rapid-request coalescing, and rebuild instrumentation. | Integration frame/build-count smoke proves one active profile and no whole-app rebuild churn. |
| REQ-012 | `client:verify:layouts` rejects cross-profile imports, complete-controller imports, legacy shell imports, backend/platform imports, shared styled components, mutable registry access, and owned-path overlap. | Each profile runs against the same fake ports in a profile-only test command; a change-impact fixture proves another profile's source manifest and golden digest remain unchanged. |
| REQ-013 | Canonical preference rewrite and retired-symbol scan are specified before cutover. | Integration removes old shell widgets, IDs, preferences, tests, branches, and contradictory docs in one convergence. |
| REQ-014 | Scoped Better Plan checks and requirement/file/command traceability prove foundation contracts. | Renderer child receipts plus the parent integration join's build, launch, independent Android verification, and scoped family checks prove the product. |

## Plan-family traceability

| Foundation requirement | Owning downstream plan/local requirements | Final proof owner |
| --- | --- | --- |
| REQ-001, REQ-002, REQ-003, REQ-005, REQ-006, REQ-010, REQ-012 | `layout-management/desktop` REQ-001, REQ-002, REQ-003, REQ-006, REQ-007, REQ-009; `layout-management/mobile` REQ-001, REQ-002, REQ-003, REQ-004, REQ-006, REQ-007, REQ-010 | Renderer children prove isolated bundles; `layout-management/integration` proves the complete registry product. |
| REQ-004, REQ-007, REQ-008, REQ-009, REQ-011, REQ-013 | `layout-management/desktop` REQ-004, REQ-005, REQ-008; `layout-management/mobile` REQ-005, REQ-008; integration transaction/migration requirements | Foundation proves pure state/repository contracts; integration proves mounted behavior and the only current path. |
| REQ-014 | All non-skipped local requirements in foundation, desktop, and mobile | The foundation plan's final integration validation records the family receipt after both children finish. |

## Planned focused checks

- `test/layout/layout_profile_contract_test.dart` — semantic IDs, surface/viewport classification, immutable values, and safe errors.
- `test/layout/layout_catalog_test.dart` — exact `(profile, surface, viewport, destination)` product, deterministic order, and O(1) lookup maps.
- `test/layout/layout_manager_test.dart` — fake repository, controllable epochs, preview/commit/cancel/reset/recovery/coalescing.
- `test/layout/presentation_preferences_repository_test.dart` — atomic canonical writes, corruption, and concurrent layout/appearance/locale updates.
- `test/layout/layout_state_store_test.dart` and `layout_focus_coordinator_test.dart` — bounded namespaces and semantic restoration.
- `test/layout/layout_host_contract_test.dart` — fixture bundles, one active tree, composed tokens, and scoped rebuilds without any built-in profile.
- `test/layout/profiles/{workbench,studio}_{desktop,mobile}_test.dart` plus profile-owned golden directories — independent bundle behavior and visuals.
- `test/layout/layout_integration_test.dart`, `layout_settings_test.dart`, and `layout_state_continuity_test.dart` — parent-owned central composition, selector transaction, cold start, and mounted switch behavior.
- `apps/desktop/scripts/verify-layout-boundaries.mjs` — owned-path manifests, forbidden imports, single composition root, exact bundle exports, retired-symbol absence, and change-impact fixture.

## Current executable gates

```sh
npm run client:format:check
npm run client:analyze
npm run client:test
npm run client:verify:architecture
npm run client:verify:plan
npm run client:contracts:test
```

The architecture node shall add `npm run client:verify:layouts` for `verify-layout-boundaries.mjs`; renderer children shall add profile-only test selectors, and the parent integration join shall add `npm run client:test:layouts`. These commands are planned evidence until their owning nodes create and self-test them.

`npm run client:verify` is the aggregate client closure and is marked by `lico-dev workflow plan client` as runtime-data side effect. It may run only with explicit side-effect authorization through the canonical workflow.

The repository currently documents `npm run client:test:coverage` but does not define it. The validation-matrix Node must either establish that executable entry and its truthful threshold or update the contract before coverage can be cited. A missing command is not acceptance evidence.

## Better Plan gates

During this plan:

```sh
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" validate docs/plan --plan layout-management --check-sources
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" check-labels docs/plan --plan layout-management
```

At full plan-family close-out, all three layout plans must be terminal and the full workspace validator must pass. Seven pre-existing release-plan graph issues currently prevent that full-workspace claim; they remain independent sibling debt and cannot be hidden by a scoped result.
