import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Whether the conversation has a renderable collaboration run.
enum CollaborationAvailability {
  /// Observation started and the port has not answered yet.
  loading,

  /// The port answered: this conversation has no collaboration run.
  none,

  /// The run port cannot serve this conversation.
  unavailable,

  /// A run snapshot is available.
  active,
}

/// Renderer-facing projection of one conversation's collaboration run.
///
/// `graph` is the viewed revision's complete graph — the head revision unless
/// the user selected a historical one. `nodeStates` is populated only while
/// viewing the head; a historical view shows structure only.
final class CollaborationProjection {
  CollaborationProjection({
    required this.availability,
    this.runId = '',
    this.conversationId = '',
    this.status,
    this.headNumber = 0,
    this.succeededWork = 0,
    this.totalWork = 0,
    this.head,
    Iterable<CollaborationRevisionSummary> revisions = const [],
    this.viewedNumber,
    this.graph,
    this.nodeStates = const {},
    this.headDiff,
    this.proposal,
    this.planChangePolicy = CollaborationPlanChangePolicy.ask,
    this.gateReviewPolicy = CollaborationGateReviewPolicy.assistant,
    this.commandPending = false,
  }) : revisions = immutablePresentationList(revisions);

  CollaborationProjection.loading()
    : this(availability: CollaborationAvailability.loading);

  CollaborationProjection.none()
    : this(availability: CollaborationAvailability.none);

  CollaborationProjection.unavailable()
    : this(availability: CollaborationAvailability.unavailable);

  final CollaborationAvailability availability;
  final String runId;
  final String conversationId;
  final CollaborationRunStatus? status;
  final int headNumber;

  /// Succeeded actor/workset nodes over all actor/workset nodes in the head.
  final int succeededWork;
  final int totalWork;

  /// Head revision summary; null when the snapshot carries no revisions.
  final CollaborationRevisionSummary? head;

  /// Revision summaries, newest first.
  final List<CollaborationRevisionSummary> revisions;

  /// The revision the user is viewing; equals [headNumber] while viewing the
  /// head.
  final int? viewedNumber;

  /// Complete graph of [viewedNumber].
  final CollaborationGraph? graph;

  /// Live node states; empty while viewing a historical revision.
  ///
  /// Shared with the snapshot, which already holds an unmodifiable map, so
  /// equality can compare identity instead of copying per emission.
  final Map<String, CollaborationNodeState> nodeStates;

  /// Head diff against its parent (drives the compare overlay).
  final CollaborationGraphDiff? headDiff;

  /// Held plan proposal under the `ask` policy.
  final CollaborationProposal? proposal;
  final CollaborationPlanChangePolicy planChangePolicy;
  final CollaborationGateReviewPolicy gateReviewPolicy;

  /// A command is in flight; command controls render disabled.
  final bool commandPending;

  bool get isActive => availability == CollaborationAvailability.active;

  bool get viewingHead => viewedNumber == null || viewedNumber == headNumber;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CollaborationProjection &&
          other.availability == availability &&
          other.runId == runId &&
          other.conversationId == conversationId &&
          other.status == status &&
          other.headNumber == headNumber &&
          other.succeededWork == succeededWork &&
          other.totalWork == totalWork &&
          identical(other.head, head) &&
          samePresentationList(other.revisions, revisions) &&
          other.viewedNumber == viewedNumber &&
          identical(other.graph, graph) &&
          identical(other.nodeStates, nodeStates) &&
          identical(other.headDiff, headDiff) &&
          identical(other.proposal, proposal) &&
          other.planChangePolicy == planChangePolicy &&
          other.gateReviewPolicy == gateReviewPolicy &&
          other.commandPending == commandPending;

  @override
  int get hashCode => Object.hash(
    availability,
    runId,
    conversationId,
    status,
    headNumber,
    succeededWork,
    totalWork,
    identityHashCode(head),
    Object.hashAll(revisions.map(identityHashCode)),
    viewedNumber,
    identityHashCode(graph),
    identityHashCode(nodeStates),
    identityHashCode(headDiff),
    identityHashCode(proposal),
    planChangePolicy,
    gateReviewPolicy,
    commandPending,
  );
}
