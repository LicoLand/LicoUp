import 'dart:async';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/contracts/collaboration_run_port.dart';

/// Synthetic reference scenario mirroring the design demo: a plan stack, a
/// fork over parallel tasks, a review that can call the index task back, a
/// join, a ship stack and a terminal.
CollaborationGraphNode collabNode(
  String id,
  CollaborationNodeKind kind, {
  String? label,
  String? group,
  String? roleLabel,
  String? agentId,
  String? modelLabel,
  String? reasoningEffort,
}) => CollaborationGraphNode(
  id: id,
  kind: kind,
  label: label ?? id,
  group: group,
  roleLabel: roleLabel,
  agentId: agentId,
  modelLabel: modelLabel,
  reasoningEffort: reasoningEffort,
);

CollaborationGraphEdge collabEdge(
  String from,
  String to, {
  CollaborationEdgeEvent event = CollaborationEdgeEvent.success,
  CollaborationEdgeMode mode = CollaborationEdgeMode.flow,
}) => CollaborationGraphEdge(from: from, to: to, event: event, mode: mode);

const String collabPlanGroup = '计划';
const String collabBuildGroup = '并行实施';
const String collabShipGroup = '验证交付';

CollaborationGraphNode _bench() => collabNode(
  'bench',
  CollaborationNodeKind.actor,
  label: '性能基准',
  group: collabBuildGroup,
  roleLabel: 'Bench',
  agentId: 'kimi-code',
  modelLabel: 'K2',
  reasoningEffort: 'medium',
);

List<CollaborationGraphNode> collabNodesV1({bool shipRevised = false}) => [
  collabNode(
    'p1',
    CollaborationNodeKind.actor,
    label: '梳理需求范围',
    group: collabPlanGroup,
    roleLabel: 'Explorer',
    agentId: 'kimi-code',
  ),
  collabNode(
    'p2',
    CollaborationNodeKind.actor,
    label: '拆分执行计划',
    group: collabPlanGroup,
    roleLabel: 'Lead',
    agentId: 'lico',
  ),
  collabNode(
    'p3',
    CollaborationNodeKind.actor,
    label: '审阅计划',
    group: collabPlanGroup,
    roleLabel: 'Architect',
    agentId: 'claude-code',
  ),
  collabNode('fork', CollaborationNodeKind.fork, label: 'fork'),
  collabNode(
    'idx',
    CollaborationNodeKind.actor,
    label: '构建本地索引',
    group: collabBuildGroup,
    roleLabel: 'Index',
    agentId: 'codex',
    modelLabel: 'Codex 5',
    reasoningEffort: 'medium',
  ),
  collabNode(
    'ui',
    CollaborationNodeKind.actor,
    label: '构建搜索界面',
    group: collabBuildGroup,
    roleLabel: 'Interface',
    agentId: 'cursor',
    modelLabel: 'Composer 1',
    reasoningEffort: 'medium',
  ),
  collabNode(
    'arch',
    CollaborationNodeKind.actor,
    label: '审阅索引方案',
    group: collabBuildGroup,
    roleLabel: 'Architect',
    agentId: 'claude-code',
    modelLabel: 'Opus 4',
    reasoningEffort: 'high',
  ),
  collabNode('join', CollaborationNodeKind.join, label: 'join'),
  collabNode(
    's1',
    CollaborationNodeKind.actor,
    label: '连接索引与界面',
    group: collabShipGroup,
    roleLabel: 'Lead',
    agentId: 'lico',
  ),
  collabNode(
    's2',
    CollaborationNodeKind.actor,
    label: '验证与最终审阅',
    group: collabShipGroup,
    roleLabel: 'Architect',
    agentId: shipRevised ? 'codex' : 'claude-code',
  ),
  collabNode(
    's3',
    CollaborationNodeKind.actor,
    label: shipRevised ? '灰度发布与回滚预案' : '交付全局搜索',
    group: collabShipGroup,
    roleLabel: 'Lead',
    agentId: 'lico',
  ),
  collabNode('done', CollaborationNodeKind.terminal, label: 'done'),
];

List<CollaborationGraphEdge> collabEdgesV1() => [
  collabEdge('p1', 'p2'),
  collabEdge('p2', 'p3'),
  collabEdge('p3', 'fork'),
  collabEdge('fork', 'idx', event: CollaborationEdgeEvent.complete),
  collabEdge('fork', 'ui', event: CollaborationEdgeEvent.complete),
  collabEdge('idx', 'arch'),
  collabEdge('arch', 'join'),
  collabEdge(
    'arch',
    'idx',
    event: CollaborationEdgeEvent.failure,
    mode: CollaborationEdgeMode.callback,
  ),
  collabEdge('ui', 'join'),
  collabEdge('join', 's1', event: CollaborationEdgeEvent.complete),
  collabEdge('s1', 's2'),
  collabEdge('s2', 's3'),
  collabEdge('s3', 'done'),
];

CollaborationGraph collaborationGraphV1() => CollaborationGraph(
  nodes: collabNodesV1(),
  edges: collabEdgesV1(),
  initialNodeId: 'p1',
);

/// v2 adds the `bench` branch, reassigns the final review and adjusts the
/// delivery step.
CollaborationGraph collaborationGraphV2() {
  final nodes = collabNodesV1(shipRevised: true);
  nodes.insert(nodes.indexWhere((node) => node.id == 'arch'), _bench());
  final edges = [
    ...collabEdgesV1(),
    collabEdge('fork', 'bench', event: CollaborationEdgeEvent.complete),
    collabEdge('bench', 'join'),
  ];
  return CollaborationGraph(nodes: nodes, edges: edges, initialNodeId: 'p1');
}

CollaborationGraphDiff collaborationDiffV2() => CollaborationGraphDiff(
  addedNodes: const ['bench'],
  removedNodes: const [],
  changedNodes: const [
    CollaborationNodeChange(
      id: 's2',
      kind: CollaborationChangeKind.reassigned,
      fromAgentId: 'claude-code',
      toAgentId: 'codex',
    ),
    CollaborationNodeChange(id: 's3', kind: CollaborationChangeKind.adjusted),
  ],
  addedEdges: const [
    CollaborationGraphEdge(
      from: 'fork',
      to: 'bench',
      event: CollaborationEdgeEvent.complete,
    ),
    CollaborationGraphEdge(
      from: 'bench',
      to: 'join',
      event: CollaborationEdgeEvent.success,
    ),
  ],
  removedEdges: const [],
);

CollaborationRevisionSummary collabRevision(
  int number, {
  String? digest,
  int? parent,
  CollaborationRevisionAuthor author = CollaborationRevisionAuthor.assistant,
  String reason = '',
  int added = 0,
  int removed = 0,
  int changed = 0,
  CollaborationRevisionApproval approval =
      CollaborationRevisionApproval.autoApplied,
  int? revertOf,
}) => CollaborationRevisionSummary(
  number: number,
  digest: digest ?? 'digest$number',
  parent: parent,
  author: author,
  authoredAt: DateTime(2026, 10, 11, 9, 30 + number).millisecondsSinceEpoch,
  reason: reason,
  added: added,
  removed: removed,
  changed: changed,
  approval: approval,
  revertOf: revertOf,
);

CollaborationRevisionSummary collabRevisionV1() =>
    collabRevision(1, digest: 'a1f8c2e9d0', reason: '初始执行计划');

CollaborationRevisionSummary collabRevisionV2({
  CollaborationRevisionApproval approval =
      CollaborationRevisionApproval.autoApplied,
}) => collabRevision(
  2,
  digest: '3f9a2c1b7e',
  parent: 1,
  reason: '发现性能瓶颈，补充基准测试',
  added: 1,
  changed: 2,
  approval: approval,
);

CollaborationRevisionSummary collabRevisionV3() => collabRevision(
  3,
  digest: '7d2e9b4a61',
  parent: 2,
  author: CollaborationRevisionAuthor.user,
  reason: '撤销 v2 变更',
  removed: 1,
  changed: 2,
  approval: CollaborationRevisionApproval.approved,
  revertOf: 2,
);

CollaborationNodeState collabState(
  CollaborationNodeStatus status, {
  int visit = 1,
  int attempt = 1,
  int maxAttempts = 3,
  int startedRevision = 1,
  CollaborationFallback? fallback,
  int artifactCount = 0,
  CollaborationGate? gate,
}) => CollaborationNodeState(
  status: status,
  visit: visit,
  attempt: attempt,
  maxAttempts: maxAttempts,
  startedRevision: startedRevision,
  fallback: fallback,
  artifactCount: artifactCount,
  gate: gate,
);

CollaborationGate collabIndexGate({
  CollaborationGateReview review = const CollaborationGateEscalated(
    '涉及超大文件，会显著影响索引耗时，需要你决定',
  ),
}) => CollaborationGate(
  gateId: 'gate-idx',
  title: '超大文件的索引范围',
  detail: 'Index 在扫描时发现 6 个超过 50MB 的文件，需要确认索引范围后继续。',
  options: const [
    CollaborationGateOption(id: 'small', label: '仅索引 50MB 以下'),
    CollaborationGateOption(id: 'all', label: '全部纳入'),
  ],
  review: review,
);

/// The golden state: Index fell back to DeepSeek Harness after repeated
/// failures and waits on an escalated gate, Interface finished with an
/// Assistant-approved gate, and Bench is running.
Map<String, CollaborationNodeState> collabStatesV2() => {
  'p1': collabState(CollaborationNodeStatus.succeeded),
  'p2': collabState(CollaborationNodeStatus.succeeded),
  'p3': collabState(CollaborationNodeStatus.succeeded),
  'fork': collabState(CollaborationNodeStatus.succeeded),
  'idx': collabState(
    CollaborationNodeStatus.waitingUser,
    attempt: 3,
    fallback: const CollaborationFallback(
      fromAgentId: 'codex',
      toAgentId: 'deepseek-harness',
      failureClass: 'retry_exhausted',
    ),
    gate: collabIndexGate(),
  ),
  'ui': collabState(
    CollaborationNodeStatus.succeeded,
    artifactCount: 1,
    gate: CollaborationGate(
      gateId: 'gate-ui',
      title: '安装依赖 ripgrep',
      detail: '安装开发依赖 ripgrep 以加速代码搜索。',
      options: const [
        CollaborationGateOption(id: 'allow', label: '允许'),
        CollaborationGateOption(id: 'deny', label: '拒绝'),
      ],
      review: const CollaborationGateAssistantApproved('低风险：仅安装开发依赖'),
    ),
  ),
  'bench': collabState(CollaborationNodeStatus.running, startedRevision: 2),
  'arch': collabState(CollaborationNodeStatus.pending),
  'join': collabState(CollaborationNodeStatus.pending),
  's1': collabState(CollaborationNodeStatus.pending),
  's2': collabState(CollaborationNodeStatus.pending),
  's3': collabState(CollaborationNodeStatus.pending),
  'done': collabState(CollaborationNodeStatus.pending),
};

CollaborationRunSnapshot collabSnapshotV2({
  CollaborationRunStatus status = CollaborationRunStatus.waiting,
  Map<String, CollaborationNodeState>? nodeStates,
  CollaborationGraphDiff? headDiff,
  CollaborationPlanChangePolicy planChangePolicy =
      CollaborationPlanChangePolicy.auto,
  CollaborationGateReviewPolicy gateReviewPolicy =
      CollaborationGateReviewPolicy.assistant,
}) => CollaborationRunSnapshot(
  runId: 'run-1',
  conversationId: 'conv-1',
  status: status,
  startedAt: DateTime(2026, 10, 11, 9, 30).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 10, 11, 9, 34).millisecondsSinceEpoch,
  planChangePolicy: planChangePolicy,
  gateReviewPolicy: gateReviewPolicy,
  headNumber: 2,
  revisions: [collabRevisionV1(), collabRevisionV2()],
  graph: collaborationGraphV2(),
  nodeStates: nodeStates ?? collabStatesV2(),
  headDiff: headDiff ?? collaborationDiffV2(),
);

/// The ask-mode proposal: v2 is held for user approval on top of v1.
CollaborationProposal collabProposal() => CollaborationProposal(
  revision: collabRevisionV2(approval: CollaborationRevisionApproval.pending),
  graph: collaborationGraphV2(),
  diff: collaborationDiffV2(),
);

Map<String, CollaborationNodeState> collabStatesV1Active() => {
  'p1': collabState(CollaborationNodeStatus.succeeded),
  'p2': collabState(CollaborationNodeStatus.succeeded),
  'p3': collabState(CollaborationNodeStatus.succeeded),
  'fork': collabState(CollaborationNodeStatus.succeeded),
  'idx': collabState(CollaborationNodeStatus.retrying, attempt: 2),
  'ui': collabState(CollaborationNodeStatus.succeeded, artifactCount: 1),
  'arch': collabState(CollaborationNodeStatus.pending),
  'join': collabState(CollaborationNodeStatus.pending),
  's1': collabState(CollaborationNodeStatus.pending),
  's2': collabState(CollaborationNodeStatus.pending),
  's3': collabState(CollaborationNodeStatus.pending),
  'done': collabState(CollaborationNodeStatus.pending),
};

/// A snapshot on v1 with the v2 graph held as a proposal.
CollaborationRunSnapshot collabSnapshotWithProposal() =>
    CollaborationRunSnapshot(
      runId: 'run-1',
      conversationId: 'conv-1',
      status: CollaborationRunStatus.running,
      startedAt: DateTime(2026, 10, 11, 9, 30).millisecondsSinceEpoch,
      updatedAt: DateTime(2026, 10, 11, 9, 33).millisecondsSinceEpoch,
      planChangePolicy: CollaborationPlanChangePolicy.ask,
      gateReviewPolicy: CollaborationGateReviewPolicy.assistant,
      headNumber: 1,
      revisions: [collabRevisionV1()],
      graph: collaborationGraphV1(),
      nodeStates: collabStatesV1Active(),
      proposal: collabProposal(),
    );

/// A completed run on v3, which reverted v2.
CollaborationRunSnapshot collabSnapshotCompletedV3() =>
    CollaborationRunSnapshot(
      runId: 'run-1',
      conversationId: 'conv-1',
      status: CollaborationRunStatus.completed,
      startedAt: DateTime(2026, 10, 11, 9, 30).millisecondsSinceEpoch,
      updatedAt: DateTime(2026, 10, 11, 9, 40).millisecondsSinceEpoch,
      planChangePolicy: CollaborationPlanChangePolicy.ask,
      gateReviewPolicy: CollaborationGateReviewPolicy.assistant,
      headNumber: 3,
      revisions: [collabRevisionV1(), collabRevisionV2(), collabRevisionV3()],
      graph: collaborationGraphV1(),
      nodeStates: {
        for (final node in collaborationGraphV1().nodes)
          node.id: collabState(CollaborationNodeStatus.succeeded),
      },
    );

Map<String, dynamic> _edgePayload(CollaborationGraphEdge edge) => {
  'from': edge.from,
  'to': edge.to,
  'event': edge.event.wireName,
  if (edge.mode != CollaborationEdgeMode.flow) 'mode': edge.mode.wireName,
};

/// Complete wire payload for the v2 snapshot, used by the contract test.
Map<String, dynamic> collabSnapshotPayload() => {
  'runId': 'run-1',
  'conversationId': 'conv-1',
  'status': 'waiting',
  'startedAt': 1759300000000,
  'updatedAt': 1759300060000,
  'policy': {'planChange': 'auto', 'gateReview': 'assistant'},
  'head': 2,
  'revisions': [
    {
      'number': 1,
      'digest': 'a1f8c2e9d0',
      'author': 'assistant',
      'authoredAt': 1759300060000,
      'reason': '初始执行计划',
      'stats': {'added': 0, 'removed': 0, 'changed': 0},
      'approval': 'auto_applied',
    },
    {
      'number': 2,
      'digest': '3f9a2c1b7e',
      'parent': 1,
      'author': 'assistant',
      'authoredAt': 1759300120000,
      'reason': '发现性能瓶颈，补充基准测试',
      'stats': {'added': 1, 'removed': 0, 'changed': 2},
      'approval': 'auto_applied',
    },
  ],
  'graph': {
    'initial': 'p1',
    'nodes': [
      for (final node in collaborationGraphV2().nodes)
        {
          'id': node.id,
          'kind': node.kind.wireName,
          'label': node.label,
          if (node.group != null) 'group': node.group,
          if (node.roleLabel != null) 'roleLabel': node.roleLabel,
          if (node.agentId != null) 'agentId': node.agentId,
          if (node.modelLabel != null) 'modelLabel': node.modelLabel,
          if (node.reasoningEffort != null)
            'reasoningEffort': node.reasoningEffort,
        },
    ],
    'edges': [
      for (final edge in collaborationGraphV2().edges) _edgePayload(edge),
    ],
  },
  'nodeStates': {
    for (final entry in collabStatesV2().entries)
      entry.key: {
        'status': entry.value.status.wireName,
        'visit': entry.value.visit,
        'attempt': entry.value.attempt,
        'maxAttempts': entry.value.maxAttempts,
        'startedRevision': entry.value.startedRevision,
        'artifactCount': entry.value.artifactCount,
        if (entry.value.fallback != null)
          'fallback': {
            'fromAgentId': entry.value.fallback!.fromAgentId,
            'toAgentId': entry.value.fallback!.toAgentId,
            'failureClass': entry.value.fallback!.failureClass,
          },
        if (entry.value.gate != null)
          'gate': {
            'gateId': entry.value.gate!.gateId,
            'title': entry.value.gate!.title,
            'detail': entry.value.gate!.detail,
            'options': [
              for (final option in entry.value.gate!.options)
                {'id': option.id, 'label': option.label},
            ],
            'review': switch (entry.value.gate!.review) {
              CollaborationGateWaitingUser() => 'waiting_user',
              CollaborationGateEscalated(:final assistantNote) => {
                'state': 'escalated',
                'assistantNote': assistantNote,
              },
              CollaborationGateAssistantApproved(:final reason) => {
                'state': 'assistant_approved',
                'reason': reason,
              },
            },
          },
      },
  },
  'headDiff': {
    'addedNodes': ['bench'],
    'removedNodes': <String>[],
    'changedNodes': [
      {
        'id': 's2',
        'kind': 'reassigned',
        'fromAgentId': 'claude-code',
        'toAgentId': 'codex',
      },
      {'id': 's3', 'kind': 'adjusted'},
    ],
    'addedEdges': [
      for (final edge in collaborationDiffV2().addedEdges) _edgePayload(edge),
    ],
    'removedEdges': <Map<String, dynamic>>[],
  },
};

/// Scripted fake over the reserved port for projection/source/widget tests.
final class FakeCollaborationRunPort implements CollaborationRunPort {
  final StreamController<CollaborationRunSnapshot?> _snapshots =
      StreamController<CollaborationRunSnapshot?>.broadcast();

  final List<CollaborationCommand> sent = [];
  final Map<int, CollaborationGraph> revisionGraphs = {};
  final List<int> loadCalls = [];

  /// When set, `loadRevision(number)` waits for the completer of that number.
  final Map<int, Completer<void>> loadGates = {};
  CollaborationCommandResult nextResult =
      const CollaborationCommandResultAccepted();
  final List<Completer<CollaborationCommandResult>> heldResults = [];
  bool holdResults = false;
  int watchCount = 0;

  void emit(CollaborationRunSnapshot? snapshot) => _snapshots.add(snapshot);

  @override
  Stream<CollaborationRunSnapshot?> watchConversation(String conversationId) {
    watchCount++;
    return _snapshots.stream;
  }

  @override
  Future<CollaborationGraph> loadRevision(String runId, int number) async {
    loadCalls.add(number);
    final gate = loadGates[number];
    if (gate != null) await gate.future;
    final graph = revisionGraphs[number];
    if (graph == null) throw StateError('collaboration_revision_unknown');
    return graph;
  }

  @override
  Future<CollaborationCommandResult> send(
    String runId,
    CollaborationCommand command,
  ) {
    sent.add(command);
    if (holdResults) {
      final completer = Completer<CollaborationCommandResult>();
      heldResults.add(completer);
      return completer.future;
    }
    return Future.value(nextResult);
  }

  Future<void> close() => _snapshots.close();
}
