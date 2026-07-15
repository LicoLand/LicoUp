# Mobile Layout Renderer Validation

## Validation principles

- Derive `N` mobile entries from parent composition; do not maintain a renderer-owned name or count list.
- Instantiate every bundle with the same semantic fake-port scenarios while keeping production code, fixtures, tests, assets, source manifests, and goldens profile-owned.
- Prove semantic parity separately from frozen presentation fidelity and profile independence.
- Renderer verification is the child boundary; selection transactions, complete migration, native builds/devices, and launch remain parent evidence.
- Record only minimum privacy-safe status and deterministic artifact evidence.

## Requirement matrix

| Requirement | Mobile renderer evidence | Parent integration evidence |
| --- | --- | --- |
| REQ-001 | Composition-derived manifest tests require exactly one bundle per registered profile under the canonical mobile profile root and reject missing/extra/duplicate/scattered entries. | Parent imports every verified mobile entry exactly once. |
| REQ-002 | Per-bundle constants/metrics, interaction, semantics, focus, animation, and golden comparisons prove equivalence to captured current baselines. | Parent deletes shared chrome/controller bridges only after aggregate equivalence. |
| REQ-003 | Ownership/import tests prove styled components and metrics stay profile-private and renderer/shared code has no profile-ID branches. | Parent registry selects by typed lookup only. |
| REQ-004 | Every bundle asserts the exact mobile destination/action set and mounts Home, Agents, and Settings through narrow fake ports. | Parent validates application-reachable destinations after integration. |
| REQ-005 | State/lifecycle tests retain semantic snapshots while bundle restoration keys remain disjoint, bounded, and reconstructible. | Mounted switching and lifecycle tests prove real continuity. |
| REQ-006 | Every bundle's mobile constraint/inset/input/text-scale/reduced-motion matrix proves stable identity, composer clearance, and no cross-surface fallback. | Parent host proves selection of the same registered variant keys. |
| REQ-007 | Every bundle has behavior, adaptive, semantic, golden, and source-manifest coverage plus touch/focus/contrast/overflow checks. | Parent performs representative whole-app accessibility inspection. |
| REQ-008 | Extension fixture adds one independent profile bundle and composition entry without editing existing bundles/tests or management algorithms. | Parent alone owns composition registration, selector wiring, and app cutover. |
| REQ-009 | Scoped format/analyze, all discovered bundle suites, exact manifest, boundary, pairwise, and Better Plan gates form the receipt. | Parent owns aggregate tests, builds, devices, packaging, release, and launch. |
| REQ-010 | Verifier enforces canonical production/test/asset roots, rejects concrete presentation in shared feature/shell paths plus forbidden imports/overlap/shared chrome/full controller; each of `N` mutations leaves `N − 1` siblings unchanged. | Parent proves one active bundle, immutable registry, and deletion of superseded authorities. |

## Required per-bundle suite

For every composition-derived mobile entry, run:

- bundle identity, exact destination/viewport manifest, and one-public-entry tests;
- shell/destination behavior and semantic action traces through narrow fake ports;
- compact/medium constraints, safe/keyboard insets, lifecycle, input, text-scale, reduced-motion, overflow, and composer-clearance tests;
- semantics, focus/traversal, touch accessibility, and representative Home/Agents/Settings fixtures;
- deterministic current-baseline goldens and normalized source-manifest verification.

Cross-bundle comparison imports public manifests only. Pairwise proof is generated from composition and contains `N(N − 1)` directed change-impact assertions.

## Planned renderer commands

```sh
cd apps/desktop && dart format --output=none --set-exit-if-changed lib/src/frontend/layout/profiles test/layout/profiles
cd apps/desktop && flutter test test/layout/profiles
npm run client:analyze
npm run client:verify:layouts
```

Selectors must discover all composition-derived mobile suites and fail when a registered entry lacks a required category. Golden-update mode is used only to capture the reviewed pre-migration current baseline; acceptance uses comparison mode. Native build/install/launch and aggregate client verification remain parent-owned.

## Better Plan gates

```sh
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" validate docs/plan --plan layout-management/mobile --check-sources
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" check-labels docs/plan --plan layout-management/mobile
```

Scoped gates prove renderer structure and traceability; parent integration owns full product closure.
