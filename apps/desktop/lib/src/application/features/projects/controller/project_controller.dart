import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';

/// One recorded import answer: what a preview reported, or what an apply did.
///
/// The record keeps the change report and whether durable state changed. It
/// carries no coordinate and no view order, so a renderer cannot mistake an
/// arrangement for work.
final class ProjectImportRecord {
  const ProjectImportRecord.previewed(this.change)
    : kind = ProjectImportRecordKind.previewed,
      applied = false;

  const ProjectImportRecord.applied(this.change, {required this.applied})
    : kind = ProjectImportRecordKind.applied;

  final ProjectImportChangeFacts change;
  final ProjectImportRecordKind kind;

  /// True only for an apply that changed durable state. A replay of the stored
  /// revision is one effect, not two.
  final bool applied;

  bool get isPreview => kind == ProjectImportRecordKind.previewed;
}

/// Whether one recorded import answer reported what an import would do, or what
/// it did.
enum ProjectImportRecordKind { previewed, applied }

/// Owns the durable project facts one projection reads.
///
/// The controller talks to the narrow [ProjectManagementGateway] and nothing
/// else. It has no coordinate, no canvas position and no list order, so no view
/// arrangement can be written through it: a drag has no method here to call.
class ProjectController extends ApplicationStateOwner {
  ProjectController({required ProjectManagementGateway gateway})
    : _gateway = gateway;

  final ProjectManagementGateway _gateway;

  List<ProjectIdentityFacts> _projects = const <ProjectIdentityFacts>[];
  final Map<String, List<ProjectDependencyFacts>> _dependencies =
      <String, List<ProjectDependencyFacts>>{};
  final Map<String, List<ProjectDependencyFacts>> _unresolved =
      <String, List<ProjectDependencyFacts>>{};
  final Map<String, ProjectBlockedConsumersFacts> _blocked =
      <String, ProjectBlockedConsumersFacts>{};
  final Map<String, ProjectPlanDocument> _declarations =
      <String, ProjectPlanDocument>{};
  final Map<String, List<ProjectImportRecord>> _imports =
      <String, List<ProjectImportRecord>>{};
  ProjectGatewayFailure? _failure;
  bool _loading = false;

  /// The registered authorized project identities, in the owner's order.
  List<ProjectIdentityFacts> get projects => _projects;

  /// True while a project request is in flight.
  bool get isLoading => _loading;

  /// The last refusal the owner published, or null.
  ProjectGatewayFailure? get lastFailure => _failure;

  /// The stable refusal code of the last failed request, or ''.
  String get lastErrorCode => _failure?.code ?? '';

  /// True when this controller already read the dependency facts of [projectId].
  ///
  /// False is an explicit absence for a renderer: the inputs of that project
  /// were not observed, which is different from observed-and-satisfied.
  bool hasDependencyFacts(String projectId) =>
      _dependencies.containsKey(projectId);

  List<ProjectDependencyFacts> dependenciesOf(String projectId) =>
      _dependencies[projectId] ?? const <ProjectDependencyFacts>[];

  List<ProjectDependencyFacts> unresolvedOf(String projectId) =>
      _unresolved[projectId] ?? const <ProjectDependencyFacts>[];

  /// The consumers [workItemId] blocks, or null when they were never read.
  ProjectBlockedConsumersFacts? blockedConsumersOf({
    required String projectId,
    required String workItemId,
  }) => _blocked['$projectId/$workItemId'];

  /// The plan declaration this client holds for [projectId], or null.
  ///
  /// The document is the caller's own conversion of a source it read under its
  /// own authorization; it is never a durable read-back, which no project route
  /// publishes.
  ProjectPlanDocument? declarationOf(String projectId) =>
      _declarations[projectId];

  /// Every import answer recorded for [projectId], oldest first.
  List<ProjectImportRecord> importRecordsOf(String projectId) =>
      _imports[projectId] ?? const <ProjectImportRecord>[];

  /// Reads the registered projects and the dependency facts of each one.
  Future<void> loadProjects() async {
    if (applicationStateDisposed) return;
    _begin();
    try {
      final projects = await _gateway.listProjects();
      _projects = List<ProjectIdentityFacts>.unmodifiable(projects);
      _failure = null;
      publishChange();
      for (final project in _projects) {
        await _readDependencyFacts(project.projectId);
      }
    } on ProjectGatewayFailure catch (failure) {
      _record(failure);
    } catch (_) {
      _record(_unreadable(ProjectOperations.list));
    } finally {
      _end();
    }
  }

  /// Reads the declared inputs and the unresolved inputs of one project.
  Future<void> loadProjectFacts(String projectId) async {
    if (applicationStateDisposed) return;
    _begin();
    try {
      await _readDependencyFacts(projectId);
      _failure = null;
    } on ProjectGatewayFailure catch (failure) {
      _record(failure);
    } catch (_) {
      _record(_unreadable(ProjectOperations.dependencies));
    } finally {
      _end();
    }
  }

  /// Reads what one blocked producer actually blocks, transitively.
  Future<void> inspectDependents({
    required String projectId,
    required String workItemId,
  }) async {
    if (applicationStateDisposed) return;
    _begin();
    try {
      final blocked = await _gateway.listBlockedConsumers(
        projectId: projectId,
        workItemId: workItemId,
      );
      _blocked['$projectId/$workItemId'] = blocked;
      _failure = null;
    } on ProjectGatewayFailure catch (failure) {
      _record(failure);
    } catch (_) {
      _record(_unreadable(ProjectOperations.blockedConsumers));
    } finally {
      _end();
    }
  }

  /// Reports what one declared plan document would change.
  Future<void> previewPlan(ProjectPlanDocument document) async {
    if (applicationStateDisposed) return;
    _begin();
    try {
      final change = await _gateway.previewPlanImport(document);
      _declarations[document.projectId] = document;
      _recordImport(change.projectId, ProjectImportRecord.previewed(change));
      _failure = null;
    } on ProjectGatewayFailure catch (failure) {
      _record(failure);
    } catch (_) {
      _record(_unreadable(ProjectOperations.importPreview));
    } finally {
      _end();
    }
  }

  /// Applies one declared plan document over the revision the caller previewed.
  ///
  /// The declaration is held only once the owner admitted it, so a refused
  /// document never becomes the projection's declared outcome.
  Future<void> applyPlan(
    ProjectPlanDocument document, {
    required int expectedRevision,
  }) async {
    if (applicationStateDisposed) return;
    _begin();
    try {
      final outcome = await _gateway.applyPlanImport(
        document,
        expectedRevision: expectedRevision,
      );
      _declarations[document.projectId] = document;
      _recordImport(
        outcome.change.projectId,
        ProjectImportRecord.applied(outcome.change, applied: outcome.applied),
      );
      await _readDependencyFacts(document.projectId);
      _failure = null;
    } on ProjectGatewayFailure catch (failure) {
      _record(failure);
    } catch (_) {
      _record(_unreadable(ProjectOperations.importApply));
    } finally {
      _end();
    }
  }

  @override
  void dispose() {
    if (applicationStateDisposed) return;
    _projects = const <ProjectIdentityFacts>[];
    super.dispose();
  }

  Future<void> _readDependencyFacts(String projectId) async {
    final declared = await _gateway.listDependencies(projectId);
    final unresolved = await _gateway.listUnresolvedArtifacts(projectId);
    _dependencies[projectId] = List<ProjectDependencyFacts>.unmodifiable(
      declared,
    );
    _unresolved[projectId] = List<ProjectDependencyFacts>.unmodifiable(
      unresolved,
    );
    publishChange();
  }

  void _recordImport(String projectId, ProjectImportRecord record) {
    final records = <ProjectImportRecord>[...?_imports[projectId], record];
    _imports[projectId] = List<ProjectImportRecord>.unmodifiable(records);
    publishChange();
  }

  void _begin() {
    _loading = true;
    publishChange();
  }

  void _end() {
    _loading = false;
    publishChange();
  }

  void _record(ProjectGatewayFailure failure) {
    _failure = failure;
    publishChange();
  }

  ProjectGatewayFailure _unreadable(String operation) =>
      ProjectGatewayFailure.malformed(operation: operation);
}
