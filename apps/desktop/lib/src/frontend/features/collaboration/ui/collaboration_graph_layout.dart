import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:licoup/src/contracts/collaboration_run_models.dart';

/// Spacing metrics shared by the flowchart layout and its canvas.
abstract final class CollaborationGraphMetrics {
  static const double padX = 30;
  static const double padBottom = 24;

  /// Top of the highest card row; the phase headers and the innermost
  /// callback lane sit above it.
  static const double cardsTop = 58;
  static const double phaseTop = 8;
  static const double phaseHeaderHeight = 24;
  static const double colGap = 64;
  static const double rowGap = 28;

  /// Vertical clearance between a long-edge lane and a card in its column.
  static const double laneClearance = 20;

  /// Vertical spacing between two long-edge lanes in one column.
  static const double laneGap = 14;

  /// Callback arcs clear the cards they span by this much; nested arcs step
  /// outward by [arcLaneGap].
  static const double arcClearance = 20;
  static const double arcLaneGap = 10;

  /// Distance of a side channel from its column edge.
  static const double channelInset = 12;

  /// Distance of a side exit from the top or bottom card edge.
  static const double sideExitInset = 16;
  static const double cornerRadius = 12;

  /// Ports keep this far from a card's top and bottom edges.
  static const double portInset = 8;
  static const double outPortSpacing = 9;
  static const double inPortSpacing = 13;
  static const double portSeparation = 6;

  /// Largest distance a port moves off its spread position to make a route
  /// straight.
  static const double maxPortSnap = 24;
}

/// How a display node is rendered on the canvas.
enum CollaborationCardKind {
  /// One work or step node (actor, workset, script, authorization).
  task,

  /// A strictly sequential chain of same-group actor nodes.
  stack,

  /// Fork, join, choice or pass: a small labelled connector.
  connector,

  /// The run's end marker.
  terminal,
}

/// One rendered node: a single graph node, or a merged stack.
final class CollaborationDisplayNode {
  CollaborationDisplayNode({
    required this.id,
    required Iterable<String> memberIds,
    required this.kind,
    this.group,
  }) : memberIds = List<String>.unmodifiable(memberIds);

  /// The node id, or the first member id for a stack.
  final String id;

  /// Every graph node this display node represents, in chain order.
  final List<String> memberIds;
  final CollaborationCardKind kind;
  final String? group;
}

/// How an edge is routed.
enum CollaborationRouteKind {
  /// Forward handoff, left to right through the column gaps.
  flow,

  /// Callback handoff, arcing above the cards it spans.
  callback,

  /// A flow edge that closes a cycle, routed below the cards it spans.
  back,
}

/// One rendered edge between display nodes. Contract edges with the same
/// display endpoints and route kind share one route.
final class CollaborationDisplayEdge {
  CollaborationDisplayEdge({
    required this.from,
    required this.to,
    required this.kind,
    required Iterable<CollaborationGraphEdge> edges,
  }) : edges = List<CollaborationGraphEdge>.unmodifiable(edges);

  final String from;
  final String to;
  final CollaborationRouteKind kind;

  /// The contract edges this route stands for.
  final List<CollaborationGraphEdge> edges;

  String get key => '$from>$to>${kind.name}';
}

/// The display-level view of a graph: merged stacks and classified edges.
final class CollaborationGraphStructure {
  CollaborationGraphStructure._({
    required this.graph,
    required this.nodes,
    required this.edges,
    required Map<String, String> displayIds,
  }) : _displayIds = displayIds,
       _byId = {for (final node in nodes) node.id: node};

  /// Merges strictly sequential same-group actor chains into stacks and
  /// classifies every edge.
  ///
  /// A chain merges when every member is an actor of the same group, every
  /// link is the member's only outgoing and the next member's only incoming
  /// non-callback edge, and no callback edge touches a member. Callback
  /// edges route as arcs; flow edges that close a cycle (found by depth-first
  /// search from the initial node) route below; self-references inside a
  /// stack are not drawn.
  factory CollaborationGraphStructure.of(CollaborationGraph graph) {
    final chains = _stackChains(graph);
    final displayIds = <String, String>{};
    final chainByFirst = <String, List<String>>{};
    for (final chain in chains) {
      chainByFirst[chain.first] = chain;
      for (final id in chain) {
        displayIds[id] = chain.first;
      }
    }
    for (final node in graph.nodes) {
      displayIds.putIfAbsent(node.id, () => node.id);
    }

    final nodes = <CollaborationDisplayNode>[];
    final seen = <String>{};
    for (final node in graph.nodes) {
      final displayId = displayIds[node.id]!;
      if (!seen.add(displayId)) continue;
      final chain = chainByFirst[displayId];
      nodes.add(
        CollaborationDisplayNode(
          id: displayId,
          memberIds: chain ?? [displayId],
          kind: chain != null
              ? CollaborationCardKind.stack
              : _cardKindOf(node.kind),
          group: node.group,
        ),
      );
    }

    final back = _backEdges(graph, nodes, displayIds);
    final grouped = <String, List<CollaborationGraphEdge>>{};
    final kinds = <String, (String, String, CollaborationRouteKind)>{};
    for (final edge in graph.edges) {
      final from = displayIds[edge.from]!;
      final to = displayIds[edge.to]!;
      if (from == to) continue;
      final kind = edge.callback
          ? CollaborationRouteKind.callback
          : back.contains('$from>$to')
          ? CollaborationRouteKind.back
          : CollaborationRouteKind.flow;
      final key = '$from>$to>${kind.name}';
      grouped.putIfAbsent(key, () => <CollaborationGraphEdge>[]).add(edge);
      kinds[key] = (from, to, kind);
    }
    return CollaborationGraphStructure._(
      graph: graph,
      nodes: List<CollaborationDisplayNode>.unmodifiable(nodes),
      edges: List<CollaborationDisplayEdge>.unmodifiable([
        for (final entry in grouped.entries)
          CollaborationDisplayEdge(
            from: kinds[entry.key]!.$1,
            to: kinds[entry.key]!.$2,
            kind: kinds[entry.key]!.$3,
            edges: entry.value,
          ),
      ]),
      displayIds: displayIds,
    );
  }

  final CollaborationGraph graph;

  /// Display nodes in graph input order; a stack takes its first member's
  /// position.
  final List<CollaborationDisplayNode> nodes;
  final List<CollaborationDisplayEdge> edges;
  final Map<String, String> _displayIds;
  final Map<String, CollaborationDisplayNode> _byId;

  /// The display node id that renders graph node [nodeId].
  String? displayIdOf(String nodeId) => _displayIds[nodeId];

  CollaborationDisplayNode? nodeFor(String displayId) => _byId[displayId];
}

/// Placement of one display node on the canvas.
final class CollaborationCardPlacement {
  const CollaborationCardPlacement({
    required this.node,
    required this.rect,
    required this.rank,
  });

  final CollaborationDisplayNode node;
  final Rect rect;
  final int rank;

  String get id => node.id;
}

/// Orthogonal route of one display edge as absolute waypoints.
final class CollaborationEdgeRoute {
  CollaborationEdgeRoute({required this.edge, required List<Offset> points})
    : points = List<Offset>.unmodifiable(points);

  final CollaborationDisplayEdge edge;

  /// Waypoints in world coordinates; consecutive points share x or y. The
  /// canvas rounds each bend with [CollaborationGraphMetrics.cornerRadius].
  final List<Offset> points;

  String get key => edge.key;
  String get from => edge.from;
  String get to => edge.to;
  CollaborationRouteKind get kind => edge.kind;
}

/// A contiguous run of ranks whose grouped nodes share one group label.
final class CollaborationPhaseSpan {
  CollaborationPhaseSpan({
    required this.group,
    required this.rect,
    required Iterable<int> ranks,
    required Iterable<String> cardIds,
  }) : ranks = List<int>.unmodifiable(ranks),
       cardIds = List<String>.unmodifiable(cardIds);

  final String group;

  /// Header band above the phase's cards.
  final Rect rect;
  final List<int> ranks;

  /// Display node ids placed in [ranks].
  final List<String> cardIds;
}

/// Complete deterministic canvas geometry for one graph.
final class CollaborationGraphLayout {
  CollaborationGraphLayout({
    required this.worldSize,
    required Iterable<CollaborationCardPlacement> cards,
    required Iterable<CollaborationEdgeRoute> edges,
    required Iterable<CollaborationPhaseSpan> phases,
  }) : cards = List<CollaborationCardPlacement>.unmodifiable(cards),
       edges = List<CollaborationEdgeRoute>.unmodifiable(edges),
       phases = List<CollaborationPhaseSpan>.unmodifiable(phases),
       _byId = {for (final card in cards) card.id: card};

  final Size worldSize;
  final List<CollaborationCardPlacement> cards;
  final List<CollaborationEdgeRoute> edges;
  final List<CollaborationPhaseSpan> phases;
  final Map<String, CollaborationCardPlacement> _byId;

  CollaborationCardPlacement? cardFor(String id) => _byId[id];
}

/// Computes deterministic card and route geometry for [structure].
///
/// [sizes] gives every display node's card size. The algorithm is layered:
///
/// 1. Ranks are longest paths over flow edges, so every rank holds a real
///    card and every flow edge points to a higher rank.
/// 2. A flow edge spanning several ranks threads a lane through each rank in
///    between, so it never crosses a card.
/// 3. Barycenter sweeps order each rank to reduce crossings.
/// 4. Alternating median sweeps align each card with its neighbours under the
///    rank's ordering and spacing, ending on a predecessor sweep so chains
///    read straight from left to right.
/// 5. Ports spread around each card's middle and snap onto the opposite end
///    when that makes the route straight.
///
/// Callback arcs pass above and back edges below every card in the ranks
/// they span; nested arcs take outer lanes. No route segment intersects a
/// card other than its own endpoints.
CollaborationGraphLayout collaborationGraphLayout(
  CollaborationGraphStructure structure, {
  required Map<String, Size> sizes,
}) {
  final nodes = structure.nodes;
  final flowEdges = [
    for (final edge in structure.edges)
      if (edge.kind == CollaborationRouteKind.flow) edge,
  ];
  final ranks = _longestPathRanks(nodes, flowEdges);
  final maxRank = ranks.values.fold<int>(0, math.max);

  final dfsIndex = _dfsIndex(structure, flowEdges);
  final itemsById = <String, _Item>{};
  final layers = List<List<_Item>>.generate(maxRank + 1, (_) => <_Item>[]);
  for (final node in nodes) {
    final size = sizes[node.id] ?? Size.zero;
    final item = _Item(
      id: node.id,
      node: node,
      rank: ranks[node.id]!,
      width: size.width,
      height: size.height,
      sortKey: dfsIndex[node.id]!.toDouble(),
    );
    itemsById[node.id] = item;
    layers[item.rank].add(item);
  }

  // Thread every flow edge through its ranks.
  final chains = <String, List<_Item>>{};
  for (final edge in flowEdges) {
    final source = itemsById[edge.from]!;
    final target = itemsById[edge.to]!;
    final chain = <_Item>[source];
    for (var rank = source.rank + 1; rank < target.rank; rank++) {
      final lane = _Item(
        id: '${edge.key}#$rank',
        rank: rank,
        sortKey: dfsIndex[edge.from]! + 0.5,
      );
      layers[rank].add(lane);
      chain.add(lane);
    }
    chain.add(target);
    for (var i = 0; i < chain.length - 1; i++) {
      chain[i].succs.add(chain[i + 1]);
      chain[i + 1].preds.add(chain[i]);
    }
    chains[edge.key] = chain;
  }

  _orderLayers(layers);
  _placeLayers(layers);

  // Columns: width of the widest card; cards centered inside.
  final colLeft = List<double>.filled(maxRank + 1, 0);
  final colRight = List<double>.filled(maxRank + 1, 0);
  var x = CollaborationGraphMetrics.padX;
  for (var rank = 0; rank <= maxRank; rank++) {
    final width = layers[rank].fold<double>(
      0,
      (max, item) => math.max(max, item.width),
    );
    colLeft[rank] = x;
    colRight[rank] = x + width;
    x += width + CollaborationGraphMetrics.colGap;
  }
  final worldWidth =
      x - CollaborationGraphMetrics.colGap + CollaborationGraphMetrics.padX;

  // Lanes for callback arcs above and back edges below.
  final callbacks = [
    for (final edge in structure.edges)
      if (edge.kind == CollaborationRouteKind.callback) edge,
  ];
  final backs = [
    for (final edge in structure.edges)
      if (edge.kind == CollaborationRouteKind.back) edge,
  ];
  final callbackLanes = _assignLanes(callbacks, ranks);
  final backLanes = _assignLanes(backs, ranks);
  final topLaneCount = callbackLanes.values.fold<int>(
    0,
    (max, lane) => math.max(max, lane + 1),
  );

  // Shift every item so the highest card or lane sits at the cards' top.
  var minTop = double.infinity;
  for (final layer in layers) {
    for (final item in layer) {
      final top = item.dummy
          ? item.center - CollaborationGraphMetrics.laneClearance
          : item.center - item.height / 2;
      minTop = math.min(minTop, top);
    }
  }
  final cardsTop =
      CollaborationGraphMetrics.cardsTop +
      math.max(0, topLaneCount - 1) * CollaborationGraphMetrics.arcLaneGap;
  final shift = cardsTop - (minTop.isFinite ? minTop : 0);
  for (final layer in layers) {
    for (final item in layer) {
      item.center += shift;
      if (!item.dummy) {
        final left =
            colLeft[item.rank] +
            (colRight[item.rank] - colLeft[item.rank] - item.width) / 2;
        item.rect = Rect.fromLTWH(
          left,
          item.center - item.height / 2,
          item.width,
          item.height,
        );
      }
    }
  }

  _assignPorts(layers, flowEdges, chains);

  final routes = <CollaborationEdgeRoute>[];
  final geometry = _Geometry(layers, colLeft, colRight);
  for (final edge in structure.edges) {
    switch (edge.kind) {
      case CollaborationRouteKind.flow:
        routes.add(
          CollaborationEdgeRoute(
            edge: edge,
            points: _flowRoute(chains[edge.key]!, edge.key, geometry),
          ),
        );
      case CollaborationRouteKind.callback:
        routes.add(
          CollaborationEdgeRoute(
            edge: edge,
            points: _arcRoute(
              itemsById[edge.from]!,
              itemsById[edge.to]!,
              callbackLanes[edge.key]!,
              geometry,
              above: true,
            ),
          ),
        );
      case CollaborationRouteKind.back:
        routes.add(
          CollaborationEdgeRoute(
            edge: edge,
            points: _arcRoute(
              itemsById[edge.from]!,
              itemsById[edge.to]!,
              backLanes[edge.key]!,
              geometry,
              above: false,
            ),
          ),
        );
    }
  }

  var maxBottom = 0.0;
  for (final layer in layers) {
    for (final item in layer) {
      maxBottom = math.max(
        maxBottom,
        item.dummy
            ? item.center + CollaborationGraphMetrics.laneClearance
            : item.rect!.bottom,
      );
    }
  }
  for (final route in routes) {
    for (final point in route.points) {
      maxBottom = math.max(maxBottom, point.dy);
    }
  }

  final cards = [
    for (final node in nodes)
      CollaborationCardPlacement(
        node: node,
        rect: itemsById[node.id]!.rect!,
        rank: itemsById[node.id]!.rank,
      ),
  ];

  return CollaborationGraphLayout(
    worldSize: Size(
      worldWidth,
      maxBottom + CollaborationGraphMetrics.padBottom,
    ),
    cards: cards,
    edges: routes,
    phases: _phases(layers),
  );
}

/// Whether any axis-aligned segment of [points] intersects the interior of a
/// card rect other than [source] and [target].
bool collaborationRouteIntersectsCards(
  List<Offset> points,
  Iterable<Rect> cards, {
  Rect? source,
  Rect? target,
}) {
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    for (final rect in cards) {
      if (rect == source || rect == target) continue;
      if ((a.dx - b.dx).abs() < 0.5) {
        final minY = math.min(a.dy, b.dy);
        final maxY = math.max(a.dy, b.dy);
        if (a.dx > rect.left &&
            a.dx < rect.right &&
            maxY > rect.top &&
            minY < rect.bottom) {
          return true;
        }
      } else {
        final minX = math.min(a.dx, b.dx);
        final maxX = math.max(a.dx, b.dx);
        if (a.dy > rect.top &&
            a.dy < rect.bottom &&
            maxX > rect.left &&
            minX < rect.right) {
          return true;
        }
      }
    }
  }
  return false;
}

/// A layered item: a card, or a lane of a long flow edge.
final class _Item {
  _Item({
    required this.id,
    required this.rank,
    required this.sortKey,
    this.node,
    this.width = 0,
    this.height = 0,
  });

  final String id;
  final CollaborationDisplayNode? node;
  final int rank;
  final double width;
  final double height;

  /// Depth-first discovery order; breaks ordering ties deterministically.
  final double sortKey;
  final List<_Item> preds = [];
  final List<_Item> succs = [];

  double position = 0;
  double center = 0;
  Rect? rect;

  /// Port y per edge key, for real cards.
  final Map<String, double> outPorts = {};
  final Map<String, double> inPorts = {};

  bool get dummy => node == null;
}

final class _Geometry {
  _Geometry(this.layers, this.colLeft, this.colRight);

  final List<List<_Item>> layers;
  final List<double> colLeft;
  final List<double> colRight;

  double gapMid(int rank) =>
      colRight[rank] + CollaborationGraphMetrics.colGap / 2;

  /// Top of the highest card in ranks [from, to].
  double spanTop(int from, int to) {
    var top = double.infinity;
    for (var rank = from; rank <= to; rank++) {
      for (final item in layers[rank]) {
        if (!item.dummy) top = math.min(top, item.rect!.top);
      }
    }
    return top;
  }

  double spanBottom(int from, int to) {
    var bottom = double.negativeInfinity;
    for (var rank = from; rank <= to; rank++) {
      for (final item in layers[rank]) {
        if (!item.dummy) bottom = math.max(bottom, item.rect!.bottom);
      }
    }
    return bottom;
  }

  bool isTopmost(_Item item) => layers[item.rank].every(
    (other) => other.dummy || other.rect!.top >= item.rect!.top,
  );

  bool isBottommost(_Item item) => layers[item.rank].every(
    (other) => other.dummy || other.rect!.bottom <= item.rect!.bottom,
  );
}

CollaborationCardKind _cardKindOf(CollaborationNodeKind kind) => switch (kind) {
  CollaborationNodeKind.fork ||
  CollaborationNodeKind.join ||
  CollaborationNodeKind.choice ||
  CollaborationNodeKind.pass => CollaborationCardKind.connector,
  CollaborationNodeKind.terminal => CollaborationCardKind.terminal,
  _ => CollaborationCardKind.task,
};

List<List<String>> _stackChains(CollaborationGraph graph) {
  final nodesById = {for (final node in graph.nodes) node.id: node};
  final outgoing = <String, List<String>>{};
  final incoming = <String, List<String>>{};
  final callbackTouched = <String>{};
  for (final edge in graph.edges) {
    if (edge.callback) {
      callbackTouched
        ..add(edge.from)
        ..add(edge.to);
      continue;
    }
    outgoing.putIfAbsent(edge.from, () => <String>[]).add(edge.to);
    incoming.putIfAbsent(edge.to, () => <String>[]).add(edge.from);
  }

  bool eligible(CollaborationGraphNode node) =>
      node.kind == CollaborationNodeKind.actor &&
      node.group != null &&
      !callbackTouched.contains(node.id);

  bool links(String from, String to) {
    final a = nodesById[from]!;
    final b = nodesById[to]!;
    return eligible(b) &&
        b.group == a.group &&
        from != to &&
        (outgoing[from]?.length ?? 0) == 1 &&
        (incoming[to]?.length ?? 0) == 1;
  }

  final chains = <List<String>>[];
  final claimed = <String>{};
  for (final node in graph.nodes) {
    if (claimed.contains(node.id) || !eligible(node)) continue;
    final preds = incoming[node.id] ?? const <String>[];
    if (preds.length == 1 && eligible(nodesById[preds.single]!)) {
      if (links(preds.single, node.id)) continue;
    }
    final chain = <String>[node.id];
    var current = node.id;
    while (true) {
      final next = outgoing[current];
      if (next == null || next.length != 1) break;
      final candidate = next.single;
      if (claimed.contains(candidate) ||
          chain.contains(candidate) ||
          !links(current, candidate)) {
        break;
      }
      chain.add(candidate);
      current = candidate;
    }
    if (chain.length >= 2) {
      chains.add(chain);
      claimed.addAll(chain);
    }
  }
  return chains;
}

/// Display-level `from>to` pairs of non-callback edges that close a cycle.
Set<String> _backEdges(
  CollaborationGraph graph,
  List<CollaborationDisplayNode> nodes,
  Map<String, String> displayIds,
) {
  final out = <String, List<String>>{};
  for (final edge in graph.edges) {
    if (edge.callback) continue;
    final from = displayIds[edge.from]!;
    final to = displayIds[edge.to]!;
    if (from == to) continue;
    final targets = out.putIfAbsent(from, () => <String>[]);
    if (!targets.contains(to)) targets.add(to);
  }
  final back = <String>{};
  final state = <String, int>{};
  void visit(String id) {
    state[id] = 1;
    for (final target in out[id] ?? const <String>[]) {
      final targetState = state[target] ?? 0;
      if (targetState == 1) {
        back.add('$id>$target');
      } else if (targetState == 0) {
        visit(target);
      }
    }
    state[id] = 2;
  }

  final initial = displayIds[graph.initialNodeId]!;
  visit(initial);
  for (final node in nodes) {
    if ((state[node.id] ?? 0) == 0) visit(node.id);
  }
  return back;
}

Map<String, int> _longestPathRanks(
  List<CollaborationDisplayNode> nodes,
  List<CollaborationDisplayEdge> flowEdges,
) {
  final inCount = {for (final node in nodes) node.id: 0};
  final out = <String, List<String>>{};
  for (final edge in flowEdges) {
    inCount[edge.to] = inCount[edge.to]! + 1;
    out.putIfAbsent(edge.from, () => <String>[]).add(edge.to);
  }
  final ranks = {for (final node in nodes) node.id: 0};
  final queue = [
    for (final node in nodes)
      if (inCount[node.id] == 0) node.id,
  ];
  for (var i = 0; i < queue.length; i++) {
    final id = queue[i];
    for (final target in out[id] ?? const <String>[]) {
      ranks[target] = math.max(ranks[target]!, ranks[id]! + 1);
      inCount[target] = inCount[target]! - 1;
      if (inCount[target] == 0) queue.add(target);
    }
  }
  return ranks;
}

Map<String, int> _dfsIndex(
  CollaborationGraphStructure structure,
  List<CollaborationDisplayEdge> flowEdges,
) {
  final out = <String, List<String>>{};
  for (final edge in flowEdges) {
    out.putIfAbsent(edge.from, () => <String>[]).add(edge.to);
  }
  final index = <String, int>{};
  void visit(String id) {
    if (index.containsKey(id)) return;
    index[id] = index.length;
    for (final target in out[id] ?? const <String>[]) {
      visit(target);
    }
  }

  final initial = structure.displayIdOf(structure.graph.initialNodeId);
  if (initial != null) visit(initial);
  for (final node in structure.nodes) {
    visit(node.id);
  }
  return index;
}

void _orderLayers(List<List<_Item>> layers) {
  void number(List<_Item> layer) {
    for (var i = 0; i < layer.length; i++) {
      layer[i].position = i.toDouble();
    }
  }

  void sortBy(List<_Item> layer, List<_Item> Function(_Item) neighbours) {
    final keys = <_Item, double>{
      for (final item in layer)
        item: switch (neighbours(item)) {
          final list when list.isEmpty => item.position,
          final list =>
            list.fold<double>(0, (sum, other) => sum + other.position) /
                list.length,
        },
    };
    layer.sort((a, b) {
      final byKey = keys[a]!.compareTo(keys[b]!);
      return byKey != 0 ? byKey : a.sortKey.compareTo(b.sortKey);
    });
    number(layer);
  }

  layers[0].sort((a, b) => a.sortKey.compareTo(b.sortKey));
  number(layers[0]);
  for (var rank = 1; rank < layers.length; rank++) {
    layers[rank].sort((a, b) => a.sortKey.compareTo(b.sortKey));
    number(layers[rank]);
  }

  var best = _snapshot(layers);
  var bestCrossings = _crossings(layers);
  for (var round = 0; round < 6 && bestCrossings > 0; round++) {
    if (round.isEven) {
      for (var rank = 1; rank < layers.length; rank++) {
        sortBy(layers[rank], (item) => item.preds);
      }
    } else {
      for (var rank = layers.length - 2; rank >= 0; rank--) {
        sortBy(layers[rank], (item) => item.succs);
      }
    }
    final crossings = _crossings(layers);
    if (crossings < bestCrossings) {
      bestCrossings = crossings;
      best = _snapshot(layers);
    }
  }
  for (var rank = 0; rank < layers.length; rank++) {
    layers[rank]
      ..clear()
      ..addAll(best[rank]);
    number(layers[rank]);
  }
}

List<List<_Item>> _snapshot(List<List<_Item>> layers) => [
  for (final layer in layers) List<_Item>.of(layer),
];

int _crossings(List<List<_Item>> layers) {
  var count = 0;
  for (var rank = 0; rank < layers.length - 1; rank++) {
    final pairs = <(double, double)>[
      for (final item in layers[rank])
        for (final next in item.succs) (item.position, next.position),
    ];
    for (var i = 0; i < pairs.length; i++) {
      for (var j = i + 1; j < pairs.length; j++) {
        final a = pairs[i];
        final b = pairs[j];
        if ((a.$1 - b.$1) * (a.$2 - b.$2) < 0) count++;
      }
    }
  }
  return count;
}

double _gapBetween(_Item above, _Item below) {
  if (above.dummy && below.dummy) return CollaborationGraphMetrics.laneGap;
  if (above.dummy || below.dummy) {
    return CollaborationGraphMetrics.laneClearance;
  }
  return CollaborationGraphMetrics.rowGap;
}

/// Places [layer] as close to [desired] centers as its order and spacing
/// allow (weighted isotonic regression over the stacked offsets).
void _placeLayer(List<_Item> layer, List<double> desired) {
  if (layer.isEmpty) return;
  final offsets = List<double>.filled(layer.length, 0);
  for (var i = 1; i < layer.length; i++) {
    offsets[i] =
        offsets[i - 1] +
        layer[i - 1].height +
        _gapBetween(layer[i - 1], layer[i]);
  }
  final targets = [
    for (var i = 0; i < layer.length; i++)
      desired[i] - layer[i].height / 2 - offsets[i],
  ];
  final blockSum = <double>[];
  final blockCount = <int>[];
  for (final target in targets) {
    blockSum.add(target);
    blockCount.add(1);
    while (blockSum.length >= 2 &&
        blockSum[blockSum.length - 2] / blockCount[blockCount.length - 2] >
            blockSum.last / blockCount.last) {
      final sum = blockSum.removeLast();
      final count = blockCount.removeLast();
      blockSum[blockSum.length - 1] += sum;
      blockCount[blockCount.length - 1] += count;
    }
  }
  var index = 0;
  for (var block = 0; block < blockSum.length; block++) {
    final value = blockSum[block] / blockCount[block];
    for (var k = 0; k < blockCount[block]; k++, index++) {
      layer[index].center = value + offsets[index] + layer[index].height / 2;
    }
  }
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

void _placeLayers(List<List<_Item>> layers) {
  for (final layer in layers) {
    _placeLayer(layer, List<double>.filled(layer.length, 0));
  }
  void sweep(List<_Item> layer, List<_Item> Function(_Item) neighbours) {
    _placeLayer(layer, [
      for (final item in layer)
        switch (neighbours(item)) {
          final list when list.isEmpty => item.center,
          final list => _median([for (final other in list) other.center]),
        },
    ]);
  }

  for (var round = 0; round < 3; round++) {
    for (var rank = 1; rank < layers.length; rank++) {
      sweep(layers[rank], (item) => item.preds);
    }
    for (var rank = layers.length - 2; rank >= 0; rank--) {
      sweep(layers[rank], (item) => item.succs);
    }
  }
  for (var rank = 1; rank < layers.length; rank++) {
    sweep(layers[rank], (item) => item.preds);
  }
}

/// Spreads [count] ports around [item]'s middle, snaps each toward its
/// preferred y when that keeps it on the card and near its spread slot, then
/// restores order and separation.
List<double> _ports(_Item item, List<double?> preferred, double spacing) {
  final count = preferred.length;
  final top = item.rect!.top + CollaborationGraphMetrics.portInset;
  final bottom = item.rect!.bottom - CollaborationGraphMetrics.portInset;
  final half = math.max(0.0, (bottom - top) / 2);
  final step = count <= 1
      ? 0.0
      : math.min(spacing, (bottom - top) / (count - 1));
  final snap = math.min(CollaborationGraphMetrics.maxPortSnap, half);
  final ideal = <double>[];
  for (var i = 0; i < count; i++) {
    final base = item.center + (i - (count - 1) / 2) * step;
    final want = preferred[i];
    ideal.add(
      want != null &&
              want >= top &&
              want <= bottom &&
              (want - base).abs() <= snap
          ? want
          : base,
    );
  }
  // Enforce ascending order with a minimum separation, then clamp.
  final separation = count <= 1
      ? 0.0
      : math.min(CollaborationGraphMetrics.portSeparation, step);
  for (var i = 1; i < count; i++) {
    ideal[i] = math.max(ideal[i], ideal[i - 1] + separation);
  }
  final overflow = ideal.isEmpty ? 0.0 : ideal.last - bottom;
  if (overflow > 0) {
    for (var i = 0; i < count; i++) {
      ideal[i] -= overflow;
    }
  }
  return [for (final value in ideal) value.clamp(top, bottom).toDouble()];
}

void _assignPorts(
  List<List<_Item>> layers,
  List<CollaborationDisplayEdge> flowEdges,
  Map<String, List<_Item>> chains,
) {
  final outgoing = <_Item, List<(String, _Item)>>{};
  final incoming = <_Item, List<(String, _Item)>>{};
  for (final edge in flowEdges) {
    final chain = chains[edge.key]!;
    outgoing.putIfAbsent(chain.first, () => []).add((edge.key, chain[1]));
    incoming.putIfAbsent(chain.last, () => []).add((
      edge.key,
      chain[chain.length - 2],
    ));
  }

  // Out-ports first: snap onto a next hop whose own y is fixed (a lane) or
  // that has a single incoming route.
  for (final entry in outgoing.entries) {
    final item = entry.key;
    final hops = [...entry.value]
      ..sort((a, b) => a.$2.center.compareTo(b.$2.center));
    final ports = _ports(item, [
      for (final hop in hops)
        hop.$2.dummy || hop.$2.preds.length == 1 ? hop.$2.center : null,
    ], CollaborationGraphMetrics.outPortSpacing);
    for (var i = 0; i < hops.length; i++) {
      item.outPorts[hops[i].$1] = ports[i];
    }
  }

  double arrivingY(String key, _Item previous) =>
      previous.dummy ? previous.center : previous.outPorts[key]!;

  for (final entry in incoming.entries) {
    final item = entry.key;
    final hops = [...entry.value]
      ..sort((a, b) => arrivingY(a.$1, a.$2).compareTo(arrivingY(b.$1, b.$2)));
    final ports = _ports(item, [
      for (final hop in hops) arrivingY(hop.$1, hop.$2),
    ], CollaborationGraphMetrics.inPortSpacing);
    for (var i = 0; i < hops.length; i++) {
      item.inPorts[hops[i].$1] = ports[i];
    }
  }
}

List<Offset> _flowRoute(List<_Item> chain, String key, _Geometry geometry) {
  final source = chain.first;
  final target = chain.last;
  final points = <Offset>[Offset(source.rect!.right, source.outPorts[key]!)];
  for (var i = 0; i < chain.length - 1; i++) {
    final a = chain[i];
    final b = chain[i + 1];
    final ya = a.dummy ? a.center : a.outPorts[key]!;
    final yb = b == target ? b.inPorts[key]! : b.center;
    if (a.dummy) points.add(Offset(geometry.colRight[a.rank], ya));
    if ((ya - yb).abs() >= 0.5) {
      final trunk = geometry.gapMid(a.rank);
      points
        ..add(Offset(trunk, ya))
        ..add(Offset(trunk, yb));
    }
    points.add(Offset(b.dummy ? geometry.colLeft[b.rank] : b.rect!.left, yb));
  }
  return _simplify(points);
}

/// Callback arcs leave and enter through the top edge (back edges through the
/// bottom edge) when the card is outermost in its column, and through a side
/// channel next to the column otherwise.
List<Offset> _arcRoute(
  _Item source,
  _Item target,
  int lane,
  _Geometry geometry, {
  required bool above,
}) {
  final low = math.min(source.rank, target.rank);
  final high = math.max(source.rank, target.rank);
  final laneOffset =
      CollaborationGraphMetrics.arcClearance +
      lane * CollaborationGraphMetrics.arcLaneGap;
  final arcY = above
      ? geometry.spanTop(low, high) - laneOffset
      : geometry.spanBottom(low, high) + laneOffset;
  final targetLeft = target.rank < source.rank;

  List<Offset> end(_Item item, {required bool leaving}) {
    final rect = item.rect!;
    final outermost = above
        ? geometry.isTopmost(item)
        : geometry.isBottommost(item);
    if (outermost) {
      final edgeY = above ? rect.top : rect.bottom;
      return [Offset(rect.center.dx, edgeY), Offset(rect.center.dx, arcY)];
    }
    // Leave toward the other end; enter from the side facing the source.
    final towardLeft = leaving ? targetLeft : !targetLeft;
    final sideX = towardLeft ? rect.left : rect.right;
    final channelX = towardLeft
        ? geometry.colLeft[item.rank] - CollaborationGraphMetrics.channelInset
        : geometry.colRight[item.rank] + CollaborationGraphMetrics.channelInset;
    final sideY = above
        ? rect.top +
              math.min(CollaborationGraphMetrics.sideExitInset, rect.height / 2)
        : rect.bottom -
              math.min(
                CollaborationGraphMetrics.sideExitInset,
                rect.height / 2,
              );
    return [
      Offset(sideX, sideY),
      Offset(channelX, sideY),
      Offset(channelX, arcY),
    ];
  }

  final start = end(source, leaving: true);
  final finish = end(target, leaving: false).reversed.toList();
  return _simplify([...start, ...finish]);
}

/// Lowest free lane per edge; edges whose rank spans overlap never share a
/// lane. Shorter spans take inner lanes.
Map<String, int> _assignLanes(
  List<CollaborationDisplayEdge> edges,
  Map<String, int> ranks,
) {
  (int, int) span(CollaborationDisplayEdge edge) {
    final a = ranks[edge.from]!;
    final b = ranks[edge.to]!;
    return (math.min(a, b), math.max(a, b));
  }

  final ordered = [...edges]
    ..sort((a, b) {
      final sa = span(a);
      final sb = span(b);
      return (sa.$2 - sa.$1).compareTo(sb.$2 - sb.$1);
    });
  final lanes = <String, int>{};
  final occupied = <int, List<(int, int)>>{};
  for (final edge in ordered) {
    final s = span(edge);
    var lane = 0;
    while ((occupied[lane] ?? const <(int, int)>[]).any(
      (other) => other.$1 <= s.$2 && s.$1 <= other.$2,
    )) {
      lane++;
    }
    occupied.putIfAbsent(lane, () => []).add(s);
    lanes[edge.key] = lane;
  }
  return lanes;
}

List<Offset> _simplify(List<Offset> points) {
  final result = <Offset>[];
  for (final point in points) {
    if (result.isNotEmpty && (result.last - point).distance < 0.01) continue;
    if (result.length >= 2) {
      final a = result[result.length - 2];
      final b = result.last;
      final collinear =
          ((a.dx - b.dx).abs() < 0.01 && (b.dx - point.dx).abs() < 0.01) ||
          ((a.dy - b.dy).abs() < 0.01 && (b.dy - point.dy).abs() < 0.01);
      if (collinear) {
        result[result.length - 1] = point;
        continue;
      }
    }
    result.add(point);
  }
  return result;
}

List<CollaborationPhaseSpan> _phases(List<List<_Item>> layers) {
  String? labelOf(List<_Item> layer) {
    String? label;
    for (final item in layer) {
      final group = item.node?.group;
      if (group == null) continue;
      if (label != null && label != group) return null;
      label = group;
    }
    return label;
  }

  final phases = <CollaborationPhaseSpan>[];
  var rank = 0;
  while (rank < layers.length) {
    final label = labelOf(layers[rank]);
    if (label == null) {
      rank++;
      continue;
    }
    final ranks = <int>[];
    while (rank < layers.length && labelOf(layers[rank]) == label) {
      ranks.add(rank);
      rank++;
    }
    final cards = [
      for (final r in ranks)
        for (final item in layers[r])
          if (!item.dummy) item,
    ];
    final left = cards.fold<double>(
      double.infinity,
      (min, item) => math.min(min, item.rect!.left),
    );
    final right = cards.fold<double>(
      double.negativeInfinity,
      (max, item) => math.max(max, item.rect!.right),
    );
    phases.add(
      CollaborationPhaseSpan(
        group: label,
        rect: Rect.fromLTWH(
          left,
          CollaborationGraphMetrics.phaseTop,
          right - left,
          CollaborationGraphMetrics.phaseHeaderHeight,
        ),
        ranks: ranks,
        cardIds: [for (final item in cards) item.id],
      ),
    );
  }
  return phases;
}
