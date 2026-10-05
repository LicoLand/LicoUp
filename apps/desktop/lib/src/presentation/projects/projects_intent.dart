import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/project_plan_document.dart';

/// Durable requests the project surface may send.
///
/// Every member reads facts or submits a declaration. There is deliberately no
/// member that carries a coordinate, an order or a selection: a drag or a view
/// switch has no intent to send, and the sealed hierarchy is the type-level
/// half of that boundary.
sealed class ProjectsIntent {
  const ProjectsIntent({this.trace});

  final TraceContext? trace;
}

/// Read the registered projects and their dependency facts again.
final class RefreshProjects extends ProjectsIntent {
  const RefreshProjects({super.trace});
}

/// Read the dependency facts of one project again.
final class LoadProjectFacts extends ProjectsIntent {
  const LoadProjectFacts(this.projectId, {super.trace});

  final String projectId;
}

/// Read what one blocked producer actually blocks.
final class InspectProjectDependents extends ProjectsIntent {
  const InspectProjectDependents({
    required this.projectId,
    required this.workItemId,
    super.trace,
  });

  final String projectId;
  final String workItemId;
}

/// Report what one declared plan document would change.
final class PreviewProjectPlan extends ProjectsIntent {
  const PreviewProjectPlan(this.document, {super.trace});

  final ProjectPlanDocument document;
}

/// Apply one declared plan document over the revision the caller previewed.
final class ApplyProjectPlan extends ProjectsIntent {
  const ApplyProjectPlan(
    this.document, {
    required this.expectedRevision,
    super.trace,
  });

  final ProjectPlanDocument document;
  final int expectedRevision;
}
