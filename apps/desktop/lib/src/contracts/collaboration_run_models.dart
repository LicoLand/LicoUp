/// Hand-written DTOs for the collaboration run projection.
///
/// Wire names follow DESIGN-SPEC.md section 4: field keys are the camelCase
/// names given there; enum and review-state values are the snake_case strings
/// given there. Payloads are identifier-level plus safe labels; transcripts,
/// prompts, tool output and paths never enter them.
///
/// Every `fromJson` throws [FormatException] with
/// `collaboration_run_payload_invalid` when a required field is missing or
/// has the wrong type, an enum wire name is unknown, a collection exceeds its
/// bound, a node id repeats, or the initial node, an edge or a node state
/// references an unknown node id.
const String collaborationRunInvalidPayload =
    'collaboration_run_payload_invalid';

/// Reported when no native producer serves collaboration runs.
const String collaborationRunUnavailable = 'collaboration_run_unavailable';

/// Reported in place of any adapter failure that does not carry a stable
/// machine code, so free-form error text never reaches the renderer.
const String collaborationCommandFailed = 'collaboration_command_failed';

const int collaborationRunMaxNodes = 512;
const int collaborationRunMaxEdges = 2048;

Never _invalid([String? detail]) =>
    throw FormatException(collaborationRunInvalidPayload, detail);

enum CollaborationRunStatus {
  running('running'),
  waiting('waiting'),
  completed('completed'),
  failed('failed'),
  blocked('blocked'),
  cancelled('cancelled');

  const CollaborationRunStatus(this.wireName);

  final String wireName;

  static CollaborationRunStatus fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

enum CollaborationNodeKind {
  actor('actor'),
  workset('workset'),
  script('script'),
  authorization('authorization'),
  choice('choice'),
  fork('fork'),
  join('join'),
  pass('pass'),
  terminal('terminal');

  const CollaborationNodeKind(this.wireName);

  final String wireName;

  /// Kinds whose visits count toward run progress.
  static const Set<CollaborationNodeKind> workKinds = {
    CollaborationNodeKind.actor,
    CollaborationNodeKind.workset,
  };

  static CollaborationNodeKind fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

enum CollaborationNodeStatus {
  pending('pending'),
  running('running'),
  waitingUser('waiting_user'),
  waitingAssistant('waiting_assistant'),
  succeeded('succeeded'),
  failed('failed'),
  retrying('retrying'),
  cancelled('cancelled'),
  heldForPlan('held_for_plan');

  const CollaborationNodeStatus(this.wireName);

  final String wireName;

  static CollaborationNodeStatus fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

enum CollaborationRevisionApproval {
  autoApplied('auto_applied'),
  approved('approved'),
  pending('pending'),
  rejected('rejected');

  const CollaborationRevisionApproval(this.wireName);

  final String wireName;

  static CollaborationRevisionApproval fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

enum CollaborationRevisionAuthor {
  assistant('assistant'),
  user('user');

  const CollaborationRevisionAuthor(this.wireName);

  final String wireName;

  static CollaborationRevisionAuthor fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

enum CollaborationPlanChangePolicy {
  auto('auto'),
  ask('ask');

  const CollaborationPlanChangePolicy(this.wireName);

  final String wireName;

  static CollaborationPlanChangePolicy fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

enum CollaborationGateReviewPolicy {
  assistant('assistant'),
  user('user');

  const CollaborationGateReviewPolicy(this.wireName);

  final String wireName;

  static CollaborationGateReviewPolicy fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

enum CollaborationChangeKind {
  reassigned('reassigned'),
  adjusted('adjusted');

  const CollaborationChangeKind(this.wireName);

  final String wireName;

  static CollaborationChangeKind fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

/// The typed transition events of the Graph contract.
enum CollaborationEdgeEvent {
  complete('complete'),
  success('success'),
  failure('failure');

  const CollaborationEdgeEvent(this.wireName);

  final String wireName;

  static CollaborationEdgeEvent fromWire(Object? value) =>
      _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

/// Node handoff mode. A missing mode is `flow`; a `callback` edge parks the
/// run until the master agent decides.
enum CollaborationEdgeMode {
  flow('flow'),
  callback('callback');

  const CollaborationEdgeMode(this.wireName);

  final String wireName;

  static CollaborationEdgeMode fromWire(Object? value) => value == null
      ? CollaborationEdgeMode.flow
      : _enumValue(values, value, (v) => v.wireName) ?? _invalid();
}

T? _enumValue<T>(List<T> values, Object? value, String Function(T) wireName) {
  for (final entry in values) {
    if (wireName(entry) == value) return entry;
  }
  return null;
}

Map<String, dynamic> _reqMap(Object? value) {
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return _invalid();
}

Map<String, dynamic>? _optMap(Object? value) =>
    value == null ? null : _reqMap(value);

String _reqString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  return _invalid(key);
}

/// Optional label: absent or empty is null; any non-string is invalid.
String? _optString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) _invalid(key);
  return value.isEmpty ? null : value;
}

int _reqInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toInt();
  return _invalid();
}

int _optInt(Map<String, dynamic> json, String key, [int fallback = 0]) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is num) return value.toInt();
  return _invalid();
}

int? _optIntOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is num) return value.toInt();
  return _invalid();
}

List<Map<String, dynamic>> _reqMaps(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) _invalid();
  return value.map((entry) => _reqMap(entry)).toList(growable: false);
}

List<String> _reqStrings(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) _invalid();
  return value
      .map((entry) => entry is String && entry.isNotEmpty ? entry : _invalid())
      .toList(growable: false);
}

/// One entry of a run's immutable revision chain.
final class CollaborationRevisionSummary {
  const CollaborationRevisionSummary({
    required this.number,
    required this.digest,
    this.parent,
    required this.author,
    required this.authoredAt,
    required this.reason,
    required this.added,
    required this.removed,
    required this.changed,
    required this.approval,
    this.revertOf,
  });

  factory CollaborationRevisionSummary.fromJson(Map<String, dynamic> json) {
    final stats = _reqMap(json['stats']);
    return CollaborationRevisionSummary(
      number: _reqInt(json, 'number'),
      digest: _reqString(json, 'digest'),
      parent: _optIntOrNull(json, 'parent'),
      author: CollaborationRevisionAuthor.fromWire(json['author']),
      authoredAt: _reqInt(json, 'authoredAt'),
      reason: _reqString(json, 'reason'),
      added: _reqInt(stats, 'added'),
      removed: _reqInt(stats, 'removed'),
      changed: _reqInt(stats, 'changed'),
      approval: CollaborationRevisionApproval.fromWire(json['approval']),
      revertOf: _optIntOrNull(json, 'revertOf'),
    );
  }

  final int number;
  final String digest;
  final int? parent;
  final CollaborationRevisionAuthor author;
  final int authoredAt;
  final String reason;
  final int added;
  final int removed;
  final int changed;
  final CollaborationRevisionApproval approval;
  final int? revertOf;

  /// First 7 characters of the digest, as shown by the revision chip.
  String get shortDigest =>
      digest.length <= 7 ? digest : digest.substring(0, 7);
}

final class CollaborationGraphNode {
  const CollaborationGraphNode({
    required this.id,
    required this.kind,
    required this.label,
    this.group,
    this.roleLabel,
    this.membershipId,
    this.agentId,
    this.modelLabel,
    this.reasoningEffort,
  });

  factory CollaborationGraphNode.fromJson(Map<String, dynamic> json) =>
      CollaborationGraphNode(
        id: _reqString(json, 'id'),
        kind: CollaborationNodeKind.fromWire(json['kind']),
        label: _reqString(json, 'label'),
        group: _optString(json, 'group'),
        roleLabel: _optString(json, 'roleLabel'),
        membershipId: _optString(json, 'membershipId'),
        agentId: _optString(json, 'agentId'),
        modelLabel: _optString(json, 'modelLabel'),
        reasoningEffort: _optString(json, 'reasoningEffort'),
      );

  final String id;
  final CollaborationNodeKind kind;
  final String label;

  /// Author-declared column label shared by the nodes of one phase.
  final String? group;

  /// Author-declared label of the actor slot this node fills.
  final String? roleLabel;
  final String? membershipId;
  final String? agentId;
  final String? modelLabel;
  final String? reasoningEffort;
}

/// Edges are keyed by `(from, to, event)`.
final class CollaborationGraphEdge {
  const CollaborationGraphEdge({
    required this.from,
    required this.to,
    required this.event,
    this.mode = CollaborationEdgeMode.flow,
    this.guardLabel = '',
  });

  factory CollaborationGraphEdge.fromJson(Map<String, dynamic> json) =>
      CollaborationGraphEdge(
        from: _reqString(json, 'from'),
        to: _reqString(json, 'to'),
        event: CollaborationEdgeEvent.fromWire(json['event']),
        mode: CollaborationEdgeMode.fromWire(json['mode']),
        guardLabel: _optString(json, 'guardLabel') ?? '',
      );

  final String from;
  final String to;
  final CollaborationEdgeEvent event;
  final CollaborationEdgeMode mode;
  final String guardLabel;

  bool get callback => mode == CollaborationEdgeMode.callback;

  String get key => '$from>$to>${event.wireName}';
}

final class CollaborationGraph {
  CollaborationGraph({
    required Iterable<CollaborationGraphNode> nodes,
    required Iterable<CollaborationGraphEdge> edges,
    required this.initialNodeId,
  }) : nodes = List<CollaborationGraphNode>.unmodifiable(nodes),
       edges = List<CollaborationGraphEdge>.unmodifiable(edges) {
    if (this.nodes.length > collaborationRunMaxNodes ||
        this.edges.length > collaborationRunMaxEdges) {
      _invalid();
    }
    final ids = <String>{};
    for (final node in this.nodes) {
      if (!ids.add(node.id)) _invalid(node.id);
    }
    if (!ids.contains(initialNodeId)) _invalid(initialNodeId);
    for (final edge in this.edges) {
      if (!ids.contains(edge.from) || !ids.contains(edge.to)) {
        _invalid(edge.key);
      }
    }
  }

  factory CollaborationGraph.fromJson(Map<String, dynamic> json) =>
      CollaborationGraph(
        nodes: _reqMaps(json, 'nodes').map(CollaborationGraphNode.fromJson),
        edges: _reqMaps(json, 'edges').map(CollaborationGraphEdge.fromJson),
        initialNodeId: _reqString(json, 'initial'),
      );

  final List<CollaborationGraphNode> nodes;
  final List<CollaborationGraphEdge> edges;
  final String initialNodeId;

  CollaborationGraphNode? nodeById(String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }
}

final class CollaborationFallback {
  const CollaborationFallback({
    required this.fromAgentId,
    required this.toAgentId,
    required this.failureClass,
  });

  factory CollaborationFallback.fromJson(Map<String, dynamic> json) =>
      CollaborationFallback(
        fromAgentId: _reqString(json, 'fromAgentId'),
        toAgentId: _reqString(json, 'toAgentId'),
        failureClass: _reqString(json, 'failureClass'),
      );

  final String fromAgentId;
  final String toAgentId;
  final String failureClass;
}

/// How a decision gate is currently being handled.
sealed class CollaborationGateReview {
  const CollaborationGateReview();

  factory CollaborationGateReview.fromJson(Object? value) {
    if (value is String) {
      return value == 'waiting_user'
          ? const CollaborationGateWaitingUser()
          : _invalid();
    }
    if (value is Map) {
      final map = _reqMap(value);
      return switch (map['state']) {
        'waiting_user' => const CollaborationGateWaitingUser(),
        'escalated' => CollaborationGateEscalated(
          _reqString(map, 'assistantNote'),
        ),
        'assistant_approved' => CollaborationGateAssistantApproved(
          _reqString(map, 'reason'),
        ),
        _ => _invalid(),
      };
    }
    return _invalid();
  }
}

final class CollaborationGateWaitingUser extends CollaborationGateReview {
  const CollaborationGateWaitingUser();
}

/// The Assistant could not decide; the gate waits for the user together with
/// the Assistant's note.
final class CollaborationGateEscalated extends CollaborationGateReview {
  const CollaborationGateEscalated(this.assistantNote);

  final String assistantNote;
}

final class CollaborationGateAssistantApproved extends CollaborationGateReview {
  const CollaborationGateAssistantApproved(this.reason);

  final String reason;
}

final class CollaborationGateOption {
  const CollaborationGateOption({required this.id, required this.label});

  factory CollaborationGateOption.fromJson(Map<String, dynamic> json) =>
      CollaborationGateOption(
        id: _reqString(json, 'id'),
        label: _reqString(json, 'label'),
      );

  final String id;
  final String label;
}

final class CollaborationGate {
  CollaborationGate({
    required this.gateId,
    required this.title,
    required this.detail,
    required Iterable<CollaborationGateOption> options,
    required this.review,
  }) : options = List<CollaborationGateOption>.unmodifiable(options);

  factory CollaborationGate.fromJson(Map<String, dynamic> json) =>
      CollaborationGate(
        gateId: _reqString(json, 'gateId'),
        title: _reqString(json, 'title'),
        detail: _reqString(json, 'detail'),
        options: _reqMaps(
          json,
          'options',
        ).map(CollaborationGateOption.fromJson),
        review: CollaborationGateReview.fromJson(json['review']),
      );

  final String gateId;
  final String title;
  final String detail;
  final List<CollaborationGateOption> options;
  final CollaborationGateReview review;
}

final class CollaborationNodeState {
  const CollaborationNodeState({
    required this.status,
    this.visit = 0,
    this.attempt = 1,
    this.maxAttempts = 1,
    this.startedRevision = 0,
    this.fallback,
    this.artifactCount = 0,
    this.gate,
  });

  factory CollaborationNodeState.fromJson(Map<String, dynamic> json) =>
      CollaborationNodeState(
        status: CollaborationNodeStatus.fromWire(json['status']),
        visit: _optInt(json, 'visit'),
        attempt: _optInt(json, 'attempt', 1),
        maxAttempts: _optInt(json, 'maxAttempts', 1),
        startedRevision: _optInt(json, 'startedRevision'),
        fallback: switch (_optMap(json['fallback'])) {
          null => null,
          final value => CollaborationFallback.fromJson(value),
        },
        artifactCount: _optInt(json, 'artifactCount'),
        gate: switch (_optMap(json['gate'])) {
          null => null,
          final value => CollaborationGate.fromJson(value),
        },
      );

  final CollaborationNodeStatus status;
  final int visit;
  final int attempt;
  final int maxAttempts;
  final int startedRevision;
  final CollaborationFallback? fallback;
  final int artifactCount;
  final CollaborationGate? gate;
}

final class CollaborationNodeChange {
  const CollaborationNodeChange({
    required this.id,
    required this.kind,
    this.fromAgentId,
    this.toAgentId,
  });

  factory CollaborationNodeChange.fromJson(Map<String, dynamic> json) =>
      CollaborationNodeChange(
        id: _reqString(json, 'id'),
        kind: CollaborationChangeKind.fromWire(json['kind']),
        fromAgentId: _optString(json, 'fromAgentId'),
        toAgentId: _optString(json, 'toAgentId'),
      );

  final String id;
  final CollaborationChangeKind kind;
  final String? fromAgentId;
  final String? toAgentId;
}

/// Per-revision structural diff, derived from the stored delta.
final class CollaborationGraphDiff {
  CollaborationGraphDiff({
    Iterable<String> addedNodes = const [],
    Iterable<String> removedNodes = const [],
    Iterable<CollaborationNodeChange> changedNodes = const [],
    Iterable<CollaborationGraphEdge> addedEdges = const [],
    Iterable<CollaborationGraphEdge> removedEdges = const [],
  }) : addedNodes = List<String>.unmodifiable(addedNodes),
       removedNodes = List<String>.unmodifiable(removedNodes),
       changedNodes = List<CollaborationNodeChange>.unmodifiable(changedNodes),
       addedEdges = List<CollaborationGraphEdge>.unmodifiable(addedEdges),
       removedEdges = List<CollaborationGraphEdge>.unmodifiable(removedEdges);

  factory CollaborationGraphDiff.fromJson(Map<String, dynamic> json) =>
      CollaborationGraphDiff(
        addedNodes: _reqStrings(json, 'addedNodes'),
        removedNodes: _reqStrings(json, 'removedNodes'),
        changedNodes: _reqMaps(
          json,
          'changedNodes',
        ).map(CollaborationNodeChange.fromJson),
        addedEdges: _reqMaps(
          json,
          'addedEdges',
        ).map(CollaborationGraphEdge.fromJson),
        removedEdges: _reqMaps(
          json,
          'removedEdges',
        ).map(CollaborationGraphEdge.fromJson),
      );

  final List<String> addedNodes;
  final List<String> removedNodes;
  final List<CollaborationNodeChange> changedNodes;
  final List<CollaborationGraphEdge> addedEdges;
  final List<CollaborationGraphEdge> removedEdges;

  CollaborationNodeChange? changeFor(String nodeId) {
    for (final change in changedNodes) {
      if (change.id == nodeId) return change;
    }
    return null;
  }
}

/// A held plan revision awaiting user approval (`ask` policy).
final class CollaborationProposal {
  const CollaborationProposal({
    required this.revision,
    required this.graph,
    required this.diff,
  });

  factory CollaborationProposal.fromJson(Map<String, dynamic> json) =>
      CollaborationProposal(
        revision: CollaborationRevisionSummary.fromJson(
          _reqMap(json['revision']),
        ),
        graph: CollaborationGraph.fromJson(_reqMap(json['graph'])),
        diff: CollaborationGraphDiff.fromJson(_reqMap(json['diff'])),
      );

  final CollaborationRevisionSummary revision;
  final CollaborationGraph graph;
  final CollaborationGraphDiff diff;
}

/// One pushed projection of a Conversation's collaboration run.
final class CollaborationRunSnapshot {
  CollaborationRunSnapshot({
    required this.runId,
    required this.conversationId,
    required this.status,
    required this.startedAt,
    required this.updatedAt,
    required this.planChangePolicy,
    required this.gateReviewPolicy,
    required this.headNumber,
    required Iterable<CollaborationRevisionSummary> revisions,
    required this.graph,
    required Map<String, CollaborationNodeState> nodeStates,
    this.headDiff,
    this.proposal,
  }) : revisions = List<CollaborationRevisionSummary>.unmodifiable(revisions),
       nodeStates = Map<String, CollaborationNodeState>.unmodifiable(
         nodeStates,
       ) {
    final ids = graph.nodes.map((node) => node.id).toSet();
    for (final nodeId in this.nodeStates.keys) {
      if (!ids.contains(nodeId)) _invalid(nodeId);
    }
  }

  factory CollaborationRunSnapshot.fromJson(Map<String, dynamic> json) {
    final policy = _reqMap(json['policy']);
    final states = <String, CollaborationNodeState>{};
    for (final entry in _reqMap(json['nodeStates']).entries) {
      states[entry.key] = CollaborationNodeState.fromJson(_reqMap(entry.value));
    }
    return CollaborationRunSnapshot(
      runId: _reqString(json, 'runId'),
      conversationId: _reqString(json, 'conversationId'),
      status: CollaborationRunStatus.fromWire(json['status']),
      startedAt: _reqInt(json, 'startedAt'),
      updatedAt: _reqInt(json, 'updatedAt'),
      planChangePolicy: CollaborationPlanChangePolicy.fromWire(
        policy['planChange'],
      ),
      gateReviewPolicy: CollaborationGateReviewPolicy.fromWire(
        policy['gateReview'],
      ),
      headNumber: _reqInt(json, 'head'),
      revisions: _reqMaps(
        json,
        'revisions',
      ).map(CollaborationRevisionSummary.fromJson),
      graph: CollaborationGraph.fromJson(_reqMap(json['graph'])),
      nodeStates: states,
      headDiff: switch (_optMap(json['headDiff'])) {
        null => null,
        final value => CollaborationGraphDiff.fromJson(value),
      },
      proposal: switch (_optMap(json['proposal'])) {
        null => null,
        final value => CollaborationProposal.fromJson(value),
      },
    );
  }

  final String runId;
  final String conversationId;
  final CollaborationRunStatus status;
  final int startedAt;
  final int updatedAt;
  final CollaborationPlanChangePolicy planChangePolicy;
  final CollaborationGateReviewPolicy gateReviewPolicy;
  final int headNumber;

  /// Revision summaries ascending by number.
  final List<CollaborationRevisionSummary> revisions;

  /// The head revision's complete graph.
  final CollaborationGraph graph;
  final Map<String, CollaborationNodeState> nodeStates;
  final CollaborationGraphDiff? headDiff;
  final CollaborationProposal? proposal;

  CollaborationRevisionSummary? get head {
    for (final revision in revisions) {
      if (revision.number == headNumber) return revision;
    }
    return null;
  }
}

/// Renderer-initiated commands. Every case carries the head number the sender
/// observed so a stale command returns a typed conflict.
sealed class CollaborationCommand {
  const CollaborationCommand({required this.expectedHead});

  final int expectedHead;

  Map<String, dynamic> toJson();

  Map<String, dynamic> _base(String type) => <String, dynamic>{
    'type': type,
    'expectedHead': expectedHead,
  };
}

final class ApproveProposal extends CollaborationCommand {
  const ApproveProposal({required this.number, required super.expectedHead});

  final int number;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._base('approveProposal'),
    'number': number,
  };
}

final class RejectProposal extends CollaborationCommand {
  const RejectProposal({required this.number, required super.expectedHead});

  final int number;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._base('rejectProposal'),
    'number': number,
  };
}

/// Asks the Assistant to revise a held proposal; [note] becomes a
/// Conversation message and the proposal stays pending.
final class RequestRevision extends CollaborationCommand {
  const RequestRevision({
    required this.number,
    required this.note,
    required super.expectedHead,
  });

  final int number;
  final String note;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._base('requestRevision'),
    'number': number,
    'note': note,
  };
}

/// Creates a new revision whose content equals [number]; history is never
/// rewritten.
final class RevertTo extends CollaborationCommand {
  const RevertTo({required this.number, required super.expectedHead});

  final int number;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._base('revertTo'),
    'number': number,
  };
}

final class DecideGate extends CollaborationCommand {
  const DecideGate({
    required this.gateId,
    required this.optionId,
    required super.expectedHead,
  });

  final String gateId;
  final String optionId;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._base('decideGate'),
    'gateId': gateId,
    'optionId': optionId,
  };
}

final class SetPlanChangePolicy extends CollaborationCommand {
  const SetPlanChangePolicy({
    required this.policy,
    required super.expectedHead,
  });

  final CollaborationPlanChangePolicy policy;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._base('setPolicy'),
    'policy': 'planChange',
    'value': policy.wireName,
  };
}

final class SetGateReviewPolicy extends CollaborationCommand {
  const SetGateReviewPolicy({
    required this.policy,
    required super.expectedHead,
  });

  final CollaborationGateReviewPolicy policy;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._base('setPolicy'),
    'policy': 'gateReview',
    'value': policy.wireName,
  };
}

/// Typed result of a [CollaborationCommand].
sealed class CollaborationCommandResult {
  const CollaborationCommandResult();

  factory CollaborationCommandResult.fromJson(Map<String, dynamic> json) =>
      switch (json['result']) {
        'accepted' => const CollaborationCommandResultAccepted(),
        'conflict' => CollaborationCommandResultConflict(
          _reqInt(json, 'currentHead'),
        ),
        'rejected' => CollaborationCommandResultRejected(
          _reqString(json, 'code'),
        ),
        _ => _invalid(),
      };
}

final class CollaborationCommandResultAccepted
    extends CollaborationCommandResult {
  const CollaborationCommandResultAccepted();
}

/// The command's `expectedHead` was stale; carries the current head.
final class CollaborationCommandResultConflict
    extends CollaborationCommandResult {
  const CollaborationCommandResultConflict(this.currentHead);

  final int currentHead;
}

final class CollaborationCommandResultRejected
    extends CollaborationCommandResult {
  const CollaborationCommandResultRejected(this.code);

  final String code;
}
