/// The bounded, deterministic layered layout of one graph document.
///
/// Layout is a pure function of topology plus the expansion state. It runs
/// inside a real preparation worker isolate, yields while it walks a large
/// document, and is cancelled at a chunk boundary when a newer topology
/// supersedes it. Status never takes part: a high-frequency status update must
/// not move a node.
library;

import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import '../scheduling/preparation_cancellation.dart';
import '../scheduling/preparation_worker.dart';

/// Worker operation name of the layered layout.
const String graphLayoutOperation = 'graph.layout';

/// Nodes one worker chunk walks before yielding to its own event loop.
///
/// The worker's event loop is where a cancel message is received, so this is
/// the honest cancellation boundary for a CPU-bound layout.
const int graphLayoutYieldEveryNodes = 64;

/// One node as the layout worker sees it.
///
/// Only topology crosses the isolate boundary: no status, no title, no source
/// text. A layout result therefore cannot depend on, or leak, status data.
final class GraphLayoutNodeInput {
  const GraphLayoutNodeInput({
    required this.id,
    required this.projectIndex,
    this.laneIndex,
    this.collapsed = false,
  });

  final String id;
  final int projectIndex;
  final int? laneIndex;
  final bool collapsed;
}

/// Everything one layout attempt needs.
final class GraphLayoutRequest {
  GraphLayoutRequest({
    required this.topologyRevision,
    required Iterable<GraphLayoutNodeInput> nodes,
    Iterable<(String, String)> requiresEdges = const <(String, String)>[],
    required Iterable<String> laneOrder,
    this.visibleLimit = graphResourceDefaultVisibleNodes,
  }) : nodes = List<GraphLayoutNodeInput>.unmodifiable(nodes),
       requiresEdges = List<(String, String)>.unmodifiable(requiresEdges),
       laneOrder = List<String>.unmodifiable(laneOrder);

  /// Revision of the topology this attempt places.
  final int topologyRevision;

  final List<GraphLayoutNodeInput> nodes;

  /// Dependency edges (`requires` and `successor`), as identity pairs.
  final List<(String, String)> requiresEdges;

  final List<String> laneOrder;
  final int visibleLimit;

  int get nodeCount => nodes.length;
}

/// Payload the worker operation accepts: `[request]`, encoded as plain lists.
List<Object?> encodeGraphLayoutRequest(GraphLayoutRequest request) => <Object?>[
  request.topologyRevision,
  request.visibleLimit,
  <String>[...request.laneOrder],
  <Object?>[
    for (final node in request.nodes)
      <Object?>[node.id, node.projectIndex, node.laneIndex, node.collapsed],
  ],
  <Object?>[
    for (final edge in request.requiresEdges) <Object?>[edge.$1, edge.$2],
  ],
];

/// Decodes one worker result into a [GraphLayout].
GraphLayout decodeGraphLayout(Object? payload) {
  final result = payload! as List<Object?>;
  final topologyRevision = result[0]! as int;
  final visibleLimit = result[1]! as int;
  final layerOf = <String, int>{};
  final positionInLayer = <String, int>{};
  final layerSizes = <String, int>{};
  final nodeIds = result[2]! as List<Object?>;
  final layers = result[3]! as List<Object?>;
  final positions = result[4]! as List<Object?>;
  final sizes = result[5]! as List<Object?>;
  for (var index = 0; index < nodeIds.length; index++) {
    final id = nodeIds[index]! as String;
    layerOf[id] = layers[index]! as int;
    positionInLayer[id] = positions[index]! as int;
    layerSizes[id] = sizes[index]! as int;
  }
  return GraphLayout(
    topologyRevision: topologyRevision,
    layerOf: layerOf,
    positionInLayer: positionInLayer,
    layerSizes: layerSizes,
    visibleNodeIds: <String>[
      for (final id in result[6]! as List<Object?>) id! as String,
    ],
    laneOrder: <String>[
      for (final id in result[7]! as List<Object?>) id! as String,
    ],
    visibleLimit: visibleLimit,
  );
}

/// Worker-isolate entry point of one layout attempt.
///
/// Public because `Isolate.spawn` needs a top-level tear-off; it is not part of
/// the presentation API.
Future<Object?> runGraphLayout(
  Object? payload,
  WorkerJobContext context,
) async {
  final encoded = payload! as List<Object?>;
  final topologyRevision = encoded[0]! as int;
  final visibleLimit = encoded[1]! as int;
  final laneOrder = <String>[
    for (final id in encoded[2]! as List<Object?>) id! as String,
  ];
  final nodes = <GraphLayoutNodeInput>[];
  for (final entry in encoded[3]! as List<Object?>) {
    final node = entry! as List<Object?>;
    nodes.add(
      GraphLayoutNodeInput(
        id: node[0]! as String,
        projectIndex: node[1]! as int,
        laneIndex: node[2] as int?,
        collapsed: node[3] == true,
      ),
    );
  }
  final edges = <(String, String)>[];
  for (final entry in encoded[4]! as List<Object?>) {
    final edge = entry! as List<Object?>;
    edges.add((edge[0]! as String, edge[1]! as String));
  }
  final placement = await planGraphLayout(
    GraphLayoutRequest(
      topologyRevision: topologyRevision,
      nodes: nodes,
      requiresEdges: edges,
      laneOrder: laneOrder,
      visibleLimit: visibleLimit,
    ),
    context,
  );
  return <Object?>[
    placement.topologyRevision,
    placement.visibleLimit,
    <Object?>[for (final node in nodes) node.id],
    <Object?>[for (final node in nodes) placement.layerOf[node.id]],
    <Object?>[for (final node in nodes) placement.positionInLayer[node.id]],
    <Object?>[for (final node in nodes) placement.layerSizes[node.id]],
    <Object?>[...placement.visibleNodeIds],
    <Object?>[...placement.laneOrder],
  ];
}

/// The deterministic layered placement itself.
///
/// Longest-path layering over the declared dependency edges, stable ordering by
/// project, lane and declaration order, and — for a producer that declared a
/// legal cycle through `visit` edges — leftover nodes placed after their
/// resolved predecessors in declaration order rather than dropped.
Future<GraphLayout> planGraphLayout(
  GraphLayoutRequest request,
  WorkerJobContext context,
) async {
  final indexOf = <String, int>{
    for (var index = 0; index < request.nodes.length; index++)
      request.nodes[index].id: index,
  };
  final successors = <int, List<int>>{};
  final inDegree = List<int>.filled(request.nodes.length, 0);
  final layer = List<int>.filled(request.nodes.length, 0);
  for (final edge in request.requiresEdges) {
    final from = indexOf[edge.$1];
    final to = indexOf[edge.$2];
    if (from == null || to == null || from == to) continue;
    (successors[from] ??= <int>[]).add(to);
    inDegree[to]++;
  }

  // Kahn's algorithm with a declaration-order queue keeps the traversal
  // deterministic; a node only advances after every dependency did.
  final queue = <int>[];
  for (var index = 0; index < inDegree.length; index++) {
    if (inDegree[index] == 0) queue.add(index);
  }
  final resolved = List<bool>.filled(request.nodes.length, false);
  var visited = 0;
  for (var cursor = 0; cursor < queue.length; cursor++) {
    final node = queue[cursor];
    resolved[node] = true;
    visited++;
    for (final successor in successors[node] ?? const <int>[]) {
      if (layer[successor] < layer[node] + 1) {
        layer[successor] = layer[node] + 1;
      }
      inDegree[successor]--;
      if (inDegree[successor] == 0) queue.add(successor);
    }
    if (context.isCancelled) {
      throw const PreparationCancelledException(
        PreparationCancellationReason.superseded,
        stage: 'graph-layout',
      );
    }
    if (visited % graphLayoutYieldEveryNodes == 0) {
      await context.yieldToControl();
    }
  }

  // Leftovers sit on a declared cycle. They keep declaration order and are
  // placed after their resolved predecessors instead of being dropped.
  if (visited < request.nodes.length) {
    var extra = 0;
    for (var index = 0; index < request.nodes.length; index++) {
      if (resolved[index]) continue;
      for (final edge in request.requiresEdges) {
        if (edge.$2 != request.nodes[index].id) continue;
        final from = indexOf[edge.$1];
        if (from != null && resolved[from] && layer[index] < layer[from] + 1) {
          layer[index] = layer[from] + 1;
        }
      }
      extra++;
      if (extra % graphLayoutYieldEveryNodes == 0) {
        await context.yieldToControl();
      }
    }
  }

  // Stable order inside one layer: project declaration order, lane order, then
  // the node's own declaration index. The comparison never looks at status, so
  // the same topology always produces the same coordinates.
  final ordered = List<int>.generate(request.nodes.length, (index) => index);
  ordered.sort((left, right) {
    final leftNode = request.nodes[left];
    final rightNode = request.nodes[right];
    final byProject = leftNode.projectIndex.compareTo(rightNode.projectIndex);
    if (byProject != 0) return byProject;
    final leftLane = leftNode.laneIndex ?? 1 << 20;
    final rightLane = rightNode.laneIndex ?? 1 << 20;
    if (leftLane != rightLane) return leftLane.compareTo(rightLane);
    return left.compareTo(right);
  });

  final positionInLayer = List<int>.filled(request.nodes.length, 0);
  final layerSizes = <int, int>{};
  for (final index in ordered) {
    final size = layerSizes[layer[index]] ?? 0;
    positionInLayer[index] = size;
    layerSizes[layer[index]] = size + 1;
  }

  // The visible window is a stable round-robin sample of every lane, so one
  // large lane cannot hide the others and status churn cannot move the window.
  final perLane = <String, List<int>>{};
  for (final index in ordered) {
    final node = request.nodes[index];
    final key = '${node.projectIndex}:${node.laneIndex ?? -1}';
    (perLane[key] ??= <int>[]).add(index);
  }
  final cursors = <String, int>{for (final key in perLane.keys) key: 0};
  final visible = <String>[];
  final chosen = <String>{};
  while (visible.length < request.visibleLimit) {
    var progressed = false;
    for (final key in perLane.keys) {
      if (visible.length >= request.visibleLimit) break;
      final lane = perLane[key]!;
      final cursor = cursors[key]!;
      if (cursor >= lane.length) continue;
      cursors[key] = cursor + 1;
      progressed = true;
      final node = request.nodes[lane[cursor]];
      if (node.collapsed) continue;
      if (chosen.add(node.id)) visible.add(node.id);
    }
    if (!progressed) break;
    if (context.isCancelled) {
      throw const PreparationCancelledException(
        PreparationCancellationReason.superseded,
        stage: 'graph-layout',
      );
    }
  }
  // A producer that collapsed every lane, or a document with more lanes than
  // the window can sample, still counts: the window falls back to the remaining
  // nodes rather than shrinking the goal.
  if (visible.length < request.visibleLimit) {
    for (final index in ordered) {
      if (visible.length >= request.visibleLimit) break;
      final id = request.nodes[index].id;
      if (chosen.add(id)) visible.add(id);
    }
  }
  // Fairness decides *which* nodes the window samples; causality decides the
  // order they are read in, so the window is a left-to-right causal slice
  // instead of an arbitrary pick order.
  final windowOrder = <String, int>{
    for (final index in ordered) request.nodes[index].id: index,
  };
  visible.sort((left, right) {
    final leftIndex = windowOrder[left]!;
    final rightIndex = windowOrder[right]!;
    final byLayer = layer[leftIndex].compareTo(layer[rightIndex]);
    if (byLayer != 0) return byLayer;
    final byPosition = positionInLayer[leftIndex].compareTo(
      positionInLayer[rightIndex],
    );
    if (byPosition != 0) return byPosition;
    return leftIndex.compareTo(rightIndex);
  });

  final layerOf = <String, int>{};
  final positions = <String, int>{};
  final sizes = <String, int>{};
  for (var index = 0; index < request.nodes.length; index++) {
    final id = request.nodes[index].id;
    layerOf[id] = layer[index];
    positions[id] = positionInLayer[index];
    sizes[id] = layerSizes[layer[index]] ?? 1;
  }
  return GraphLayout(
    topologyRevision: request.topologyRevision,
    layerOf: layerOf,
    positionInLayer: positions,
    layerSizes: sizes,
    visibleNodeIds: visible,
    laneOrder: request.laneOrder,
    visibleLimit: request.visibleLimit,
  );
}
