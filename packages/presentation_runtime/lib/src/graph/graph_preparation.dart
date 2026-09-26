/// Prepared graph installation over the shared preparation pipeline.
///
/// One controller follows one document source. A revision whose topology
/// changed runs the layered placement in a real worker isolate through the
/// runtime's preparation admission; a revision that only changed status merges
/// the affected entries locally and never re-runs layout. Both install through
/// [PreparedDisplay], so a superseded or revoked result can never become
/// visible, and withdrawal hides labels, counts and anchors at once.
library;

import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import '../presentation_runtime.dart';
import '../resources/prepared_display.dart';
import '../resources/resource_observation.dart';
import '../scheduling/preparation_cancellation.dart';
import '../scheduling/preparation_executor.dart' show PreparationPriority;
import '../scheduling/preparation_worker.dart';
import '../scheduling/preparation_worker_pool.dart';
import 'graph_layout_engine.dart';

/// Field group name of the admitted document.
const String graphDocumentField = 'document';

/// Field group name of the prepared renderable value.
const String graphPreparedField = 'prepared';

/// The admitted document field group of one graph resource.
ResourceFieldGroup<GraphDocumentUpdate> graphDocumentFieldGroupFor(
  ResourceKey resource,
) => ResourceFieldGroup<GraphDocumentUpdate>(
  resource: resource,
  name: graphDocumentField,
);

/// The prepared field group of one graph resource.
ResourceFieldGroup<GraphPreparedValue> graphPreparedFieldGroupFor(
  ResourceKey resource,
) => ResourceFieldGroup<GraphPreparedValue>(
  resource: resource,
  name: graphPreparedField,
);

/// One admitted graph revision with the producer's own change declaration.
///
/// [changedNodeIds] is producer fact, not a hint the interface may invent: a
/// revision that only restates the document passes an empty set and costs
/// nothing, while `null` honestly says "changed nodes unknown" and costs a full
/// status recompute. [topologyChanged] says whether structure moved, so a
/// status update can never trigger a re-layout.
final class GraphDocumentUpdate {
  GraphDocumentUpdate({
    required this.document,
    Set<String>? changedNodeIds,
    this.topologyChanged = false,
  }) : changedNodeIds = changedNodeIds == null
           ? null
           : Set<String>.unmodifiable(changedNodeIds);

  final GraphResourceValue document;
  final Set<String>? changedNodeIds;
  final bool topologyChanged;

  @override
  String toString() =>
      'GraphDocumentUpdate(rev ${document.planRevision}, '
      '${changedNodeIds?.length ?? 'unknown'} changed)';
}

/// Measurement of one controller's real preparation behavior.
final class GraphPreparationStats {
  const GraphPreparationStats({
    required this.layoutRuns,
    required this.statusMerges,
    required this.lastRecomputedStatuses,
    required this.lastTouchedNodes,
    required this.lastTouchedEdges,
    required this.lastLayoutDuration,
    this.lastWorker,
  });

  /// Times the layered layout actually ran in a worker.
  final int layoutRuns;

  /// Times a status-only revision merged locally.
  final int statusMerges;

  /// Status entries recomputed by the last preparation.
  final int lastRecomputedStatuses;

  final int lastTouchedNodes;
  final int lastTouchedEdges;
  final Duration lastLayoutDuration;

  /// Identity of the worker that answered the last layout, when one ran.
  final PreparationWorkerIdentity? lastWorker;

  bool get layoutRanInRealWorker =>
      lastWorker != null && !lastWorker!.runsInCallerIsolate;
}

/// Merges one admitted revision into a renderer-ready value.
///
/// [changedNodeIds] `null` means the producer did not declare a change set: the
/// merge then recomputes every status entry and reports it, so a caller that
/// wants locality can observe the difference instead of trusting a claim.
GraphPreparedValue mergeGraphPreparedValue({
  required GraphResourceValue document,
  required GraphLayout layout,
  required GraphPreparedValue? previous,
  required Set<String>? changedNodeIds,
  required bool layoutComputed,
}) {
  final index = document.index;
  final previousStatuses = previous?.statusById;
  final statuses = <String, GraphStatusEntry>{};
  var recomputed = 0;
  final touchedNodes = <String>{};
  final previousLayout = previous?.layout;
  for (final id in index.nodeOrder) {
    final node = index.nodeById[id]!;
    final prior = previousStatuses == null ? null : previousStatuses[id];
    // A node the producer did not declare changed keeps its entry object, so a
    // high-frequency update cannot repaint or recompute the rest of the graph.
    if (changedNodeIds != null &&
        !changedNodeIds.contains(id) &&
        prior != null) {
      statuses[id] = prior;
      continue;
    }
    statuses[id] = _statusEntry(node);
    recomputed++;
    if (layoutComputed &&
        (previousLayout == null ||
            previousLayout.layerOf[id] != layout.layerOf[id] ||
            previousLayout.positionInLayer[id] != layout.positionInLayer[id])) {
      touchedNodes.add(id);
    }
  }

  final gateRepresentative = layoutComputed || previous == null
      ? _gateRepresentatives(document, layout)
      : Map<String, String>.of(previous.gateRepresentative);

  final (laneSummaries, projectSummaries) = _summaries(
    document: document,
    statuses: statuses,
    previous: previous,
    changedNodeIds: changedNodeIds,
    previousStatuses: previousStatuses,
  );

  final touchedEdges = layoutComputed
      ? <String>{for (final edge in document.edges) edge.id}
      : const <String>{};
  return GraphPreparedValue(
    document: document,
    layout: layout,
    statusById: statuses,
    laneSummaries: laneSummaries,
    projectSummaries: projectSummaries,
    gateRepresentative: gateRepresentative,
    change: GraphPreparedChange(
      layoutComputed: layoutComputed,
      touchedNodeIds: layoutComputed ? touchedNodes : const <String>{},
      recomputedStatusCount: recomputed,
      touchedEdgeIds: touchedEdges,
    ),
  );
}

GraphStatusEntry _statusEntry(GraphNode node) {
  final attempts = node.attempts;
  final events = node.events;
  String? errorCode;
  for (final attempt in attempts.reversed) {
    if (attempt.state == GraphAttemptState.failed &&
        attempt.errorCode != null) {
      errorCode = attempt.errorCode;
      break;
    }
  }
  return GraphStatusEntry(
    nodeId: node.id,
    execution: node.execution,
    acceptance: node.acceptance,
    observation: node.observation,
    ready: node.ready,
    startable: node.startable,
    role: node.role,
    route: node.route,
    laneId: node.laneId,
    gateId: node.gateId,
    blockers: node.blockers,
    attemptCount: attempts.length,
    visitCount: node.visits.length,
    eventCount: events.length,
    evidenceCount: node.evidence.length,
    lastErrorCode: errorCode,
    lastEventKind: events.isEmpty ? null : events.last.kind,
  );
}

Map<String, String> _gateRepresentatives(
  GraphResourceValue document,
  GraphLayout layout,
) {
  final representatives = <String, String>{};
  // Walk nodes in stable placement order so the representative is a function of
  // topology: every anchor of a gate resolves to the same first anchor.
  final placed = <String>[for (final id in layout.layerOf.keys) id]
    ..sort((left, right) {
      final byLayer = layout.layerOf[left]!.compareTo(layout.layerOf[right]!);
      if (byLayer != 0) return byLayer;
      return layout.positionInLayer[left]!.compareTo(
        layout.positionInLayer[right]!,
      );
    });
  for (final id in placed) {
    final gateId = document.index.nodeById[id]?.gateId;
    if (gateId != null) representatives.putIfAbsent(gateId, () => id);
  }
  for (final project in document.projects) {
    for (final gate in project.gates) {
      for (final anchor in gate.anchors) {
        representatives.putIfAbsent(gate.id, () => anchor);
      }
    }
  }
  return representatives;
}

/// The eight complete counters of one node, `0` when it has no entry yet.
typedef _NodeCounters = (
  int total,
  int ready,
  int startable,
  int running,
  int accepted,
  int blocked,
  int stale,
  int failed,
);

_NodeCounters _counters(GraphStatusEntry? entry) {
  if (entry == null) return (0, 0, 0, 0, 0, 0, 0, 0);
  final failed = entry.execution == GraphExecutionState.failed ? 1 : 0;
  return (
    1,
    entry.ready ? 1 : 0,
    entry.startable ? 1 : 0,
    entry.execution == GraphExecutionState.running ? 1 : 0,
    entry.acceptance == GraphAcceptanceState.accepted ? 1 : 0,
    !entry.startable && entry.blockers.isNotEmpty ? 1 : 0,
    entry.observation == GraphObservationState.stale ? 1 : 0,
    failed,
  );
}

(Map<String, GraphLaneSummary>, Map<String, GraphProjectSummary>) _summaries({
  required GraphResourceValue document,
  required Map<String, GraphStatusEntry> statuses,
  required GraphPreparedValue? previous,
  required Set<String>? changedNodeIds,
  required Map<String, GraphStatusEntry>? previousStatuses,
}) {
  final laneTitles = <String, String>{};
  final projectTitles = <String, String>{};
  for (final project in document.projects) {
    projectTitles[project.id] = project.title;
    for (final lane in project.lanes) {
      laneTitles[lane.id] = lane.title;
    }
  }

  // Mutable counters keyed by lane and project. A status-only merge starts from
  // the previous totals and applies one delta per changed node, so nothing else
  // is recomputed.
  final incremental = previous != null && changedNodeIds != null;
  final laneTotals = <String, List<int>>{
    for (final lane in laneTitles.keys) lane: List<int>.filled(8, 0),
  };
  final projectTotals = <String, List<int>>{
    for (final project in document.projects) project.id: List<int>.filled(8, 0),
  };
  if (incremental) {
    for (final entry in previous.laneSummaries.entries) {
      _loadTotals(
        laneTotals[entry.key],
        entry.value.total,
        entry.value.ready,
        entry.value.startable,
        entry.value.running,
        entry.value.accepted,
        entry.value.blocked,
        entry.value.stale,
      );
    }
    for (final entry in previous.projectSummaries.entries) {
      _loadTotals(
        projectTotals[entry.key],
        entry.value.total,
        entry.value.ready,
        entry.value.startable,
        entry.value.running,
        entry.value.accepted,
        entry.value.blocked,
        entry.value.stale,
      );
    }
  }

  final ids = incremental
      ? changedNodeIds.where(statuses.containsKey).toList(growable: false)
      : statuses.keys.toList(growable: false);
  for (final id in ids) {
    final projectId = document.index.projectOfNode[id];
    if (projectId == null) continue;
    final entry = statuses[id];
    final laneId = entry?.laneId ?? document.index.laneOfNode[id];
    if (incremental && previousStatuses != null) {
      final old = _counters(previousStatuses[id]);
      _apply(projectTotals[projectId], old, -1);
      if (laneId != null) _apply(laneTotals[laneId], old, -1);
    }
    final next = _counters(entry);
    _apply(projectTotals[projectId], next, 1);
    if (laneId != null) _apply(laneTotals[laneId], next, 1);
  }

  final laneSummaries = <String, GraphLaneSummary>{};
  for (final lane in laneTotals.keys) {
    final totals = laneTotals[lane]!;
    laneSummaries[lane] = GraphLaneSummary(
      laneId: lane,
      title: laneTitles[lane] ?? lane,
      total: totals[0],
      ready: totals[1],
      startable: totals[2],
      running: totals[3],
      accepted: totals[4],
      blocked: totals[5],
      stale: totals[6],
    );
  }
  final projectSummaries = <String, GraphProjectSummary>{};
  for (final project in projectTotals.keys) {
    final totals = projectTotals[project]!;
    projectSummaries[project] = GraphProjectSummary(
      projectId: project,
      title: projectTitles[project] ?? project,
      total: totals[0],
      ready: totals[1],
      startable: totals[2],
      running: totals[3],
      accepted: totals[4],
      blocked: totals[5],
      stale: totals[6],
    );
  }
  return (laneSummaries, projectSummaries);
}

void _loadTotals(
  List<int>? target,
  int total,
  int ready,
  int startable,
  int running,
  int accepted,
  int blocked,
  int stale,
) {
  if (target == null) return;
  target[0] = total;
  target[1] = ready;
  target[2] = startable;
  target[3] = running;
  target[4] = accepted;
  target[5] = blocked;
  target[6] = stale;
}

void _apply(List<int>? target, _NodeCounters counters, int sign) {
  if (target == null) return;
  target[0] += counters.$1 * sign;
  target[1] += counters.$2 * sign;
  target[2] += counters.$3 * sign;
  target[3] += counters.$4 * sign;
  target[4] += counters.$5 * sign;
  target[5] += counters.$6 * sign;
  target[6] += counters.$7 * sign;
  target[7] += counters.$8 * sign;
}

/// Follows one graph document source and installs prepared values.
final class GraphPreparationController {
  GraphPreparationController({
    required PresentationRuntime runtime,
    required PresentationSource<GraphDocumentUpdate> source,
    this.visibleLimit = graphResourceDefaultVisibleNodes,
  }) : _runtime = runtime,
       _source = source,
       _documentField = source.fieldGroup,
       _preparedField = graphPreparedFieldGroupFor(source.fieldGroup.resource);

  final PresentationRuntime _runtime;
  final PresentationSource<GraphDocumentUpdate> _source;
  final ResourceFieldGroup<GraphDocumentUpdate> _documentField;
  final ResourceFieldGroup<GraphPreparedValue> _preparedField;

  /// Nodes the layout worker places into the visible window.
  final int visibleLimit;

  final StreamController<GraphPreparedValue?> _displayed =
      StreamController<GraphPreparedValue?>.broadcast(sync: true);
  GraphPreparedValue? _current;
  PreparedDisplay<GraphPreparedValue>? _display;
  ResourceObservationSubscription<GraphDocumentUpdate>? _observation;
  PreparationCancellationToken? _layoutCancel;
  Future<PreparationWorkerPool>? _pool;
  bool _active = false;
  bool _disposed = false;
  String? _localUnavailable;
  int _layoutRuns = 0;
  int _statusMerges = 0;
  GraphPreparedChange _lastChange = GraphPreparedChange.initial;
  Duration _lastLayoutDuration = Duration.zero;
  PreparationWorkerIdentity? _lastWorker;

  /// The installed prepared value, or null while loading, unavailable or
  /// withdrawn. A withdrawn authority clears it immediately.
  GraphPreparedValue? get current => _current;

  /// Every installed value and every withdrawal, in order.
  Stream<GraphPreparedValue?> get displayed => _displayed.stream;

  void _setDisplayed(GraphPreparedValue? value) {
    _current = value;
    if (!_displayed.isClosed) _displayed.add(value);
  }

  /// Prepared field group this controller installs into.
  ResourceFieldGroup<GraphPreparedValue> get preparedField => _preparedField;

  ResourceKey get resource => _documentField.resource;

  /// A host-local reason nothing can be shown, or null.
  String? get localUnavailableReason => _localUnavailable;

  GraphPreparationStats get stats => GraphPreparationStats(
    layoutRuns: _layoutRuns,
    statusMerges: _statusMerges,
    lastRecomputedStatuses: _lastChange.recomputedStatusCount,
    lastTouchedNodes: _lastChange.touchedNodeIds.length,
    lastTouchedEdges: _lastChange.touchedEdgeIds.length,
    lastLayoutDuration: _lastLayoutDuration,
    lastWorker: _lastWorker,
  );

  /// Observes the source through the runtime and prepares every revision.
  void start() {
    if (_disposed || _active) return;
    _active = true;
    final display = _runtime.preparedDisplay<GraphPreparedValue>();
    _display = display;
    display.onInstalled(_onInstalled);
    display.onWithdrawn(_onWithdrawn);
    // A value another session already installed at this position is this
    // session's starting value: a remount after an epoch change renders the
    // admitted revision instead of waiting for a new install event.
    final installed = display.current(_preparedField)?.value;
    if (installed != null) _setDisplayed(installed);
    try {
      final observation = _runtime.observe(_source);
      _observation = observation;
      observation.stream.listen(
        _onSnapshot,
        onError: (Object error, StackTrace stack) => _onSourceError(),
      );
    } on Object {
      // The reason is set before the frame drops, so the placeholder names the
      // real cause instead of a generic loading state.
      _localUnavailable = 'binding_unavailable';
      _setDisplayed(null);
    }
  }

  /// Stops following the source. Work already accepted keeps running and its
  /// result installs nowhere; nothing durable is cancelled here.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _active = false;
    _layoutCancel?.cancel(PreparationCancellationReason.disposed);
    _layoutCancel = null;
    final observation = _observation;
    _observation = null;
    if (observation != null) unawaited(observation.close());
    final pool = _pool;
    _pool = null;
    if (pool != null) {
      // The pool is released only after an accepted job settles, so a caller
      // that stops watching the view does not kill preparation that was
      // already admitted.
      unawaited(() async {
        final value = await pool;
        await value.idle;
        await value.dispose();
      }());
    }
    _setDisplayed(null);
    unawaited(_displayed.close());
  }

  Future<PreparationWorkerPool> _workerPool() {
    final existing = _pool;
    if (existing != null) return existing;
    final spawned = PreparationWorkerPool.spawn(
      name: 'presentation-graph',
      operations: const <String, PreparationWorkerOperation>{
        graphLayoutOperation: runGraphLayout,
      },
      workers: 1,
    );
    _pool = spawned;
    return spawned;
  }

  void _onSnapshot(ResourceSnapshot<GraphDocumentUpdate> snapshot) {
    if (!_active || _disposed) return;
    final update = snapshot.value;
    final previous = _current;
    final topologyChanged =
        update.topologyChanged ||
        previous == null ||
        _display?.current(_preparedField) == null;
    if (topologyChanged) {
      unawaited(_prepareLayout(snapshot, previous));
    } else {
      unawaited(_mergeStatus(snapshot, previous));
    }
  }

  Future<void> _prepareLayout(
    ResourceSnapshot<GraphDocumentUpdate> snapshot,
    GraphPreparedValue? previous,
  ) async {
    _layoutCancel?.cancel(PreparationCancellationReason.superseded);
    final token = PreparationCancellationToken();
    _layoutCancel = token;
    final update = snapshot.value;
    final layout = await _runLayoutWorker(update, token);
    if (layout == null || token.isCancelled || !_active) return;
    final merged = mergeGraphPreparedValue(
      document: update.document,
      layout: layout,
      previous: previous,
      changedNodeIds: update.changedNodeIds,
      layoutComputed: true,
    );
    await _offer(snapshot, merged);
  }

  Future<GraphLayout?> _runLayoutWorker(
    GraphDocumentUpdate update,
    PreparationCancellationToken token,
  ) async {
    final document = update.document;
    final request = _layoutRequest(document);
    final watch = Stopwatch()..start();
    try {
      final pool = await _workerPool();
      if (token.isCancelled || !_active) return null;
      final result = await pool.execute(
        operation: graphLayoutOperation,
        payload: encodeGraphLayoutRequest(request),
        cancel: token,
        priority: PreparationPriority.foreground,
        onWorker: (identity) => _lastWorker = identity,
        estimatedBytes: request.nodeCount * 48,
      );
      watch.stop();
      _layoutRuns++;
      _lastLayoutDuration = watch.elapsed;
      return decodeGraphLayout(result);
    } on PreparationFailure {
      return null;
    } on Object {
      if (_active) _localUnavailable = 'layout_unavailable';
      return null;
    }
  }

  GraphLayoutRequest _layoutRequest(GraphResourceValue document) {
    final index = document.index;
    final laneOrder = <String>[
      for (final project in document.projects)
        for (final lane
            in (project.lanes.toList()
              ..sort((left, right) => left.order.compareTo(right.order))))
          lane.id,
    ];
    final laneIndex = <String, int>{
      for (var position = 0; position < laneOrder.length; position++)
        laneOrder[position]: position,
    };
    final projectIndex = <String, int>{
      for (var position = 0; position < document.projects.length; position++)
        document.projects[position].id: position,
    };
    return GraphLayoutRequest(
      topologyRevision: document.planRevision,
      nodes: <GraphLayoutNodeInput>[
        for (final id in index.nodeOrder)
          GraphLayoutNodeInput(
            id: id,
            projectIndex:
                projectIndex[index.projectOfNode[id]] ??
                document.projects.length,
            laneIndex: index.laneOfNode[id] == null
                ? null
                : laneIndex[index.laneOfNode[id]],
          ),
      ],
      requiresEdges: <(String, String)>[
        for (final edge in document.edges)
          if (edge.kind == GraphEdgeKind.requires ||
              edge.kind == GraphEdgeKind.successor)
            (edge.from, edge.to),
      ],
      laneOrder: laneOrder,
      visibleLimit: visibleLimit,
    );
  }

  Future<void> _mergeStatus(
    ResourceSnapshot<GraphDocumentUpdate> snapshot,
    GraphPreparedValue? previous,
  ) async {
    if (_display == null || previous == null) return;
    final update = snapshot.value;
    final merged = mergeGraphPreparedValue(
      document: update.document,
      layout: previous.layout,
      previous: previous,
      changedNodeIds: update.changedNodeIds,
      layoutComputed: false,
    );
    _statusMerges++;
    await _offer(snapshot, merged);
  }

  Future<void> _offer(
    ResourceSnapshot<GraphDocumentUpdate> snapshot,
    GraphPreparedValue value,
  ) async {
    final display = _display;
    if (display == null || !_active) return;
    final request = snapshot.consistencyGroup;
    try {
      await display.prepareAndOffer(
        snapshot: ResourceSnapshot<GraphPreparedValue>(
          fieldGroup: _preparedField,
          epoch: snapshot.epoch,
          version: snapshot.version,
          value: value,
          consistencyGroup: request == null
              ? null
              : ConsistencyGroup(
                  id: request.id,
                  position: request.position,
                  changed: <ChangedFieldGroup>[
                    ChangedFieldGroup.of(_preparedField),
                  ],
                ),
        ),
        generation: RequestGeneration(snapshot.version.value),
        operation: () => value,
        estimatedBytes: value.document.nodeCount * 16,
      );
    } on PreparationCancelledException {
      // Superseded work stays silent: a newer revision owns the resource.
    } on Object {
      if (_active) _localUnavailable = 'preparation_unavailable';
    }
  }

  void _onInstalled(
    Map<
      ResourceFieldGroup<GraphPreparedValue>,
      PreparedResource<GraphPreparedValue>
    >
    installed,
  ) {
    if (!_active) return;
    final value = installed[_preparedField]?.value;
    if (value == null) return;
    _localUnavailable = null;
    _lastChange = value.change;
    _setDisplayed(value);
  }

  void _onWithdrawn(Set<ResourceFieldGroup<GraphPreparedValue>> withdrawn) {
    if (!withdrawn.contains(_preparedField)) return;
    // The installed value lost its authority. Name that cause before the frame
    // drops so the placeholder says `source_unavailable`, not `loading`.
    _localUnavailable = 'source_unavailable';
    _setDisplayed(null);
  }

  void _onSourceError() {
    if (!_active) return;
    // Authority loss clears the frame at once: labels, counts and anchors go
    // with it rather than waiting for a group to complete. The reason is set
    // first so the frame that renders the placeholder names the real cause.
    _localUnavailable = 'source_unavailable';
    _setDisplayed(null);
    _layoutCancel?.cancel(PreparationCancellationReason.revoked);
    _layoutCancel = null;
  }
}
