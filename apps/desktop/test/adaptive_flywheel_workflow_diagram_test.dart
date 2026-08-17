import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_workflow_diagram.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_workflow_layout.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  test('keeps the happy path on one row and drops blocked below it', () {
    final layout = AdaptiveFlywheelWorkflowLayout.build(
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
      greaterThan(schedule.dy + AdaptiveFlywheelWorkflowLayout.nodeHeight),
    );
  });

  test(
    'bundles duplicate from-to edges and fans failure away from success',
    () {
      final layout = AdaptiveFlywheelWorkflowLayout.build(
        states: _collaborationStates,
        edges: [
          ..._collaborationEdges,
          const AdaptiveFlywheelGraphEdge(
            from: 'authorize',
            to: 'schedule',
            event: 'success',
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
    final layout = AdaptiveFlywheelWorkflowLayout.build(
      states: _collaborationStates,
      edges: _collaborationEdges,
      initialState: 'authorize',
    );

    final back = layout.routes.singleWhere(
      (route) => route.from == 'again' && route.to == 'schedule',
    );
    final blockedBottom =
        layout.positions['blocked']!.dy +
        AdaptiveFlywheelWorkflowLayout.nodeHeight;
    expect(
      back.points.map((point) => point.dy).reduce((a, b) => a > b ? a : b),
      greaterThan(blockedBottom),
    );
  });

  test('keeps routed polylines unique', () {
    final layout = AdaptiveFlywheelWorkflowLayout.build(
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
    final layout = AdaptiveFlywheelWorkflowLayout.build(
      states: const [
        AdaptiveFlywheelGraphState(id: 'start', kind: 'actor', label: 'Start'),
        AdaptiveFlywheelGraphState(id: 'failed', kind: 'fail', label: 'Failed'),
        AdaptiveFlywheelGraphState(
          id: 'blocked',
          kind: 'blocked',
          label: 'Blocked',
        ),
      ],
      edges: const [
        AdaptiveFlywheelGraphEdge(
          from: 'start',
          to: 'failed',
          event: 'failure',
        ),
        AdaptiveFlywheelGraphEdge(
          from: 'start',
          to: 'blocked',
          event: 'blocked',
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
            AdaptiveFlywheelWorkflowLayout.nodeWidth +
            AdaptiveFlywheelWorkflowLayout.columnGap,
      ),
    );
  });

  test('reads a guard into the visible edge caption', () {
    final edge = AdaptiveFlywheelGraphEdge.fromJson({
      'from': 'route',
      'to': 'specialist',
      'event': 'success',
      'guard': {'path': 'context.route', 'equals': 'complex'},
    });
    expect(edge.guardLabel, 'route=complex');
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
            child: AdaptiveFlywheelWorkflowDiagram(
              inspection: AdaptiveFlywheelInspection(
                status: 'pending',
                currentStates: const [],
                neighborStates: const [],
                allowedOperations: const [],
                bindings: const {},
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
  AdaptiveFlywheelGraphState(
    id: 'authorize',
    kind: 'authorization',
    label: 'Authorize exact semantics',
  ),
  AdaptiveFlywheelGraphState(
    id: 'schedule',
    kind: 'actor',
    label: 'Schedule collaboration',
  ),
  AdaptiveFlywheelGraphState(
    id: 'design',
    kind: 'actor',
    label: 'Design the work',
  ),
  AdaptiveFlywheelGraphState(id: 'route', kind: 'choice', label: 'Route'),
  AdaptiveFlywheelGraphState(
    id: 'specialist',
    kind: 'actor',
    label: 'Specialist',
  ),
  AdaptiveFlywheelGraphState(id: 'tasks', kind: 'workset', label: 'Tasks'),
  AdaptiveFlywheelGraphState(id: 'review', kind: 'actor', label: 'Review'),
  AdaptiveFlywheelGraphState(id: 'again', kind: 'choice', label: 'Again'),
  AdaptiveFlywheelGraphState(
    id: 'complete',
    kind: 'succeed',
    label: 'Complete',
  ),
  AdaptiveFlywheelGraphState(id: 'blocked', kind: 'blocked', label: 'Blocked'),
];

const _collaborationEdges = [
  AdaptiveFlywheelGraphEdge(
    from: 'authorize',
    to: 'schedule',
    event: 'success',
  ),
  AdaptiveFlywheelGraphEdge(from: 'authorize', to: 'blocked', event: 'failure'),
  AdaptiveFlywheelGraphEdge(from: 'schedule', to: 'design', event: 'success'),
  AdaptiveFlywheelGraphEdge(from: 'schedule', to: 'blocked', event: 'failure'),
  AdaptiveFlywheelGraphEdge(from: 'design', to: 'route', event: 'success'),
  AdaptiveFlywheelGraphEdge(from: 'design', to: 'blocked', event: 'failure'),
  AdaptiveFlywheelGraphEdge(
    from: 'route',
    to: 'specialist',
    event: 'success',
    guardLabel: 'route=complex',
  ),
  AdaptiveFlywheelGraphEdge(from: 'route', to: 'tasks', event: 'success'),
  AdaptiveFlywheelGraphEdge(from: 'specialist', to: 'review', event: 'success'),
  AdaptiveFlywheelGraphEdge(
    from: 'specialist',
    to: 'blocked',
    event: 'failure',
  ),
  AdaptiveFlywheelGraphEdge(from: 'tasks', to: 'review', event: 'success'),
  AdaptiveFlywheelGraphEdge(from: 'tasks', to: 'blocked', event: 'failure'),
  AdaptiveFlywheelGraphEdge(from: 'review', to: 'again', event: 'success'),
  AdaptiveFlywheelGraphEdge(from: 'review', to: 'blocked', event: 'failure'),
  AdaptiveFlywheelGraphEdge(
    from: 'again',
    to: 'schedule',
    event: 'success',
    guardLabel: 'again=true',
  ),
  AdaptiveFlywheelGraphEdge(from: 'again', to: 'complete', event: 'success'),
];
