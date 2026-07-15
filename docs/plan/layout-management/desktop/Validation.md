# Desktop Layout Profiles Validation

## Validation principles

- Derive `N` desktop entries from parent composition; do not maintain a renderer-owned name or count list.
- Run every bundle against the same semantic fake-port scenarios while keeping source, fixtures, tests, assets, source manifests, and goldens profile-owned.
- Prove capability parity separately from frozen presentation fidelity.
- Renderer verification is the child boundary; production switching, preference policy, complete migration, build, and launch remain parent evidence.
- Record only minimum privacy-safe command and artifact status.

## Requirement matrix

| Requirement | Desktop renderer evidence | Parent integration evidence |
| --- | --- | --- |
| REQ-001 | Composition-derived manifest tests require exactly one bundle per registered profile under the canonical desktop profile root and reject missing/extra/duplicate/scattered entries. | Parent imports every verified desktop entry exactly once. |
| REQ-002 | Per-bundle constants/metrics, interaction, semantics, focus, animation, and golden comparisons prove equivalence to the captured current baseline. | Parent deletes shared chrome/controller bridges only after aggregate equivalence passes. |
| REQ-003 | Every bundle asserts the exact desktop destination/action set and mounts representative Home, Agents, and Settings content with no sibling fallback. | Central composition validates the complete registered destination product. |
| REQ-004 | Fixture host replaces any bundle with any other; narrow-port contract tests reject controller/domain/platform/styled-widget dependencies. | Parent proves preview, confirm, cancel, reset, recovery, and mounted switching. |
| REQ-005 | Fake-port and namespace tests retain semantic state while keeping bundle-local restoration keys disjoint and bounded. | Mounted tests prove destination/session/draft/operation/focus continuity. |
| REQ-006 | Every bundle's desktop viewport/constraint/input matrix proves stable identity, no overflow, and no cross-surface fallback. | Parent resolver proves resize never persists selection. |
| REQ-007 | Every bundle has behavior, adaptive, semantic, golden, and source-manifest coverage plus keyboard/pointer/text-scale/contrast/reduced-motion checks. | Parent performs representative integrated accessibility inspection. |
| REQ-008 | Extension fixture adds one independent profile bundle and composition entry without editing existing bundle tests or management algorithms. | Parent alone owns composition registration, app cutover, build, and launch. |
| REQ-009 | Verifier enforces canonical production/test/asset roots, rejects concrete presentation in shared feature/shell paths plus forbidden imports/overlap/shared chrome/profile-ID branches; each of `N` mutations leaves `N − 1` siblings unchanged. | Parent proves one active bundle, immutable registry, and deletion of superseded authorities. |

## Required per-bundle suite

For every composition-derived desktop entry, run:

- bundle identity, exact destination/viewport manifest, and one-public-entry tests;
- shell/destination behavior and semantic action traces using narrow fake ports;
- adaptive constraints, input, text-scale, reduced-motion, and overflow tests;
- semantics, focus traversal, accessibility, and representative Home/Agents/Settings fixtures;
- deterministic current-baseline goldens and normalized source-manifest verification.

Cross-bundle comparison imports public manifests only. Pairwise proof is generated from composition and contains `N(N − 1)` directed change-impact assertions.

## Planned renderer commands

```sh
npm run client:format:check
npm run client:analyze
npm run client:verify:layouts
cd apps/desktop && flutter test test/layout/profiles
```

The selector must discover all composition-derived desktop suites and fail when a registered entry lacks any required category. Golden-update mode is used only to capture the reviewed pre-migration current baseline; acceptance runs use comparison mode. The child does not claim production cutover, build, or launch.

## Better Plan gates

```sh
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" validate docs/plan --plan layout-management/desktop --check-sources
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" check-labels docs/plan --plan layout-management/desktop
```
