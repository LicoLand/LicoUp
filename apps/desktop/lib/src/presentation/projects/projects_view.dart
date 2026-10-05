import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/projects/projects_intent.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';
import 'package:licoup/src/presentation/projects/projects_resources.dart';

/// One row of the list view: the shared facts plus the local list position.
///
/// The row adds an order and nothing else, so it cannot disagree with the graph
/// view about the executor, the declared result, the blocking reason or the
/// real dependents.
final class ProjectListRowInputs {
  const ProjectListRowInputs({required this.position, required this.facts});

  /// Position in the local order, zero-based.
  final int position;

  final ProjectWorkItemFacts facts;

  String get workItemId => facts.workItemId;
  String get key => facts.key;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectListRowInputs &&
          other.position == position &&
          other.facts == facts;

  @override
  int get hashCode => Object.hash(position, facts);
}

/// One node of the graph view: the same facts plus a local canvas position.
final class ProjectCanvasNodeInputs {
  const ProjectCanvasNodeInputs({required this.placement, required this.facts});

  /// The local position, derived from the arrangement or moved by a person.
  final ProjectCanvasPlacement placement;

  final ProjectWorkItemFacts facts;

  String get workItemId => facts.workItemId;
  String get key => facts.key;

  /// The declared results this node waits for, as edges into other nodes.
  List<ProjectDeclaredInputFacts> get incoming => facts.inputs.inputs;

  /// The work items that actually wait on this node's result.
  List<ProjectWorkRefFacts> get outgoing => facts.dependents.dependents;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectCanvasNodeInputs &&
          other.placement == placement &&
          other.facts == facts;

  @override
  int get hashCode => Object.hash(placement, facts);
}

/// The facts one project surface presents, with no view attached.
final class _ProjectSurfaceFacts {
  const _ProjectSurfaceFacts(this.card, this.facts);

  final ProjectCardProjection? card;
  final List<ProjectWorkItemFacts> facts;
}

_ProjectSurfaceFacts _surfaceFacts(
  ProjectsProjection projection,
  String projectId,
) {
  final card = projectId.trim().isEmpty
      ? projection.firstProject
      : projection.project(projectId.trim());
  return _ProjectSurfaceFacts(
    card,
    card?.workItems ?? const <ProjectWorkItemFacts>[],
  );
}

/// Narrow renderer-facing inputs for the project list view.
final class ProjectsListViewInputs {
  const ProjectsListViewInputs({
    required this.scope,
    required this.projectId,
    required this.card,
    required this.facts,
    required this.rows,
    required this.phase,
    this.notice,
  });

  factory ProjectsListViewInputs.fromProjection({
    required ProjectsProjection projection,
    required ProjectsLayoutState layout,
    String projectId = '',
  }) {
    final surface = _surfaceFacts(projection, projectId);
    final ordered = layout.orderedKeys(<String>[
      for (final item in surface.facts) item.key,
    ]);
    final byKey = <String, ProjectWorkItemFacts>{
      for (final item in surface.facts) item.key: item,
    };
    return ProjectsListViewInputs(
      scope: projectsPresentationScope,
      projectId: surface.card?.projectId ?? '',
      card: surface.card,
      facts: surface.facts,
      rows: <ProjectListRowInputs>[
        for (var position = 0; position < ordered.length; position += 1)
          ProjectListRowInputs(
            position: position,
            facts: byKey[ordered[position]]!,
          ),
      ],
      phase: projection.phase,
      notice: projection.notice,
    );
  }

  final ResourceScope scope;
  final String projectId;
  final ProjectCardProjection? card;

  /// The shared fact list, in the canonical order the durable read published.
  /// The graph view reads the identical list.
  final List<ProjectWorkItemFacts> facts;

  final List<ProjectListRowInputs> rows;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectsListViewInputs &&
          other.scope == scope &&
          other.projectId == projectId &&
          other.card == card &&
          samePresentationList(other.facts, facts) &&
          samePresentationList(other.rows, rows) &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    scope,
    projectId,
    card,
    Object.hashAll(facts),
    Object.hashAll(rows),
    phase,
    notice,
  );
}

/// Narrow renderer-facing inputs for the project graph view.
///
/// It presents the same [facts] as [ProjectsListViewInputs] and adds only local
/// coordinates, so a switch between the two views cannot change a fact.
final class ProjectsCanvasViewInputs {
  const ProjectsCanvasViewInputs({
    required this.scope,
    required this.projectId,
    required this.card,
    required this.facts,
    required this.nodes,
    required this.phase,
    this.notice,
  });

  factory ProjectsCanvasViewInputs.fromProjection({
    required ProjectsProjection projection,
    required ProjectsLayoutState layout,
    String projectId = '',
  }) {
    final surface = _surfaceFacts(projection, projectId);
    final canonicalKeys = <String>[for (final item in surface.facts) item.key];
    final placements = layout.placementsFor(
      projectId: surface.card?.projectId ?? '',
      canonicalKeys: canonicalKeys,
    );
    return ProjectsCanvasViewInputs(
      scope: projectsPresentationScope,
      projectId: surface.card?.projectId ?? '',
      card: surface.card,
      facts: surface.facts,
      nodes: <ProjectCanvasNodeInputs>[
        for (var index = 0; index < surface.facts.length; index += 1)
          ProjectCanvasNodeInputs(
            placement: placements[index],
            facts: surface.facts[index],
          ),
      ],
      phase: projection.phase,
      notice: projection.notice,
    );
  }

  final ResourceScope scope;
  final String projectId;
  final ProjectCardProjection? card;

  /// The shared fact list: the identical list the list view reads.
  final List<ProjectWorkItemFacts> facts;

  final List<ProjectCanvasNodeInputs> nodes;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectsCanvasViewInputs &&
          other.scope == scope &&
          other.projectId == projectId &&
          other.card == card &&
          samePresentationList(other.facts, facts) &&
          samePresentationList(other.nodes, nodes) &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    scope,
    projectId,
    card,
    Object.hashAll(facts),
    Object.hashAll(nodes),
    phase,
    notice,
  );
}

/// Narrow renderer actions for the durable project surface.
///
/// Every dispatch carries the pinned originating scope, so an asynchronous
/// refusal stays attributable. No member takes a coordinate or an order.
final class ProjectsActions {
  const ProjectsActions({
    required this.origin,
    required this.refresh,
    required this.loadFacts,
    required this.inspectDependents,
    required this.previewImport,
    required this.applyImport,
  });

  factory ProjectsActions.fromIntents(IntentSink<ProjectsIntent> intents) {
    const origin = ActionOrigin(
      scope: projectsPresentationScope,
      resource: projectsCatalogResource,
    );
    final channel = CallbackActions<ProjectsIntent>(
      origin: origin,
      onDispatch: (intent, _) => intents.send(intent),
    );
    return ProjectsActions(
      origin: origin,
      refresh: () => channel.dispatch(const RefreshProjects()),
      loadFacts: (projectId) => channel.dispatch(LoadProjectFacts(projectId)),
      inspectDependents:
          ({required String projectId, required String workItemId}) =>
              channel.dispatch(
                InspectProjectDependents(
                  projectId: projectId,
                  workItemId: workItemId,
                ),
              ),
      previewImport: (document) =>
          channel.dispatch(PreviewProjectPlan(document)),
      applyImport: (document, {required int expectedRevision}) =>
          channel.dispatch(
            ApplyProjectPlan(document, expectedRevision: expectedRevision),
          ),
    );
  }

  final ActionOrigin origin;
  final FutureOr<void> Function() refresh;
  final FutureOr<void> Function(String projectId) loadFacts;
  final FutureOr<void> Function({
    required String projectId,
    required String workItemId,
  })
  inspectDependents;
  final FutureOr<void> Function(ProjectPlanDocument document) previewImport;
  final FutureOr<void> Function(
    ProjectPlanDocument document, {
    required int expectedRevision,
  })
  applyImport;
}

/// Narrow renderer actions for the local arrangement.
///
/// The type holds a [ProjectLayoutMutations] and no [IntentSink]: a drag
/// dispatched here has no durable command to reach, which is the interface half
/// of the boundary the projection keeps in its types.
final class ProjectLayoutActions {
  const ProjectLayoutActions({
    required this.origin,
    required this.moveCard,
    required this.reorder,
  });

  factory ProjectLayoutActions.fromMutations(ProjectLayoutMutations mutations) {
    const origin = ActionOrigin(
      scope: projectsPresentationScope,
      resource: projectsLayoutResource,
    );
    final channel = CallbackActions<ProjectLayoutAction>(
      origin: origin,
      onDispatch: (action, _) {
        switch (action) {
          case MoveProjectCard():
            mutations.moveCard(
              projectId: action.projectId,
              workItemId: action.workItemId,
              x: action.x,
              y: action.y,
            );
          case ReorderProjectList():
            mutations.reorder(action.keys);
        }
      },
    );
    return ProjectLayoutActions(
      origin: origin,
      moveCard:
          ({
            required String projectId,
            required String workItemId,
            required double x,
            required double y,
          }) => channel.dispatch(
            MoveProjectCard(
              projectId: projectId,
              workItemId: workItemId,
              x: x,
              y: y,
            ),
          ),
      reorder: (keys) => channel.dispatch(ReorderProjectList(keys)),
    );
  }

  final ActionOrigin origin;
  final void Function({
    required String projectId,
    required String workItemId,
    required double x,
    required double y,
  })
  moveCard;
  final void Function(Iterable<String> keys) reorder;
}
