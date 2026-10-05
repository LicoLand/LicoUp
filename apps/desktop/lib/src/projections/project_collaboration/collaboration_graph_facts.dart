import 'package:licoup/src/contracts/generated/conversation.g.dart';

/// The facts the native collaboration graph reports for one Goal.
///
/// The three planes are independent: a run that keeps executing, a review that
/// waits for acceptance and an observation that only records facts never
/// overwrite each other. A plane the native side did not report stays `null`,
/// which the projection renders as unknown rather than as success.
final class CollaborationGoalFact {
  const CollaborationGoalFact({
    required this.relation,
    this.progress,
    this.run,
    this.review,
    this.observation,
    this.workContextStatus,
  });

  /// Topology plus the card anchor that owns this Goal.
  final ContinuityTaskConversationRelation relation;

  /// Lifecycle, control, attention, evidence and blockers, or `null` when the
  /// native side has not reported this Goal's state yet.
  final ContinuityGoalProgress? progress;

  /// Execution facts, or `null` when nothing was reported.
  final CollaborationRunFact? run;

  /// Review and acceptance facts, or `null` when nothing was reported.
  final CollaborationReviewFact? review;

  /// Observation facts, or `null` when nothing was reported.
  final CollaborationObservationFact? observation;

  /// The connection between this Goal's child conversation and its executor.
  final ContinuityWorkContextStatus? workContextStatus;

  String get goalId => relation.goalId;
}

/// Execution plane facts for one Goal.
final class CollaborationRunFact {
  const CollaborationRunFact({
    this.activeExecutionRef,
    this.approvalWaiting = false,
  });

  /// The execution the run is currently inside, if any.
  final String? activeExecutionRef;

  /// Whether the run is blocked on an approval decision a human must make.
  final bool approvalWaiting;
}

/// Review and acceptance plane facts for one Goal.
final class CollaborationReviewFact {
  const CollaborationReviewFact({
    this.requiredCriteria = 0,
    this.satisfiedCriteria = 0,
    this.rejectedCriteria = 0,
  });

  /// Required criteria the admitted contract states.
  final int requiredCriteria;

  /// Required criteria with a current accepted pass.
  final int satisfiedCriteria;

  /// Criteria a reviewer explicitly rejected; a rejection is a repair request.
  final int rejectedCriteria;

  /// Whether every required criterion has a current accepted pass.
  bool get acceptanceComplete =>
      requiredCriteria > 0 && satisfiedCriteria >= requiredCriteria;
}

/// Observation plane facts for one Goal.
final class CollaborationObservationFact {
  const CollaborationObservationFact({
    this.observationCount = 0,
    this.lastObservationRef,
  });

  /// How many run facts were recorded. Recording changes nothing else.
  final int observationCount;

  /// The most recent recorded observation, if any.
  final String? lastObservationRef;
}

/// One native graph epoch: the whole topology and every reported fact.
final class CollaborationGraphSnapshot {
  const CollaborationGraphSnapshot({required this.epoch, required this.goals});

  /// The native connection epoch. Facts from another epoch never patch this
  /// one.
  final int epoch;

  final List<CollaborationGoalFact> goals;
}

/// One incremental native update inside an epoch.
final class CollaborationGraphDelta {
  const CollaborationGraphDelta({
    required this.epoch,
    required this.goals,
    this.removedGoalIds = const <String>[],
    this.topologyChanged = false,
  });

  /// The epoch the update was produced in. A different epoch is a reconnect,
  /// not a patch.
  final int epoch;

  /// Goals whose facts changed.
  final List<CollaborationGoalFact> goals;

  /// Goals the native side removed from the graph.
  final List<String> removedGoalIds;

  /// Whether the update adds or removes topology. A state-only update keeps
  /// `false`, which is what lets the client refresh a local region without a
  /// new layout.
  final bool topologyChanged;
}
