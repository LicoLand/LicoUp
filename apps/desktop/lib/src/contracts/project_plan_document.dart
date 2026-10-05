/// The canonical plan document one caller converts and submits.
///
/// `project import-preview` and `project import-apply` take this document on
/// `--stdin-json`; an authorized Agent reads the source under its own
/// authorization and converts it deliberately. The native owner never opens,
/// scans or parses a source document, and there is no model call anywhere on
/// that path.
///
/// The declaration is total and it is a *declaration*: an outcome, the criteria
/// it will be judged by, the results it takes, the roles declared for it, and
/// the anchor in the source it was read from. A status, a progress, a completion
/// or an acceptance has no field anywhere in this file, and the owner refuses
/// such a field by name (`project_plan_progress_not_admitted`), so no
/// submission and no projection can assert that work ran or was accepted.
library;

/// Schema the canonical plan document declares.
const projectPlanDocumentSchema = 'licoup.project-plan/v1';

/// The declared result one work item takes along a dependency edge.
///
/// The two shapes are the whole rule: a location inside the declaring project's
/// own authorized root, or a work item of another registered project. A
/// dependency entry republishes the reference exactly as the caller declared
/// it, so this type serves both the declaration and the read-back.
sealed class ProjectArtifactDeclaration {
  const ProjectArtifactDeclaration();

  factory ProjectArtifactDeclaration.local({
    required String producerWorkItemId,
    required String path,
  }) = ProjectLocalArtifactDeclaration;

  factory ProjectArtifactDeclaration.crossProject({
    required String projectId,
    required String workItemId,
  }) = ProjectCrossProjectArtifactDeclaration;

  /// The kind name the owner publishes: `local` or `cross-project`.
  String get kind;

  /// The work item that produces the result, on either shape.
  String get producerWorkItemId;

  /// The project that owns the producing work item.
  String get producerProjectId;

  Map<String, Object?> toWire();
}

final class ProjectLocalArtifactDeclaration extends ProjectArtifactDeclaration {
  const ProjectLocalArtifactDeclaration({
    required this.producerWorkItemId,
    required this.path,
  });

  @override
  final String producerWorkItemId;

  /// The declared location inside the declaring project's authorized root.
  final String path;

  @override
  String get kind => 'local';

  @override
  String get producerProjectId => '';

  @override
  Map<String, Object?> toWire() => <String, Object?>{
    'kind': kind,
    'producerWorkItemId': producerWorkItemId,
    'path': path,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectLocalArtifactDeclaration &&
          other.producerWorkItemId == producerWorkItemId &&
          other.path == path;

  @override
  int get hashCode => Object.hash(kind, producerWorkItemId, path);
}

final class ProjectCrossProjectArtifactDeclaration
    extends ProjectArtifactDeclaration {
  const ProjectCrossProjectArtifactDeclaration({
    required this.projectId,
    required this.workItemId,
  });

  /// The registered project that declares the producing work item.
  final String projectId;

  final String workItemId;

  @override
  String get kind => 'cross-project';

  @override
  String get producerWorkItemId => workItemId;

  @override
  String get producerProjectId => projectId;

  @override
  Map<String, Object?> toWire() => <String, Object?>{
    'kind': kind,
    'projectId': projectId,
    'workItemId': workItemId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectCrossProjectArtifactDeclaration &&
          other.projectId == projectId &&
          other.workItemId == workItemId;

  @override
  int get hashCode => Object.hash(kind, projectId, workItemId);
}

/// Why scope one declared role reference applies to.
enum ProjectRoleScope {
  plan('plan'),
  project('project'),
  workItem('work-item');

  const ProjectRoleScope(this.wireName);

  final String wireName;
}

/// One reference into the role policy that already exists.
///
/// A reference and nothing more: no credential, membership or permission set is
/// carried, and no field here could hold one.
final class ProjectRoleDeclaration {
  const ProjectRoleDeclaration({
    required this.roleId,
    required this.scope,
    this.capability,
  });

  final String roleId;
  final ProjectRoleScope scope;

  /// The capability the role must hold in that scope, when one is named.
  final String? capability;

  Map<String, Object?> toWire() => <String, Object?>{
    'roleId': roleId,
    'scope': scope.wireName,
    'capability': capability,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectRoleDeclaration &&
          other.roleId == roleId &&
          other.scope == scope &&
          other.capability == capability;

  @override
  int get hashCode => Object.hash(roleId, scope, capability);
}

/// Where the canonical document was read from.
///
/// The locator is attribution only: the native owner stores and reports it and
/// never opens it.
final class ProjectPlanSourceDeclaration {
  const ProjectPlanSourceDeclaration({
    required this.sourceId,
    required this.sourceKind,
    required this.locator,
  });

  final String sourceId;

  /// The declared kind of the source, in the caller's own vocabulary.
  final String sourceKind;

  final String locator;

  Map<String, Object?> toWire() => <String, Object?>{
    'sourceId': sourceId,
    'sourceKind': sourceKind,
    'locator': locator,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectPlanSourceDeclaration &&
          other.sourceId == sourceId &&
          other.sourceKind == sourceKind &&
          other.locator == locator;

  @override
  int get hashCode => Object.hash(sourceId, sourceKind, locator);
}

/// One declared work item of a plan.
///
/// The declaration is total and it is a *declaration*: an outcome, the criteria
/// it will be judged by, the results it takes, the roles declared for it, and
/// the anchor in the source it was read from. There is deliberately no field
/// that could assert a run, a completion or an acceptance.
final class ProjectPlanWorkItemDeclaration {
  ProjectPlanWorkItemDeclaration({
    required this.workItemId,
    required this.outcome,
    Iterable<String> acceptance = const <String>[],
    Iterable<ProjectArtifactDeclaration> inputs =
        const <ProjectArtifactDeclaration>[],
    Iterable<ProjectRoleDeclaration> roles = const <ProjectRoleDeclaration>[],
    this.sourceAnchor = '',
  }) : acceptance = List<String>.unmodifiable(acceptance),
       inputs = List<ProjectArtifactDeclaration>.unmodifiable(inputs),
       roles = List<ProjectRoleDeclaration>.unmodifiable(roles);

  final String workItemId;

  /// What this work item is for.
  final String outcome;

  /// The criteria the work will be judged by. Declarations, not evidence.
  final List<String> acceptance;

  final List<ProjectArtifactDeclaration> inputs;
  final List<ProjectRoleDeclaration> roles;

  /// The anchor in the source this work item was read from.
  final String sourceAnchor;

  Map<String, Object?> toWire() => <String, Object?>{
    'workItemId': workItemId,
    'outcome': outcome,
    'acceptance': acceptance,
    'inputs': <Object?>[for (final input in inputs) input.toWire()],
    'roles': <Object?>[for (final role in roles) role.toWire()],
    'sourceAnchor': sourceAnchor,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectPlanWorkItemDeclaration &&
          other.workItemId == workItemId &&
          other.outcome == outcome &&
          _sameTexts(other.acceptance, acceptance) &&
          _sameValues(other.inputs, inputs) &&
          _sameValues(other.roles, roles) &&
          other.sourceAnchor == sourceAnchor;

  @override
  int get hashCode => Object.hash(
    workItemId,
    outcome,
    Object.hashAll(acceptance),
    Object.hashAll(inputs),
    Object.hashAll(roles),
    sourceAnchor,
  );
}

/// One canonical plan document: the caller's deliberate conversion of a source
/// this client read under its own authorization.
///
/// The same value is what `project import-preview` and `project import-apply`
/// carry on `--stdin-json`, and what the projection reads its declared outcome
/// and acceptance criteria from. A status, a progress or a completion has no
/// field here, so no submission and no projection can assert one.
final class ProjectPlanDocument {
  ProjectPlanDocument({
    required this.projectId,
    required this.planId,
    required this.source,
    required Iterable<ProjectPlanWorkItemDeclaration> workItems,
    this.schema = projectPlanDocumentSchema,
  }) : workItems = List<ProjectPlanWorkItemDeclaration>.unmodifiable(workItems);

  final String schema;
  final String projectId;
  final String planId;
  final ProjectPlanSourceDeclaration source;
  final List<ProjectPlanWorkItemDeclaration> workItems;

  Map<String, Object?> toWire() => <String, Object?>{
    'schema': schema,
    'projectId': projectId,
    'planId': planId,
    'source': source.toWire(),
    'workItems': <Object?>[for (final item in workItems) item.toWire()],
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectPlanDocument &&
          other.schema == schema &&
          other.projectId == projectId &&
          other.planId == planId &&
          other.source == source &&
          _sameValues(other.workItems, workItems);

  @override
  int get hashCode =>
      Object.hash(schema, projectId, planId, source, Object.hashAll(workItems));
}

bool _sameTexts(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameValues<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
