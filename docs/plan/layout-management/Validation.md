# Layout Management Foundation Validation

## Validation principles

- Validation follows REQ-001 through REQ-014 and derives expected cardinality from immutable composition: `N` profiles, `M` surfaces, `B = N × M` bundles.
- The current worktree rendering, semantics, focus order, interaction behavior, and metrics are frozen before isolation work. Validation detects redesign; it does not authorize one.
- Registration and persistence use deterministic unit tests. Independence uses isolated behavior, adaptive, semantic, golden, source-manifest, and pairwise change-impact tests generated from the registered product.
- Historical partial-scope receipts are non-current until rerun against the current registered-product baseline.
- Evidence excludes raw runtime data, local paths, user content, device identity, credentials, secrets, and ciphertext.

## Requirement matrix

| Requirement | Foundation evidence | Renderer/integration evidence |
| --- | --- | --- |
| REQ-001 | Parameterized catalog tests accept arbitrary valid `N`, reject duplicate/invalid IDs, require one catalog default, and validate one injected preferred ID shared by first run/reset/load/manager/resolver. | Current-registration fixtures assert exact IDs/labels/default metadata and both current platform-preference outcomes. |
| REQ-002 | Composition tests derive `B = N × M`, require one bundle per profile/surface pair under `frontend/layout/profiles/<profile>/<surface>/`, and reject missing, extra, duplicate, or scattered entries without hard-coded counts. | Every registered bundle passes behavior, adaptive, semantic, golden, and source-manifest tests from corresponding owned roots. |
| REQ-003 | Product validation derives every `(profile, surface, viewport, destination)` key and rejects missing/extra builders. | Representative Home, Agents, and Settings content opens through every registered key without sibling fallback. |
| REQ-004 | Narrow shell/destination-port tests expose semantic snapshots/callbacks only and reject controller/domain/platform/styled-widget values. | Production fixtures exercise navigation, search/status, pairing entry, capability state, Home, Agents, and Settings without `ClientController`. |
| REQ-005 | Parameterized resolver tests use each registered surface policy, distinguish same-named viewports across surfaces, and never persist environment changes. | Current surface constraint matrices prove stable selected identity and no cross-surface chrome fallback. |
| REQ-006 | Appearance/layout composition tests keep palette authority separate from bundle-private metrics and styled recipes. | Representative appearance and text-scale goldens pass for every registered bundle without a layout-by-theme matrix. |
| REQ-007 | Repository tests cover atomic serialization, corruption, and concurrent layout/appearance/locale updates. | Cold-start integration waits for typed preference hydration before meaningful shell paint. |
| REQ-008 | Manager tests cover preview, confirm, cancel, reset to injected preference, timeout, unknown/unavailable ID, and save failure. Mismatch fixtures reject competing fallback values across load/manager/resolver. | Settings fixtures exercise every registered selection and every supported current preferred-default outcome. |
| REQ-009 | State-store bounds and focus-coordinator contracts are parameterized by registration. | Mounted switching across all registered profiles preserves semantic/domain state and mounts only one bundle. |
| REQ-010 | Semantics, text-scale, surface-input, and reduced-motion contracts are generated per bundle. | Current keyboard/pointer/touch/focus matrices pass without changing frozen rendering or interactions. |
| REQ-011 | Cardinality tests run the same catalog/registry/manager/resolver/host/Settings algorithms at multiple `N` and `M` values; lookup remains O(1) after construction. Static scans reject profile-ID branches outside composition data/tests. | Adding a fixture profile requires only independent fixture bundles and composition registration; no management algorithm or existing profile fixture changes. |
| REQ-012 | The boundary verifier derives entries from composition; enforces canonical production/test/asset roots; allows only contracts/composition/host/neutral ports in shared layout infrastructure; and rejects concrete presentation in shared feature/shell paths, cross-bundle imports, full-controller access, shared styled chrome/metrics, mutable registration, and overlap. | For `B` bundles, each isolated change leaves `B − 1` others unchanged; all `B(B − 1)` directed source/golden assertions pass. |
| REQ-013 | Current-schema recovery uses the injected platform preference; retired/shared-chrome/controller-bridge scans require superseded code, paths, tests, docs, aliases, and wrappers absent. | Integration proves one direct cutover, one preferred-default authority, and no compatibility/fallback path. |
| REQ-014 | Scoped Better Plan checks and registration-derived requirement/file/command traceability cover the full product. | Fresh per-bundle receipts, Home/Agents/Settings fixtures, build/open, platform verification, and scoped family checks form final evidence. |

## No-redesign baseline gate

Before privatization, capture deterministic source manifests plus representative pixel, semantics, focus, and interaction output for every currently registered bundle. The matrix includes every registered surface/viewport, representative appearance inputs, text scale, reduced motion, and Home/Agents/Settings content. Current profile-specific protected interactions are enumerated in `Evidence.md` and current exact tests.

After privatization:

- constants and visual metrics copied from shared chrome are byte-equivalent;
- golden output is pixel-equivalent under the existing deterministic comparison policy;
- semantics, focus traversal, callbacks, and interaction traces are equivalent;
- no implementation change is accepted merely to make a redesigned golden pass;
- shared styled chrome, metrics, and controller bridges are deleted before the gate passes.

## Cardinality and extension tests

- A generic fixture matrix exercises multiple `N` and `M` values, including adding one profile through independent bundle fixtures plus one composition registration.
- Catalog, registry, manager, resolver, host, persistence, and Settings tests are unchanged when fixture cardinality changes.
- Exact current-registration tests assert the inventory recorded in `Evidence.md`; they are release-baseline assertions, not architectural constants.
- The verifier computes `B` and the `B(B − 1)` impact matrix from composition rather than maintaining an expected-name list in its algorithm.

## Focused checks

- Contract/catalog/manager/repository/state-store/host tests cover variable cardinality, one catalog default, one injected preferred authority, exact products, transitions, recovery, bounded namespaces, and one active tree.
- Composition tests assert derived cardinality, exact bundle grouping, one metadata source, and no duplicate registry authority.
- Every current bundle root has behavior, adaptive, semantic, golden, and source-manifest coverage.
- Parent production fixtures mount representative Home, Agents, and Settings content through every current profile/surface.
- The boundary verifier enforces canonical roots, keeps shared layout infrastructure neutral, rejects concrete presentation in shared feature/shell paths, allows only declared imports, rejects full controller/profile-ID branches, requires deleted shared chrome/metrics, derives exact entries, and computes the directed change-impact matrix.

## Executable closure

```sh
npm run client:format:check
npm run client:analyze
npm run client:test:layouts
npm run client:verify:layouts
npm run client:verify:architecture
npm run client:verify:plan
npm run client:contracts:test
```

The integration join additionally runs the canonical approved client workflow, rebuilds and opens the client, and starts independent verification for affected platforms. Packaging and store publication remain separate claims.

## Better Plan gates

```sh
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" validate docs/plan --plan layout-management --check-sources
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" check-labels docs/plan --plan layout-management
```

Scoped success is reported separately from unrelated workspace-plan debt. Full-family close-out requires every registered-surface child and the foundation integration plan to be terminal.
