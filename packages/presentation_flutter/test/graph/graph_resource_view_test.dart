import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

/// One prepared fixture with three projects, a unique shared gate and real
/// blockers. It is built through the same merge the runtime uses, so the widget
/// is exercised against the real prepared shape.
GraphPreparedValue fixture({int revision = 4}) {
  final document = GraphResourceValue.fromJson(<String, Object?>{
    'schema': graphResourceV1Schema,
    'revision': revision,
    'projects': <Object?>[
      <String, Object?>{
        'id': 'licoup.project/alpha',
        'title': 'Alpha',
        'lanes': <Object?>[
          {'id': 'licoup.lane/build', 'title': 'Build', 'order': 0},
          {'id': 'licoup.lane/review', 'title': 'Review', 'order': 1},
        ],
        'nodes': <Object?>[
          {
            'id': 'licoup.node/alpha-build',
            'title': 'Build alpha',
            'laneId': 'licoup.lane/build',
            'gateId': 'licoup.gate/alpha-accept',
            'role': 'licoup.role/builder',
            'route': 'licoup.route/primary',
            'execution': 'running',
            'acceptance': 'reviewing',
            'observation': 'fresh',
            'ready': true,
            'startable': true,
            'blockers': <Object?>[],
            'actions': <Object?>[
              'licoup.action/unit-pause',
              'licoup.action/unit-cancel',
            ],
            'attempts': <Object?>[
              {
                'id': 'attempt-1',
                'role': 'licoup.role/builder',
                'state': 'running',
              },
            ],
            'visits': <Object?>[
              {'id': 'visit-1', 'kind': 'visit', 'at': 'run-4'},
            ],
            'events': <Object?>[
              {'kind': 'licoup.event/started', 'at': 'run-4'},
            ],
            'evidence': <Object?>[
              {'ref': 'evidence/alpha-build-1', 'kind': 'licoup.evidence/run'},
            ],
            'consumes': <Object?>[],
            'results': <Object?>[],
          },
          {
            'id': 'licoup.node/alpha-review',
            'title': 'Review alpha',
            'laneId': 'licoup.lane/review',
            'gateId': 'licoup.gate/alpha-accept',
            'role': 'licoup.role/reviewer',
            'execution': 'claimed',
            'acceptance': 'pending',
            'observation': 'stale',
            'ready': true,
            'startable': false,
            'blockers': <Object?>[
              {
                'code': 'conflicting_writer',
                'detail': 'an old writer still holds the unit',
                'affects': <Object?>['licoup.node/alpha-review'],
              },
              {
                'code': 'authority_missing',
                'detail': 'original authority was withdrawn',
              },
            ],
            'actions': <Object?>['licoup.action/unit-takeover'],
            'attempts': <Object?>[],
            'visits': <Object?>[],
            'events': <Object?>[],
            'evidence': <Object?>[],
            'consumes': <Object?>[
              {'nodeId': 'licoup.node/alpha-build', 'kind': 'candidate'},
            ],
            'results': <Object?>[],
          },
        ],
        'gates': <Object?>[
          {
            'id': 'licoup.gate/alpha-accept',
            'title': 'Alpha acceptance',
            'anchors': <Object?>[
              'licoup.node/alpha-build',
              'licoup.node/alpha-review',
            ],
            'runCount': 4,
          },
        ],
      },
      <String, Object?>{
        'id': 'licoup.project/beta',
        'title': 'Beta',
        'lanes': <Object?>[
          {'id': 'licoup.lane/beta-build', 'title': 'Build', 'order': 0},
        ],
        'nodes': <Object?>[
          {
            'id': 'licoup.node/beta-build',
            'title': 'Build beta',
            'laneId': 'licoup.lane/beta-build',
            'role': 'licoup.role/builder',
            'execution': 'not-started',
            'acceptance': 'pending',
            'observation': 'fresh',
            'ready': false,
            'startable': false,
            'blockers': <Object?>[
              {
                'code': 'dependency_missing',
                'detail': 'waiting for alpha acceptance',
                'affects': <Object?>['licoup.node/beta-build'],
              },
            ],
            'actions': <Object?>[],
            'attempts': <Object?>[],
            'visits': <Object?>[],
            'events': <Object?>[],
            'evidence': <Object?>[],
            'consumes': <Object?>[],
            'results': <Object?>[],
          },
        ],
        'gates': <Object?>[],
      },
      <String, Object?>{
        'id': 'licoup.project/gamma',
        'title': 'Gamma',
        'lanes': <Object?>[
          {'id': 'licoup.lane/gamma-build', 'title': 'Build', 'order': 0},
        ],
        'nodes': <Object?>[
          {
            'id': 'licoup.node/gamma-build',
            'title': 'Build gamma',
            'laneId': 'licoup.lane/gamma-build',
            'role': 'licoup.role/builder',
            'execution': 'succeeded',
            'acceptance': 'accepted',
            'observation': 'fresh',
            'ready': true,
            'startable': false,
            'blockers': <Object?>[],
            'actions': <Object?>[],
            'attempts': <Object?>[],
            'visits': <Object?>[],
            'events': <Object?>[],
            'evidence': <Object?>[],
            'consumes': <Object?>[],
            'results': <Object?>[],
          },
        ],
        'gates': <Object?>[],
      },
    ],
    'edges': <Object?>[
      {
        'id': 'licoup.edge/alpha-review-alpha-build',
        'from': 'licoup.node/alpha-build',
        'to': 'licoup.node/alpha-review',
        'kind': 'requires',
      },
      {
        'id': 'licoup.edge/beta-alpha',
        'from': 'licoup.node/alpha-build',
        'to': 'licoup.node/beta-build',
        'kind': 'requires',
      },
    ],
  });
  return mergeGraphPreparedValue(
    document: document,
    layout: GraphLayout(
      topologyRevision: document.planRevision,
      layerOf: const <String, int>{
        'licoup.node/alpha-build': 0,
        'licoup.node/alpha-review': 1,
        'licoup.node/beta-build': 0,
        'licoup.node/gamma-build': 0,
      },
      positionInLayer: const <String, int>{
        'licoup.node/alpha-build': 0,
        'licoup.node/alpha-review': 0,
        'licoup.node/beta-build': 0,
        'licoup.node/gamma-build': 0,
      },
      layerSizes: const <String, int>{
        'licoup.node/alpha-build': 1,
        'licoup.node/alpha-review': 1,
        'licoup.node/beta-build': 1,
        'licoup.node/gamma-build': 1,
      },
      visibleNodeIds: const <String>[
        'licoup.node/alpha-build',
        'licoup.node/alpha-review',
        'licoup.node/beta-build',
        'licoup.node/gamma-build',
      ],
      laneOrder: const <String>[
        'licoup.lane/build',
        'licoup.lane/review',
        'licoup.lane/beta-build',
        'licoup.lane/gamma-build',
      ],
      visibleLimit: graphResourceDefaultVisibleNodes,
    ),
    previous: null,
    changedNodeIds: null,
    layoutComputed: true,
  );
}

Future<void> pumpView(
  WidgetTester tester, {
  required GraphPreparedValue value,
  List<GraphActionRequest>? actions,
  Set<String> pending = const <String>{},
  GraphViewState state = const GraphViewState(),
  Size size = const Size(1400, 900),
  ValueChanged<GraphViewState>? onStateChanged,
  Key? key,
}) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GraphResourceView(
          key: key,
          value: value,
          initialState: state,
          pendingActions: pending,
          onAction: actions == null ? null : actions.add,
          onStateChanged: onStateChanged,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'wide canvas shows project cards and an on-demand project control',
    (tester) async {
      await pumpView(tester, value: fixture());
      expect(
        find.byKey(const Key('project-collaboration-open-projects')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key(
            'project-collaboration-canvas-summary-licoup.project/alpha',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('project-collaboration-node-licoup.node/alpha-build'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('project-collaboration-gap-licoup.node/alpha-review'),
        ),
        findsOneWidget,
      );
      // Three status dimensions on the card.
      expect(
        find.byKey(
          const Key('project-collaboration-execution-licoup.node/alpha-build'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('project-collaboration-acceptance-licoup.node/alpha-build'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key(
            'project-collaboration-observation-licoup.node/alpha-build',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('one shared gate keeps one run count across its anchors', (
    tester,
  ) async {
    await pumpView(tester, value: fixture());
    final representative = find.byKey(
      const Key('project-collaboration-gate-badge-licoup.node/alpha-build'),
    );
    final anchor = find.byKey(
      const Key('project-collaboration-gate-badge-licoup.node/alpha-review'),
    );
    expect(representative, findsOneWidget);
    expect(tester.widget<Text>(representative).data, contains('4 runs'));
    expect(anchor, findsOneWidget);
    expect(
      tester.widget<Text>(anchor).data,
      contains('one run'),
      reason: 'a second anchor never adds a second count',
    );
  });

  testWidgets('selecting any anchor speaks about the gate, not the anchor', (
    tester,
  ) async {
    await pumpView(tester, value: fixture());
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-review'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key('project-collaboration-detail-licoup.node/alpha-review'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('project-collaboration-gate-count')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('project-collaboration-gate-count')),
          )
          .data,
      contains('4 runs'),
    );
    expect(
      find.byKey(const Key('project-collaboration-blocker-conflicting_writer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('project-collaboration-blocker-authority_missing')),
      findsOneWidget,
    );
  });

  testWidgets('why it cannot start names the native reason and highlights only '
      'real consumers', (tester) async {
    final states = <GraphViewState>[];
    await pumpView(tester, value: fixture(), onStateChanged: states.add);
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-review'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-highlight-conflicting_writer'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      states.last.highlightedNodeIds,
      <String>{'licoup.node/alpha-review'},
      reason: 'only the nodes the blocker really names are highlighted',
    );
    // The real consumer of alpha-build is alpha-review, derived from the typed
    // edges and declared inputs rather than from a guess.
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-build'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(
        const Key('project-collaboration-detail-licoup.node/alpha-build'),
      ),
      const Offset(0, -320),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key('project-collaboration-consumer-licoup.node/alpha-review'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('filters and collapse change the drawing, never the counts', (
    tester,
  ) async {
    final value = fixture();
    await pumpView(tester, value: value);
    await tester.tap(
      find.byKey(const Key('project-collaboration-open-projects')),
    );
    await tester.pumpAndSettle();
    final before = tester
        .widget<Text>(
          find.byKey(
            const Key('project-collaboration-summary-licoup.project/alpha'),
          ),
        )
        .data;
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-project-licoup.project/alpha'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-board-licoup.project/alpha')),
      findsNothing,
      reason: 'a collapsed project is not drawn',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const Key('project-collaboration-summary-licoup.project/alpha'),
            ),
          )
          .data,
      before,
      reason: 'complete goal counts survive collapse',
    );

    await tester.tap(
      find.byKey(const Key('project-collaboration-role-licoup.role/reviewer')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-board-licoup.project/beta')),
      findsOneWidget,
    );
  });

  testWidgets('frontier and anomaly filters select nodes without dispatching', (
    tester,
  ) async {
    final actions = <GraphActionRequest>[];
    await pumpView(tester, value: fixture(), actions: actions);
    await tester.tap(find.text('Frontier'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-build'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/beta-build'),
      ),
      findsNothing,
      reason: 'beta is not dependency-ready',
    );
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/gamma-build'),
      ),
      findsOneWidget,
      reason: 'gamma is ready even though it cannot start again',
    );
    await tester.tap(find.text('Needs attention'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-review'),
      ),
      findsOneWidget,
      reason: 'a stale observation with a conflicting writer is an anomaly',
    );
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-build'),
      ),
      findsNothing,
      reason: 'a healthy running unit is not an anomaly',
    );
    expect(actions, isEmpty, reason: 'filtering is interface state only');
  });

  testWidgets('keyboard traversal selects, opens and clears without dispatch', (
    tester,
  ) async {
    final actions = <GraphActionRequest>[];
    await pumpView(tester, value: fixture(), actions: actions);
    await tester.tap(find.byKey(const Key('project-collaboration-graph')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-detail-close')),
      findsOneWidget,
      reason: 'arrow traversal selects a unit and opens its detail',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(actions, isEmpty, reason: 'keyboard traversal never dispatches');
  });

  testWidgets('zoom controls are accessible and reset restores the view', (
    tester,
  ) async {
    await pumpView(tester, value: fixture());
    await tester.tap(find.byKey(const Key('project-collaboration-zoom-in')));
    await tester.pumpAndSettle();
    expect(find.text('120%'), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-collaboration-zoom-reset')));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('lane drag reorders locally and never dispatches', (
    tester,
  ) async {
    final actions = <GraphActionRequest>[];
    final states = <GraphViewState>[];
    await pumpView(
      tester,
      value: fixture(),
      actions: actions,
      onStateChanged: states.add,
    );
    final laneHeader = find.byKey(
      const Key('project-collaboration-lane-header-licoup.lane/review'),
    );
    final dropTarget = find.byKey(
      const Key('project-collaboration-lane-licoup.lane/build'),
    );
    final gesture = await tester.startGesture(tester.getCenter(laneHeader));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(dropTarget));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(actions, isEmpty, reason: 'layout changes do not dispatch');
    expect(
      states.any((state) => state.laneOrder.isNotEmpty),
      isTrue,
      reason: 'the local lane order changed',
    );
  });

  testWidgets('the compact list and the board share one fact set', (
    tester,
  ) async {
    await pumpView(tester, value: fixture());
    await tester.tap(
      find.byKey(const Key('project-collaboration-list-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-collaboration-list')), findsOneWidget);
    expect(
      find.byKey(
        const Key('project-collaboration-list-row-licoup.node/alpha-review'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-list-row-licoup.node/alpha-review'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key('project-collaboration-detail-licoup.node/alpha-review'),
      ),
      findsOneWidget,
      reason: 'list selection opens the same detail',
    );
  });

  testWidgets('the advanced inspector shows attempts, visits, events and '
      'evidence', (tester) async {
    await pumpView(
      tester,
      value: fixture(),
      state: const GraphViewState(
        selectedNodeId: 'licoup.node/alpha-build',
        showInspector: true,
        showDetailPanel: true,
      ),
    );
    expect(
      find.byKey(const Key('project-collaboration-attempt-attempt-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('project-collaboration-visit-visit-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('project-collaboration-event-licoup.event/started-run-4'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('project-collaboration-evidence-evidence/alpha-build-1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an action dispatches only after its confirmation and stays '
      'waiting for the receipt', (tester) async {
    final actions = <GraphActionRequest>[];
    await pumpView(
      tester,
      value: fixture(),
      actions: actions,
      state: const GraphViewState(
        selectedNodeId: 'licoup.node/alpha-review',
        showDetailPanel: true,
      ),
    );
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-action-licoup.action/unit-takeover'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-takeover-confirm')),
      findsOneWidget,
    );
    expect(
      actions,
      isEmpty,
      reason: 'nothing is dispatched before confirmation',
    );
    await tester.tap(
      find.byKey(const Key('project-collaboration-takeover-cancel')),
    );
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-action-licoup.action/unit-takeover'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('project-collaboration-takeover-confirm-button')),
    );
    await tester.pumpAndSettle();
    expect(actions.single.actionRef, 'licoup.action/unit-takeover');
    expect(actions.single.nodeId, 'licoup.node/alpha-review');
  });

  testWidgets(
    'a pending action is visibly waiting, not optimistically applied',
    (tester) async {
      await pumpView(
        tester,
        value: fixture(),
        pending: <String>{
          const GraphActionRequest(
            actionRef: 'licoup.action/unit-pause',
            nodeId: 'licoup.node/alpha-build',
          ).key,
        },
        state: const GraphViewState(
          selectedNodeId: 'licoup.node/alpha-build',
          showDetailPanel: true,
        ),
      );
      expect(find.textContaining('Waiting for owner'), findsOneWidget);
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.textContaining('Waiting for owner'),
          matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton,
          ),
        ),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'no second dispatch while waiting',
      );
    },
  );

  testWidgets('narrow layout calls out the project and detail panels', (
    tester,
  ) async {
    await pumpView(tester, value: fixture(), size: const Size(430, 900));
    expect(
      find.byKey(const Key('project-collaboration-graph')),
      findsOneWidget,
      reason: 'the pannable board stays',
    );
    await tester.tap(
      find.byKey(const Key('project-collaboration-open-projects')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-projects-panel')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('project-collaboration-close-projects')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-projects-panel')),
      findsNothing,
    );
  });

  testWidgets('a withdrawn authority leaves its own unavailable state', (
    tester,
  ) async {
    await pumpView(tester, value: fixture(), state: const GraphViewState());
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GraphResourceView(value: null, unavailableReason: 'revoked'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('node semantics carry the reason, not only a colour', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpView(tester, value: fixture());
    expect(
      find.bySemanticsLabel(RegExp('Cannot start: another writer')),
      findsOneWidget,
    );
    handle.dispose();
  });
  testWidgets('selecting a unit repaints the cards, not the board rows', (
    tester,
  ) async {
    await pumpView(tester, value: fixture());
    final laneKey = const Key('project-collaboration-lane-licoup.lane/build');
    final rowBefore = tester.widget(find.byKey(laneKey));
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-build'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      identical(tester.widget(find.byKey(laneKey)), rowBefore),
      isTrue,
      reason: 'a selection must not rebuild the board rows',
    );
    expect(
      find.byKey(
        const Key('project-collaboration-detail-licoup.node/alpha-build'),
      ),
      findsOneWidget,
      reason: 'the selection still reaches the detail panel',
    );
  });

  testWidgets('the wide-scale board builds only the rows and cards in view', (
    tester,
  ) async {
    final value = wideFixture();
    expect(value.document.nodeCount, 1000);
    // 13 windowed units per project across 8 projects.
    expect(value.layout.visibleNodeIds.length, 104);
    await pumpView(tester, value: value);
    final builtCards = find.byType(NodeCard).evaluate().length;
    expect(builtCards, greaterThan(0), reason: 'the visible rows are built');
    expect(
      builtCards,
      lessThan(40),
      reason:
          'a 100-unit window must not build every card: '
          'built $builtCards of ${value.layout.visibleNodeIds.length}',
    );
    // Virtualization limits the drawing, never the totals.
    expect(
      find.byKey(
        const Key('project-collaboration-canvas-summary-licoup.project/p0'),
      ),
      findsOneWidget,
    );
  });
}

/// One wide-scale prepared fixture: 8 projects, 125 units each, two lanes, a
/// 100-unit visible window. Built through the same merge the runtime uses.
GraphPreparedValue wideFixture() {
  final projects = <Object?>[];
  final layerOf = <String, int>{};
  final positionOf = <String, int>{};
  final visible = <String>[];
  final laneOrder = <String>[];
  for (var project = 0; project < 8; project++) {
    final lanes = <Object?>[
      {'id': 'licoup.lane/p$project-build', 'title': 'Build', 'order': 0},
      {'id': 'licoup.lane/p$project-review', 'title': 'Review', 'order': 1},
    ];
    final nodes = <Object?>[];
    for (var index = 0; index < 125; index++) {
      final lane = 'licoup.lane/p$project-${index.isEven ? 'build' : 'review'}';
      final id = 'licoup.node/p$project-$index';
      nodes.add({
        'id': id,
        'title': 'Unit $index',
        'laneId': lane,
        'role': 'licoup.role/builder',
        'execution': 'running',
        'acceptance': 'pending',
        'observation': 'fresh',
        'ready': true,
        'startable': true,
      });
      if (index < 13) {
        visible.add(id);
        layerOf[id] = index;
        positionOf[id] = 0;
      }
    }
    laneOrder.addAll(<String>[
      'licoup.lane/p$project-build',
      'licoup.lane/p$project-review',
    ]);
    projects.add({
      'id': 'licoup.project/p$project',
      'title': 'Project $project',
      'lanes': lanes,
      'nodes': nodes,
      'gates': <Object?>[],
    });
  }
  final document = GraphResourceValue.fromJson(<String, Object?>{
    'schema': graphResourceV1Schema,
    'revision': 1,
    'projects': projects,
    'edges': <Object?>[],
  });
  return mergeGraphPreparedValue(
    document: document,
    layout: GraphLayout(
      topologyRevision: 1,
      layerOf: layerOf,
      positionInLayer: positionOf,
      layerSizes: <String, int>{for (final id in visible) id: 1},
      visibleNodeIds: visible,
      laneOrder: laneOrder,
      visibleLimit: 100,
    ),
    previous: null,
    changedNodeIds: null,
    layoutComputed: true,
  );
}
