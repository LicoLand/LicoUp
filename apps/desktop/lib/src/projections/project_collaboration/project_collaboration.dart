import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/projections/project_collaboration/collaboration_graph_facts.dart';

/// Why a Goal cannot move right now, derived only from reported facts.
///
/// The client never invents a reason: an unreported or unrecognized state stays
/// [unknown] instead of becoming progress or completion.
enum CollaborationBlockingReason {
  /// Nothing blocks the Goal.
  none('none'),

  /// Follow-ups are paused; the work is retained and can resume.
  paused('paused'),

  /// Cancellation was requested and has not settled.
  cancelRequested('cancel-requested'),

  /// A human decision is required before the run continues.
  approvalWaiting('approval-waiting'),

  /// A reviewer rejected a criterion, so the work needs repair.
  reviewRejected('review-rejected'),

  /// The Goal waits on a dependency the Assistant does not control.
  dependencyWait('dependency-wait'),

  /// The executor connection is lost or was replaced.
  executorUnknown('executor-unknown'),

  /// The native side has not reported this Goal's state yet.
  unreported('unreported');

  const CollaborationBlockingReason(this.wireName);

  final String wireName;
}

/// One Goal as the collaboration graph shows it.
///
/// Run, review and observation are separate planes so a recorded observation
/// cannot change an acceptance decision and a running execution cannot claim
/// completion.
final class CollaborationNodeProjection {
  const CollaborationNodeProjection({
    required this.goalId,
    required this.childConversationId,
    required this.parentConversationId,
    required this.revision,
    required this.lifecycle,
    required this.control,
    required this.run,
    required this.review,
    required this.observation,
    required this.blockingReason,
    required this.topologyRevision,
  });

  final String goalId;
  final String childConversationId;
  final String parentConversationId;

  /// The Goal revision the facts belong to. An older revision never overwrites
  /// a newer one.
  final int revision;

  /// `null` when the native side has not reported the lifecycle. An unreported
  /// Goal is never rendered as achieved.
  final ContinuityGoalLifecycle? lifecycle;

  /// `null` when the native side has not reported the control state.
  final ContinuityGoalControl? control;

  final CollaborationRunFact run;
  final CollaborationReviewFact review;
  final CollaborationObservationFact observation;

  final CollaborationBlockingReason blockingReason;

  /// The topology revision this node was laid out in. A matching revision means
  /// the node keeps its region.
  final int topologyRevision;

  /// Whether the reported lifecycle is terminal. Only a reported lifecycle can
  /// be terminal; an unreported Goal is not.
  bool get completed =>
      lifecycle == ContinuityGoalLifecycle.achieved ||
      lifecycle == ContinuityGoalLifecycle.cancelled ||
      lifecycle == ContinuityGoalLifecycle.superseded;

  /// Whether the Goal is retained but deliberately not advancing.
  bool get held =>
      control == ContinuityGoalControl.paused ||
      control == ContinuityGoalControl.cancelRequested;
}

/// The projected collaboration graph for one native epoch.
final class CollaborationGraphProjection {
  const CollaborationGraphProjection({
    required this.epoch,
    required this.topologyRevision,
    required this.nodes,
  });

  /// An empty graph that belongs to no epoch yet.
  static const CollaborationGraphProjection empty =
      CollaborationGraphProjection(
        epoch: -1,
        topologyRevision: 0,
        nodes: <CollaborationNodeProjection>[],
      );

  final int epoch;

  /// Advances only when topology changes. A state-only update keeps it, which
  /// is what lets the client re-render local regions without a new layout.
  final int topologyRevision;

  final List<CollaborationNodeProjection> nodes;

  CollaborationNodeProjection? node(String goalId) {
    for (final item in nodes) {
      if (item.goalId == goalId) return item;
    }
    return null;
  }
}

/// The result of applying a snapshot or a delta.
///
/// [relayoutRequired] is the only signal a renderer needs to decide between a
/// local region refresh and a new layout; [reconnected] tells it that the
/// previous epoch was discarded rather than patched.
final class CollaborationProjectionUpdate {
  const CollaborationProjectionUpdate({
    required this.projection,
    required this.relayoutRequired,
    required this.reconnected,
  });

  final CollaborationGraphProjection projection;
  final bool relayoutRequired;
  final bool reconnected;
}

/// Projects native collaboration snapshots and deltas into graph state.
///
/// The reducer is pure: it holds no connection and performs no layout itself.
/// Expensive layout belongs to the preparation worker that consumes
/// [CollaborationProjectionUpdate.relayoutRequired].
final class ProjectCollaboration {
  const ProjectCollaboration();

  /// Project a full native snapshot.
  CollaborationProjectionUpdate snapshot(CollaborationGraphSnapshot snapshot) {
    final nodes = <CollaborationNodeProjection>[];
    for (final fact in snapshot.goals) {
      nodes.add(_project(fact, topologyRevision: 1));
    }
    return CollaborationProjectionUpdate(
      projection: CollaborationGraphProjection(
        epoch: snapshot.epoch,
        topologyRevision: 1,
        nodes: List.unmodifiable(nodes),
      ),
      relayoutRequired: true,
      reconnected: false,
    );
  }

  /// Apply one incremental native update.
  ///
  /// A delta from another epoch discards the previous epoch's topology and node
  /// state instead of mixing them. A state-only delta inside the current epoch
  /// replaces exactly the touched nodes and keeps every untouched node
  /// instance, so local regions refresh without a full-graph layout.
  CollaborationProjectionUpdate apply(
    CollaborationGraphProjection current,
    CollaborationGraphDelta delta,
  ) {
    if (delta.epoch != current.epoch) {
      return _reconnect(delta);
    }
    final removed = delta.removedGoalIds.toSet();
    final updated = <String, CollaborationGoalFact>{
      for (final fact in delta.goals) fact.goalId: fact,
    };
    final existing = <String, CollaborationNodeProjection>{
      for (final node in current.nodes) node.goalId: node,
    };
    final topologyChanged =
        delta.topologyChanged ||
        removed.isNotEmpty ||
        updated.keys.any((goalId) => !existing.containsKey(goalId));
    final topologyRevision = topologyChanged
        ? current.topologyRevision + 1
        : current.topologyRevision;
    final nodes = <CollaborationNodeProjection>[];
    for (final node in current.nodes) {
      if (removed.contains(node.goalId)) continue;
      final fact = updated[node.goalId];
      if (fact == null) {
        // Untouched region: keep the same instance so the renderer can skip it.
        nodes.add(
          topologyChanged && node.topologyRevision != topologyRevision
              ? _reanchored(node, topologyRevision)
              : node,
        );
        continue;
      }
      final next = _project(fact, topologyRevision: topologyRevision);
      nodes.add(
        _stateOnly(node, next) ? node : _merge(node, next, topologyRevision),
      );
    }
    for (final fact in delta.goals) {
      if (existing.containsKey(fact.goalId)) continue;
      nodes.add(_project(fact, topologyRevision: topologyRevision));
    }
    return CollaborationProjectionUpdate(
      projection: CollaborationGraphProjection(
        epoch: current.epoch,
        topologyRevision: topologyRevision,
        nodes: List.unmodifiable(nodes),
      ),
      relayoutRequired: topologyChanged,
      reconnected: false,
    );
  }

  /// Rebuild the graph from a delta produced in a new epoch.
  ///
  /// Nothing from the previous epoch is carried over: its topology and node
  /// state belonged to a connection that no longer exists.
  CollaborationProjectionUpdate _reconnect(CollaborationGraphDelta delta) {
    final nodes = <CollaborationNodeProjection>[];
    for (final fact in delta.goals) {
      nodes.add(_project(fact, topologyRevision: 1));
    }
    return CollaborationProjectionUpdate(
      projection: CollaborationGraphProjection(
        epoch: delta.epoch,
        topologyRevision: 1,
        nodes: List.unmodifiable(nodes),
      ),
      relayoutRequired: true,
      reconnected: true,
    );
  }

  static bool _stateOnly(
    CollaborationNodeProjection previous,
    CollaborationNodeProjection next,
  ) {
    return previous.goalId == next.goalId &&
        previous.childConversationId == next.childConversationId &&
        previous.parentConversationId == next.parentConversationId &&
        previous.revision == next.revision &&
        previous.lifecycle == next.lifecycle &&
        previous.control == next.control &&
        previous.run.activeExecutionRef == next.run.activeExecutionRef &&
        previous.run.approvalWaiting == next.run.approvalWaiting &&
        previous.review.requiredCriteria == next.review.requiredCriteria &&
        previous.review.satisfiedCriteria == next.review.satisfiedCriteria &&
        previous.review.rejectedCriteria == next.review.rejectedCriteria &&
        previous.observation.observationCount ==
            next.observation.observationCount &&
        previous.observation.lastObservationRef ==
            next.observation.lastObservationRef &&
        previous.blockingReason == next.blockingReason;
  }

  static CollaborationNodeProjection _merge(
    CollaborationNodeProjection previous,
    CollaborationNodeProjection next,
    int topologyRevision,
  ) {
    // A late fact for a revision the client already moved past never rewrites
    // the newer state.
    if (next.revision < previous.revision) {
      return previous.topologyRevision == topologyRevision
          ? previous
          : _reanchored(previous, topologyRevision);
    }
    return next;
  }

  static CollaborationNodeProjection _reanchored(
    CollaborationNodeProjection node,
    int topologyRevision,
  ) {
    return CollaborationNodeProjection(
      goalId: node.goalId,
      childConversationId: node.childConversationId,
      parentConversationId: node.parentConversationId,
      revision: node.revision,
      lifecycle: node.lifecycle,
      control: node.control,
      run: node.run,
      review: node.review,
      observation: node.observation,
      blockingReason: node.blockingReason,
      topologyRevision: topologyRevision,
    );
  }

  static CollaborationNodeProjection _project(
    CollaborationGoalFact fact, {
    required int topologyRevision,
  }) {
    final progress = fact.progress;
    return CollaborationNodeProjection(
      goalId: fact.goalId,
      childConversationId: fact.relation.childConversationId,
      parentConversationId: fact.relation.parentConversationId,
      revision: progress?.revision ?? fact.relation.revision,
      lifecycle: progress?.lifecycle,
      control: progress?.control,
      run: fact.run ?? const CollaborationRunFact(),
      review: fact.review ?? const CollaborationReviewFact(),
      observation: fact.observation ?? const CollaborationObservationFact(),
      blockingReason: _blockingReason(fact),
      topologyRevision: topologyRevision,
    );
  }

  static CollaborationBlockingReason _blockingReason(
    CollaborationGoalFact fact,
  ) {
    final progress = fact.progress;
    final control = progress?.control;
    if (control == ContinuityGoalControl.paused) {
      return CollaborationBlockingReason.paused;
    }
    if (control == ContinuityGoalControl.cancelRequested) {
      return CollaborationBlockingReason.cancelRequested;
    }
    if (fact.run?.approvalWaiting ?? false) {
      return CollaborationBlockingReason.approvalWaiting;
    }
    if (progress == null ||
        progress.lifecycle == ContinuityGoalLifecycle.unrecognized) {
      return CollaborationBlockingReason.unreported;
    }
    if ((fact.review?.rejectedCriteria ?? 0) > 0) {
      return CollaborationBlockingReason.reviewRejected;
    }
    if (progress.nextAttention is ContinuityNextAttentionWait) {
      return CollaborationBlockingReason.dependencyWait;
    }
    final status = fact.workContextStatus;
    if (status == ContinuityWorkContextStatus.lost ||
        status == ContinuityWorkContextStatus.replaced) {
      return CollaborationBlockingReason.executorUnknown;
    }
    return CollaborationBlockingReason.none;
  }
}
