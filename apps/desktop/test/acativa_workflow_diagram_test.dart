import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/acativa_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/acativa_workflow_diagram.dart';
import 'package:licoup/src/frontend/features/agents/ui/acativa_workflow_layout.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/acativa_projection.dart';

void main() {
  test('keeps the happy path on one row and drops blocked below it', () {
    final layout = AcativaWorkflowLayout.build(
      states: _collaborationStates,
      edges: _collaborationEdges,
      initialState: 'authorize',
    );

    final authorize = layout.positions['authorize']!;
    final schedule = layout.positions['schedule']!;
    final design = layout.positions['design']!;
    final blocked = layout.positions['blocked']!;
    final complete = layout.positions['complete']!;

    expect(schedule.dx, greaterThan(authorize.dx + 80));
    expect(design.dx, greaterThan(schedule.dx + 80));
    expect(complete.dx, greaterThan(design.dx));
    expect(schedule.dy, closeTo(authorize.dy, 1));
    expect(
      blocked.dy,
      greaterThan(schedule.dy + AcativaWorkflowLayout.nodeHeight),
    );
  });

  test(
    'bundles duplicate from-to edges and fans failure away from success',
    () {
      final layout = AcativaWorkflowLayout.build(
        states: _collaborationStates,
        edges: [
          ..._collaborationEdges,
          const AcativaGraphEdgeProjection(
            from: 'authorize',
            to: 'schedule',
            event: 'success',
            guardLabel: '',
          ),
        ],
        initialState: 'authorize',
      );

      final success = layout.routes.where(
        (route) => route.from == 'authorize' && route.to == 'schedule',
      );
      final failure = layout.routes.where(
        (route) => route.from == 'authorize' && route.to == 'blocked',
      );
      expect(success, hasLength(1));
      expect(failure, hasLength(1));
      expect(
        failure.single.points.first.dy,
        greaterThan(success.single.points.first.dy),
      );
    },
  );

  test('routes loops under the graph instead of through the happy path', () {
    final layout = AcativaWorkflowLayout.build(
      states: _collaborationStates,
      edges: _collaborationEdges,
      initialState: 'authorize',
    );

    final back = layout.routes.singleWhere(
      (route) => route.from == 'again' && route.to == 'schedule',
    );
    final blockedBottom =
        layout.positions['blocked']!.dy + AcativaWorkflowLayout.nodeHeight;
    expect(
      back.points.map((point) => point.dy).reduce((a, b) => a > b ? a : b),
      greaterThan(blockedBottom),
    );
  });

  test('keeps routed polylines unique', () {
    final layout = AcativaWorkflowLayout.build(
      states: _collaborationStates,
      edges: _collaborationEdges,
      initialState: 'authorize',
    );
    final signatures = {
      for (final route in layout.routes)
        route.points
            .map(
              (point) =>
                  '${point.dx.toStringAsFixed(1)},${point.dy.toStringAsFixed(1)}',
            )
            .join('|'),
    };
    expect(signatures.length, layout.routes.length);
  });

  test('keeps sibling exception nodes from overlapping', () {
    final layout = AcativaWorkflowLayout.build(
      states: const [
        AcativaGraphStateProjection(id: 'start', kind: 'actor', label: 'Start'),
        AcativaGraphStateProjection(
          id: 'failed',
          kind: 'fail',
          label: 'Failed',
        ),
        AcativaGraphStateProjection(
          id: 'blocked',
          kind: 'blocked',
          label: 'Blocked',
        ),
      ],
      edges: const [
        AcativaGraphEdgeProjection(
          from: 'start',
          to: 'failed',
          event: 'failure',
          guardLabel: '',
        ),
        AcativaGraphEdgeProjection(
          from: 'start',
          to: 'blocked',
          event: 'blocked',
          guardLabel: '',
        ),
      ],
      initialState: 'start',
    );
    final first = layout.positions['failed']!;
    final second = layout.positions['blocked']!;
    expect(
      second.dx,
      greaterThanOrEqualTo(
        first.dx +
            AcativaWorkflowLayout.nodeWidth +
            AcativaWorkflowLayout.columnGap,
      ),
    );
  });

  test('reads a guard into the visible edge caption', () {
    final edge = AcativaGraphEdge.fromJson({
      'from': 'route',
      'to': 'specialist',
      'event': 'success',
      'guard': {'path': 'context.route', 'equals': 'complex'},
    });
    expect(edge.guardLabel, 'route=complex');
    expect(edge.mode, 'flow');
    expect(edge.callback, isFalse);
  });

  test('declares callback and flow modes on the routed caption', () {
    final callback = AcativaGraphEdge.fromJson({
      'from': 'review',
      'to': 'done',
      'event': 'success',
      'mode': 'callback',
    });
    expect(callback.mode, 'callback');
    expect(callback.callback, isTrue);

    final layout = AcativaWorkflowLayout.build(
      states: const [
        AcativaGraphStateProjection(
          id: 'review',
          kind: 'actor',
          label: 'Review',
        ),
        AcativaGraphStateProjection(id: 'done', kind: 'succeed', label: 'Done'),
        AcativaGraphStateProjection(
          id: 'failed',
          kind: 'fail',
          label: 'Failed',
        ),
      ],
      edges: [
        AcativaGraphEdgeProjection(
          from: 'review',
          to: 'done',
          event: 'success',
          mode: 'callback',
          guardLabel: '',
        ),
        const AcativaGraphEdgeProjection(
          from: 'review',
          to: 'failed',
          event: 'failure',
          guardLabel: '',
        ),
      ],
      initialState: 'review',
    );
    final callbackRoute = layout.routes.singleWhere(
      (route) => route.from == 'review' && route.to == 'done',
    );
    final flowRoute = layout.routes.singleWhere(
      (route) => route.from == 'review' && route.to == 'failed',
    );
    expect(callbackRoute.callback, isTrue);
    expect(callbackRoute.label, 'callback · success');
    expect(flowRoute.callback, isFalse);
    expect(flowRoute.label, 'flow · failure');
  });

  testWidgets('renders blocked below the happy-path nodes', (tester) async {
    tester.view.physicalSize = const Size(1100, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: 420,
            child: AcativaWorkflowDiagram(
              inspection: AcativaInspectionProjection(
                status: 'pending',
                currentStates: const [],
                neighborStates: const [],
                allowedOperations: const [],
                assignments: const [],
                slots: const [],
                states: _collaborationStates,
                edges: _collaborationEdges,
                initialState: 'authorize',
                diagnosticCode: '',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final schedule = tester.getRect(
      find.byKey(const ValueKey('workflow-node-schedule')),
    );
    final blocked = tester.getRect(
      find.byKey(const ValueKey('workflow-node-blocked')),
    );
    expect(blocked.top, greaterThan(schedule.bottom));
  });
}

const _collaborationStates = [
  AcativaGraphStateProjection(
    id: 'authorize',
    kind: 'authorization',
    label: 'Authorize exact semantics',
  ),
  AcativaGraphStateProjection(
    id: 'schedule',
    kind: 'actor',
    label: 'Schedule collaboration',
  ),
  AcativaGraphStateProjection(
    id: 'design',
    kind: 'actor',
    label: 'Design the work',
  ),
  AcativaGraphStateProjection(id: 'route', kind: 'choice', label: 'Route'),
  AcativaGraphStateProjection(
    id: 'specialist',
    kind: 'actor',
    label: 'Specialist',
  ),
  AcativaGraphStateProjection(id: 'tasks', kind: 'workset', label: 'Tasks'),
  AcativaGraphStateProjection(id: 'review', kind: 'actor', label: 'Review'),
  AcativaGraphStateProjection(id: 'again', kind: 'choice', label: 'Again'),
  AcativaGraphStateProjection(
    id: 'complete',
    kind: 'succeed',
    label: 'Complete',
  ),
  AcativaGraphStateProjection(id: 'blocked', kind: 'blocked', label: 'Blocked'),
];

const _collaborationEdges = [
  AcativaGraphEdgeProjection(
    from: 'authorize',
    to: 'schedule',
    event: 'success',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'authorize',
    to: 'blocked',
    event: 'failure',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'schedule',
    to: 'design',
    event: 'success',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'schedule',
    to: 'blocked',
    event: 'failure',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'design',
    to: 'route',
    event: 'success',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'design',
    to: 'blocked',
    event: 'failure',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'route',
    to: 'specialist',
    event: 'success',
    guardLabel: 'route=complex',
  ),
  AcativaGraphEdgeProjection(
    from: 'route',
    to: 'tasks',
    event: 'success',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'specialist',
    to: 'review',
    event: 'success',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'specialist',
    to: 'blocked',
    event: 'failure',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'tasks',
    to: 'review',
    event: 'success',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'tasks',
    to: 'blocked',
    event: 'failure',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'review',
    to: 'again',
    event: 'success',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'review',
    to: 'blocked',
    event: 'failure',
    guardLabel: '',
  ),
  AcativaGraphEdgeProjection(
    from: 'again',
    to: 'schedule',
    event: 'success',
    guardLabel: 'again=true',
  ),
  AcativaGraphEdgeProjection(
    from: 'again',
    to: 'complete',
    event: 'success',
    guardLabel: '',
  ),
];
