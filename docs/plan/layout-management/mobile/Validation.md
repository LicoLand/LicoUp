# Mobile Layout Renderer Validation

## Validation boundary

- This child validates two isolated renderer bundles, not the integrated application.
- Tests instantiate each bundle directly with the same deterministic layout environment, appearance input, localization, and narrow fake feature ports.
- Workbench and studio tests and goldens remain under disjoint profile-owned directories.
- Central registry composition, Settings transactions, live cross-profile switching, fixed-shell removal, application integration, native builds, simulator/device work, packaging, and launch are validated only by the parent integration join.
- Evidence records commands, source manifests, and deterministic artifacts without local paths, user content, device identity, backend runtime data, credentials, secrets, or ciphertext.

## Requirement matrix

| Requirement | Renderer evidence | Parent handoff boundary |
| --- | --- | --- |
| REQ-001 | Each profile bundle test asserts the parent semantic ID, `mobile` surface, compact/medium variants, immutable metadata, and one public `LayoutSurfaceBundle` export. | Parent imports each entry point exactly once and forms the aggregate definition. |
| REQ-002 | Workbench widget and golden matrices prove spacious card/stack composition, contextual navigation, and unobstructed composer geometry. | Parent proves the registered workbench selection reaches this bundle. |
| REQ-003 | Studio widget and golden matrices prove dense edge-to-edge composition, compact overlay/drawer, medium rail/dock, and landmarks structurally distinct from workbench. | Parent proves the registered studio selection reaches this bundle. |
| REQ-004 | Per-profile parameterized tests compare bundle destination keys and semantic actions with the parent-declared mobile set; adapters run only through narrow fake ports. | Parent proves the declared set matches application-reachable destinations after integration. |
| REQ-005 | Fake-port tests prove domain snapshots and commands remain external, restoration keys are profile-specific and bounded, and rebuilding from the same supplied state preserves semantic selection and draft values. | Parent proves mounted switch and application lifecycle continuity. |
| REQ-006 | Compact/medium constraint matrices cover portrait-like and landscape/split/fold-like sizes, safe insets, keyboard inset, text scale, reduced motion, and input facts without a preference write. | Parent proves the host selects the same keys in the wired app. |
| REQ-007 | Semantics, touch-target, traversal, focus, contrast-token, overflow, composer-clearance, reduced-motion, and deterministic appearance/golden checks pass per profile. | Parent performs any whole-app accessibility and launch inspection. |
| REQ-008 | Changed-file and import evidence is limited to declared profile/test/golden roots; static verification rejects central integration ownership. | Parent alone changes registry, app, shell, Settings, migration, integration tests, native projects, and product docs. |
| REQ-009 | Scoped format/analyze, two profile-only suites, golden consistency, bundle-manifest checks, boundary verification, and Better Plan gates form the renderer receipt. | Parent owns aggregate tests, rebuilds, native builds, simulator/device, packaging, release, and launch evidence. |
| REQ-010 | Owned-path manifests, forbidden-import checks, isolated fake-port tests, unique restoration namespaces, and change-impact source/golden digests prove sibling independence. | Parent consumes bundles without importing profile internals or sharing runtime state. |

## Profile-owned test targets

### Workbench

- `test/layout/profiles/workbench/mobile/workbench_mobile_bundle_test.dart` — immutable bundle identity, surface, variants, destination product, preview, and restoration namespace.
- `test/layout/profiles/workbench/mobile/workbench_mobile_shell_test.dart` — compact/medium structure, navigation, composer clearance, state snapshots, constraints, semantics, and reduced motion.
- `test/layout/profiles/workbench/mobile/workbench_mobile_golden_test.dart` and `test/layout/profiles/workbench/mobile/goldens/` — deterministic representative appearance, size, inset, and text-scale matrix.

### Studio

- `test/layout/profiles/studio/mobile/studio_mobile_bundle_test.dart` — immutable bundle identity, surface, variants, destination product, preview, and restoration namespace.
- `test/layout/profiles/studio/mobile/studio_mobile_shell_test.dart` — compact/medium structure, drawer or overlay, rail or dock, composer clearance, state snapshots, constraints, semantics, and reduced motion.
- `test/layout/profiles/studio/mobile/studio_mobile_golden_test.dart` and `test/layout/profiles/studio/mobile/goldens/` — deterministic representative appearance, size, inset, and text-scale matrix.

Both suites use the same parent-owned fake-port contract fixture but keep profile assertions and outputs inside their own roots. Cross-profile comparison is limited to public bundle manifests and normalized structural landmark or golden digests; no test imports sibling internals.

## Planned renderer commands

The parent architecture Node establishes `npm run client:verify:layouts`; it is planned evidence until that Node creates and self-tests the command. The mobile final Node runs only renderer-scoped checks:

```sh
cd apps/desktop && dart format --output=none --set-exit-if-changed lib/src/frontend/layout/profiles/workbench/mobile lib/src/frontend/layout/profiles/studio/mobile test/layout/profiles/workbench/mobile test/layout/profiles/studio/mobile
cd apps/desktop && flutter test test/layout/profiles/workbench/mobile
cd apps/desktop && flutter test test/layout/profiles/studio/mobile
npm run client:analyze
npm run client:verify:layouts
```

`client:analyze` is the compile/static-analysis closure needed for orphanable Dart profile files; it does not establish app integration. The final Node must also record immutable bundle manifest and golden consistency evidence. It does not run `client:test`, `client:verify`, an integration test, a native build, a simulator, a device install, packaging, or a launch command.

## Better Plan gates

```sh
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" validate docs/plan --plan layout-management/mobile --check-sources
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" check-labels docs/plan --plan layout-management/mobile
```

These scoped gates prove this child plan's structure and traceability. Full plan-family and full-workspace closure remain parent responsibilities.
