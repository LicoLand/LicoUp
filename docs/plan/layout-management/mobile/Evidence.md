# Mobile Layout Renderer Evidence

## Parent-plan contract

| Evidence | Observed contract | Mobile planning consequence |
| --- | --- | --- |
| `docs/plan/layout-management/Requirements.md` | Layout identity, selection, persistence, semantic destination coverage, state authority, appearance composition, and hard isolation are parent-owned concerns. | Mobile consumes stable contracts and delivers renderer bundles; it does not create another manager, preference store, or semantic catalog. |
| `docs/plan/layout-management/Architecture.md` | `LayoutSurfaceBundle` is the sole renderer interface, profile directories are isolated, and one parent integration composition root imports the four desktop/mobile bundles. | Workbench and studio mobile each expose one bundle entry point and never edit or mutate the central registry. |
| `docs/plan/layout-management/Validation.md` | Renderer children prove bundle completeness, material difference, accessibility, and isolation; the parent join proves registration, switching, migration, build, and launch. | The mobile final Node stops at renderer-bundle evidence and hands terminal child evidence to the parent. |

## Repository evidence

| Evidence | Observed behavior | Planning consequence |
| --- | --- | --- |
| `apps/desktop/lib/src/frontend/shell/client_shell.dart` | A runtime/platform check selects `_mobileShell`; the mobile branch is one `Column`, one section body, and one fixed navigation widget. It receives the complete `ClientController`. | The existing shell is integration-owned migration input, not a profile implementation to wrap or edit in this child. New profiles render through narrow ports below their own roots. |
| `apps/desktop/lib/src/frontend/shell/client_mobile_navigation.dart` | Relay, feed, agents, and Settings are hard-coded into a permanent 72-pixel bottom row, including direct controller commands and profile-neutral styling. | Each profile needs its own contextual navigation and component recipes. Exact semantic actions must be adapted without retaining one shared styled navigation implementation. |
| `apps/desktop/lib/src/application/controller/controller_shell_state.dart` | Mobile visibility and fallback are decided in a controller switch, independently of a profile coverage manifest. | Destination policy remains parent-owned; bundles consume the resulting semantic destination contract and provide exact profile-owned adapters. |
| `apps/desktop/lib/src/frontend/features/settings/ui/settings_panel.dart` | Desktop appearance settings include the string shell-layout selector, while `_MobileSettingsBody` includes appearance and locale only. | Mobile child tests cannot claim selector or transaction behavior. Settings wiring belongs to the parent integration join. |
| `apps/desktop/test/client_shell_mobile_layout_test.dart` | Mobile checks exercise the fixed `ClientShell`, broad controller/backend fakes, and bottom-navigation keys; there is no isolated workbench/studio bundle matrix or profile-owned golden tree. | Add profile-only tests against the same narrow fake ports. Existing integration tests are migration inputs and are not edited by sibling profile Nodes. |
| `PRODUCT.md` | The mobile product is conversation-first and explicitly warns against navigation that competes with the composer. | Both bundles keep the composer clear while achieving materially different navigation and component systems. |
| `apps/desktop/pubspec.yaml` | Flutter Material icons are available and current assets are package-wide; no layout-profile asset namespace exists. | Prefer profile-owned Dart recipes and explicitly style-free inputs. If a profile adds assets, it owns a disjoint namespace and the parent integration owner performs any central asset-list change. |

## Current gap

The repository does not yet contain either mobile profile directory, a mobile bundle entry point, profile-owned destination adapters, compact/medium bundle tests, profile-owned golden directories, or a change-impact proof between workbench and studio. Current mobile behavior also couples presentation directly to the complete controller and fixed shell. These are missing renderer capabilities, not evidence that the mobile child should own the central cutover.

## Design evidence inherited from the foundation

The parent evidence records the relevant Flutter primary guidance for constraint-based adaptive layouts, view/view-model boundaries, explicit dependency injection, typed theme extensions, scoped state restoration, and bounded rebuilds. The mobile child applies those decisions as follows:

- local constraints and input/accessibility facts choose compact or medium composition, never profile identity;
- immutable feature snapshots and command ports cross into profile code instead of `ClientController`;
- non-color tokens and styled components remain profile-owned while appearance colors remain an input;
- semantic restoration keys replace whole-tree retention or cross-profile widget state;
- immutable destination-builder maps make lookup deterministic and prevent fallback to sibling implementations.

No new algorithm or data structure beyond the parent immutable bundle/map contracts is justified. A profile-local composition root plus plain immutable records keeps the renderer surface small and makes isolation mechanically testable.

## Audit decisions and risks

- The earlier mobile plan mixed renderer implementation with Settings, fixed-shell deletion, app cutover, Android/iOS build, simulator, and physical-device work. Those responsibilities overlap the parent integration join and would prevent independent profile development, so the rewritten child plan excludes them.
- Shell/component, destination-adapter, and test/golden Nodes use explicit, disjoint owned paths. Workbench and studio branches share only the completed parent interfaces and can proceed independently.
- The profile destination Node owns the bundle entry point because it is the local composition root that can assemble a complete shell, components, preview, tokens, and exact destination map after the shell/component Node is available.
- The final mobile result is intentionally not a runnable-app claim. A bundle can be complete while still unregistered; only the parent join can prove live switching, migration, or platform execution.
- Evidence and goldens must exclude local paths, user content, device identity, backend runtime data, credentials, secrets, and ciphertext.
