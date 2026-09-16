# UI interaction state machine

| Version | Entry |
| --- | --- |
| Normative | English (this document) |
| Localization | [简体中文](UI-INTERACTIONS.zh-CN.md) |

[UI-INTERACTIONS.json](UI-INTERACTIONS.json) is the behavior contract: what a
person sees, what they can do there, and what should be visible afterwards.
It contains no Flutter keys, controller names, RPC methods, or backend states.
The [Flutter adapter](../../apps/desktop/test/ui_state_machine/flutter_adapter.dart)
maps that contract to current controls and rendered content. Refactoring changes
the adapter; intentional product behavior changes require reviewing the model.

A selected navigation button alone does not prove success. The expected page
content must be visible. For example, returning from a group to the parent list
changes the left list while keeping the group on the right. Leaving for Settings
and returning preserves the group, list, and member-panel context.
Opening a group starts with its member panel collapsed; the ellipsis menu
provides the explicit expand action.

## Run locally

```bash
npm run client:test:ui -- --describe
npm run client:test:ui
npm run client:test:ui -- --seed 42 --steps 60
npm run client:test:ui -- --machine dashboard.conversation-journey --seed 42
npm run client:test:ui -- --profile --device macos --seed 42
```

Use an already available local environment. The developer organizes other
devices; missing devices do not block this work. Widget mode exercises compact,
medium, and wide layouts locally. Profile mode currently exercises wide desktop
views on the selected local target. It uses production widgets and animations
with synthetic services, temporary storage, a simulated keyboard, and no real
Agent conversation. The engine schedules frames from application activity;
test pumps wait for observation without forcing extra frames. This does not
test the operating system input method. On
macOS the test uses a temporary bundle identifier so it can run beside an open
personal-data application; production bundle settings are unchanged.

`--steps` controls exploration length, not an acceptance threshold. The default
run prints a fresh seed; supply it to repeat that run. `--machine` selects one
flow. A recorded action sequence can also be replayed without the preceding
coverage walk:

```bash
npm run client:test:ui -- --machine dashboard.conversation-journey --replay list.back,group.open,group.menu,roster.toggle,group.menu,roster.toggle
```

Each flow starts once. The driver first visits every declared transition using
shortest click paths to the remaining edges, then continues from that state with
a seeded random walk. It chooses among currently visible controls and fails if
a declared action disappears. It does not reset a controller between clicks or
wait for every animation to finish before allowing the next click. Dialogs,
search, scrolling, returning, and switching pages participate in the same walk.
The recorded sequence includes both phases. Setup actions are applied separately
on replay.

## What is covered

The model covers primary navigation in both layouts, compact menus, desktop
feature-window opening/reselect/closing, all settings index entries, and a
populated dashboard journey connecting group conversations, parent lists,
native-conversation selection, search input/results, creation-dialog cancellation,
group-menu cancellation, settings/features, refresh, and scrolling in both
directions. The nonmodal group menu also allows the visible surrounding
navigation, list, search, roster, and scroll actions in that same state.
Messages must actually move when scrolling, unless already at the requested end.
Synthetic groups provide a long transcript and an empty peer conversation.

This is **coverage of declared transitions**, not proof that every product
operation or every possible sequence has been tested. The runner also inventories
enabled, hit-testable buttons in visited states. The report lists controls that
have no transition in that context, including unnamed buttons. That inventory
helps find omissions; custom gestures, hover-only controls, operating-system
surfaces, and pages not visited still require inspection. Disabled controls are
not randomly selected.

Known remaining areas include other conversation rows and native-session
selection, message actions/execution detail, member mentions and assistant
configuration, successful data-editing commands, file pickers, feature-specific
forms, and concurrent desktop-window arrangements. These are visible coverage
gaps, not silently accepted transitions. Add their expected user behavior to the
model and map their controls in the adapter; do not infer expected destinations
from controller state or make an unexpected result pass by changing the oracle.

No new CI gate, device matrix, backend tracing service, or test dependency is
introduced. [Verification scope](../../CONTRIBUTING.md#verification-scope) applies.

## Read the results

The last run writes the complete action sequence in JSON and a concise Markdown
summary by user action, plus failures and the slowest operations, under
`build/reports/ui-state-machine/` (`widget` or `profile`). It reports:

- Each flow's visited distinct transitions versus declared transitions, with
  completed, failed, and not-run flows distinguished.
- Starting state, user action, expected destination, pass/fail, sequence number,
  and coverage/random/replay phase.
- The seed and failing sequence, plus visible controls missing from that state.
- In profile mode, response time, frame count, longest UI/raster frame, frame
  submission rate when measurable, and frames exceeding the display interval.

Response time runs from gesture dispatch until the expected content has rendered.
It includes driver overhead; a drag also includes its gesture duration. It is not
a physical input-to-photon measurement. Engine frame timestamps associate batched
frame samples with the transition that produced them. One-frame actions have no
meaningful frame rate; absent samples are unavailable, never zero. Idle UI need
not render continuously. Widget tests use virtual time and make no performance
claim. Report local measurements without asserting results for untested devices.

## Implementation map

| Responsibility | File |
| --- | --- |
| Product states, actions, expected destinations | [UI-INTERACTIONS.json](UI-INTERACTIONS.json) |
| Model validation and edge walk; no Flutter/app imports | [model.dart](../../apps/desktop/test/ui_state_machine/model.dart) |
| Pointer/typing/scroll actions and rendered observations | [flutter_adapter.dart](../../apps/desktop/test/ui_state_machine/flutter_adapter.dart) |
| Production fixture, random selection, replay, per-transition frames | [runner.dart](../../apps/desktop/test/ui_state_machine/runner.dart) |
| Local command and readable report | [client-ui-state-machine.mjs](../../tools/scripts/client-ui-state-machine.mjs) |
| Functional entry | [Widget tests](../../apps/desktop/test/ui_state_machine/ui_state_machine_test.dart) |
| Real-engine entry | [Integration test](../../apps/desktop/integration_test/ui_state_machine_test.dart) |
