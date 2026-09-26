# UI interaction state machine

Updated: 2026-09-25

| Version | Entry |
| --- | --- |
| Normative | English (this document) |
| Localization | [简体中文](UI-INTERACTIONS.zh-CN.md) |

[UI interaction configuration](../../apps/desktop/test/ui_state_machine/model.json) is the behavior contract: what a
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
npm run client:test:ui -- --machine project-collaboration-wide --seed 42
npm run client:test:ui -- --profile --device macos --machine project-collaboration-wide
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
feature-pane opening from the features grid, dock-icon reselect, left-pane
collapse and expand, all settings index entries, and a populated dashboard
journey connecting group conversations, parent lists, native-conversation
selection, search input/results, creation-dialog cancellation,
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
forms, desktop dock folder management and pane-resize drags, and — for project
collaboration — a live native producer instead of the fixture owner, real
cross-repository work, and any action the native backend still refuses. These are
visible coverage gaps, not silently accepted transitions. Add their expected user behavior to the
model and map their controls in the adapter; do not infer expected destinations
from controller state or make an unexpected result pass by changing the oracle.

No new CI gate, device matrix, backend tracing service, or test dependency is
introduced. [Verification scope](../RUNBOOK.md) applies.

## Project collaboration

The `project-collaboration-wide` flow drives the native project collaboration
surface: the project rail with complete goal counts, the causal swimlanes, the
node detail with the three separate dimensions (command execution, work
acceptance, observation freshness), the reasons a unit cannot start and the
real consumers a blocker affects, the shared gate that keeps one identity, one
count and one run across every reference anchor it is drawn at, the compact list
and the advanced inspector over the same facts, filters and role selection,
zoom and reset, and one insertion that is previewed and then committed at
exactly the revision its preview described.

Two events in that flow belong to the native owner, not to the interface: the
withdrawal of authority (the surface goes local-unavailable and drops labels,
counts and anchors at once) and the reconnect (the application reads the same
source again in a new incarnation, and a replaced incarnation starts a fresh
interface state). The adapter drives both through the runtime so no UI control
pretends to have that power. Actions are answered only by the native receipt:
the flow shows the refusal reason of a takeover that conflicts with an old
writer and the accepted receipt of a pause, and never a state the owner has not
confirmed.

Profile mode seeds the frozen budget scale (8 projects, 1000 nodes, 2000 typed
edges, about 100 nodes in the visible window) and reports the engine's frames
and response times for the same user actions. Layout runs in a preparation
worker isolate; a status-only revision updates the affected entries and no
layout run, which the focused tests assert directly, including a negative
control where an undeclared change set is an honest full rebuild. Response
times include test-driver overhead and are not an input-to-photon measurement;
the frame record is the performance evidence, and the run record now carries the
per-frame build/raster samples plus a cold flag for the first measured
transition, so a slow frame can be located instead of guessed at. Results are
written to the ignored local report directory and make no repository-wide or
device-wide performance claim.

The project collaboration surface follows the interface language through a
host-supplied string bundle and never shows an internal reason code as its
message: a refused action, a withdrawn source and a blocker read as sentences,
and the plan revision is shown as a value. Visual review images of the real page
are written by
`apps/desktop/test/project_collaboration/project_collaboration_visual_evidence_test.dart`
when `LICO_PROJECT_COLLABORATION_EVIDENCE_DIR` is set; the interaction model and
its assertions remain the oracle.

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
| Product states, actions, expected destinations | [UI interaction configuration](../../apps/desktop/test/ui_state_machine/model.json) |
| Model validation and edge walk; no Flutter/app imports | [model.dart](../../apps/desktop/test/ui_state_machine/model.dart) |
| Pointer/typing/scroll actions and rendered observations | [flutter_adapter.dart](../../apps/desktop/test/ui_state_machine/flutter_adapter.dart) |
| Production fixture, random selection, replay, per-transition frames | [runner.dart](../../apps/desktop/test/ui_state_machine/runner.dart) |
| Project collaboration surface mount, revoke and reconnect for the flow | [project_collaboration_harness.dart](../../apps/desktop/test/ui_state_machine/project_collaboration_harness.dart) |
| Local command and readable report | [client-ui-state-machine.mjs](../../tools/scripts/client-ui-state-machine.mjs) |
| Functional entry | [Widget tests](../../apps/desktop/test/ui_state_machine/ui_state_machine_test.dart) |
| Real-engine entry | [Integration test](../../apps/desktop/integration_test/ui_state_machine_test.dart) |
