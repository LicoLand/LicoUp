/// C15: the versioned, bounded prepared graph resource.
///
/// One document is one projection of the native project collaboration
/// resources: stable project/lane/node/gate identities, typed edges, the
/// plan/run revision, and — per node — the three separate dimensions of
/// command execution, work acceptance and observation freshness, the
/// ready/startable flags with their native reasons, and opaque action, result
/// and evidence references.
///
/// The decoder is total and bounded. It refuses unknown fields, unknown
/// enumerations, duplicate identities, dangling edge endpoints, and any
/// document over the published budget instead of silently truncating it: a
/// truncated graph would show a smaller goal than the one that exists. What it
/// cannot do is decide readiness or acceptance — those are the native owner's
/// facts, and the interface only renders them.
library;

/// The capability identifier this document publishes.
const String graphResourceV1Schema = 'licoup.ui.graph-resource.v1';

/// The largest multi-project projection the frozen budget describes.
const int graphResourceMaxProjects = 8;

/// The largest complete node set one document may carry.
const int graphResourceMaxNodes = 1000;

/// The largest typed edge set one document may carry.
const int graphResourceMaxEdges = 2000;

/// The default number of nodes a visible window renders.
///
/// Virtualization limits what is painted, never what is counted: every project
/// and lane keeps its complete goal totals while only the window is built.
const int graphResourceDefaultVisibleNodes = 100;

/// The longest label, detail, or opaque reference accepted.
const int graphResourceMaxLabelBytes = 200;
const int graphResourceMaxDetailBytes = 400;
const int graphResourceMaxOpaqueRefBytes = 200;
const int graphResourceMaxNamespacedNameBytes = 160;

/// Why one document could not be accepted, and which field caused it.
final class GraphResourceRefusal {
  const GraphResourceRefusal(this.code, {this.field});

  /// Stable refusal code: `graph_resource_unknown_schema`,
  /// `graph_resource_invalid`, or `graph_resource_too_large`.
  final String code;

  /// The offending field, when the refusal names one.
  final String? field;

  @override
  String toString() => field == null ? code : '$code($field)';
}

/// Projected command execution of one node.
enum GraphExecutionState {
  notStarted('not-started'),
  claimed('claimed'),
  running('running'),
  succeeded('succeeded'),
  failed('failed'),
  cancelled('cancelled');

  const GraphExecutionState(this.wireName);

  final String wireName;

  static GraphExecutionState? fromWireName(String name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// Work acceptance of one node, separate from its command execution.
enum GraphAcceptanceState {
  pending('pending'),
  reviewing('reviewing'),
  accepted('accepted'),
  rejected('rejected'),
  superseded('superseded');

  const GraphAcceptanceState(this.wireName);

  final String wireName;

  static GraphAcceptanceState? fromWireName(String name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// Freshness of the last observation of one node.
///
/// `stale` is not evidence that execution failed: an expired observation is
/// shown as its own dimension, never converted into a failure.
enum GraphObservationState {
  fresh('fresh'),
  stale('stale'),
  unknown('unknown');

  const GraphObservationState(this.wireName);

  final String wireName;

  static GraphObservationState? fromWireName(String name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// Typed relationship between two nodes.
enum GraphEdgeKind {
  requires('requires'),
  visit('visit'),
  successor('successor'),
  result('result');

  const GraphEdgeKind(this.wireName);

  final String wireName;

  static GraphEdgeKind? fromWireName(String name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// Which result a typed reference names.
enum GraphResultKind {
  candidate('candidate'),
  accepted('accepted');

  const GraphResultKind(this.wireName);

  final String wireName;

  static GraphResultKind? fromWireName(String name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// State of one recorded attempt.
enum GraphAttemptState {
  queued('queued'),
  running('running'),
  succeeded('succeeded'),
  failed('failed'),
  cancelled('cancelled'),
  superseded('superseded');

  const GraphAttemptState(this.wireName);

  final String wireName;

  static GraphAttemptState? fromWireName(String name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// Kind of one recorded visit.
enum GraphVisitKind {
  visit('visit'),
  join('join');

  const GraphVisitKind(this.wireName);

  final String wireName;

  static GraphVisitKind? fromWireName(String name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// Why a node is not ready or not startable, as the native owner reported it.
enum GraphBlockerCode {
  dependencyMissing('dependency_missing'),
  resultMissing('result_missing'),
  visitMissing('visit_missing'),
  notMaterialized('not_materialized'),
  authorityMissing('authority_missing'),
  routeUnavailable('route_unavailable'),
  budgetMissing('budget_missing'),
  capacityMissing('capacity_missing'),
  conflictingWriter('conflicting_writer'),
  observationStale('observation_stale'),
  managedByOther('managed_by_other'),
  paused('paused'),
  unknown('unknown');

  const GraphBlockerCode(this.wireName);

  final String wireName;

  static GraphBlockerCode? fromWireName(String name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// One reason a node cannot start, and the nodes it really affects.
final class GraphBlocker {
  GraphBlocker({
    required this.code,
    this.detail,
    Iterable<String> affects = const <String>[],
  }) : affects = List<String>.unmodifiable(affects);

  final GraphBlockerCode code;

  /// The native reason, bounded and free of source text.
  final String? detail;

  /// Nodes this blocker really affects, when the producer named them.
  ///
  /// The interface highlights only these; it never guesses a wider impact.
  final List<String> affects;

  @override
  String toString() => 'GraphBlocker(${code.wireName}, ${affects.length})';
}

/// One typed result reference a node consumes or produces.
final class GraphResultRef {
  const GraphResultRef({required this.nodeId, required this.kind, this.ref});

  final String nodeId;
  final GraphResultKind kind;

  /// Opaque producer-issued reference.
  final String? ref;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphResultRef &&
          other.nodeId == nodeId &&
          other.kind == kind &&
          other.ref == ref;

  @override
  int get hashCode => Object.hash(nodeId, kind, ref);

  @override
  String toString() => 'GraphResultRef($nodeId/${kind.wireName})';
}

/// One recorded execution attempt.
final class GraphAttempt {
  const GraphAttempt({
    required this.id,
    required this.role,
    required this.state,
    this.route,
    this.errorCode,
    this.errorDetail,
  });

  final String id;
  final String role;
  final GraphAttemptState state;
  final String? route;
  final String? errorCode;
  final String? errorDetail;

  @override
  String toString() => 'GraphAttempt($id, ${state.wireName})';
}

/// One recorded visit or join.
final class GraphVisit {
  const GraphVisit({required this.id, required this.kind, this.at});

  final String id;
  final GraphVisitKind kind;

  /// Producer-issued ordering label, not a scheduling clock.
  final String? at;

  @override
  String toString() => 'GraphVisit($id, ${kind.wireName})';
}

/// One recorded event of the node's own history.
final class GraphEvent {
  const GraphEvent({required this.kind, this.at, this.detail});

  final String kind;
  final String? at;
  final String? detail;

  @override
  String toString() => 'GraphEvent($kind)';
}

/// One opaque evidence reference.
final class GraphEvidenceRef {
  const GraphEvidenceRef({required this.ref, required this.kind});

  final String ref;
  final String kind;

  @override
  String toString() => 'GraphEvidenceRef($kind)';
}

/// One node of the project graph.
final class GraphNode {
  GraphNode({
    required this.id,
    required this.title,
    required this.role,
    required this.execution,
    required this.acceptance,
    required this.observation,
    required this.ready,
    required this.startable,
    this.laneId,
    this.gateId,
    this.route,
    Iterable<GraphBlocker> blockers = const <GraphBlocker>[],
    Iterable<GraphResultRef> consumes = const <GraphResultRef>[],
    Iterable<GraphResultRef> results = const <GraphResultRef>[],
    Iterable<String> actions = const <String>[],
    Iterable<GraphAttempt> attempts = const <GraphAttempt>[],
    Iterable<GraphVisit> visits = const <GraphVisit>[],
    Iterable<GraphEvent> events = const <GraphEvent>[],
    Iterable<GraphEvidenceRef> evidence = const <GraphEvidenceRef>[],
  }) : blockers = List<GraphBlocker>.unmodifiable(blockers),
       consumes = List<GraphResultRef>.unmodifiable(consumes),
       results = List<GraphResultRef>.unmodifiable(results),
       actions = List<String>.unmodifiable(actions),
       attempts = List<GraphAttempt>.unmodifiable(attempts),
       visits = List<GraphVisit>.unmodifiable(visits),
       events = List<GraphEvent>.unmodifiable(events),
       evidence = List<GraphEvidenceRef>.unmodifiable(evidence);

  final String id;
  final String title;
  final String role;
  final GraphExecutionState execution;
  final GraphAcceptanceState acceptance;
  final GraphObservationState observation;

  /// Whether every typed dependency of this node is satisfied.
  final bool ready;

  /// Whether this node may actually start now: readiness plus materialized
  /// inputs, original authority, an eligible route, budget and capacity, and
  /// no conflicting writer.
  final bool startable;

  final String? laneId;

  /// The one shared gate this node is a reference anchor of.
  final String? gateId;

  final String? route;
  final List<GraphBlocker> blockers;
  final List<GraphResultRef> consumes;
  final List<GraphResultRef> results;

  /// Opaque action references the host may dispatch for this node.
  final List<String> actions;

  final List<GraphAttempt> attempts;
  final List<GraphVisit> visits;
  final List<GraphEvent> events;
  final List<GraphEvidenceRef> evidence;

  /// The main gap shown on the node card: the first declared blocker.
  GraphBlocker? get mainBlocker => blockers.isEmpty ? null : blockers.first;

  @override
  String toString() =>
      'GraphNode($id, ${execution.wireName}/${acceptance.wireName})';
}

/// One shared gate.
///
/// Several nodes may be reference anchors of the same gate; they share one
/// identity, one count and one run, so no anchor can double the work.
final class GraphGate {
  GraphGate({
    required this.id,
    required this.title,
    required this.runCount,
    Iterable<String> anchors = const <String>[],
    this.role,
  }) : anchors = List<String>.unmodifiable(anchors);

  final String id;
  final String title;
  final int runCount;
  final List<String> anchors;
  final String? role;

  @override
  String toString() =>
      'GraphGate($id, ${anchors.length} anchors, $runCount runs)';
}

/// One swimlane of a project.
final class GraphLane {
  const GraphLane({
    required this.id,
    required this.title,
    required this.order,
    this.role,
  });

  final String id;
  final String title;
  final int order;
  final String? role;

  @override
  String toString() => 'GraphLane($id, order $order)';
}

/// One project of the multi-project projection.
final class GraphProject {
  GraphProject({
    required this.id,
    required this.title,
    Iterable<GraphLane> lanes = const <GraphLane>[],
    Iterable<GraphNode> nodes = const <GraphNode>[],
    Iterable<GraphGate> gates = const <GraphGate>[],
    this.role,
  }) : lanes = List<GraphLane>.unmodifiable(lanes),
       nodes = List<GraphNode>.unmodifiable(nodes),
       gates = List<GraphGate>.unmodifiable(gates);

  final String id;
  final String title;
  final String? role;
  final List<GraphLane> lanes;
  final List<GraphNode> nodes;
  final List<GraphGate> gates;

  @override
  String toString() => 'GraphProject($id, ${nodes.length} nodes)';
}

/// One typed edge between two nodes of any project.
final class GraphEdge {
  const GraphEdge({
    required this.id,
    required this.from,
    required this.to,
    required this.kind,
  });

  final String id;
  final String from;
  final String to;
  final GraphEdgeKind kind;

  @override
  String toString() => 'GraphEdge($id, ${kind.wireName})';
}

/// Pure lookups over one decoded document.
///
/// Built once per revision so a renderer never rescans the document: consumers
/// of a node, the anchors of a gate, and lane membership are all direct
/// lookups.
final class GraphIndex {
  GraphIndex._({
    required Map<String, GraphNode> nodeById,
    required Map<String, String> projectOfNode,
    required Map<String, String> laneOfNode,
    required Map<String, GraphGate> gateById,
    required Map<String, Map<String, int>> laneOrder,
    required Map<String, List<GraphEdge>> edgesBySource,
    required Map<String, List<GraphEdge>> edgesByTarget,
    required Map<String, List<String>> consumersByNode,
    required List<String> nodeOrder,
  }) : nodeById = Map<String, GraphNode>.unmodifiable(nodeById),
       projectOfNode = Map<String, String>.unmodifiable(projectOfNode),
       laneOfNode = Map<String, String>.unmodifiable(laneOfNode),
       gateById = Map<String, GraphGate>.unmodifiable(gateById),
       laneOrder = Map<String, Map<String, int>>.unmodifiable(
         laneOrder.map(
           (key, value) => MapEntry(key, Map<String, int>.unmodifiable(value)),
         ),
       ),
       edgesBySource = Map<String, List<GraphEdge>>.unmodifiable(
         edgesBySource.map(
           (key, value) => MapEntry(key, List<GraphEdge>.unmodifiable(value)),
         ),
       ),
       edgesByTarget = Map<String, List<GraphEdge>>.unmodifiable(
         edgesByTarget.map(
           (key, value) => MapEntry(key, List<GraphEdge>.unmodifiable(value)),
         ),
       ),
       consumersByNode = Map<String, List<String>>.unmodifiable(
         consumersByNode.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       ),
       nodeOrder = List<String>.unmodifiable(nodeOrder);

  final Map<String, GraphNode> nodeById;
  final Map<String, String> projectOfNode;
  final Map<String, String> laneOfNode;
  final Map<String, GraphGate> gateById;

  /// Position of each lane inside its project, for stable layout input.
  final Map<String, Map<String, int>> laneOrder;

  final Map<String, List<GraphEdge>> edgesBySource;
  final Map<String, List<GraphEdge>> edgesByTarget;

  /// Nodes that declared a typed input from this node or depend on it through a
  /// `requires`/`result` edge.
  final Map<String, List<String>> consumersByNode;

  /// Node identity order as the document declared it.
  final List<String> nodeOrder;

  GraphNode? node(String id) => nodeById[id];

  /// Nodes that really consume this node, in declaration order.
  ///
  /// Derived once at decode from typed edges and declared inputs, so a "who is
  /// affected" view highlights only real consumers instead of guessing from
  /// spatial proximity.
  List<String> consumersOf(String nodeId) =>
      consumersByNode[nodeId] ?? const <String>[];

  /// Every anchor node of one shared gate.
  List<String> anchorsOf(String gateId) =>
      gateById[gateId]?.anchors ?? const <String>[];
}

/// One complete bounded graph document.
final class GraphResourceValue {
  GraphResourceValue._({
    required this.planRevision,
    required List<GraphProject> projects,
    required List<GraphEdge> edges,
    required this.index,
    required this.nodeCount,
    required this.edgeCount,
  }) : projects = List<GraphProject>.unmodifiable(projects),
       edges = List<GraphEdge>.unmodifiable(edges);

  /// The plan/run revision this document was projected from.
  ///
  /// The wire key stays `revision`; the boundary rule that governs this
  /// package reserves that member name for the legacy syntax configuration, so
  /// the Dart value names the same fact in full.
  final int planRevision;

  final List<GraphProject> projects;
  final List<GraphEdge> edges;

  /// Lookups over this document.
  final GraphIndex index;

  final int nodeCount;
  final int edgeCount;

  GraphNode? node(String id) => index.nodeById[id];

  /// Every node of one project, in declaration order.
  Iterable<GraphNode> nodesOf(String projectId) => projects
      .where((project) => project.id == projectId)
      .expand((project) => project.nodes);

  /// Decodes one document, refusing anything outside the published contract.
  ///
  /// Throws a [GraphResourceFormatException] carrying a [GraphResourceRefusal]
  /// so a caller can report the exact reason and the exact field.
  static GraphResourceValue fromJson(Map<String, Object?> json) {
    _refuseUnknownKeys(json, const {
      'schema',
      'revision',
      'projects',
      'edges',
    }, 'document');
    final schema = json['schema'];
    if (schema != graphResourceV1Schema) {
      throw const GraphResourceFormatException(
        GraphResourceRefusal('graph_resource_unknown_schema', field: 'schema'),
      );
    }
    final planRevision = json['revision'];
    if (planRevision is! int || planRevision < 1) {
      throw const GraphResourceFormatException(
        GraphResourceRefusal('graph_resource_invalid', field: 'revision'),
      );
    }
    final projectsJson = json['projects'];
    if (projectsJson is! List || projectsJson.isEmpty) {
      throw const GraphResourceFormatException(
        GraphResourceRefusal('graph_resource_invalid', field: 'projects'),
      );
    }
    if (projectsJson.length > graphResourceMaxProjects) {
      throw const GraphResourceFormatException(
        GraphResourceRefusal('graph_resource_too_large', field: 'projects'),
      );
    }

    final projects = <GraphProject>[];
    final nodeById = <String, GraphNode>{};
    final projectOfNode = <String, String>{};
    final laneOfNode = <String, String>{};
    final gateById = <String, GraphGate>{};
    final laneOrder = <String, Map<String, int>>{};
    final nodeOrder = <String>[];
    for (final entry in projectsJson) {
      final project = _project(_object(entry, 'projects'));
      if (projectOfNode.containsValue(project.id) ||
          projects.any((existing) => existing.id == project.id)) {
        throw GraphResourceFormatException(
          GraphResourceRefusal('graph_resource_invalid', field: 'projects.id'),
        );
      }
      for (final node in project.nodes) {
        if (nodeById.containsKey(node.id)) {
          throw const GraphResourceFormatException(
            GraphResourceRefusal('graph_resource_invalid', field: 'nodes.id'),
          );
        }
        nodeById[node.id] = node;
        projectOfNode[node.id] = project.id;
        if (node.laneId != null) laneOfNode[node.id] = node.laneId!;
        nodeOrder.add(node.id);
      }
      for (final gate in project.gates) {
        if (gateById.containsKey(gate.id)) {
          throw const GraphResourceFormatException(
            GraphResourceRefusal('graph_resource_invalid', field: 'gates.id'),
          );
        }
        gateById[gate.id] = gate;
      }
      laneOrder[project.id] = <String, int>{
        for (final lane in project.lanes) lane.id: lane.order,
      };
      projects.add(project);
    }
    if (nodeById.length > graphResourceMaxNodes) {
      throw const GraphResourceFormatException(
        GraphResourceRefusal('graph_resource_too_large', field: 'nodes'),
      );
    }

    final edgesJson = json['edges'];
    if (edgesJson is! List) {
      throw const GraphResourceFormatException(
        GraphResourceRefusal('graph_resource_invalid', field: 'edges'),
      );
    }
    if (edgesJson.length > graphResourceMaxEdges) {
      throw const GraphResourceFormatException(
        GraphResourceRefusal('graph_resource_too_large', field: 'edges'),
      );
    }
    final edges = <GraphEdge>[];
    final edgeIds = <String>{};
    final edgesBySource = <String, List<GraphEdge>>{};
    final edgesByTarget = <String, List<GraphEdge>>{};
    final consumers = <String, Set<String>>{};
    for (final node in nodeById.values) {
      for (final consumed in node.consumes) {
        (consumers[consumed.nodeId] ??= <String>{}).add(node.id);
      }
    }
    for (final entry in edgesJson) {
      final edge = _edge(_object(entry, 'edges'));
      if (!edgeIds.add(edge.id)) {
        throw const GraphResourceFormatException(
          GraphResourceRefusal('graph_resource_invalid', field: 'edges.id'),
        );
      }
      if (!nodeById.containsKey(edge.from) || !nodeById.containsKey(edge.to)) {
        throw const GraphResourceFormatException(
          GraphResourceRefusal('graph_resource_invalid', field: 'edges'),
        );
      }
      edges.add(edge);
      (edgesBySource[edge.from] ??= <GraphEdge>[]).add(edge);
      (edgesByTarget[edge.to] ??= <GraphEdge>[]).add(edge);
      if (edge.kind == GraphEdgeKind.requires ||
          edge.kind == GraphEdgeKind.result) {
        (consumers[edge.from] ??= <String>{}).add(edge.to);
      }
    }
    final consumersByNode = <String, List<String>>{
      for (final entry in consumers.entries)
        entry.key: <String>[
          for (final id in nodeOrder)
            if (entry.value.contains(id)) id,
        ],
    };

    // Anchors and blockers may only name nodes of this document.
    for (final gate in gateById.values) {
      for (final anchor in gate.anchors) {
        if (!nodeById.containsKey(anchor)) {
          throw const GraphResourceFormatException(
            GraphResourceRefusal(
              'graph_resource_invalid',
              field: 'gates.anchors',
            ),
          );
        }
      }
    }
    for (final node in nodeById.values) {
      if (node.gateId != null && !gateById.containsKey(node.gateId)) {
        throw const GraphResourceFormatException(
          GraphResourceRefusal('graph_resource_invalid', field: 'nodes.gateId'),
        );
      }
      for (final blocker in node.blockers) {
        for (final affected in blocker.affects) {
          if (!nodeById.containsKey(affected)) {
            throw const GraphResourceFormatException(
              GraphResourceRefusal(
                'graph_resource_invalid',
                field: 'nodes.blockers.affects',
              ),
            );
          }
        }
      }
      for (final consumed in node.consumes) {
        if (!nodeById.containsKey(consumed.nodeId)) {
          throw const GraphResourceFormatException(
            GraphResourceRefusal(
              'graph_resource_invalid',
              field: 'nodes.consumes',
            ),
          );
        }
      }
    }

    return GraphResourceValue._(
      planRevision: planRevision,
      projects: projects,
      edges: edges,
      index: GraphIndex._(
        nodeById: nodeById,
        projectOfNode: projectOfNode,
        laneOfNode: laneOfNode,
        gateById: gateById,
        laneOrder: laneOrder,
        edgesBySource: edgesBySource,
        edgesByTarget: edgesByTarget,
        consumersByNode: consumersByNode,
        nodeOrder: nodeOrder,
      ),
      nodeCount: nodeById.length,
      edgeCount: edges.length,
    );
  }

  @override
  String toString() =>
      'GraphResourceValue(rev $planRevision, ${projects.length} projects, '
      '$nodeCount nodes, $edgeCount edges)';
}

/// Raised when a document violates the published contract.
final class GraphResourceFormatException implements Exception {
  const GraphResourceFormatException(this.refusal);

  final GraphResourceRefusal refusal;

  @override
  String toString() => 'GraphResourceFormatException($refusal)';
}

GraphProject _project(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {
    'id',
    'title',
    'role',
    'lanes',
    'nodes',
    'gates',
  }, 'project');
  final id = _stableId(json, 'id', 'project');
  final title = _label(json, 'title', 'project');
  final lanesJson = json['lanes'];
  if (lanesJson is! List || lanesJson.isEmpty || lanesJson.length > 24) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'project.lanes'),
    );
  }
  final laneIds = <String>{};
  final lanes = <GraphLane>[
    for (final entry in lanesJson) _lane(_object(entry, 'lanes'), laneIds),
  ];
  final nodesJson = json['nodes'];
  if (nodesJson is! List) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'project.nodes'),
    );
  }
  if (nodesJson.length > graphResourceMaxNodes) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_too_large', field: 'project.nodes'),
    );
  }
  final nodes = <GraphNode>[
    for (final entry in nodesJson) _node(_object(entry, 'nodes'), laneIds),
  ];
  final gatesJson = json['gates'];
  if (gatesJson is! List || gatesJson.length > 64) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'project.gates'),
    );
  }
  final gates = <GraphGate>[
    for (final entry in gatesJson) _gate(_object(entry, 'gates')),
  ];
  final role = json['role'];
  if (role != null && role is! String) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'project.role'),
    );
  }
  return GraphProject(
    id: id,
    title: title,
    role: role as String?,
    lanes: lanes,
    nodes: nodes,
    gates: gates,
  );
}

GraphLane _lane(Map<String, Object?> json, Set<String> seen) {
  _refuseUnknownKeys(json, const {'id', 'title', 'order', 'role'}, 'lane');
  final id = _stableId(json, 'id', 'lane');
  if (!seen.add(id)) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'lanes.id'),
    );
  }
  final order = json['order'];
  if (order is! int || order < 0) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'lanes.order'),
    );
  }
  final role = _optionalName(json, 'role');
  return GraphLane(
    id: id,
    title: _label(json, 'title', 'lane'),
    order: order,
    role: role,
  );
}

GraphNode _node(Map<String, Object?> json, Set<String> laneIds) {
  _refuseUnknownKeys(json, const {
    'id',
    'title',
    'laneId',
    'gateId',
    'role',
    'route',
    'execution',
    'acceptance',
    'observation',
    'ready',
    'startable',
    'blockers',
    'consumes',
    'results',
    'actions',
    'attempts',
    'visits',
    'events',
    'evidence',
  }, 'node');
  final id = _stableId(json, 'id', 'node');
  final laneId = json['laneId'];
  if (laneId != null && (laneId is! String || !laneIds.contains(laneId))) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'nodes.laneId'),
    );
  }
  final execution = GraphExecutionState.fromWireName(
    _string(json, 'execution', 'node'),
  );
  final acceptance = GraphAcceptanceState.fromWireName(
    _string(json, 'acceptance', 'node'),
  );
  final observation = GraphObservationState.fromWireName(
    _string(json, 'observation', 'node'),
  );
  if (execution == null || acceptance == null || observation == null) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'node.status'),
    );
  }
  final ready = json['ready'];
  final startable = json['startable'];
  if (ready is! bool || startable is! bool) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'node.readiness'),
    );
  }
  return GraphNode(
    id: id,
    title: _label(json, 'title', 'node'),
    laneId: laneId as String?,
    gateId: _stableIdOrNull(json, 'gateId', 'node'),
    role: _name(json, 'role', 'node'),
    route: _optionalName(json, 'route'),
    execution: execution,
    acceptance: acceptance,
    observation: observation,
    ready: ready,
    startable: startable,
    blockers: _bounded(
      json['blockers'],
      32,
      'node.blockers',
      (entry) => _blocker(_object(entry, 'blockers')),
    ),
    consumes: _bounded(
      json['consumes'],
      64,
      'node.consumes',
      (entry) => _resultRef(_object(entry, 'consumes')),
    ),
    results: _bounded(
      json['results'],
      64,
      'node.results',
      (entry) => _resultRef(_object(entry, 'results')),
    ),
    actions: _bounded(
      json['actions'],
      16,
      'node.actions',
      (entry) => _opaqueRef(entry, 'actions'),
    ),
    attempts: _bounded(
      json['attempts'],
      64,
      'node.attempts',
      (entry) => _attempt(_object(entry, 'attempts')),
    ),
    visits: _bounded(
      json['visits'],
      64,
      'node.visits',
      (entry) => _visit(_object(entry, 'visits')),
    ),
    events: _bounded(
      json['events'],
      128,
      'node.events',
      (entry) => _event(_object(entry, 'events')),
    ),
    evidence: _bounded(
      json['evidence'],
      64,
      'node.evidence',
      (entry) => _evidence(_object(entry, 'evidence')),
    ),
  );
}

GraphBlocker _blocker(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {'code', 'detail', 'affects'}, 'blocker');
  final code = GraphBlockerCode.fromWireName(_string(json, 'code', 'blocker'));
  if (code == null) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'blockers.code'),
    );
  }
  final detail = json['detail'];
  if (detail != null &&
      (detail is! String || detail.length > graphResourceMaxDetailBytes)) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'blockers.detail'),
    );
  }
  final affectsJson = json['affects'];
  if (affectsJson != null && affectsJson is! List) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'blockers.affects'),
    );
  }
  final affects = <String>[];
  if (affectsJson is List) {
    if (affectsJson.length > 64) {
      throw const GraphResourceFormatException(
        GraphResourceRefusal(
          'graph_resource_too_large',
          field: 'blockers.affects',
        ),
      );
    }
    for (final entry in affectsJson) {
      affects.add(_stableIdValue(entry, 'blockers.affects'));
    }
  }
  return GraphBlocker(code: code, detail: detail as String?, affects: affects);
}

GraphResultRef _resultRef(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {'nodeId', 'kind', 'ref'}, 'resultRef');
  final kind = GraphResultKind.fromWireName(_string(json, 'kind', 'resultRef'));
  if (kind == null) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'results.kind'),
    );
  }
  final ref = json['ref'];
  if (ref != null &&
      (ref is! String || ref.length > graphResourceMaxOpaqueRefBytes)) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'results.ref'),
    );
  }
  return GraphResultRef(
    nodeId: _stableId(json, 'nodeId', 'resultRef'),
    kind: kind,
    ref: ref as String?,
  );
}

GraphAttempt _attempt(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {
    'id',
    'role',
    'route',
    'state',
    'errorCode',
    'errorDetail',
  }, 'attempt');
  final state = GraphAttemptState.fromWireName(
    _string(json, 'state', 'attempt'),
  );
  if (state == null) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'attempts.state'),
    );
  }
  final errorDetail = json['errorDetail'];
  if (errorDetail != null &&
      (errorDetail is! String ||
          errorDetail.length > graphResourceMaxDetailBytes)) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal(
        'graph_resource_invalid',
        field: 'attempts.errorDetail',
      ),
    );
  }
  final id = json['id'];
  if (id is! String ||
      id.isEmpty ||
      id.length > graphResourceMaxOpaqueRefBytes) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'attempts.id'),
    );
  }
  return GraphAttempt(
    id: id,
    role: _name(json, 'role', 'attempt'),
    state: state,
    route: _optionalName(json, 'route'),
    errorCode: _optionalName(json, 'errorCode'),
    errorDetail: errorDetail as String?,
  );
}

GraphVisit _visit(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {'id', 'kind', 'at'}, 'visit');
  final kind = GraphVisitKind.fromWireName(_string(json, 'kind', 'visit'));
  if (kind == null) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'visits.kind'),
    );
  }
  final id = json['id'];
  if (id is! String ||
      id.isEmpty ||
      id.length > graphResourceMaxOpaqueRefBytes) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'visits.id'),
    );
  }
  return GraphVisit(id: id, kind: kind, at: _optionalLabel(json, 'at'));
}

GraphEvent _event(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {'at', 'kind', 'detail'}, 'event');
  final detail = json['detail'];
  if (detail != null &&
      (detail is! String || detail.length > graphResourceMaxDetailBytes)) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'events.detail'),
    );
  }
  return GraphEvent(
    kind: _name(json, 'kind', 'event'),
    at: _optionalLabel(json, 'at'),
    detail: detail as String?,
  );
}

GraphEvidenceRef _evidence(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {'ref', 'kind'}, 'evidenceRef');
  return GraphEvidenceRef(
    ref: _opaqueRef(json['ref'], 'evidence.ref'),
    kind: _name(json, 'kind', 'evidence'),
  );
}

GraphGate _gate(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {
    'id',
    'title',
    'anchors',
    'runCount',
    'role',
  }, 'gate');
  final anchorsJson = json['anchors'];
  if (anchorsJson is! List || anchorsJson.isEmpty || anchorsJson.length > 64) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'gates.anchors'),
    );
  }
  final runCount = json['runCount'];
  if (runCount is! int || runCount < 0) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'gates.runCount'),
    );
  }
  return GraphGate(
    id: _stableId(json, 'id', 'gate'),
    title: _label(json, 'title', 'gate'),
    runCount: runCount,
    anchors: <String>[
      for (final anchor in anchorsJson) _stableIdValue(anchor, 'gates.anchors'),
    ],
    role: _optionalName(json, 'role'),
  );
}

GraphEdge _edge(Map<String, Object?> json) {
  _refuseUnknownKeys(json, const {'id', 'from', 'to', 'kind'}, 'edge');
  final kind = GraphEdgeKind.fromWireName(_string(json, 'kind', 'edge'));
  if (kind == null) {
    throw const GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: 'edges.kind'),
    );
  }
  return GraphEdge(
    id: _stableId(json, 'id', 'edge'),
    from: _stableId(json, 'from', 'edge'),
    to: _stableId(json, 'to', 'edge'),
    kind: kind,
  );
}

List<T> _bounded<T>(
  Object? json,
  int maximum,
  String field,
  T Function(Object? entry) decode,
) {
  if (json == null) return const <Never>[];
  if (json is! List) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: field),
    );
  }
  if (json.length > maximum) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_too_large', field: field),
    );
  }
  return <T>[for (final entry in json) decode(entry)];
}

void _refuseUnknownKeys(
  Map<String, Object?> json,
  Set<String> allowed,
  String field,
) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw GraphResourceFormatException(
        GraphResourceRefusal('graph_resource_invalid', field: '$field.$key'),
      );
    }
  }
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: field),
    );
  }
  return value.map((key, entry) => MapEntry(key.toString(), entry));
}

String _string(Map<String, Object?> json, String key, String field) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: '$field.$key'),
    );
  }
  return value;
}

String _label(Map<String, Object?> json, String key, String field) {
  final value = _string(json, key, field);
  if (value.length > graphResourceMaxLabelBytes) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: '$field.$key'),
    );
  }
  return value;
}

String? _optionalLabel(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.length > graphResourceMaxLabelBytes) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: key),
    );
  }
  return value;
}

String _name(Map<String, Object?> json, String key, String field) {
  final value = _string(json, key, field);
  if (!_isNamespaced(value)) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: '$field.$key'),
    );
  }
  return value;
}

String? _optionalName(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || !_isNamespaced(value)) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: key),
    );
  }
  return value;
}

String _stableId(Map<String, Object?> json, String key, String field) =>
    _stableIdValue(json[key], '$field.$key');

String? _stableIdOrNull(Map<String, Object?> json, String key, String field) {
  final value = json[key];
  return value == null ? null : _stableIdValue(value, '$field.$key');
}

String _stableIdValue(Object? value, String field) {
  if (value is! String ||
      value.length > graphResourceMaxNamespacedNameBytes ||
      !_isNamespaced(value)) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: field),
    );
  }
  return value;
}

String _opaqueRef(Object? value, String field) {
  if (value is! String ||
      value.isEmpty ||
      value.length > graphResourceMaxOpaqueRefBytes ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/#-]*$').hasMatch(value)) {
    throw GraphResourceFormatException(
      GraphResourceRefusal('graph_resource_invalid', field: field),
    );
  }
  return value;
}

/// Whether [name] follows the namespaced identity rule the schemas publish.
bool _isNamespaced(String name) =>
    name.length <= graphResourceMaxNamespacedNameBytes &&
    RegExp(
      r'^[a-z0-9]+(?:[.-][a-z0-9]+)(?:[./-][A-Za-z0-9_-]+)*$',
    ).hasMatch(name);
