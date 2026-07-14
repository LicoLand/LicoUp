# Desktop Layout Profiles Evidence

## Repository evidence

| Evidence | Observed behavior | Desktop planning consequence |
| --- | --- | --- |
| `apps/desktop/lib/src/frontend/shell/client_shell.dart` | A `shellLayoutId` branch selects private topbar/sidebar builders while `_sectionBody` constructs the shared destination tree. | A desktop profile must own complete shell and destination composition; the child must not add another branch to this central file. |
| `apps/desktop/lib/src/frontend/shell/shell_navigation.dart`, `shell_navigation_search_and_status.dart`, and `shell_sidebar_chrome.dart` | Navigation identity, aliases, search, status, and styled chrome are distributed across shared shell files. | Destination identity comes from the parent semantic catalog; profile-specific navigation and styling move behind separate bundle boundaries. |
| `apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart` | The feature imports the retired layout contract and branches on the sidebar ID while also owning substantial pane, tab, scroll, composer, and focus behavior. | Profiles consume narrow feature state/command ports and compose their own Agents chrome; direct feature/profile branching is removed later by the parent integration join. |
| `apps/desktop/lib/src/frontend/features/settings/ui/settings_panel.dart` | A static dropdown writes the old layout selection directly and has no governed preview transaction. | Settings and selection UX are central integration responsibilities, not renderer-child files. |
| `apps/desktop/test/client_shell_mobile_layout_test.dart`, `shell_sidebar_rail_layout_test.dart`, and `agents_workspace_layout_test.dart` | Existing tests assign old IDs and assert a few landmarks rather than independently exercising complete bundles. | Each profile needs its own fake-port behavior, destination, accessibility, adaptive, and golden suite. |
| `apps/desktop/lib/src/frontend/layout/profiles/{workbench,studio}/desktop/` | No complete desktop bundle exists in the inspected renderer tree. | Treat both bundle implementations as missing deliverables rather than wrappers around current shell branches. |
| Parent `Requirements.md`, `Validation.md`, and `Architecture.md` | The parent defines `LayoutSurfaceBundle`, exact surface/viewport/destination coverage, hard isolation, and one integration-owned composition root. | Desktop exports only two immutable surface bundles; central registration, cutover, migration, build, and launch stay in the parent join. |

## Product and architecture gap

The current desktop code does not prove complete profile-owned component systems, exact destination/action coverage, deterministic previews, profile-qualified restoration namespaces, isolated assets/tests/goldens, or that changing one profile leaves the other untouched. A cosmetic rename of the existing two shell branches would preserve the same coupling.

The parent contract resolves the shared concerns: semantic destinations, layout-neutral state/commands, surface/viewport classification, host behavior, selection transaction, appearance palette, and immutable registry validation. The desktop child therefore has no reason to edit `app.dart`, `ClientShell`, Settings, the manager, preferences, or the central registry.

## Isolation evidence and consequence

- Current shell and feature files are shared mutation hotspots. Independent development requires new profile-owned directories rather than simultaneous edits to those files.
- A single bundle entry file per profile provides a narrow public API while internal shell/components and destination adapters remain private.
- Separate source paths, test fixtures, golden roots, asset namespaces, and restoration namespaces make ownership machine-checkable.
- Identical fake-port suites prove semantic equivalence without sharing styled widgets; structural landmarks and golden digests prove the profiles are not aliases.
- The parent boundary verifier can reject cross-profile imports, forbidden dependencies, owned-path overlap, extra public exports, and sibling digest changes without mounting the application.

## Delivery boundary

Renderer evidence can prove bundle completeness, parity, visual difference, accessibility, adaptation, and independence. It cannot prove the production registry, Settings transaction, cold start, old-shell removal, application cutover, rebuild, or launch. Those claims require the parent integration join after desktop and mobile renderer receipts exist.
