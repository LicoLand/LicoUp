import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';

/// One project envelope, framed exactly as the native surface publishes it.
Map<String, Object?> projectOkEnvelope(
  String operation,
  Map<String, Object?> outcome,
) => <String, Object?>{
  'schema': projectEnvelopeSchema,
  'family': projectEnvelopeFamily,
  'operation': operation,
  'status': 'ok',
  'outcome': outcome,
};

/// One refused project envelope, framed exactly as the native surface
/// publishes it.
Map<String, Object?> projectFailureEnvelope(
  String operation,
  Map<String, Object?> failure,
) => <String, Object?>{
  'schema': projectEnvelopeSchema,
  'family': projectEnvelopeFamily,
  'operation': operation,
  'status': 'failed',
  'failure': failure,
};

/// One registered project as `project list` publishes it.
Map<String, Object?> projectIdentityWire(
  String projectId, {
  int sequence = 1,
  String displayName = '',
  String authorizedRoot = '',
}) => <String, Object?>{
  'projectId': projectId,
  'displayName': displayName.isEmpty ? 'Project $projectId' : displayName,
  'authorizedRoot': authorizedRoot.isEmpty
      ? '/srv/roots/$projectId'
      : authorizedRoot,
  'authorityKind': 'role',
  'authorityReference': 'role:developer',
  'workspaceId': '$projectId-workspace',
  'planId': '$projectId-plan',
  'registrationSequence': sequence,
};

/// One declared dependency as `project dependency list` publishes it.
Map<String, Object?> projectDependencyWire({
  required int sequence,
  required String consumerProject,
  required String consumerItem,
  required String producerProject,
  required String producerItem,
  String state = 'materialized',
  String path = 'artifacts/spec.md',
  bool crossProject = false,
}) => <String, Object?>{
  'dependencySequence': sequence,
  'consumer': <String, Object?>{
    'projectId': consumerProject,
    'workItemId': consumerItem,
  },
  'producer': <String, Object?>{
    'projectId': producerProject,
    'workItemId': producerItem,
  },
  'artifact': crossProject
      ? <String, Object?>{
          'kind': 'cross-project',
          'projectId': producerProject,
          'workItemId': producerItem,
        }
      : <String, Object?>{
          'kind': 'local',
          'producerWorkItemId': producerItem,
          'path': path,
        },
  'artifactState': state,
};

/// One import change as `project import-preview` publishes it.
Map<String, Object?> projectChangeWire({
  String projectId = 'alpha',
  int revision = 3,
  bool replayed = false,
  List<String> added = const <String>['docs'],
  List<String> unchanged = const <String>[],
  List<String> retained = const <String>[],
  List<String> anchors = const <String>['docs'],
}) => <String, Object?>{
  'projectId': projectId,
  'planId': '$projectId-plan',
  'sourceId': 'plan-source',
  'revision': revision,
  'digest': 'digest-$revision',
  'replayed': replayed,
  'added': added,
  'unchanged': unchanged,
  'retained': retained,
  'mapping': <Object?>[
    for (final anchor in anchors)
      <String, Object?>{
        'workItemId': anchor,
        'sourceId': 'plan-source',
        'sourceAnchor': 'Plan#$anchor',
      },
  ],
  'inputCount': 1,
};

/// Recording test double for the narrow project gateway.
///
/// It answers with the typed facts the native envelopes decode into, so a
/// controller test exercises the boundary instead of a live read. Every call is
/// recorded, which is what lets a drag test prove that no durable read or write
/// happened.
final class ProjectGatewayFixture implements ProjectManagementGateway {
  ProjectGatewayFixture({
    List<ProjectIdentityFacts> projects = const <ProjectIdentityFacts>[],
    Map<String, List<ProjectDependencyFacts>> dependencies =
        const <String, List<ProjectDependencyFacts>>{},
    Map<String, List<ProjectDependencyFacts>> unresolved =
        const <String, List<ProjectDependencyFacts>>{},
    Map<String, ProjectBlockedConsumersFacts> blocked =
        const <String, ProjectBlockedConsumersFacts>{},
    this.previewResult,
    this.applyResult,
    this.failure,
  }) : projects = List<ProjectIdentityFacts>.unmodifiable(projects),
       dependencies = Map<String, List<ProjectDependencyFacts>>.unmodifiable(
         dependencies,
       ),
       unresolved = Map<String, List<ProjectDependencyFacts>>.unmodifiable(
         unresolved,
       ),
       blocked = Map<String, ProjectBlockedConsumersFacts>.unmodifiable(
         blocked,
       );

  List<ProjectIdentityFacts> projects;
  Map<String, List<ProjectDependencyFacts>> dependencies;
  Map<String, List<ProjectDependencyFacts>> unresolved;
  Map<String, ProjectBlockedConsumersFacts> blocked;
  ProjectImportChangeFacts? previewResult;
  ProjectPlanImportOutcomeFacts? applyResult;

  /// Every call this double answered, as `<method>:<argument>`.
  final List<String> calls = <String>[];

  /// While set, every call is refused with this failure.
  ProjectGatewayFailure? failure;

  /// While set, every call throws this object instead of answering.
  Object? transportError;

  /// While set, only calls whose recorded name starts with this prefix are
  /// refused, so one read can fail while the others answer.
  String? refusedCallPrefix;

  /// The plan documents this double was asked to preview or apply.
  final List<ProjectPlanDocument> submitted = <ProjectPlanDocument>[];

  int get callCount => calls.length;

  @override
  Future<List<ProjectIdentityFacts>> listProjects() async {
    calls.add('listProjects');
    _refuse(calls.last);
    return projects;
  }

  @override
  Future<ProjectIdentityFacts?> readProject(String projectId) async {
    calls.add('readProject:$projectId');
    _refuse(calls.last);
    for (final project in projects) {
      if (project.projectId == projectId) return project;
    }
    return null;
  }

  @override
  Future<ProjectImportChangeFacts> previewPlanImport(
    ProjectPlanDocument document,
  ) async {
    calls.add('previewPlanImport:${document.projectId}');
    submitted.add(document);
    _refuse(calls.last);
    final result = previewResult;
    if (result == null) throw StateError('no preview answer configured');
    return result;
  }

  @override
  Future<ProjectPlanImportOutcomeFacts> applyPlanImport(
    ProjectPlanDocument document, {
    required int expectedRevision,
  }) async {
    calls.add('applyPlanImport:${document.projectId}@$expectedRevision');
    submitted.add(document);
    _refuse(calls.last);
    final result = applyResult;
    if (result == null) throw StateError('no apply answer configured');
    return result;
  }

  @override
  Future<List<ProjectDependencyFacts>> listDependencies(
    String projectId,
  ) async {
    calls.add('listDependencies:$projectId');
    _refuse(calls.last);
    return dependencies[projectId] ?? const <ProjectDependencyFacts>[];
  }

  @override
  Future<List<ProjectDependencyFacts>> listUnresolvedArtifacts(
    String projectId,
  ) async {
    calls.add('listUnresolvedArtifacts:$projectId');
    _refuse(calls.last);
    return unresolved[projectId] ?? const <ProjectDependencyFacts>[];
  }

  @override
  Future<ProjectBlockedConsumersFacts> listBlockedConsumers({
    required String projectId,
    required String workItemId,
  }) async {
    calls.add('listBlockedConsumers:$projectId/$workItemId');
    _refuse(calls.last);
    return blocked['$projectId/$workItemId'] ??
        ProjectBlockedConsumersFacts(
          producer: ProjectWorkRefFacts(
            projectId: projectId,
            workItemId: workItemId,
          ),
        );
  }

  void _refuse(String call) {
    final prefix = refusedCallPrefix;
    if (prefix != null && !call.startsWith(prefix)) return;
    final error = transportError;
    if (error != null) throw error;
    final refusal = failure;
    if (refusal != null) throw refusal;
  }
}
