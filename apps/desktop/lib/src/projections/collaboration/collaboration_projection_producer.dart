import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';

/// Pure derivation of the renderer-facing collaboration projection.
///
/// `viewedNumber`/`viewedGraph` describe a historical revision selected by the
/// user; while viewing the head they are null and the snapshot's head graph
/// and live node states are shown. A historical view shows structure only.
/// A null snapshot means the conversation has no run; [unavailable] reports
/// that the port failed to observe the conversation.
CollaborationProjection collaborationProjection({
  required CollaborationRunSnapshot? snapshot,
  bool unavailable = false,
  int? viewedNumber,
  CollaborationGraph? viewedGraph,
  bool commandPending = false,
}) {
  if (unavailable) return CollaborationProjection.unavailable();
  final run = snapshot;
  if (run == null) return CollaborationProjection.none();

  final total = run.graph.nodes
      .where((node) => CollaborationNodeKind.workKinds.contains(node.kind))
      .length;
  var succeeded = 0;
  for (final node in run.graph.nodes) {
    if (!CollaborationNodeKind.workKinds.contains(node.kind)) continue;
    if (run.nodeStates[node.id]?.status == CollaborationNodeStatus.succeeded) {
      succeeded++;
    }
  }

  final viewingHead = viewedNumber == null || viewedNumber == run.headNumber;
  return CollaborationProjection(
    availability: CollaborationAvailability.active,
    runId: run.runId,
    conversationId: run.conversationId,
    status: run.status,
    headNumber: run.headNumber,
    succeededWork: succeeded,
    totalWork: total,
    head: run.head,
    revisions: run.revisions.reversed,
    viewedNumber: viewingHead ? run.headNumber : viewedNumber,
    graph: viewingHead ? run.graph : viewedGraph,
    nodeStates: viewingHead ? run.nodeStates : const {},
    headDiff: run.headDiff,
    proposal: run.proposal,
    planChangePolicy: run.planChangePolicy,
    gateReviewPolicy: run.gateReviewPolicy,
    commandPending: commandPending,
  );
}
