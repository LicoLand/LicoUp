# Desktop Layout Profiles Validation

## Validation principles

- Run each profile against the same parent-provided fake state/command ports, but keep its production code, fixtures, tests, assets, and goldens profile-owned.
- Prove capability parity separately from structural and visual difference.
- Treat renderer-bundle verification as the child acceptance boundary. Production switching, Settings, migration, build, and launch remain parent-integration evidence.
- Record only minimum, privacy-safe command/file evidence.

## Requirement matrix

| Requirement | Desktop renderer evidence | Parent integration evidence |
| --- | --- | --- |
| REQ-001 | Workbench bundle manifest, shell/components, destination, adaptive, preview, token, semantics, and golden tests. | Parent imports the verified workbench desktop entry once. |
| REQ-002 | Studio bundle manifest, shell/components, destination, adaptive, preview, token, semantics, and golden tests. | Parent imports the verified studio desktop entry once. |
| REQ-003 | Both profile-only suites assert the exact parent desktop destination/action set with no missing, extra, or fallback builder. | Central composition validates the complete built-in product and mounted destinations. |
| REQ-004 | Fixture host replaces bundles in both directions and proves deterministic preview/landmarks with no manager or persistence dependency. | Parent proves live preview, confirm, cancel, reset, error recovery, and reduced-motion switching. |
| REQ-005 | Fake-port and namespace tests retain semantic state while keeping profile-local restoration keys disjoint and bounded. | Parent mounted tests prove real destination/session/draft/operation/focus continuity. |
| REQ-006 | Medium/expanded and supported narrow-constraint matrices prove stable identity, correct input adaptation, and no overflow. | Parent resolver proves resize never persists selection. |
| REQ-007 | Keyboard, pointer, semantics, focus, text-scale, contrast, reduced-motion, appearance-token, landmark, and deterministic golden checks. | Parent performs representative integrated accessibility inspection. |
| REQ-008 | Static diff/ownership evidence shows only profile roots, profile tests/goldens, and bundle receipts changed; each entry exports one desktop bundle. | Parent alone edits composition, app, shell, Settings, migration, docs, build, and launch paths. |
| REQ-009 | Boundary verifier rejects forbidden/cross-profile imports and path overlap; identical fake-port suites plus sibling source/golden digest fixture prove change isolation. | Parent proves only the active registered profile is mounted and registry state is immutable. |

## Profile-owned checks

- Workbench: exact manifest, all destination builders, command/search shell, floating/card components, medium/expanded adaptation, deterministic preview, semantic landmarks, appearance composition, accessibility, and goldens.
- Studio: exact manifest, all destination builders, contextual navigation, docked/dense components, medium/expanded adaptation, deterministic preview, semantic landmarks, appearance composition, accessibility, and goldens.
- Both: the same immutable fake states and command recorder, exact action traces, stable state across fixture-host replacement, bounded profile-qualified restoration IDs, and no backend/platform/controller imports.
- Difference proof: distinct structural landmark sets and independently reviewed golden digests; color-only or token-only differences do not pass.
- Isolation proof: owned-path manifests are disjoint and a deterministic change-impact fixture changes one profile manifest while the sibling source manifest and golden digest remain unchanged.

## Planned renderer commands

Run from the repository root unless a command states otherwise:

```sh
npm run client:format:check
npm run client:analyze
npm run client:verify:layouts
cd apps/desktop && flutter test test/layout/profiles/workbench/desktop
cd apps/desktop && flutter test test/layout/profiles/studio/desktop
```

The two Flutter selectors are separate receipts. `client:verify:layouts` is created and self-tested by the parent foundation before renderer work starts. The desktop final-validation Node does not run `client:run:macos`, edit application files, or claim production cutover; the parent integration join owns those checks.

## Better Plan gates

```sh
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" validate docs/plan --plan layout-management/desktop --check-sources
python3 "$HOME/.agents/skills/better-plan/scripts/manifest_tool.py" check-labels docs/plan --plan layout-management/desktop
```
