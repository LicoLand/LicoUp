import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/application/features/projects/controller/project_controller.dart';
import 'package:licoup/src/application/features/projects/controller/project_layout_controller.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/presentation/projects/projects_binding.dart';
import 'package:licoup/src/presentation/projects/projects_effect.dart';
import 'package:licoup/src/presentation/projects/projects_intent.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';
import 'package:licoup/src/projections/projects/projects_layout_presentation_source.dart';
import 'package:licoup/src/projections/projects/projects_layout_projection_producer.dart';
import 'package:licoup/src/projections/projects/projects_presentation_source.dart';
import 'package:licoup/src/projections/projects/projects_projection_producer.dart';

/// Refusal code this client publishes when no project owner is bound at all.
const unboundProjectManagementCode = 'project_management_unbound';

/// The project management lane of a client that has no project owner bound.
///
/// The production gateway lives in `lib/src/platform/`, next to the native
/// transport it drives. Until that lane is injected, this client must not
/// pretend it read or changed durable project state: every call refuses with
/// [unboundProjectManagementCode], so the project surface renders an explicit
/// absence instead of an empty catalog that could be mistaken for "no
/// projects". It sends no command, opens no source and starts no owner.
final class UnboundProjectManagementGateway
    implements ProjectManagementGateway {
  const UnboundProjectManagementGateway();

  @override
  Future<List<ProjectIdentityFacts>> listProjects() async {
    throw _refusal();
  }

  @override
  Future<ProjectIdentityFacts?> readProject(String projectId) async {
    throw _refusal();
  }

  @override
  Future<ProjectImportChangeFacts> previewPlanImport(
    ProjectPlanDocument document,
  ) async {
    throw _refusal();
  }

  @override
  Future<ProjectPlanImportOutcomeFacts> applyPlanImport(
    ProjectPlanDocument document, {
    required int expectedRevision,
  }) async {
    throw _refusal();
  }

  @override
  Future<List<ProjectDependencyFacts>> listDependencies(
    String projectId,
  ) async {
    throw _refusal();
  }

  @override
  Future<List<ProjectDependencyFacts>> listUnresolvedArtifacts(
    String projectId,
  ) async {
    throw _refusal();
  }

  @override
  Future<ProjectBlockedConsumersFacts> listBlockedConsumers({
    required String projectId,
    required String workItemId,
  }) async {
    throw _refusal();
  }

  ProjectGatewayFailure _refusal() => const ProjectGatewayFailure(
    operation: ProjectOperations.list,
    code: unboundProjectManagementCode,
    stage: 'client_composition',
    recovery: 'bind_project_management',
  );
}

/// The project canvas feature: its owners, resources, channels and binding.
///
/// The durable facts and the local arrangement are two owners with two
/// resources. The durable owner talks to the [ProjectManagementGateway] the
/// composition was given; the arrangement owner has no gateway and no intent
/// sink at all, so a drag reaches local state and nothing else. The composition
/// is the only place that constructs the binding, and it constructs it from the
/// producers it owns, so no renderer can reach a project command this feature
/// did not mount.
final class ProjectsFeatureComposition {
  ProjectsFeatureComposition(
    ProjectManagementGateway gateway, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _beginRendererIntent = beginRendererIntent {
    _controller = ProjectController(gateway: gateway);
    _layoutController = ProjectLayoutController();
    _projection = ProjectsProjectionProducer(controller: _controller);
    _layoutProjection = ProjectsLayoutProjectionProducer(
      controller: _layoutController,
    );
    _effects = SemanticEffectChannel<ProjectsEffect>();
    _intents = SemanticIntentChannel<ProjectsIntent>(_handleIntent);
    _catalogSource = ProjectsPresentationSource(projection: _projection);
    _arrangementSource = ProjectsLayoutPresentationSource(
      projection: _layoutProjection,
    );
    catalogEntry = presentationProviderEntry(_catalogSource);
    layoutEntry = presentationProviderEntry(_arrangementSource);
    binding = ProjectsBinding(
      projection: _projection,
      layout: _layoutProjection,
      intents: _intents,
      layoutMutations: _layoutController,
      effects: _effects,
    );
  }

  final RendererIntentTraceFactory? _beginRendererIntent;
  late final ProjectController _controller;
  late final ProjectLayoutController _layoutController;
  late final ProjectsProjectionProducer _projection;
  late final ProjectsLayoutProjectionProducer _layoutProjection;
  late final SemanticEffectChannel<ProjectsEffect> _effects;
  late final SemanticIntentChannel<ProjectsIntent> _intents;
  late final ProjectsPresentationSource _catalogSource;
  late final ProjectsLayoutPresentationSource _arrangementSource;

  /// The durable project facts resource entry for this container.
  late final PresentationProviderEntry<ProjectsProjection> catalogEntry;

  /// The local arrangement resource entry for this container.
  ///
  /// A separate entry on purpose: the arrangement has its own resource
  /// identity, so observing where a card is drawn cannot publish a durable
  /// fact and cannot reach the gateway the facts resource reads.
  late final PresentationProviderEntry<ProjectsLayoutState> layoutEntry;

  /// Everything one renderer binds for the project surface.
  late final ProjectsBinding binding;
  Future<void>? _disposal;

  Future<void> _handleIntent(ProjectsIntent intent) async {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case RefreshProjects():
        await _controller.loadProjects();
        _rejectLastFailure(trace);
      case LoadProjectFacts(:final projectId):
        await _controller.loadProjectFacts(projectId);
        _rejectLastFailure(trace);
      case InspectProjectDependents(:final projectId, :final workItemId):
        await _controller.inspectDependents(
          projectId: projectId,
          workItemId: workItemId,
        );
        if (_rejectLastFailure(trace)) return;
        final blocked = _controller.blockedConsumersOf(
          projectId: projectId,
          workItemId: workItemId,
        );
        _effects.emit(
          ProjectDependentsIdentified(
            projectId: projectId,
            workItemId: workItemId,
            dependentCount: blocked?.blockedConsumers.length ?? 0,
            trace: trace,
          ),
        );
      case PreviewProjectPlan(:final document):
        await _controller.previewPlan(document);
        if (_rejectLastFailure(trace)) return;
        final record = _lastRecord(document.projectId);
        if (record == null || !record.isPreview) return;
        _effects.emit(
          ProjectPlanPreviewed(
            projectId: record.change.projectId,
            planId: record.change.planId,
            revision: record.change.revision,
            replayed: record.change.replayed,
            addedCount: record.change.added.length,
            unchangedCount: record.change.unchanged.length,
            retainedCount: record.change.retained.length,
            trace: trace,
          ),
        );
      case ApplyProjectPlan(:final document, :final expectedRevision):
        await _controller.applyPlan(
          document,
          expectedRevision: expectedRevision,
        );
        if (_rejectLastFailure(trace)) return;
        final record = _lastRecord(document.projectId);
        if (record == null || record.isPreview) return;
        _effects.emit(
          ProjectPlanApplied(
            projectId: record.change.projectId,
            planId: record.change.planId,
            revision: record.change.revision,
            applied: record.applied,
            trace: trace,
          ),
        );
    }
  }

  ProjectImportRecord? _lastRecord(String projectId) {
    final records = _controller.importRecordsOf(projectId);
    return records.isEmpty ? null : records.last;
  }

  /// Reports the owner's own refusal, when this request recorded one.
  ///
  /// The owner's vocabulary travels unchanged: one stable `code`, its `stage`,
  /// whether it is `retryable` and the `recovery` it published. A request that
  /// recorded no refusal emits nothing, so a renderer never sees a stale
  /// refusal it did not cause.
  bool _rejectLastFailure(TraceContext? trace) {
    final failure = _controller.lastFailure;
    if (failure == null) return false;
    _effects.emit(
      ProjectRequestRejected(
        operation: failure.operation,
        reasonCode: failure.code,
        stage: failure.stage,
        retryable: failure.retryable,
        recovery: failure.recovery,
        reference: failure.reference,
        trace: trace,
      ),
    );
    return true;
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _catalogSource.dispose();
    await _arrangementSource.dispose();
    await _projection.dispose();
    await _layoutProjection.dispose();
    await _effects.dispose();
    _layoutController.dispose();
    _controller.dispose();
  }
}
