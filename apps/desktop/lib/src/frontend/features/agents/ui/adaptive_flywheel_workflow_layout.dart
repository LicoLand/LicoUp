import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';

/// Layered positions and non-overlapping routes for a strategy Graph.
final class AdaptiveFlywheelWorkflowLayout {
  const AdaptiveFlywheelWorkflowLayout({
    required this.positions,
    required this.size,
    required this.routes,
  });

  static const double nodeWidth = 184;
  static const double nodeHeight = 78;
  static const double columnGap = 108;
  static const double rowGap = 52;
  static const double margin = 48;
  static const double exceptionGap = 76;
  static const double backLaneGap = 22;
  static const double portInset = 16;

  final Map<String, Offset> positions;
  final Size size;
  final List<AdaptiveFlywheelWorkflowRoute> routes;

  static AdaptiveFlywheelWorkflowLayout build({
    required List<AdaptiveFlywheelGraphState> states,
    required List<AdaptiveFlywheelGraphEdge> edges,
    required String initialState,
  }) {
    if (states.isEmpty) {
      return const AdaptiveFlywheelWorkflowLayout(
        positions: {},
        size: Size(480, 240),
        routes: [],
      );
    }

    final ids = {for (final state in states) state.id};
    final exceptionIds = {
      for (final state in states)
        if (_isExceptionKind(state.kind)) state.id,
    };
    final mainIds = ids.difference(exceptionIds);
    final outgoing = <String, List<String>>{
      for (final id in ids) id: <String>[],
    };
    for (final edge in edges) {
      if (ids.contains(edge.from) && ids.contains(edge.to)) {
        outgoing[edge.from]!.add(edge.to);
      }
    }

    final root = ids.contains(initialState)
        ? initialState
        : (mainIds.isNotEmpty ? mainIds.first : states.first.id);
    final backKeys = _backEdges(
      root: root,
      mainIds: mainIds,
      outgoing: outgoing,
    );
    final ranks = _longestPathRanks(
      root: mainIds.contains(root)
          ? root
          : (mainIds.isEmpty ? root : mainIds.first),
      mainIds: mainIds,
      outgoing: outgoing,
      backKeys: backKeys,
      states: states,
    );

    final columns = SplayTreeMap<int, List<String>>();
    for (final id in mainIds) {
      columns.putIfAbsent(ranks[id]!, () => []).add(id);
    }
    _orderColumns(columns, outgoing, ranks, states);

    final maxRows = columns.values.fold<int>(
      1,
      (value, column) => math.max(value, column.length),
    );
    final mainBandHeight = maxRows * nodeHeight + (maxRows - 1) * rowGap;
    final positions = <String, Offset>{};
    var columnIndex = 0;
    for (final column in columns.values) {
      final columnHeight =
          column.length * nodeHeight + (column.length - 1) * rowGap;
      final top = margin + (mainBandHeight - columnHeight) / 2;
      for (var row = 0; row < column.length; row++) {
        positions[column[row]] = Offset(
          margin + columnIndex * (nodeWidth + columnGap),
          top + row * (nodeHeight + rowGap),
        );
      }
      columnIndex++;
    }

    final mainWidth =
        margin * 2 +
        math.max(1, columns.length) * nodeWidth +
        math.max(0, columns.length - 1) * columnGap;
    final exceptionList = [
      for (final state in states)
        if (exceptionIds.contains(state.id)) state.id,
    ];
    if (exceptionList.isNotEmpty) {
      final exceptionTop = margin + mainBandHeight + exceptionGap;
      final incomingX = <String, List<double>>{
        for (final id in exceptionList) id: <double>[],
      };
      for (final edge in edges) {
        if (!exceptionIds.contains(edge.to)) continue;
        final from = positions[edge.from];
        if (from == null) continue;
        incomingX[edge.to]!.add(from.dx + nodeWidth / 2);
      }
      final totalExceptionWidth =
          exceptionList.length * nodeWidth +
          (exceptionList.length - 1) * columnGap;
      var cursor = math.max(margin, (mainWidth - totalExceptionWidth) / 2);
      for (final id in exceptionList) {
        final xs = incomingX[id]!;
        final preferred = xs.isEmpty
            ? cursor
            : xs.reduce((a, b) => a + b) / xs.length - nodeWidth / 2;
        final clampedPreferred = preferred
            .clamp(margin, math.max(margin, mainWidth - margin - nodeWidth))
            .toDouble();
        final left = math.max(cursor, clampedPreferred);
        positions[id] = Offset(left, exceptionTop);
        cursor = left + nodeWidth + columnGap;
      }
    }

    final bundles = _bundleEdges(edges, ids);
    final routes = _routeEdges(
      bundles: bundles,
      positions: positions,
      exceptionIds: exceptionIds,
      mainBandBottom: margin + mainBandHeight,
    );
    _nudgeLabels(routes);

    final maxX = positions.values.fold<double>(
      mainWidth,
      (value, offset) => math.max(value, offset.dx + nodeWidth),
    );
    final maxY = [
      margin + mainBandHeight,
      ...positions.values.map((offset) => offset.dy + nodeHeight),
      ...routes.expand((route) => route.points).map((point) => point.dy),
    ].fold<double>(0, math.max);

    return AdaptiveFlywheelWorkflowLayout(
      positions: Map.unmodifiable(positions),
      size: Size(maxX + margin, maxY + margin),
      routes: List.unmodifiable(routes),
    );
  }
}

final class AdaptiveFlywheelWorkflowRoute {
  AdaptiveFlywheelWorkflowRoute({
    required this.from,
    required this.to,
    required this.label,
    required this.points,
    required this.labelAnchor,
  });

  final String from;
  final String to;
  final String label;
  final List<Offset> points;
  Offset labelAnchor;
}

bool _isExceptionKind(String kind) => kind == 'blocked' || kind == 'fail';

Set<(String, String)> _backEdges({
  required String root,
  required Set<String> mainIds,
  required Map<String, List<String>> outgoing,
}) {
  final back = <(String, String)>{};
  final visited = <String>{};
  final visiting = <String>{};

  void walk(String current) {
    visiting.add(current);
    visited.add(current);
    for (final next in outgoing[current] ?? const <String>[]) {
      if (!mainIds.contains(next) || next == current) continue;
      if (visiting.contains(next)) {
        back.add((current, next));
      } else if (!visited.contains(next)) {
        walk(next);
      }
    }
    visiting.remove(current);
  }

  if (mainIds.contains(root)) {
    walk(root);
  }
  for (final id in mainIds) {
    if (!visited.contains(id)) {
      walk(id);
    }
  }
  return back;
}

Map<String, int> _longestPathRanks({
  required String root,
  required Set<String> mainIds,
  required Map<String, List<String>> outgoing,
  required Set<(String, String)> backKeys,
  required List<AdaptiveFlywheelGraphState> states,
}) {
  final ranks = <String, int>{};
  if (mainIds.isEmpty) {
    return ranks;
  }
  ranks[root] = 0;
  final indegree = {for (final id in mainIds) id: 0};
  final forward = <String, List<String>>{
    for (final id in mainIds) id: <String>[],
  };
  for (final from in mainIds) {
    for (final to in outgoing[from] ?? const <String>[]) {
      if (!mainIds.contains(to) ||
          to == from ||
          backKeys.contains((from, to))) {
        continue;
      }
      forward[from]!.add(to);
      indegree[to] = (indegree[to] ?? 0) + 1;
    }
  }
  final queue = Queue<String>();
  for (final id in mainIds) {
    if ((indegree[id] ?? 0) == 0) {
      queue.add(id);
    }
  }
  if (!queue.contains(root)) {
    queue.addFirst(root);
  }
  final seen = <String>{};
  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    if (!seen.add(current)) continue;
    final nextRank = (ranks[current] ?? 0) + 1;
    for (final next in forward[current]!) {
      ranks[next] = math.max(ranks[next] ?? 0, nextRank);
      indegree[next] = (indegree[next] ?? 1) - 1;
      if ((indegree[next] ?? 0) <= 0) {
        queue.add(next);
      }
    }
  }
  var fallback = ranks.values.fold(0, math.max) + 1;
  for (final state in states) {
    if (!mainIds.contains(state.id)) continue;
    ranks.putIfAbsent(state.id, () => fallback++);
  }
  return ranks;
}

void _orderColumns(
  SplayTreeMap<int, List<String>> columns,
  Map<String, List<String>> outgoing,
  Map<String, int> ranks,
  List<AdaptiveFlywheelGraphState> states,
) {
  final order = {for (var i = 0; i < states.length; i++) states[i].id: i};
  final predecessors = <String, List<String>>{
    for (final id in ranks.keys) id: <String>[],
  };
  for (final from in outgoing.keys) {
    for (final to in outgoing[from]!) {
      if (predecessors.containsKey(to) && ranks.containsKey(from)) {
        predecessors[to]!.add(from);
      }
    }
  }
  final bary = {for (final id in ranks.keys) id: (order[id] ?? 0).toDouble()};
  for (final column in columns.values) {
    column.sort((a, b) {
      final parents = predecessors[a]!;
      if (parents.isNotEmpty) {
        bary[a] =
            parents.map((id) => bary[id] ?? 0).reduce((x, y) => x + y) /
            parents.length;
      }
      final otherParents = predecessors[b]!;
      if (otherParents.isNotEmpty) {
        bary[b] =
            otherParents.map((id) => bary[id] ?? 0).reduce((x, y) => x + y) /
            otherParents.length;
      }
      final compared = bary[a]!.compareTo(bary[b]!);
      if (compared != 0) return compared;
      return (order[a] ?? 0).compareTo(order[b] ?? 0);
    });
    for (var i = 0; i < column.length; i++) {
      bary[column[i]] = i.toDouble();
    }
  }
}

List<_BundledEdge> _bundleEdges(
  List<AdaptiveFlywheelGraphEdge> edges,
  Set<String> ids,
) {
  final groups = <(String, String), List<AdaptiveFlywheelGraphEdge>>{};
  for (final edge in edges) {
    if (!ids.contains(edge.from) || !ids.contains(edge.to)) continue;
    groups.putIfAbsent((edge.from, edge.to), () => []).add(edge);
  }
  return [
    for (final entry in groups.entries)
      _BundledEdge(
        from: entry.key.$1,
        to: entry.key.$2,
        label: _bundleLabel(entry.value),
      ),
  ];
}

String _bundleLabel(List<AdaptiveFlywheelGraphEdge> edges) {
  final parts = <String>[];
  for (final edge in edges) {
    final caption = edge.guardLabel.isEmpty
        ? edge.event
        : (edge.event.isEmpty
              ? edge.guardLabel
              : '${edge.event} · ${edge.guardLabel}');
    if (caption.isNotEmpty && !parts.contains(caption)) {
      parts.add(caption);
    }
  }
  return parts.join(' / ');
}

List<AdaptiveFlywheelWorkflowRoute> _routeEdges({
  required List<_BundledEdge> bundles,
  required Map<String, Offset> positions,
  required Set<String> exceptionIds,
  required double mainBandBottom,
}) {
  final classified = <_Classified>[];
  for (final bundle in bundles) {
    final from = positions[bundle.from];
    final to = positions[bundle.to];
    if (from == null || to == null) continue;
    final kind = bundle.from == bundle.to
        ? _RouteKind.loop
        : exceptionIds.contains(bundle.to)
        ? _RouteKind.down
        : (to.dx - from.dx).abs() < 1
        ? _RouteKind.column
        : to.dx > from.dx
        ? _RouteKind.forward
        : _RouteKind.back;
    classified.add(_Classified(bundle: bundle, kind: kind, from: from, to: to));
  }

  final rightOut = <String, List<_Classified>>{};
  final leftIn = <String, List<_Classified>>{};
  final bottomOut = <String, List<_Classified>>{};
  final topIn = <String, List<_Classified>>{};
  for (final item in classified) {
    switch (item.kind) {
      case _RouteKind.forward:
      case _RouteKind.column:
        rightOut.putIfAbsent(item.bundle.from, () => []).add(item);
        leftIn.putIfAbsent(item.bundle.to, () => []).add(item);
      case _RouteKind.down:
        bottomOut.putIfAbsent(item.bundle.from, () => []).add(item);
        topIn.putIfAbsent(item.bundle.to, () => []).add(item);
      case _RouteKind.back:
      case _RouteKind.loop:
        break;
    }
  }

  void sortByTargetY(List<_Classified> items) {
    items.sort((a, b) {
      final byY = a.to.dy.compareTo(b.to.dy);
      return byY != 0 ? byY : a.to.dx.compareTo(b.to.dx);
    });
  }

  void sortBySourceY(List<_Classified> items) {
    items.sort((a, b) {
      final byY = a.from.dy.compareTo(b.from.dy);
      return byY != 0 ? byY : a.from.dx.compareTo(b.from.dx);
    });
  }

  for (final items in rightOut.values) {
    sortByTargetY(items);
  }
  for (final items in leftIn.values) {
    sortBySourceY(items);
  }
  for (final items in bottomOut.values) {
    items.sort((a, b) => a.to.dx.compareTo(b.to.dx));
  }
  for (final items in topIn.values) {
    sortBySourceY(items);
  }

  final starts = <_Classified, Offset>{};
  final ends = <_Classified, Offset>{};
  for (final items in rightOut.values) {
    for (var i = 0; i < items.length; i++) {
      starts[items[i]] = Offset(
        items[i].from.dx + AdaptiveFlywheelWorkflowLayout.nodeWidth,
        _slot(
          i,
          items.length,
          items[i].from.dy + AdaptiveFlywheelWorkflowLayout.portInset,
          items[i].from.dy +
              AdaptiveFlywheelWorkflowLayout.nodeHeight -
              AdaptiveFlywheelWorkflowLayout.portInset,
        ),
      );
    }
  }
  for (final items in leftIn.values) {
    for (var i = 0; i < items.length; i++) {
      ends[items[i]] = Offset(
        items[i].to.dx,
        _slot(
          i,
          items.length,
          items[i].to.dy + AdaptiveFlywheelWorkflowLayout.portInset,
          items[i].to.dy +
              AdaptiveFlywheelWorkflowLayout.nodeHeight -
              AdaptiveFlywheelWorkflowLayout.portInset,
        ),
      );
    }
  }
  for (final items in bottomOut.values) {
    for (var i = 0; i < items.length; i++) {
      starts[items[i]] = Offset(
        _slot(
          i,
          items.length,
          items[i].from.dx + AdaptiveFlywheelWorkflowLayout.portInset,
          items[i].from.dx +
              AdaptiveFlywheelWorkflowLayout.nodeWidth -
              AdaptiveFlywheelWorkflowLayout.portInset,
        ),
        items[i].from.dy + AdaptiveFlywheelWorkflowLayout.nodeHeight,
      );
    }
  }
  for (final items in topIn.values) {
    for (var i = 0; i < items.length; i++) {
      ends[items[i]] = Offset(
        _slot(
          i,
          items.length,
          items[i].to.dx + AdaptiveFlywheelWorkflowLayout.portInset,
          items[i].to.dx +
              AdaptiveFlywheelWorkflowLayout.nodeWidth -
              AdaptiveFlywheelWorkflowLayout.portInset,
        ),
        items[i].to.dy,
      );
    }
  }

  final backs =
      classified.where((item) => item.kind == _RouteKind.back).toList()
        ..sort((a, b) => a.from.dx.compareTo(b.from.dx));
  final exceptionBottom = positions.values.fold<double>(
    mainBandBottom,
    (value, offset) =>
        math.max(value, offset.dy + AdaptiveFlywheelWorkflowLayout.nodeHeight),
  );
  final backBase = exceptionBottom + 36;

  final routes = <AdaptiveFlywheelWorkflowRoute>[];
  for (final item in classified) {
    late final List<Offset> points;
    switch (item.kind) {
      case _RouteKind.loop:
        final start = Offset(
          item.from.dx + AdaptiveFlywheelWorkflowLayout.nodeWidth,
          item.from.dy + AdaptiveFlywheelWorkflowLayout.nodeHeight / 2,
        );
        final apex = Offset(
          item.from.dx + AdaptiveFlywheelWorkflowLayout.nodeWidth / 2,
          item.from.dy - 36,
        );
        final end = Offset(
          item.from.dx,
          item.from.dy + AdaptiveFlywheelWorkflowLayout.nodeHeight / 2,
        );
        points = [
          start,
          Offset(start.dx + 28, start.dy),
          apex,
          Offset(end.dx - 28, end.dy),
          end,
        ];
      case _RouteKind.forward:
        final start = starts[item]!;
        final end = ends[item]!;
        if ((start.dy - end.dy).abs() < 1.5) {
          points = [start, end];
        } else {
          final midX = (start.dx + end.dx) / 2;
          points = [start, Offset(midX, start.dy), Offset(midX, end.dy), end];
        }
      case _RouteKind.column:
        final start = starts[item]!;
        final end = ends[item]!;
        final bypass = math.max(start.dx, end.dx) + 28;
        points = [start, Offset(bypass, start.dy), Offset(bypass, end.dy), end];
      case _RouteKind.down:
        final start = starts[item]!;
        final end = ends[item]!;
        final elbowY = end.dy - 28;
        if ((start.dx - end.dx).abs() < 1.5) {
          points = [start, end];
        } else {
          points = [
            start,
            Offset(start.dx, elbowY),
            Offset(end.dx, elbowY),
            end,
          ];
        }
      case _RouteKind.back:
        final index = backs.indexOf(item);
        final laneY =
            backBase + index * AdaptiveFlywheelWorkflowLayout.backLaneGap;
        final start = Offset(
          item.from.dx + AdaptiveFlywheelWorkflowLayout.nodeWidth / 2,
          item.from.dy + AdaptiveFlywheelWorkflowLayout.nodeHeight,
        );
        final end = Offset(
          item.to.dx + AdaptiveFlywheelWorkflowLayout.nodeWidth / 2,
          item.to.dy + AdaptiveFlywheelWorkflowLayout.nodeHeight,
        );
        points = [start, Offset(start.dx, laneY), Offset(end.dx, laneY), end];
    }
    routes.add(
      AdaptiveFlywheelWorkflowRoute(
        from: item.bundle.from,
        to: item.bundle.to,
        label: item.bundle.label,
        points: points,
        labelAnchor: _labelAnchor(points),
      ),
    );
  }
  return routes;
}

Offset _labelAnchor(List<Offset> points) {
  if (points.length < 2) {
    return points.isEmpty ? Offset.zero : points.first;
  }
  var bestFrom = points.first;
  var bestTo = points[1];
  var bestLength = (bestTo - bestFrom).distance;
  for (var i = 1; i < points.length - 1; i++) {
    final length = (points[i + 1] - points[i]).distance;
    if (length > bestLength) {
      bestLength = length;
      bestFrom = points[i];
      bestTo = points[i + 1];
    }
  }
  final mid = Offset(
    (bestFrom.dx + bestTo.dx) / 2,
    (bestFrom.dy + bestTo.dy) / 2,
  );
  final horizontal =
      (bestTo.dx - bestFrom.dx).abs() >= (bestTo.dy - bestFrom.dy).abs();
  return horizontal ? Offset(mid.dx, mid.dy - 10) : Offset(mid.dx + 8, mid.dy);
}

void _nudgeLabels(List<AdaptiveFlywheelWorkflowRoute> routes) {
  final labeled =
      routes.where((route) => route.label.trim().isNotEmpty).toList()
        ..sort((a, b) => a.labelAnchor.dy.compareTo(b.labelAnchor.dy));
  for (var i = 1; i < labeled.length; i++) {
    final previous = labeled[i - 1];
    final current = labeled[i];
    if ((current.labelAnchor.dx - previous.labelAnchor.dx).abs() > 88) {
      continue;
    }
    final overlap = 14 - (current.labelAnchor.dy - previous.labelAnchor.dy);
    if (overlap > 0) {
      current.labelAnchor = current.labelAnchor.translate(0, overlap);
    }
  }
}

double _slot(int index, int count, double lo, double hi) {
  if (count <= 1) return (lo + hi) / 2;
  return lo + (hi - lo) * index / (count - 1);
}

final class _BundledEdge {
  const _BundledEdge({
    required this.from,
    required this.to,
    required this.label,
  });

  final String from;
  final String to;
  final String label;
}

enum _RouteKind { forward, down, back, column, loop }

final class _Classified {
  const _Classified({
    required this.bundle,
    required this.kind,
    required this.from,
    required this.to,
  });

  final _BundledEdge bundle;
  final _RouteKind kind;
  final Offset from;
  final Offset to;
}
