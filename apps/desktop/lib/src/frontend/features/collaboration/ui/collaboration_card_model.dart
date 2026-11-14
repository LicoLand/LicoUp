import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_graph_layout.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/agents/agent_product_identity.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';

/// How a node relates to the plan the canvas shows.
enum CollaborationPresence {
  /// Part of the shown plan.
  planned,

  /// Added by the held proposal and not approved yet.
  proposed,

  /// In the current plan but dropped by the held proposal.
  removed,
}

/// Statuses that mean a node is doing or waiting on work right now.
const Set<CollaborationNodeStatus> collaborationInProgress = {
  CollaborationNodeStatus.running,
  CollaborationNodeStatus.retrying,
  CollaborationNodeStatus.waitingUser,
  CollaborationNodeStatus.waitingAssistant,
};

/// The graph the canvas renders and every overlay on top of it.
final class CollaborationDisplayPlan {
  CollaborationDisplayPlan._({
    required this.graph,
    required this.structure,
    required this.nodeStates,
    required this.structureOnly,
    required this.proposal,
    required this.diff,
    required this.presence,
    required this.lockedIds,
    required this.addedEdgeKeys,
    required this.removedEdgeKeys,
  });

  /// Builds the plan for [projection].
  ///
  /// A held proposal (while viewing the head) renders the proposed graph with
  /// the nodes it drops kept as ghosts, so the user reviews one picture of the
  /// change. Otherwise the viewed graph renders as is, with the head diff as
  /// tags when [compare] is on. A historical revision carries no states and
  /// no diff.
  factory CollaborationDisplayPlan.of(
    CollaborationProjection projection, {
    required bool compare,
  }) {
    final viewed = projection.graph!;
    final proposal = projection.viewingHead ? projection.proposal : null;
    if (proposal != null) {
      final removed = {
        for (final id in proposal.diff.removedNodes)
          if (viewed.nodeById(id) != null &&
              proposal.graph.nodeById(id) == null)
            id,
      };
      final graph = _withRemovedNodes(
        proposal.graph,
        viewed,
        removed,
        proposal.diff.removedEdges,
      );
      final states = projection.nodeStates;
      return CollaborationDisplayPlan._(
        graph: graph,
        structure: CollaborationGraphStructure.of(graph),
        nodeStates: states,
        structureOnly: false,
        proposal: true,
        diff: proposal.diff,
        presence: {
          for (final id in proposal.diff.addedNodes)
            id: CollaborationPresence.proposed,
          for (final id in removed) id: CollaborationPresence.removed,
        },
        lockedIds: {
          for (final node in graph.nodes)
            if (_lockedByProposal(node.id, proposal.diff, removed, states))
              node.id,
        },
        addedEdgeKeys: {for (final edge in proposal.diff.addedEdges) edge.key},
        removedEdgeKeys: {
          for (final edge in graph.edges)
            if (removed.contains(edge.from) || removed.contains(edge.to))
              edge.key,
          for (final edge in proposal.diff.removedEdges) edge.key,
        },
      );
    }
    final diff = compare && projection.viewingHead ? projection.headDiff : null;
    return CollaborationDisplayPlan._(
      graph: viewed,
      structure: CollaborationGraphStructure.of(viewed),
      nodeStates: projection.nodeStates,
      structureOnly: !projection.viewingHead,
      proposal: false,
      diff: diff,
      presence: const {},
      lockedIds: {
        for (final entry in projection.nodeStates.entries)
          if (entry.value.status == CollaborationNodeStatus.heldForPlan)
            entry.key,
      },
      addedEdgeKeys: {
        for (final edge in diff?.addedEdges ?? const <CollaborationGraphEdge>[])
          edge.key,
      },
      removedEdgeKeys: const {},
    );
  }

  final CollaborationGraph graph;
  final CollaborationGraphStructure structure;
  final Map<String, CollaborationNodeState> nodeStates;

  /// A historical revision: structure only, no live states.
  final bool structureOnly;

  /// Whether a held proposal is shown.
  final bool proposal;

  /// Diff rendered as tags: the proposal diff, or the head diff in compare.
  final CollaborationGraphDiff? diff;
  final Map<String, CollaborationPresence> presence;

  /// Nodes that wait for the proposal decision before they may start.
  final Set<String> lockedIds;

  /// Contract edge keys added by [diff].
  final Set<String> addedEdgeKeys;

  /// Contract edge keys the held proposal drops.
  final Set<String> removedEdgeKeys;

  CollaborationPresence presenceOf(String nodeId) =>
      presence[nodeId] ?? CollaborationPresence.planned;

  CollaborationNodeStatus statusOf(String nodeId) =>
      nodeStates[nodeId]?.status ?? CollaborationNodeStatus.pending;
}

bool _lockedByProposal(
  String id,
  CollaborationGraphDiff diff,
  Set<String> removed,
  Map<String, CollaborationNodeState> states,
) {
  final status = states[id]?.status ?? CollaborationNodeStatus.pending;
  if (status == CollaborationNodeStatus.heldForPlan) return true;
  if (status != CollaborationNodeStatus.pending) return false;
  return removed.contains(id) || diff.changeFor(id) != null;
}

/// [proposed] plus the [removed] nodes of [current], each placed after the
/// nearest preceding node it followed in [current], with their edges.
CollaborationGraph _withRemovedNodes(
  CollaborationGraph proposed,
  CollaborationGraph current,
  Set<String> removed,
  List<CollaborationGraphEdge> removedEdges,
) {
  if (removed.isEmpty && removedEdges.isEmpty) return proposed;
  final nodes = [...proposed.nodes];
  String? previous;
  for (final node in current.nodes) {
    if (removed.contains(node.id)) {
      final at = previous == null
          ? 0
          : nodes.indexWhere((entry) => entry.id == previous) + 1;
      nodes.insert(at, node);
    }
    previous = node.id;
  }
  final ids = {for (final node in nodes) node.id};
  final keys = {for (final edge in proposed.edges) edge.key};
  final edges = [...proposed.edges];
  for (final edge in [...current.edges, ...removedEdges]) {
    final touchesRemoved =
        removed.contains(edge.from) || removed.contains(edge.to);
    final listed = removedEdges.any((entry) => entry.key == edge.key);
    if ((touchesRemoved || listed) &&
        ids.contains(edge.from) &&
        ids.contains(edge.to) &&
        keys.add(edge.key)) {
      edges.add(edge);
    }
  }
  return CollaborationGraph(
    nodes: nodes,
    edges: edges,
    initialNodeId: proposed.initialNodeId,
  );
}

enum CollaborationTagTone { added, changed, proposal, removed }

final class CollaborationCardTag {
  const CollaborationCardTag(this.label, this.tone);

  final String label;
  final CollaborationTagTone tone;
}

enum CollaborationNoteTone { muted, warning, receipt }

/// One annotation line under a task card's status row.
final class CollaborationCardNote {
  const CollaborationCardNote(this.text, this.tone);

  final String text;
  final CollaborationNoteTone tone;
}

/// Renderable content of one display node.
sealed class CollaborationCardModel {
  const CollaborationCardModel({
    required this.id,
    required this.status,
    required this.presence,
  });

  /// The display node id.
  final String id;

  /// The status that drives the card's frame treatment.
  final CollaborationNodeStatus status;
  final CollaborationPresence presence;

  bool get inProgress => collaborationInProgress.contains(status);

  /// One line for assistive technology.
  String get semanticLabel;
}

final class CollaborationTaskCardModel extends CollaborationCardModel {
  CollaborationTaskCardModel({
    required super.id,
    required super.status,
    required super.presence,
    required this.title,
    required this.roleLabel,
    required this.agentId,
    required this.agentLabel,
    required this.modelChip,
    required this.statusLabel,
    required this.actionLabel,
    required this.locked,
    required this.approvedReason,
    required Iterable<CollaborationCardNote> notes,
    required this.tag,
    required this.state,
    required this.node,
  }) : notes = List<CollaborationCardNote>.unmodifiable(notes);

  final String title;
  final String roleLabel;

  /// The agent currently doing the work: the fallback target after a switch.
  final String? agentId;
  final String agentLabel;
  final String? modelChip;

  /// Empty for a historical revision, which shows structure only.
  final String statusLabel;

  /// The status row's trailing action; null for a historical revision.
  final String? actionLabel;
  final bool locked;

  /// The Assistant approved this node's gate with this reason.
  final String? approvedReason;
  final List<CollaborationCardNote> notes;
  final CollaborationCardTag? tag;

  /// Live state; null for a historical revision or an unstarted node.
  final CollaborationNodeState? state;
  final CollaborationGraphNode node;

  @override
  String get semanticLabel => [
    title,
    if (roleLabel.isNotEmpty) roleLabel,
    agentLabel,
    if (statusLabel.isNotEmpty) statusLabel,
    if (tag != null) tag!.label,
  ].join(', ');
}

/// One step of a stack card.
final class CollaborationStepModel {
  const CollaborationStepModel({
    required this.nodeId,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.presence,
    required this.locked,
    required this.tag,
    required this.structureOnly,
  });

  final String nodeId;
  final String title;

  /// `role · agent`.
  final String subtitle;
  final CollaborationNodeStatus status;
  final CollaborationPresence presence;
  final bool locked;
  final CollaborationCardTag? tag;
  final bool structureOnly;
}

final class CollaborationStackCardModel extends CollaborationCardModel {
  CollaborationStackCardModel({
    required super.id,
    required super.status,
    required super.presence,
    required this.headLabel,
    required Iterable<CollaborationStepModel> steps,
  }) : steps = List<CollaborationStepModel>.unmodifiable(steps);

  final String headLabel;
  final List<CollaborationStepModel> steps;

  int get succeeded => steps
      .where((step) => step.status == CollaborationNodeStatus.succeeded)
      .length;

  @override
  String get semanticLabel => [
    '$headLabel ${steps.length}',
    for (final step in steps) step.title,
  ].join(', ');
}

final class CollaborationConnectorModel extends CollaborationCardModel {
  const CollaborationConnectorModel({
    required super.id,
    required super.status,
    required super.presence,
    required this.nodeKind,
    required this.label,
  });

  final CollaborationNodeKind nodeKind;
  final String label;

  @override
  String get semanticLabel => label;
}

final class CollaborationTerminalModel extends CollaborationCardModel {
  const CollaborationTerminalModel({
    required super.id,
    required super.status,
    required super.presence,
    required this.label,
  });

  final String label;

  @override
  String get semanticLabel => label;
}

/// Display label for an agent id; a node without an agent is the Lead's.
String collaborationAgentLabel(String? agentId) =>
    agentId == null ? 'Lead' : agentProductLabel(agentId);

/// Content for every display node of [plan], keyed by display id.
Map<String, CollaborationCardModel> collaborationCardModels(
  CollaborationDisplayPlan plan,
  LicoStrings strings,
) {
  final graph = plan.graph;
  final joins = {
    for (final node in graph.nodes)
      if (node.kind == CollaborationNodeKind.join) node.id,
  };
  return {
    for (final display in plan.structure.nodes)
      display.id: switch (display.kind) {
        CollaborationCardKind.task => _task(
          graph.nodeById(display.id)!,
          plan,
          strings,
          joins,
        ),
        CollaborationCardKind.stack => _stack(display, plan, strings),
        CollaborationCardKind.connector => _connector(
          graph.nodeById(display.id)!,
          plan,
          strings,
        ),
        CollaborationCardKind.terminal => CollaborationTerminalModel(
          id: display.id,
          status: plan.statusOf(display.id),
          presence: plan.presenceOf(display.id),
          label: strings.collaborationDone,
        ),
      },
  };
}

CollaborationTaskCardModel _task(
  CollaborationGraphNode node,
  CollaborationDisplayPlan plan,
  LicoStrings strings,
  Set<String> joins,
) {
  final state = plan.structureOnly ? null : plan.nodeStates[node.id];
  final status = state?.status ?? CollaborationNodeStatus.pending;
  final locked = !plan.structureOnly && plan.lockedIds.contains(node.id);
  final fallback = state?.fallback;
  final agentId = fallback?.toAgentId ?? node.agentId;
  final effort = node.reasoningEffort;
  final chipParts = [
    // A fallback switches the agent, so the authored model and its effort no
    // longer apply.
    if (fallback == null && node.modelLabel != null) node.modelLabel!,
    if (fallback == null && effort != null)
      strings.reasoningEffortOptionLabel(effort, effort),
  ];
  final review = state?.gate?.review;
  final notes = <CollaborationCardNote>[
    if (status == CollaborationNodeStatus.failed)
      CollaborationCardNote(
        strings.collaborationFailedNote(state!.attempt, state.maxAttempts),
        CollaborationNoteTone.warning,
      ),
    if (review is CollaborationGateEscalated)
      CollaborationCardNote(
        strings.collaborationAssistantNote(review.assistantNote),
        CollaborationNoteTone.warning,
      ),
    if (fallback != null)
      CollaborationCardNote(
        strings.collaborationFallbackReceipt(
          collaborationAgentLabel(fallback.fromAgentId),
          collaborationAgentLabel(fallback.toAgentId),
          strings.collaborationFailureClass(fallback.failureClass),
        ),
        CollaborationNoteTone.receipt,
      ),
    if (status == CollaborationNodeStatus.succeeded &&
        _awaitsMerge(node.id, plan, joins))
      CollaborationCardNote(
        strings.collaborationAwaitingMerge(
          withArtifacts: state!.artifactCount > 0,
        ),
        CollaborationNoteTone.muted,
      ),
  ];
  final String statusLabel;
  if (plan.structureOnly) {
    statusLabel = '';
  } else if (locked) {
    statusLabel = strings.collaborationHeldForPlan;
  } else if (status == CollaborationNodeStatus.retrying) {
    statusLabel = strings.collaborationRetrying(state!.attempt);
  } else {
    statusLabel = strings.collaborationNodeStatus(status);
  }
  final artifacts = state?.artifactCount ?? 0;
  // A pending node has no progress to open yet, so it shows no action.
  final showAction =
      artifacts > 0 ||
      collaborationInProgress.contains(status) ||
      status == CollaborationNodeStatus.succeeded;
  return CollaborationTaskCardModel(
    id: node.id,
    status: status,
    presence: plan.presenceOf(node.id),
    title: node.label,
    roleLabel: node.roleLabel ?? '',
    agentId: agentId,
    agentLabel: collaborationAgentLabel(agentId),
    modelChip: chipParts.isEmpty ? null : chipParts.join(' · '),
    statusLabel: statusLabel,
    actionLabel: plan.structureOnly || !showAction
        ? null
        : artifacts > 0
        ? strings.collaborationArtifactCount(artifacts)
        : strings.collaborationViewProgress,
    locked: locked,
    approvedReason: review is CollaborationGateAssistantApproved
        ? review.reason
        : null,
    notes: notes,
    tag: _tagOf(node.id, plan, strings),
    state: state,
    node: node,
  );
}

/// The task model for one graph node, for the node-details popover. A stack
/// card resolves its hot step to this.
CollaborationTaskCardModel collaborationTaskModel(
  CollaborationDisplayPlan plan,
  String nodeId,
  LicoStrings strings,
) {
  final joins = {
    for (final node in plan.graph.nodes)
      if (node.kind == CollaborationNodeKind.join) node.id,
  };
  return _task(plan.graph.nodeById(nodeId)!, plan, strings, joins);
}

bool _awaitsMerge(String id, CollaborationDisplayPlan plan, Set<String> joins) {
  for (final edge in plan.graph.edges) {
    if (edge.from == id &&
        !edge.callback &&
        joins.contains(edge.to) &&
        plan.statusOf(edge.to) != CollaborationNodeStatus.succeeded) {
      return true;
    }
  }
  return false;
}

CollaborationCardTag? _tagOf(
  String id,
  CollaborationDisplayPlan plan,
  LicoStrings strings,
) {
  switch (plan.presenceOf(id)) {
    case CollaborationPresence.proposed:
      return CollaborationCardTag(
        strings.collaborationProposalTag,
        CollaborationTagTone.proposal,
      );
    case CollaborationPresence.removed:
      return CollaborationCardTag(
        strings.collaborationRemovedTag,
        CollaborationTagTone.removed,
      );
    case CollaborationPresence.planned:
      break;
  }
  final diff = plan.diff;
  if (diff == null) return null;
  if (!plan.proposal && diff.addedNodes.contains(id)) {
    return CollaborationCardTag(
      strings.collaborationAddedTag,
      CollaborationTagTone.added,
    );
  }
  final change = diff.changeFor(id);
  if (change == null) return null;
  final to = collaborationAgentLabel(change.toAgentId);
  return switch ((plan.proposal, change.kind)) {
    (true, CollaborationChangeKind.reassigned) => CollaborationCardTag(
      strings.collaborationProposalReassignTo(to),
      CollaborationTagTone.proposal,
    ),
    (true, CollaborationChangeKind.adjusted) => CollaborationCardTag(
      strings.collaborationProposalAdjustTag,
      CollaborationTagTone.proposal,
    ),
    (false, CollaborationChangeKind.reassigned) => CollaborationCardTag(
      strings.collaborationReassignedFromTo(
        collaborationAgentLabel(change.fromAgentId),
        to,
      ),
      CollaborationTagTone.changed,
    ),
    (false, CollaborationChangeKind.adjusted) => CollaborationCardTag(
      strings.collaborationAdjustedTag,
      CollaborationTagTone.changed,
    ),
  };
}

CollaborationStackCardModel _stack(
  CollaborationDisplayNode display,
  CollaborationDisplayPlan plan,
  LicoStrings strings,
) {
  final steps = <CollaborationStepModel>[];
  for (final id in display.memberIds) {
    final node = plan.graph.nodeById(id)!;
    final status = plan.structureOnly
        ? CollaborationNodeStatus.pending
        : plan.statusOf(id);
    final role = node.roleLabel;
    final agent = collaborationAgentLabel(node.agentId);
    steps.add(
      CollaborationStepModel(
        nodeId: id,
        title: node.label,
        subtitle: role == null
            ? agent
            : strings.collaborationStepRole(role, agent),
        status: status,
        presence: plan.presenceOf(id),
        locked: !plan.structureOnly && plan.lockedIds.contains(id),
        tag: _tagOf(id, plan, strings),
        structureOnly: plan.structureOnly,
      ),
    );
  }
  final presences = {for (final step in steps) step.presence};
  return CollaborationStackCardModel(
    id: display.id,
    status: _aggregate([for (final step in steps) step.status]),
    presence: presences.length == 1
        ? presences.single
        : CollaborationPresence.planned,
    headLabel: strings.collaborationStackHead,
    steps: steps,
  );
}

/// The status a multi-step card shows: what needs attention first.
CollaborationNodeStatus _aggregate(List<CollaborationNodeStatus> statuses) {
  const priority = [
    CollaborationNodeStatus.waitingUser,
    CollaborationNodeStatus.failed,
    CollaborationNodeStatus.retrying,
    CollaborationNodeStatus.running,
    CollaborationNodeStatus.waitingAssistant,
    CollaborationNodeStatus.heldForPlan,
  ];
  for (final status in priority) {
    if (statuses.contains(status)) return status;
  }
  if (statuses.isNotEmpty &&
      statuses.every((status) => status == CollaborationNodeStatus.succeeded)) {
    return CollaborationNodeStatus.succeeded;
  }
  if (statuses.contains(CollaborationNodeStatus.cancelled)) {
    return CollaborationNodeStatus.cancelled;
  }
  return CollaborationNodeStatus.pending;
}

CollaborationConnectorModel _connector(
  CollaborationGraphNode node,
  CollaborationDisplayPlan plan,
  LicoStrings strings,
) => CollaborationConnectorModel(
  id: node.id,
  status: plan.structureOnly
      ? CollaborationNodeStatus.pending
      : plan.statusOf(node.id),
  presence: plan.presenceOf(node.id),
  nodeKind: node.kind,
  label: switch (node.kind) {
    CollaborationNodeKind.fork => strings.collaborationDispatch,
    CollaborationNodeKind.join => strings.collaborationMerge,
    CollaborationNodeKind.choice => strings.collaborationChoice,
    _ => strings.collaborationPass,
  },
);

/// How one route is drawn.
final class CollaborationEdgeStyle {
  const CollaborationEdgeStyle({
    required this.kind,
    this.active = false,
    this.added = false,
    this.ghost = false,
  });

  final CollaborationRouteKind kind;

  /// Work is flowing along this edge right now.
  final bool active;

  /// Added by the shown diff.
  final bool added;

  /// Touches a proposal ghost or is dropped by the proposal.
  final bool ghost;
}

/// Draw style for every route of [plan], keyed by route key.
Map<String, CollaborationEdgeStyle> collaborationEdgeStyles(
  CollaborationDisplayPlan plan,
) {
  final structure = plan.structure;
  CollaborationNodeStatus endStatus(String displayId, {required bool head}) {
    final members = structure.nodeFor(displayId)!.memberIds;
    return plan.statusOf(head ? members.first : members.last);
  }

  bool ghostCard(String displayId) => structure
      .nodeFor(displayId)!
      .memberIds
      .every((id) => plan.presenceOf(id) != CollaborationPresence.planned);

  return {
    for (final edge in structure.edges)
      edge.key: CollaborationEdgeStyle(
        kind: edge.kind,
        active:
            !plan.structureOnly &&
            collaborationInProgress.contains(endStatus(edge.to, head: true)) &&
            const {
              CollaborationNodeStatus.succeeded,
              CollaborationNodeStatus.failed,
            }.contains(endStatus(edge.from, head: false)),
        added: edge.edges.any(
          (entry) => plan.addedEdgeKeys.contains(entry.key),
        ),
        ghost:
            ghostCard(edge.from) ||
            ghostCard(edge.to) ||
            edge.edges.every(
              (entry) => plan.removedEdgeKeys.contains(entry.key),
            ),
      ),
  };
}
