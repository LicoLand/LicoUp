import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:test/test.dart';

/// A source a test drives directly: it publishes whole documents and declares
/// exactly which node identities changed.
final class TestGraphSource implements PresentationSource<GraphDocumentUpdate> {
  TestGraphSource(this.fieldGroup);

  @override
  final ResourceFieldGroup<GraphDocumentUpdate> fieldGroup;

  final StreamController<SourceChange<GraphDocumentUpdate>> _changes =
      StreamController<SourceChange<GraphDocumentUpdate>>.broadcast(sync: true);
  ResourceSnapshot<GraphDocumentUpdate>? _current;
  String _epochId = 'test';

  ResourceSnapshot<GraphDocumentUpdate> get snapshot => _current!;

  /// Publishes a fresh incarnation from this same source, as a reconnect does.
  void reopen(GraphResourceValue document, {required String epochId}) {
    _epochId = epochId;
    final epoch = SourceEpoch(_epochId);
    final version = SourceVersion(1);
    final position = SourcePosition(epoch: epoch, version: version);
    final group = ConsistencyGroup(
      id: ConsistencyGroupId('reopen:${document.planRevision}'),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    _current = ResourceSnapshot<GraphDocumentUpdate>(
      fieldGroup: fieldGroup,
      epoch: epoch,
      version: version,
      value: GraphDocumentUpdate(document: document, topologyChanged: true),
      consistencyGroup: group,
    );
  }

  void publish(
    GraphResourceValue document, {
    Set<String>? changedNodeIds,
    bool topologyChanged = false,
  }) {
    final previous = _current;
    final epoch = previous?.epoch ?? SourceEpoch(_epochId);
    final version = SourceVersion((previous?.version.value ?? 0) + 1);
    final position = SourcePosition(epoch: epoch, version: version);
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        'test',
        source: SourceIdentity(
          scope: fieldGroup.resource.scope,
          stableKey: fieldGroup.resource.stableKey,
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    final snapshot = ResourceSnapshot<GraphDocumentUpdate>(
      fieldGroup: fieldGroup,
      epoch: epoch,
      version: version,
      value: GraphDocumentUpdate(
        document: document,
        changedNodeIds: changedNodeIds,
        topologyChanged: topologyChanged,
      ),
      consistencyGroup: group,
    );
    _current = snapshot;
    if (previous != null) {
      _changes.add(
        SourceChange<GraphDocumentUpdate>(
          snapshot: snapshot,
          base: previous.position,
          group: group,
        ),
      );
    }
  }

  @override
  Future<SourceObservation<GraphDocumentUpdate>> open() async =>
      SourceObservation<GraphDocumentUpdate>(
        initial: _current!,
        changes: _changes.stream,
      );
}

Map<String, Object?> nodeJson(
  String id, {
  String lane = 'licoup.lane/build',
  String? gate,
  String execution = 'claimed',
  String acceptance = 'pending',
  String observation = 'fresh',
  bool ready = true,
  bool startable = true,
  List<Map<String, Object?>> blockers = const <Map<String, Object?>>[],
  List<String> actions = const <String>['licoup.action/unit-start'],
}) => <String, Object?>{
  'id': id,
  'title': id.split('/').last,
  'laneId': lane,
  if (gate != null) 'gateId': gate,
  'role': 'licoup.role/builder',
  'execution': execution,
  'acceptance': acceptance,
  'observation': observation,
  'ready': ready,
  'startable': startable,
  'blockers': blockers,
  'actions': actions,
  'attempts': <Object?>[],
  'visits': <Object?>[],
  'events': <Object?>[],
  'evidence': <Object?>[],
  'consumes': <Object?>[],
  'results': <Object?>[],
};

Map<String, Object?> documentJson({
  required int revision,
  required List<Map<String, Object?>> nodes,
  List<Map<String, Object?>> edges = const <Map<String, Object?>>[],
  List<Map<String, Object?>>? gates,
  String projectId = 'licoup.project/alpha',
  String projectTitle = 'Alpha',
}) => <String, Object?>{
  'schema': graphResourceV1Schema,
  'revision': revision,
  'projects': <Object?>[
    <String, Object?>{
      'id': projectId,
      'title': projectTitle,
      'lanes': <Object?>[
        <String, Object?>{
          'id': 'licoup.lane/build',
          'title': 'Build',
          'order': 0,
        },
        <String, Object?>{
          'id': 'licoup.lane/review',
          'title': 'Review',
          'order': 1,
        },
      ],
      'nodes': nodes,
      'gates': gates ?? <Object?>[],
    },
  ],
  'edges': edges,
};

GraphResourceValue document({
  required int revision,
  required List<Map<String, Object?>> nodes,
  List<Map<String, Object?>> edges = const <Map<String, Object?>>[],
  List<Map<String, Object?>>? gates,
  String projectId = 'licoup.project/alpha',
}) => GraphResourceValue.fromJson(
  documentJson(
    revision: revision,
    nodes: nodes,
    edges: edges,
    gates: gates,
    projectId: projectId,
  ),
);

Map<String, Object?> edgeJson(String id, String from, String to, String kind) =>
    <String, Object?>{'id': id, 'from': from, 'to': to, 'kind': kind};

Future<void> until(bool Function() condition, {String? reason}) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError(reason ?? 'condition not reached');
}

void main() {
  test('a real worker isolate places the layered layout', () async {
    final pool = await PreparationWorkerPool.spawn(
      name: 'graph-layout-test',
      operations: const <String, PreparationWorkerOperation>{
        graphLayoutOperation: runGraphLayout,
      },
    );
    addTearDown(pool.dispose);
    final request = GraphLayoutRequest(
      topologyRevision: 7,
      nodes: const <GraphLayoutNodeInput>[
        GraphLayoutNodeInput(id: 'a', projectIndex: 0, laneIndex: 0),
        GraphLayoutNodeInput(id: 'b', projectIndex: 0, laneIndex: 0),
        GraphLayoutNodeInput(id: 'c', projectIndex: 0, laneIndex: 1),
      ],
      requiresEdges: const <(String, String)>[('a', 'b'), ('b', 'c')],
      laneOrder: const <String>['licoup.lane/build', 'licoup.lane/review'],
    );
    PreparationWorkerIdentity? worker;
    final result = await pool.execute(
      operation: graphLayoutOperation,
      payload: encodeGraphLayoutRequest(request),
      onWorker: (identity) => worker = identity,
    );
    final layout = decodeGraphLayout(result);
    expect(worker, isNotNull);
    expect(
      worker!.runsInCallerIsolate,
      isFalse,
      reason: 'layout must run in a real worker isolate',
    );
    expect(layout.topologyRevision, 7);
    expect(layout.layerOf['a'], 0);
    expect(layout.layerOf['b'], 1);
    expect(layout.layerOf['c'], 2);
    expect(layout.visibleNodeIds, <String>['a', 'b', 'c']);
    expect(pool.workerStats.handled, 1);
  });

  test('a legal visit cycle is kept, not dropped or hung', () async {
    final request = GraphLayoutRequest(
      topologyRevision: 1,
      nodes: const <GraphLayoutNodeInput>[
        GraphLayoutNodeInput(id: 'a', projectIndex: 0),
        GraphLayoutNodeInput(id: 'b', projectIndex: 0),
      ],
      requiresEdges: const <(String, String)>[('a', 'b'), ('b', 'a')],
      laneOrder: const <String>[],
    );
    final layout = await planGraphLayout(request, _NoopContext());
    expect(layout.layerOf.length, 2);
    expect(layout.visibleNodeIds, <String>['a', 'b']);
  });

  test('a status-only revision never re-runs layout', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final resource = ResourceKey(
      scope: const ResourceScope('licoup.test.graph'),
      stableKey: 'alpha',
    );
    final source = TestGraphSource(
      ResourceFieldGroup<GraphDocumentUpdate>(
        resource: resource,
        name: graphDocumentField,
      ),
    );
    source.publish(
      document(
        revision: 1,
        nodes: <Map<String, Object?>>[
          nodeJson('licoup.node/alpha-build'),
          nodeJson('licoup.node/alpha-review', lane: 'licoup.lane/review'),
        ],
      ),
      topologyChanged: true,
    );
    final controller = GraphPreparationController(
      runtime: runtime,
      source: source,
    );
    addTearDown(controller.dispose);
    controller.start();
    await until(() => controller.current != null, reason: 'initial layout');
    expect(controller.stats.layoutRuns, 1);
    expect(controller.stats.lastWorker!.runsInCallerIsolate, isFalse);
    expect(controller.current!.layout.layerOf, isNotEmpty);
    expect(controller.stats.lastRecomputedStatuses, 2);

    source.publish(
      document(
        revision: 2,
        nodes: <Map<String, Object?>>[
          nodeJson(
            'licoup.node/alpha-build',
            execution: 'running',
            acceptance: 'reviewing',
          ),
          nodeJson('licoup.node/alpha-review', lane: 'licoup.lane/review'),
        ],
      ),
      changedNodeIds: <String>{'licoup.node/alpha-build'},
    );
    await until(
      () => controller.current?.planRevision == 2,
      reason: 'status-only merge',
    );
    expect(controller.stats.layoutRuns, 1, reason: 'no second layout run');
    expect(controller.stats.statusMerges, 1);
    expect(
      controller.stats.lastRecomputedStatuses,
      1,
      reason: 'only the declared node was recomputed',
    );
    expect(
      controller.current!.statusById['licoup.node/alpha-build']!.execution,
      GraphExecutionState.running,
    );
    expect(
      controller.current!.projectSummaries['licoup.project/alpha']!.running,
      1,
    );
    expect(
      controller.current!.projectSummaries['licoup.project/alpha']!.total,
      2,
      reason: 'complete goal counts survive a status update',
    );
  });

  test('an undeclared change set is a full rebuild the oracle can see', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final resource = ResourceKey(
      scope: const ResourceScope('licoup.test.graph-naive'),
      stableKey: 'alpha',
    );
    final source = TestGraphSource(
      ResourceFieldGroup<GraphDocumentUpdate>(
        resource: resource,
        name: graphDocumentField,
      ),
    );
    final nodes = <Map<String, Object?>>[
      for (var index = 0; index < 40; index++)
        nodeJson('licoup.node/alpha-$index'),
    ];
    source.publish(document(revision: 1, nodes: nodes), topologyChanged: true);
    final controller = GraphPreparationController(
      runtime: runtime,
      source: source,
    );
    addTearDown(controller.dispose);
    controller.start();
    await until(() => controller.current != null);
    // Same document, no change declaration: the producer cannot say what moved,
    // so the merge honestly recomputes every status entry.
    source.publish(document(revision: 2, nodes: nodes));
    await until(() => controller.current?.planRevision == 2);
    expect(controller.stats.layoutRuns, 1);
    expect(
      controller.stats.lastRecomputedStatuses,
      40,
      reason: 'no silent locality claim for an undeclared change set',
    );
  });

  test('a topology change runs layout again and reports what moved', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final resource = ResourceKey(
      scope: const ResourceScope('licoup.test.graph-topology'),
      stableKey: 'alpha',
    );
    final source = TestGraphSource(
      ResourceFieldGroup<GraphDocumentUpdate>(
        resource: resource,
        name: graphDocumentField,
      ),
    );
    source.publish(
      document(
        revision: 1,
        nodes: <Map<String, Object?>>[nodeJson('licoup.node/a')],
      ),
      topologyChanged: true,
    );
    final controller = GraphPreparationController(
      runtime: runtime,
      source: source,
    );
    addTearDown(controller.dispose);
    controller.start();
    await until(() => controller.current != null);

    source.publish(
      document(
        revision: 2,
        nodes: <Map<String, Object?>>[
          nodeJson('licoup.node/a'),
          nodeJson('licoup.node/b'),
        ],
        edges: <Map<String, Object?>>[
          edgeJson(
            'licoup.edge/a-b',
            'licoup.node/a',
            'licoup.node/b',
            'requires',
          ),
        ],
      ),
      topologyChanged: true,
      changedNodeIds: <String>{'licoup.node/b'},
    );
    await until(() => controller.current?.planRevision == 2);
    expect(controller.stats.layoutRuns, 2);
    expect(controller.current!.layout.layerOf['licoup.node/b'], 1);
    expect(controller.current!.change.layoutComputed, isTrue);
    expect(controller.current!.change.touchedNodeIds, isNotEmpty);
    expect(
      controller.current!.projectSummaries['licoup.project/alpha']!.total,
      2,
    );
  });

  test('revocation clears the prepared value immediately', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final resource = ResourceKey(
      scope: const ResourceScope('licoup.test.graph-revoke'),
      stableKey: 'alpha',
    );
    final source = TestGraphSource(
      ResourceFieldGroup<GraphDocumentUpdate>(
        resource: resource,
        name: graphDocumentField,
      ),
    );
    source.publish(
      document(
        revision: 1,
        nodes: <Map<String, Object?>>[nodeJson('licoup.node/a')],
      ),
      topologyChanged: true,
    );
    final controller = GraphPreparationController(
      runtime: runtime,
      source: source,
    );
    addTearDown(controller.dispose);
    controller.start();
    await until(() => controller.current != null);
    runtime.revoke(resource);
    expect(
      controller.current,
      isNull,
      reason: 'labels, counts and anchors go with the revocation',
    );
  });
}

final class _NoopContext implements WorkerJobContext {
  @override
  bool get isCancelled => false;

  @override
  int get yieldCount => 0;

  @override
  Future<void> yieldToControl() async {}

  @override
  void recordWorkBytes(int bytes) {}
}
