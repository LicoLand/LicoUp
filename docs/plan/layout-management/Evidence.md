# Layout Management Foundation Evidence

## Repository evidence

| Evidence | Observed behavior | Planning consequence |
| --- | --- | --- |
| `apps/desktop/lib/src/contracts/appearance/shell_layout.dart` | Defines only `topbar` and `sidebar-rail` string constants and silently normalizes unknown values to `topbar`. | Replace the string list with typed descriptors, a unique default, explicit validation, and semantic names. |
| `apps/desktop/lib/src/frontend/shell/client_shell.dart` | Chooses a desktop `Column` or `Row` with one conditional and reuses the same section body. The mobile shell is fixed and ignores the selection. | Separate profile identity from adaptive variants and route every surface through one layout host. |
| `apps/desktop/lib/src/frontend/shell/shell_navigation.dart`, `shell_navigation_search_and_status.dart`, `client_mobile_navigation.dart`, and `application/controller/controller_shell_state.dart` | Destination identity, aliases, search visibility, desktop navigation, mobile filtering, and fixed bottom navigation are maintained in separate lists and switches. | Introduce one semantic destination catalog and validate exact coverage by runtime surface instead of trusting source placement. |
| `apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart` | Directly checks the shell ID to invert one chrome card. Other feature pages ignore it. | Layout knowledge has leaked into feature UI; introduce semantic slots/factories and remove direct ID checks. |
| `apps/desktop/lib/src/frontend/shared/ui/apple_glass.dart` and feature widgets using `AppleControlMetrics` | Visually opinionated radius, density, glass, and motion choices are shared directly by all current surfaces. | A profile must own styled components and tokens; only explicitly style-free primitives may be shared across profiles. |
| `apps/desktop/lib/src/application/controller/controller_lifecycle_actions.dart` | Mutates in-memory layout state, notifies the app, then saves asynchronously. | A failed write can leave UI and disk disagreeing; selection needs an explicit transaction state machine. |
| `apps/desktop/lib/src/platform/appearance/appearance_preferences_service.dart` | Appearance, locale, and layout setters each read the whole JSON document and independently rename a temporary file. There is no serialization. | Concurrent read-modify-write operations can lose fields; use one typed repository and serialized atomic commits. |
| `apps/desktop/lib/app.dart` | `MaterialApp` is built before asynchronous preference hydration completes. | Gate the first meaningful shell paint on presentation hydration to avoid a default-layout flash. |
| `apps/desktop/lib/src/frontend/shared/ui/theme.dart` and `assets/appearance-presets/` | Existing presets provide a validated color/light-dark axis through `LicoThemeColors`. | Preserve this authority and compose it with layout-owned non-color tokens instead of duplicating every palette per layout. |
| `apps/desktop/test/client_shell_mobile_layout_test.dart`, `shell_sidebar_rail_layout_test.dart`, and `agents_workspace_layout_test.dart` | Tests assign IDs directly and assert isolated structures; they do not exercise a live switch, persistence, failure, state continuity, or full destination coverage. | Add manager/store tests, a parameterized profile matrix, state-continuity tests, goldens, and cold-start integration tests. |
| `apps/desktop/scripts/verify-client-architecture.mjs` | Uses source-string assertions that require destination construction to remain directly inside `client_shell.dart`. | Replace the brittle assertion with semantic destination/profile coverage and dependency-boundary checks. |
| Planned paths under `contracts/presentation`, `application/features/layout`, `platform/presentation`, and `frontend/layout` | None of the planned runtime modules exists in the current tree. | Treat the layout runtime as missing implementation, not as an incremental extension of an existing registry. |
| `apps/desktop/Design.md` | States that desktop has no left icon rail while the working tree contains one; labels/tests also use numbered layout language. | Update current design truth during the complete migration and use semantic profile identities. |
| `docs/functionality/CLIENT-DESKTOP.md` | Defines appearance/theme preferences but no multi-layout product contract. | Add the governed layout contract after implementation, without changing feature or policy ownership. |

## Product gap

The current code proves only a partial desktop shell variant. It does not provide:

- a registry or definition contract;
- component-style, page-composition, preview, breakpoint, or accessibility ownership;
- mobile selection or compact variants;
- exact semantic destination coverage;
- a surface dimension that distinguishes `desktop/medium` from `mobile/medium` while retaining one profile identity;
- deterministic save failure recovery;
- preservation of page-local state across a root-tree replacement;
- bounded transition or rebuild policy;
- source, asset, state, and test isolation between profiles;
- a verifier that prevents layout-ID branching from spreading through feature modules.

## Primary and open-source practice

- Flutter's [adaptive layout guidance](https://docs.flutter.dev/ui/adaptive-responsive/general) and [adaptive best practices](https://docs.flutter.dev/ui/adaptive-responsive/best-practices) distinguish user-facing design from adaptation to available constraints, recommend `LayoutBuilder` or `MediaQuery.sizeOf`, and warn against device-name or orientation routing.
- Flutter's [app architecture guide](https://docs.flutter.dev/app-architecture/guide) keeps mutable UI state and commands in view models while views own composition. The plan therefore keeps business/semantic state above profile widgets.
- Flutter's [dependency-injection guidance](https://docs.flutter.dev/app-architecture/case-study/dependency-injection) asks an architecture to state which components may communicate and what each exposes. The plan therefore passes narrow immutable feature state/command ports into profiles instead of the complete `ClientController`.
- Flutter's [ThemeExtension API](https://api.flutter.dev/flutter/material/ThemeExtension-class.html) provides typed custom tokens with `copyWith` and `lerp`, which fits layout-owned spacing, shape, density, typography, elevation, and motion layered over the existing palette.
- Flutter's [Widget key contract](https://api.flutter.dev/flutter/widgets/Widget/key.html), [PageStorage](https://api.flutter.dev/flutter/widgets/PageStorage-class.html), and [RestorationMixin](https://api.flutter.dev/flutter/widgets/RestorationMixin-mixin.html) support explicit identity and scoped restoration. Whole-tree global-key grafting is avoided.
- Flutter's [performance guidance](https://docs.flutter.dev/perf/best-practices) supports small rebuild boundaries, const subtrees, lazy construction, and avoiding repeated work in `build`. The plan uses an immutable map registry and builds only the active profile.
- VS Code's [custom layout](https://code.visualstudio.com/docs/configure/custom-layout), [profiles](https://code.visualstudio.com/docs/configure/profiles), and [layout service source](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/services/layout/browser/layoutService.ts) separate registered parts, restored state, layout events, reset behavior, and profile-scoped UI state. Lico Arc adopts the typed-boundary and explicit-reset ideas without importing VS Code's workbench complexity.

## Constraints and contradictions

- The repository has a valid Better Plan workspace at `docs/plan`. Existing release plans are separate delivery contracts and are not the parent of this UI capability.
- Desktop and mobile currently have different shell directions. The plan family therefore uses one platform-neutral parent, desktop/mobile renderer children, and one parent integration join Node that alone owns composition-root registration, app cutover, and complete retired-path removal.
- Desktop and mobile both require a `medium` viewport. A registry keyed only by `(profile, viewport)` would collide; the architecture must key variants by `(profile, surface, viewport)` and validate coverage in `O(P × S × V × D)` at composition time.
- Parent fixtures can prove contracts, manager, repository, and host behavior, but cannot claim real profile tokens, complete built-in registration, or old-renderer removal before child bundles exist. Those claims belong to the parent integration join after both renderer children finish.
- The full existing Better Plan workspace has seven pre-existing unstartable sibling nodes in release platform plans. Layout work can use plan-scoped validation, but cannot claim a full-workspace close-out until that independent debt is repaired.
- `apps/desktop/AGENTS.md` names `npm run client:test:coverage`, but `package.json` currently lacks that script. The validation-matrix work must establish a real executable coverage entry or correct the contract before coverage is used as evidence.
- The client working tree contains extensive user changes. This plan is grounded in the current tree and must preserve unrelated work.
