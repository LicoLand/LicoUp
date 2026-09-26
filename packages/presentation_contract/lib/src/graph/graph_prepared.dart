/// The prepared form of one graph document.
///
/// Topology and high-frequency status prepare separately: a revision that only
/// changes status must not re-run the layered layout, and the prepared value
/// says exactly what it touched. The document itself is carried by reference —
/// it is immutable, so graph and detail can never mix two revisions.
library;

import 'graph_resource.dart';

/// One stable layered placement produced by the layout worker.
///
/// The placement is a pure function of topology plus the expansion state: the
/// same inputs give the same coordinates and the same visible window, so a
/// rebuild, a status update or a reconnect cannot move a node the user was
/// looking at.
final class GraphLayout {
  GraphLayout({
    required this.topologyRevision,
    required Map<String, int> layerOf,
    required Map<String, int> positionInLayer,
    required Map<String, int> layerSizes,
    required List<String> visibleNodeIds,
    required List<String> laneOrder,
    required this.visibleLimit,
  }) : layerOf = Map<String, int>.unmodifiable(layerOf),
       positionInLayer = Map<String, int>.unmodifiable(positionInLayer),
       layerSizes = Map<String, int>.unmodifiable(layerSizes),
       visibleNodeIds = List<String>.unmodifiable(visibleNodeIds),
       laneOrder = List<String>.unmodifiable(laneOrder);

  /// Empty placement used before the first layout arrives.
  static final GraphLayout empty = GraphLayout(
    topologyRevision: 0,
    layerOf: const <String, int>{},
    positionInLayer: const <String, int>{},
    layerSizes: const <String, int>{},
    visibleNodeIds: const <String>[],
    laneOrder: const <String>[],
    visibleLimit: graphResourceDefaultVisibleNodes,
  );

  /// Topology revision this placement was computed for.
  final int topologyRevision;

  /// Causal column of each node. Horizontal order is causality, not time.
  final Map<String, int> layerOf;

  /// Position of each node inside its layer.
  final Map<String, int> positionInLayer;

  /// Total nodes per layer, so a visible window can show its own extent.
  final Map<String, int> layerSizes;

  /// The visible window, frontier and anomalies first.
  final List<String> visibleNodeIds;

  /// Stable lane order.
  final List<String> laneOrder;

  /// Window size this placement virtualized to.
  final int visibleLimit;

  /// Number of layers the placement has.
  int get layerCount {
    var maximum = 0;
    for (final layer in layerOf.values) {
      if (layer + 1 > maximum) maximum = layer + 1;
    }
    return maximum;
  }

  @override
  String toString() =>
      'GraphLayout(rev $topologyRevision, ${layerOf.length} placed, '
      '${visibleNodeIds.length} visible)';
}

/// The status dimensions and reasons of one node.
final class GraphStatusEntry {
  GraphStatusEntry({
    required this.nodeId,
    required this.execution,
    required this.acceptance,
    required this.observation,
    required this.ready,
    required this.startable,
    required this.role,
    this.route,
    this.laneId,
    this.gateId,
    Iterable<GraphBlocker> blockers = const <GraphBlocker>[],
    this.attemptCount = 0,
    this.visitCount = 0,
    this.eventCount = 0,
    this.evidenceCount = 0,
    this.lastErrorCode,
    this.lastEventKind,
  }) : blockers = List<GraphBlocker>.unmodifiable(blockers);

  final String nodeId;
  final GraphExecutionState execution;
  final GraphAcceptanceState acceptance;
  final GraphObservationState observation;
  final bool ready;
  final bool startable;
  final String role;
  final String? route;
  final String? laneId;
  final String? gateId;
  final List<GraphBlocker> blockers;
  final int attemptCount;
  final int visitCount;
  final int eventCount;
  final int evidenceCount;
  final String? lastErrorCode;
  final String? lastEventKind;

  GraphBlocker? get mainBlocker => blockers.isEmpty ? null : blockers.first;

  bool get isAnomaly =>
      observation == GraphObservationState.stale ||
      execution == GraphExecutionState.failed ||
      acceptance == GraphAcceptanceState.rejected ||
      (!startable && ready) ||
      blockers.any(
        (blocker) =>
            blocker.code == GraphBlockerCode.conflictingWriter ||
            blocker.code == GraphBlockerCode.observationStale,
      );

  /// The status fields a card shows, as a stable comparison key.
  int get statusSignature => Object.hash(
    execution,
    acceptance,
    observation,
    ready,
    startable,
    _blockerHash(blockers),
  );

  static int _blockerHash(List<GraphBlocker> blockers) {
    var hash = 0;
    for (final blocker in blockers) {
      hash ^= Object.hash(blocker.code, blocker.detail, blocker.affects.length);
    }
    return hash;
  }

  @override
  String toString() =>
      'GraphStatusEntry($nodeId, ${execution.wireName}/${acceptance.wireName}/'
      '${observation.wireName})';
}

/// Complete counts of one lane.
///
/// Counts cover every node of the lane, whether or not it is in the visible
/// window and whether or not its project is expanded: collapsing changes what
/// is drawn, never what is counted.
final class GraphLaneSummary {
  const GraphLaneSummary({
    required this.laneId,
    required this.title,
    required this.total,
    required this.ready,
    required this.startable,
    required this.running,
    required this.accepted,
    required this.blocked,
    required this.stale,
  });

  final String laneId;
  final String title;
  final int total;
  final int ready;
  final int startable;
  final int running;
  final int accepted;
  final int blocked;
  final int stale;

  @override
  String toString() => 'GraphLaneSummary($laneId, $total nodes)';
}

/// Complete counts of one project.
final class GraphProjectSummary {
  const GraphProjectSummary({
    required this.projectId,
    required this.title,
    required this.total,
    required this.ready,
    required this.startable,
    required this.running,
    required this.accepted,
    required this.blocked,
    required this.stale,
  });

  final String projectId;
  final String title;
  final int total;
  final int ready;
  final int startable;
  final int running;
  final int accepted;
  final int blocked;
  final int stale;

  @override
  String toString() => 'GraphProjectSummary($projectId, $total nodes)';
}

/// What one preparation actually touched.
///
/// This is measurement, not decoration: a status-only preparation must report
/// a bounded touched set and no layout run, so a full rebuild is visible as a
/// failure instead of passing as an equivalent implementation.
final class GraphPreparedChange {
  const GraphPreparedChange({
    required this.layoutComputed,
    required this.touchedNodeIds,
    required this.recomputedStatusCount,
    required this.touchedEdgeIds,
  });

  static const GraphPreparedChange initial = GraphPreparedChange(
    layoutComputed: true,
    touchedNodeIds: <String>{},
    recomputedStatusCount: 0,
    touchedEdgeIds: <String>{},
  );

  /// Whether the layered layout ran for this revision.
  final bool layoutComputed;

  /// Nodes whose placed entry changed.
  final Set<String> touchedNodeIds;

  /// Status entries recomputed, not reused.
  final int recomputedStatusCount;

  /// Edges whose routed endpoints changed.
  final Set<String> touchedEdgeIds;

  @override
  String toString() =>
      'GraphPreparedChange(layout: $layoutComputed, '
      '${touchedNodeIds.length} nodes, $recomputedStatusCount statuses)';
}

/// One renderer-ready graph value.
final class GraphPreparedValue {
  GraphPreparedValue({
    required this.document,
    required this.layout,
    required Map<String, GraphStatusEntry> statusById,
    required Map<String, GraphLaneSummary> laneSummaries,
    required Map<String, GraphProjectSummary> projectSummaries,
    required Map<String, String> gateRepresentative,
    required this.change,
  }) : statusById = Map<String, GraphStatusEntry>.unmodifiable(statusById),
       laneSummaries = Map<String, GraphLaneSummary>.unmodifiable(
         laneSummaries,
       ),
       projectSummaries = Map<String, GraphProjectSummary>.unmodifiable(
         projectSummaries,
       ),
       gateRepresentative = Map<String, String>.unmodifiable(
         gateRepresentative,
       );

  /// The immutable document this value was prepared from.
  final GraphResourceValue document;

  final GraphLayout layout;

  /// Status of every node of the document.
  final Map<String, GraphStatusEntry> statusById;

  final Map<String, GraphLaneSummary> laneSummaries;
  final Map<String, GraphProjectSummary> projectSummaries;

  /// The one representative anchor of each shared gate.
  ///
  /// Every anchor of a gate resolves to the same representative, so a gate
  /// keeps one identity, one count and one run however many anchors it has.
  final Map<String, String> gateRepresentative;

  final GraphPreparedChange change;

  int get planRevision => document.planRevision;

  GraphStatusEntry? statusOf(String nodeId) => statusById[nodeId];

  @override
  String toString() =>
      'GraphPreparedValue(rev $planRevision, ${statusById.length} statuses)';
}
