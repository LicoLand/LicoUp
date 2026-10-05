import 'package:presentation_contract/presentation_contract.dart';

/// One-shot results the project surface reports to a renderer.
///
/// An effect says what one request did. It never carries a fact a renderer
/// should read from the projection instead, and it never carries a coordinate.
sealed class ProjectsEffect {
  const ProjectsEffect({this.trace});

  final TraceContext? trace;
}

/// One plan document was previewed and its change report is available.
final class ProjectPlanPreviewed extends ProjectsEffect {
  const ProjectPlanPreviewed({
    required this.projectId,
    required this.planId,
    required this.revision,
    required this.replayed,
    required this.addedCount,
    required this.unchangedCount,
    required this.retainedCount,
    super.trace,
  });

  final String projectId;
  final String planId;
  final int revision;
  final bool replayed;
  final int addedCount;
  final int unchangedCount;
  final int retainedCount;
}

/// One plan document was applied, or recognised as the stored revision.
final class ProjectPlanApplied extends ProjectsEffect {
  const ProjectPlanApplied({
    required this.projectId,
    required this.planId,
    required this.revision,
    required this.applied,
    super.trace,
  });

  final String projectId;
  final String planId;
  final int revision;
  final bool applied;
}

/// One blocked producer's real dependents were read.
final class ProjectDependentsIdentified extends ProjectsEffect {
  const ProjectDependentsIdentified({
    required this.projectId,
    required this.workItemId,
    required this.dependentCount,
    super.trace,
  });

  final String projectId;
  final String workItemId;
  final int dependentCount;
}

/// One project request was refused, with the owner's own refusal vocabulary.
final class ProjectRequestRejected extends ProjectsEffect {
  const ProjectRequestRejected({
    required this.operation,
    required this.reasonCode,
    required this.stage,
    required this.retryable,
    required this.recovery,
    this.reference = '',
    super.trace,
  });

  final String operation;
  final String reasonCode;
  final String stage;
  final bool retryable;
  final String recovery;

  /// The public argument the refusal named, when it published one.
  final String reference;
}
