import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/projects/controller/project_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

/// Projects the durable project facts into one renderer value.
///
/// The producer reads declarations and durable facts only. It never reads a
/// canvas position or a list order, so a refresh after a drag republishes the
/// same work items with the same state.
final class ProjectsProjectionProducer
    implements ProjectionSource<ProjectsProjection> {
  ProjectsProjectionProducer({required ProjectController controller})
    : _controller = controller,
      _current = _read(controller) {
    _subscription = controller.changes.listen(_handleChange);
  }

  final ProjectController _controller;
  final StreamController<ProjectionUpdate<ProjectsProjection>> _changes =
      StreamController<ProjectionUpdate<ProjectsProjection>>.broadcast(
        sync: true,
      );
  late final StreamSubscription<ApplicationChange> _subscription;
  ProjectsProjection _current;
  bool _disposed = false;

  @override
  ProjectsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<ProjectsProjection>> get changes => _changes.stream;

  void _handleChange(ApplicationChange change) =>
      _publish(trace: _trace(change.cause));

  void _publish({TraceContext? trace}) {
    if (_disposed) return;
    final next = _read(_controller);
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate<ProjectsProjection>(next, trace: trace));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await closeBroadcastController(_changes);
  }

  static ProjectsProjection _read(ProjectController controller) {
    final failure = controller.lastFailure;
    return ProjectsProjection(
      projects: <ProjectCardProjection>[
        for (final identity in controller.projects) _card(controller, identity),
      ],
      phase: failure != null
          ? PresentationPhase.failed
          : controller.isLoading
          ? PresentationPhase.loading
          : PresentationPhase.ready,
      notice: failure == null
          ? null
          : PresentationNotice(
              id: 'projects-failure',
              title: 'Projects',
              message: failure.code,
              severity: PresentationNoticeSeverity.error,
              reasonCode: failure.code,
              reference: failure.reference,
              recovery: failure.recovery,
            ),
      failureCode: failure?.code ?? '',
    );
  }

  static ProjectCardProjection _card(
    ProjectController controller,
    ProjectIdentityFacts identity,
  ) {
    final projectId = identity.projectId;
    final declaration = controller.declarationOf(projectId);
    final dependencies = controller.dependenciesOf(projectId);
    final observed = controller.hasDependencyFacts(projectId);
    final membership = _membership(controller.importRecordsOf(projectId));

    final declaredInputsByItem = <String, List<ProjectDeclaredInputFacts>>{};
    final durableWorkItemIds = <String>{};
    for (final dependency in dependencies) {
      if (dependency.consumer.projectId == projectId) {
        (declaredInputsByItem[dependency.consumer.workItemId] ??=
                <ProjectDeclaredInputFacts>[])
            .add(
              ProjectDeclaredInputFacts(
                producer: dependency.producer,
                artifact: dependency.artifact,
                state: ProjectInputState.fromArtifactState(
                  dependency.artifactState,
                ),
                dependencySequence: dependency.dependencySequence,
              ),
            );
        durableWorkItemIds.add(dependency.consumer.workItemId);
      }
      if (dependency.producer.projectId == projectId) {
        durableWorkItemIds.add(dependency.producer.workItemId);
      }
    }

    final declaredItems = declaration?.workItems;
    final declaredIds = <String>[
      for (final item
          in declaredItems ?? const <ProjectPlanWorkItemDeclaration>[])
        item.workItemId,
    ];
    // A receipt names work items the durable slice holds, including the ones an
    // applied document omitted. They are real work items and are projected even
    // though nothing declares them here.
    final durableOnly = <String>{
      ...durableWorkItemIds,
      ...membership.keys,
    }.where((id) => !declaredIds.contains(id)).toList()..sort();

    return ProjectCardProjection(
      projectId: projectId,
      displayName: identity.displayName.trim().isEmpty
          ? projectId
          : identity.displayName,
      authorizedRoot: identity.authorizedRoot,
      authorityKind: identity.authorityKind,
      authorityReference: identity.authorityReference,
      workspaceId: identity.workspaceId,
      planId: identity.planId,
      registrationSequence: identity.registrationSequence,
      workItems: <ProjectWorkItemFacts>[
        for (final item
            in declaredItems ?? const <ProjectPlanWorkItemDeclaration>[])
          _workItem(
            controller: controller,
            projectId: projectId,
            membership: membership,
            declaration: item,
            declaredInputs: declaredInputsByItem[item.workItemId],
            observed: observed,
          ),
        for (final workItemId in durableOnly)
          _workItem(
            controller: controller,
            projectId: projectId,
            membership: membership,
            declaration: null,
            declaredInputs: declaredInputsByItem[workItemId],
            observed: observed,
            workItemId: workItemId,
          ),
      ],
      importReceipts: <ProjectImportReceiptProjection>[
        for (final record in controller.importRecordsOf(projectId))
          record.isPreview
              ? ProjectImportReceiptProjection.previewed(record.change)
              : ProjectImportReceiptProjection.applied(
                  record.change,
                  applied: record.applied,
                ),
      ],
    );
  }

  static ProjectWorkItemFacts _workItem({
    required ProjectController controller,
    required String projectId,
    required Map<String, ProjectDurableMembership> membership,
    required ProjectPlanWorkItemDeclaration? declaration,
    required List<ProjectDeclaredInputFacts>? declaredInputs,
    required bool observed,
    String workItemId = '',
  }) {
    final id = declaration?.workItemId ?? workItemId;
    final blocked = controller.blockedConsumersOf(
      projectId: projectId,
      workItemId: id,
    );
    return ProjectWorkItemFacts(
      projectId: projectId,
      workItemId: id,
      declarationState: declaration == null
          ? ProjectDeclarationState.notHeld
          : ProjectDeclarationState.held,
      durableMembership: membership[id] ?? ProjectDurableMembership.notObserved,
      declaredOutcome: declaration?.outcome ?? '',
      declaredAcceptance: declaration?.acceptance ?? const <String>[],
      sourceAnchor: declaration?.sourceAnchor ?? '',
      inputs: observed
          ? ProjectDeclaredInputsFacts.observed(
              _inputs(
                projectId: projectId,
                declaration: declaration,
                durable: declaredInputs ?? const <ProjectDeclaredInputFacts>[],
              ),
            )
          : const ProjectDeclaredInputsFacts.notObserved(),
      dependents: blocked == null
          ? const ProjectDependentsFacts.notObserved()
          : ProjectDependentsFacts.observed(blocked.blockedConsumers),
    );
  }

  /// The declared inputs of one work item, with their explicit state.
  ///
  /// The durable declarations are the state source. A held declaration can name
  /// an input no apply has stored yet: that input keeps its declared reference
  /// and the explicit [ProjectInputState.notApplied] state rather than an
  /// assumed one.
  static List<ProjectDeclaredInputFacts> _inputs({
    required String projectId,
    required ProjectPlanWorkItemDeclaration? declaration,
    required List<ProjectDeclaredInputFacts> durable,
  }) {
    if (declaration == null) return durable;
    final covered = <String>{
      for (final input in durable)
        _inputKey(
          artifact: input.artifact,
          producerProjectId: input.producer.projectId,
        ),
    };
    return <ProjectDeclaredInputFacts>[
      ...durable,
      for (final artifact in declaration.inputs)
        if (!covered.contains(
          _inputKey(
            artifact: artifact,
            producerProjectId: artifact.producerProjectId.isEmpty
                ? projectId
                : artifact.producerProjectId,
          ),
        ))
          ProjectDeclaredInputFacts(
            producer: ProjectWorkRefFacts(
              projectId: artifact.producerProjectId.isEmpty
                  ? projectId
                  : artifact.producerProjectId,
              workItemId: artifact.producerWorkItemId,
            ),
            artifact: artifact,
            state: ProjectInputState.notApplied,
          ),
    ];
  }

  /// Identity of one declared reference: its shape, its producer and its
  /// declared location. A durable declaration and a held declaration name the
  /// same input exactly when these agree.
  static String _inputKey({
    required ProjectArtifactDeclaration artifact,
    required String producerProjectId,
  }) =>
      '${artifact.kind}|$producerProjectId|'
      '${artifact.producerWorkItemId}|$_artifactLabel(artifact)';

  static String _artifactLabel(ProjectArtifactDeclaration artifact) =>
      artifact is ProjectLocalArtifactDeclaration
      ? artifact.path
      : '${artifact.producerProjectId}/${artifact.producerWorkItemId}';

  /// Durable membership as the last applied receipt reported it.
  ///
  /// A preview changes nothing, so it never establishes membership: a work item
  /// a preview would add is not observed as durable until an apply admits it.
  static Map<String, ProjectDurableMembership> _membership(
    List<ProjectImportRecord> records,
  ) {
    ProjectImportRecord? lastApplied;
    for (final record in records) {
      if (record.kind == ProjectImportRecordKind.applied) lastApplied = record;
    }
    if (lastApplied == null) {
      return const <String, ProjectDurableMembership>{};
    }
    final change = lastApplied.change;
    return <String, ProjectDurableMembership>{
      for (final id in change.added) id: ProjectDurableMembership.added,
      for (final id in change.unchanged) id: ProjectDurableMembership.unchanged,
      for (final id in change.retained) id: ProjectDurableMembership.retained,
    };
  }
}

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
