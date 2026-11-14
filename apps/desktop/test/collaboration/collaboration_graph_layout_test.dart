import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_graph_layout.dart';

import 'support/collaboration_fixture.dart';

Map<String, Size> _sizes(CollaborationGraphStructure structure) => {
  for (final node in structure.nodes)
    node.id: switch (node.kind) {
      CollaborationCardKind.task => const Size(216, 104),
      CollaborationCardKind.stack => Size(
        228,
        36 + 48.0 * node.memberIds.length,
      ),
      CollaborationCardKind.connector => const Size(76, 34),
      CollaborationCardKind.terminal => const Size(52, 52),
    },
};

CollaborationGraphLayout _layout(CollaborationGraph graph) {
  final structure = CollaborationGraphStructure.of(graph);
  return collaborationGraphLayout(structure, sizes: _sizes(structure));
}

void _expectNoCardCrossings(CollaborationGraphLayout layout) {
  final rects = [for (final card in layout.cards) card.rect];
  for (final route in layout.edges) {
    expect(
      collaborationRouteIntersectsCards(
        route.points,
        rects,
        source: layout.cardFor(route.from)!.rect,
        target: layout.cardFor(route.to)!.rect,
      ),
      isFalse,
      reason: '${route.key} crosses a card',
    );
  }
}

void _expectOrthogonal(CollaborationGraphLayout layout) {
  for (final route in layout.edges) {
    expect(route.points.length, greaterThanOrEqualTo(2), reason: route.key);
    for (var i = 0; i < route.points.length - 1; i++) {
      final a = route.points[i];
      final b = route.points[i + 1];
      final axisAligned =
          (a.dx - b.dx).abs() < 0.01 || (a.dy - b.dy).abs() < 0.01;
      expect(axisAligned, isTrue, reason: '${route.key} segment $i');
    }
  }
}

void main() {
  group('structure', () {
    test('sequential same-group actors merge into stack cards', () {
      final structure = CollaborationGraphStructure.of(collaborationGraphV1());
      final plan = structure.nodeFor('p1')!;
      expect(plan.kind, CollaborationCardKind.stack);
      expect(plan.memberIds, ['p1', 'p2', 'p3']);
      final ship = structure.nodeFor('s1')!;
      expect(ship.kind, CollaborationCardKind.stack);
      expect(ship.memberIds, ['s1', 's2', 's3']);
      expect(structure.displayIdOf('p3'), 'p1');
      expect(structure.nodeFor('p2'), isNull);
      expect(structure.nodeFor('idx')!.kind, CollaborationCardKind.task);
      expect(structure.nodeFor('fork')!.kind, CollaborationCardKind.connector);
      expect(structure.nodeFor('join')!.kind, CollaborationCardKind.connector);
      expect(structure.nodeFor('done')!.kind, CollaborationCardKind.terminal);
    });

    test('a callback-touched actor never joins a stack', () {
      final structure = CollaborationGraphStructure.of(collaborationGraphV1());
      expect(structure.nodeFor('idx')!.memberIds, ['idx']);
      expect(structure.nodeFor('arch')!.memberIds, ['arch']);
      final callback = structure.edges.singleWhere(
        (edge) => edge.kind == CollaborationRouteKind.callback,
      );
      expect(callback.from, 'arch');
      expect(callback.to, 'idx');
    });

    test('a flow edge closing a cycle routes as a back edge', () {
      final graph = CollaborationGraph(
        nodes: [
          collabNode('a', CollaborationNodeKind.actor, group: 'x'),
          collabNode('b', CollaborationNodeKind.script),
          collabNode('c', CollaborationNodeKind.actor, group: 'y'),
          collabNode('end', CollaborationNodeKind.terminal),
        ],
        edges: [
          collabEdge('a', 'b'),
          collabEdge('b', 'c'),
          collabEdge('c', 'a', event: CollaborationEdgeEvent.failure),
          collabEdge('c', 'end'),
        ],
        initialNodeId: 'a',
      );
      final structure = CollaborationGraphStructure.of(graph);
      final back = structure.edges.singleWhere(
        (edge) => edge.kind == CollaborationRouteKind.back,
      );
      expect(back.key, 'c>a>back');
      final layout = collaborationGraphLayout(
        structure,
        sizes: _sizes(structure),
      );
      final route = layout.edges.singleWhere((edge) => edge.key == back.key);
      final lowest = layout.cards
          .map((card) => card.rect.bottom)
          .reduce((a, b) => a > b ? a : b);
      expect(
        route.points.map((point) => point.dy).reduce((a, b) => a > b ? a : b),
        greaterThan(lowest),
      );
      _expectNoCardCrossings(layout);
    });
  });

  group('reference scenario', () {
    test('ranks follow the longest flow path', () {
      final layout = _layout(collaborationGraphV2());
      final ranks = {for (final card in layout.cards) card.id: card.rank};
      expect(ranks, {
        'p1': 0,
        'fork': 1,
        'idx': 2,
        'ui': 2,
        'bench': 2,
        'arch': 3,
        'join': 4,
        's1': 5,
        'done': 6,
      });
    });

    test('cards never overlap and same-column rows keep 28px apart', () {
      for (final graph in [collaborationGraphV1(), collaborationGraphV2()]) {
        final layout = _layout(graph);
        for (var i = 0; i < layout.cards.length; i++) {
          for (var j = i + 1; j < layout.cards.length; j++) {
            expect(
              layout.cards[i].rect.overlaps(layout.cards[j].rect),
              isFalse,
              reason: '${layout.cards[i].id} overlaps ${layout.cards[j].id}',
            );
          }
        }
        final byRank = <int, List<Rect>>{};
        for (final card in layout.cards) {
          byRank.putIfAbsent(card.rank, () => []).add(card.rect);
        }
        for (final entry in byRank.entries) {
          final rects = [...entry.value]
            ..sort((a, b) => a.top.compareTo(b.top));
          for (var i = 0; i < rects.length - 1; i++) {
            expect(
              rects[i + 1].top - rects[i].bottom,
              greaterThanOrEqualTo(CollaborationGraphMetrics.rowGap - 0.01),
              reason: 'rank ${entry.key} row gap',
            );
          }
        }
      }
    });

    test('routes are orthogonal and never cross a card', () {
      for (final graph in [collaborationGraphV1(), collaborationGraphV2()]) {
        final layout = _layout(graph);
        _expectOrthogonal(layout);
        _expectNoCardCrossings(layout);
      }
    });

    test('flow routes leave the right edge and enter the left edge', () {
      final layout = _layout(collaborationGraphV2());
      for (final route in layout.edges) {
        if (route.kind != CollaborationRouteKind.flow) continue;
        final source = layout.cardFor(route.from)!.rect;
        final target = layout.cardFor(route.to)!.rect;
        expect(route.points.first.dx, source.right, reason: route.key);
        expect(route.points.last.dx, target.left, reason: route.key);
        expect(
          route.points.first.dy,
          inInclusiveRange(source.top, source.bottom),
        );
        expect(
          route.points.last.dy,
          inInclusiveRange(target.top, target.bottom),
        );
      }
    });

    test('a single-successor chain reads as one straight line', () {
      final layout = _layout(collaborationGraphV2());
      final route = layout.edges.singleWhere(
        (edge) => edge.key == 'idx>arch>flow',
      );
      expect(route.points, hasLength(2));
    });

    test('the callback arc passes above every card it spans', () {
      final layout = _layout(collaborationGraphV2());
      final callback = layout.edges.singleWhere(
        (edge) => edge.kind == CollaborationRouteKind.callback,
      );
      final arch = layout.cardFor('arch')!;
      final idx = layout.cardFor('idx')!;
      final spanTop = layout.cards
          .where((card) => card.rank >= idx.rank && card.rank <= arch.rank)
          .map((card) => card.rect.top)
          .reduce((a, b) => a < b ? a : b);
      final highest = callback.points
          .map((point) => point.dy)
          .reduce((a, b) => a < b ? a : b);
      expect(highest, lessThan(spanTop));
      expect(
        highest,
        greaterThanOrEqualTo(
          CollaborationGraphMetrics.phaseTop +
              CollaborationGraphMetrics.phaseHeaderHeight,
        ),
      );
    });

    test('phases come from contiguous ranks sharing a group', () {
      final layout = _layout(collaborationGraphV2());
      expect(layout.phases.map((phase) => phase.group), [
        collabPlanGroup,
        collabBuildGroup,
        collabShipGroup,
      ]);
      final build = layout.phases[1];
      expect(build.ranks, [2, 3]);
      expect(build.cardIds.toSet(), {'idx', 'ui', 'bench', 'arch'});
      final cards = [for (final id in build.cardIds) layout.cardFor(id)!.rect];
      expect(
        build.rect.left,
        cards.map((r) => r.left).reduce((a, b) => a < b ? a : b),
      );
      expect(
        build.rect.right,
        cards.map((r) => r.right).reduce((a, b) => a > b ? a : b),
      );
      for (final phase in layout.phases) {
        final top = phase.cardIds
            .map((id) => layout.cardFor(id)!.rect.top)
            .reduce((a, b) => a < b ? a : b);
        expect(phase.rect.bottom, lessThan(top));
      }
    });

    test('the world encloses every card and route', () {
      final layout = _layout(collaborationGraphV2());
      final world = Offset.zero & layout.worldSize;
      for (final card in layout.cards) {
        expect(world.contains(card.rect.topLeft), isTrue);
        expect(world.contains(card.rect.bottomRight), isTrue);
      }
      for (final route in layout.edges) {
        for (final point in route.points) {
          expect(world.contains(point), isTrue, reason: route.key);
        }
      }
    });

    test('identical input produces identical geometry', () {
      final a = _layout(collaborationGraphV2());
      final b = _layout(collaborationGraphV2());
      expect(a.worldSize, b.worldSize);
      expect(
        [for (final card in a.cards) (card.id, card.rect)],
        [for (final card in b.cards) (card.id, card.rect)],
      );
      expect(
        [for (final edge in a.edges) '${edge.key} ${edge.points}'],
        [for (final edge in b.edges) '${edge.key} ${edge.points}'],
      );
    });
  });
}
