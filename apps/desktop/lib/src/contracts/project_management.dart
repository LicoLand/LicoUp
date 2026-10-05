/// Authorized project facts, as the native `project` command family publishes
/// them.
///
/// Every route answers one envelope:
///
/// ```text
/// {"schema": "licoup.project-identity/v1", "family": "project",
///  "operation": "project.list", "status": "ok", "outcome": { ... }}
/// ```
///
/// or the same envelope with `"status": "failed"` and a `failure`
/// `{code, stage, retryable, recovery}` body. [ProjectEnvelope] reads that
/// frame once, so a decode failure is one typed refusal instead of a map lookup
/// at every call site.
///
/// Two properties of the native model are carried through unchanged, because a
/// client that repairs them would be inventing state:
///
/// - A declared reference always has an explicit [ProjectArtifactState]. An
///   absent result is `missing`, never an empty one.
/// - A plan document declares work; it cannot assert a run, a completion or an
///   acceptance. The document model in `project_plan_document.dart` has no field
///   that could hold one, and the owner refuses such a field by name.
library;

import 'package:licoup/src/contracts/project_plan_document.dart';

/// Schema every project command envelope declares.
const projectEnvelopeSchema = 'licoup.project-identity/v1';

/// Family every project command envelope declares.
const projectEnvelopeFamily = 'project';

/// Refusal code this client publishes when an answer cannot be read at all.
const projectOperationUnreadable = 'project_operation_unreadable';

/// Operations the project command family publishes, as the owner names them.
abstract final class ProjectOperations {
  static const String register = 'project.register';
  static const String read = 'project.read';
  static const String list = 'project.list';
  static const String importPreview = 'project.import.preview';
  static const String importApply = 'project.import.apply';
  static const String declareDependency = 'project.declare-dependency';
  static const String dependencies = 'project.dependencies';
  static const String unresolvedArtifacts = 'project.unresolved-artifacts';
  static const String blockedConsumers = 'project.blocked-consumers';
}

/// One registered authorized project identity, as `project list` publishes it.
///
/// The authority travels as the reference the owner admitted, in its two parts.
/// There is no field for a credential, because the record has none.
final class ProjectIdentityFacts {
  const ProjectIdentityFacts({
    required this.projectId,
    required this.displayName,
    required this.authorizedRoot,
    required this.authorityKind,
    required this.authorityReference,
    required this.workspaceId,
    required this.planId,
    required this.registrationSequence,
  });

  factory ProjectIdentityFacts.fromWire(Object? wire) {
    if (wire is! Map) {
      throw ProjectGatewayFailure.malformed(operation: ProjectOperations.list);
    }
    final json = wire.cast<String, Object?>();
    return ProjectIdentityFacts(
      projectId: _text(json, 'projectId', ProjectOperations.list),
      displayName: (json['displayName'] ?? '').toString(),
      authorizedRoot: (json['authorizedRoot'] ?? '').toString(),
      authorityKind: (json['authorityKind'] ?? '').toString(),
      authorityReference: (json['authorityReference'] ?? '').toString(),
      workspaceId: (json['workspaceId'] ?? '').toString(),
      planId: (json['planId'] ?? '').toString(),
      registrationSequence: _integer(
        json['registrationSequence'],
        ProjectOperations.list,
      ),
    );
  }

  /// Reads the `outcome.projects` list of a `project list` envelope.
  static List<ProjectIdentityFacts> listFromEnvelope(Object? wire) {
    final envelope = ProjectEnvelope.decode(
      wire,
      expectedOperation: ProjectOperations.list,
    );
    return <ProjectIdentityFacts>[
      for (final project in _objects(envelope.outcome['projects']))
        ProjectIdentityFacts.fromWire(project),
    ];
  }

  /// Reads the `outcome.project` of a `project read` envelope.
  ///
  /// A null project is the owner's own answer that no registration carries the
  /// identity — different from a registration with empty fields.
  static ProjectIdentityFacts? readFromEnvelope(
    Object? wire, {
    required String projectId,
  }) {
    final envelope = ProjectEnvelope.decode(
      wire,
      expectedOperation: ProjectOperations.read,
    );
    final project = envelope.outcome['project'];
    if (project == null) return null;
    final facts = ProjectIdentityFacts.fromWire(project);
    if (facts.projectId != projectId) {
      throw ProjectGatewayFailure.malformed(
        operation: ProjectOperations.read,
        reference: projectId,
      );
    }
    return facts;
  }

  final String projectId;
  final String displayName;

  /// The root the registration declares. Stored as a declaration, never
  /// resolved: no route lists or opens it.
  final String authorizedRoot;

  final String authorityKind;
  final String authorityReference;
  final String workspaceId;
  final String planId;

  /// Order in which the owner admitted the registration.
  final int registrationSequence;

  /// Renderer-facing label for [authorizedRoot].
  ///
  /// The full root identifies a project to the person who registered it, but a
  /// renderer must not echo a local absolute path, so the label keeps only the
  /// final segment.
  String get authorizedRootLabel => projectRootLabel(authorizedRoot);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectIdentityFacts &&
          other.projectId == projectId &&
          other.displayName == displayName &&
          other.authorizedRoot == authorizedRoot &&
          other.authorityKind == authorityKind &&
          other.authorityReference == authorityReference &&
          other.workspaceId == workspaceId &&
          other.planId == planId &&
          other.registrationSequence == registrationSequence;

  @override
  int get hashCode => Object.hash(
    projectId,
    displayName,
    authorizedRoot,
    authorityKind,
    authorityReference,
    workspaceId,
    planId,
    registrationSequence,
  );
}

/// The last declared component of one authorized root, for renderers.
String projectRootLabel(String root) {
  final trimmed = root.trim();
  if (trimmed.isEmpty) return '';
  var end = trimmed.length;
  while (end > 0 && (trimmed[end - 1] == '/' || trimmed[end - 1] == r'\')) {
    end -= 1;
  }
  if (end == 0) return trimmed;
  var start = end;
  while (start > 0 && trimmed[start - 1] != '/' && trimmed[start - 1] != r'\') {
    start -= 1;
  }
  return trimmed.substring(start, end);
}

/// One work item addressed across projects.
///
/// A work item identity is unique inside its project, not globally, so every
/// reference to one carries the project that owns it.
final class ProjectWorkRefFacts {
  const ProjectWorkRefFacts({
    required this.projectId,
    required this.workItemId,
  });

  factory ProjectWorkRefFacts.fromWire(Object? wire) {
    if (wire is! Map) {
      throw ProjectGatewayFailure.malformed(
        operation: ProjectOperations.dependencies,
      );
    }
    final json = wire.cast<String, Object?>();
    return ProjectWorkRefFacts(
      projectId: _text(json, 'projectId', ProjectOperations.dependencies),
      workItemId: _text(json, 'workItemId', ProjectOperations.dependencies),
    );
  }

  final String projectId;
  final String workItemId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectWorkRefFacts &&
          other.projectId == projectId &&
          other.workItemId == workItemId;

  @override
  int get hashCode => Object.hash(projectId, workItemId);

  @override
  String toString() => '$projectId/$workItemId';
}

/// The explicit state of one declared artifact reference.
///
/// The owner publishes one of these per reference; a client never infers a
/// state it did not read.
enum ProjectArtifactState {
  /// The declared location exists inside the authorized root, or the referenced
  /// project declares the referenced work item.
  materialized('materialized'),

  /// The declared location is absent, or the referenced project declares no
  /// such work item. Explicit: an absent result never becomes an empty one.
  missing('missing'),

  /// The reference cannot be evaluated inside the declared authority.
  unavailable('unavailable');

  const ProjectArtifactState(this.wireName);

  final String wireName;

  static ProjectArtifactState? fromWire(Object? value) {
    for (final state in ProjectArtifactState.values) {
      if (state.wireName == value) return state;
    }
    return null;
  }
}

/// One declared dependency: the reference, its producer, and its state.
///
/// Nothing here is a resolution: a missing result is published as `missing`
/// rather than as an absent entry.
final class ProjectDependencyFacts {
  const ProjectDependencyFacts({
    required this.dependencySequence,
    required this.consumer,
    required this.producer,
    required this.artifact,
    required this.artifactState,
  });

  factory ProjectDependencyFacts.fromWire(Object? wire) {
    if (wire is! Map) {
      throw ProjectGatewayFailure.malformed(
        operation: ProjectOperations.dependencies,
      );
    }
    final json = wire.cast<String, Object?>();
    final state = ProjectArtifactState.fromWire(json['artifactState']);
    if (state == null) {
      throw ProjectGatewayFailure.malformed(
        operation: ProjectOperations.dependencies,
      );
    }
    return ProjectDependencyFacts(
      dependencySequence: _integer(
        json['dependencySequence'],
        ProjectOperations.dependencies,
      ),
      consumer: ProjectWorkRefFacts.fromWire(json['consumer']),
      producer: ProjectWorkRefFacts.fromWire(json['producer']),
      artifact: _artifactWire(json['artifact'], ProjectOperations.dependencies),
      artifactState: state,
    );
  }

  final int dependencySequence;
  final ProjectWorkRefFacts consumer;
  final ProjectWorkRefFacts producer;
  final ProjectArtifactDeclaration artifact;
  final ProjectArtifactState artifactState;

  /// Reads the `outcome.dependencies` list of a `project dependency list`
  /// envelope.
  static List<ProjectDependencyFacts> listFromEnvelope(Object? wire) {
    final envelope = ProjectEnvelope.decode(
      wire,
      expectedOperation: ProjectOperations.dependencies,
    );
    return <ProjectDependencyFacts>[
      for (final entry in _objects(envelope.outcome['dependencies']))
        ProjectDependencyFacts.fromWire(entry),
    ];
  }

  /// Reads the `outcome.unresolvedArtifacts` list of a `project dependency
  /// unresolved` envelope.
  static List<ProjectDependencyFacts> unresolvedFromEnvelope(Object? wire) {
    final envelope = ProjectEnvelope.decode(
      wire,
      expectedOperation: ProjectOperations.unresolvedArtifacts,
    );
    return <ProjectDependencyFacts>[
      for (final entry in _objects(envelope.outcome['unresolvedArtifacts']))
        ProjectDependencyFacts.fromWire(entry),
    ];
  }

  bool get isMaterialized => artifactState == ProjectArtifactState.materialized;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectDependencyFacts &&
          other.dependencySequence == dependencySequence &&
          other.consumer == consumer &&
          other.producer == producer &&
          other.artifact == artifact &&
          other.artifactState == artifactState;

  @override
  int get hashCode => Object.hash(
    dependencySequence,
    consumer,
    producer,
    artifact,
    artifactState,
  );
}

/// One anchor per declared work item, in document order.
final class ProjectSourceMappingFacts {
  const ProjectSourceMappingFacts({
    required this.workItemId,
    required this.sourceId,
    required this.sourceAnchor,
  });

  factory ProjectSourceMappingFacts.fromWire(Object? wire) {
    if (wire is! Map) {
      throw ProjectGatewayFailure.malformed(
        operation: ProjectOperations.importPreview,
      );
    }
    final json = wire.cast<String, Object?>();
    return ProjectSourceMappingFacts(
      workItemId: _text(json, 'workItemId', ProjectOperations.importPreview),
      sourceId: _text(json, 'sourceId', ProjectOperations.importPreview),
      sourceAnchor: (json['sourceAnchor'] ?? '').toString(),
    );
  }

  final String workItemId;
  final String sourceId;
  final String sourceAnchor;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectSourceMappingFacts &&
          other.workItemId == workItemId &&
          other.sourceId == sourceId &&
          other.sourceAnchor == sourceAnchor;

  @override
  int get hashCode => Object.hash(workItemId, sourceId, sourceAnchor);
}

/// What one explicit import changes, or would change.
///
/// The same value answers the preview and the applied result, so a renderer
/// showing what an import would do and the owner reporting what it did cannot
/// disagree about the fields.
final class ProjectImportChangeFacts {
  ProjectImportChangeFacts({
    required this.projectId,
    required this.planId,
    required this.sourceId,
    required this.revision,
    required this.digest,
    required this.replayed,
    Iterable<String> added = const <String>[],
    Iterable<String> unchanged = const <String>[],
    Iterable<String> retained = const <String>[],
    Iterable<ProjectSourceMappingFacts> mapping =
        const <ProjectSourceMappingFacts>[],
    required this.inputCount,
  }) : added = List<String>.unmodifiable(added),
       unchanged = List<String>.unmodifiable(unchanged),
       retained = List<String>.unmodifiable(retained),
       mapping = List<ProjectSourceMappingFacts>.unmodifiable(mapping);

  factory ProjectImportChangeFacts.fromWire(
    Object? wire, {
    String operation = ProjectOperations.importPreview,
  }) {
    if (wire is! Map) {
      throw ProjectGatewayFailure.malformed(operation: operation);
    }
    final json = wire.cast<String, Object?>();
    return ProjectImportChangeFacts(
      projectId: _text(json, 'projectId', operation),
      planId: _text(json, 'planId', operation),
      sourceId: _text(json, 'sourceId', operation),
      revision: _integer(json['revision'], operation),
      digest: (json['digest'] ?? '').toString(),
      replayed: json['replayed'] == true,
      added: _texts(json['added'], operation),
      unchanged: _texts(json['unchanged'], operation),
      retained: _texts(json['retained'], operation),
      mapping: <ProjectSourceMappingFacts>[
        for (final entry in _objects(json['mapping']))
          ProjectSourceMappingFacts.fromWire(entry),
      ],
      inputCount: _integer(json['inputCount'], operation),
    );
  }

  /// Reads the change a `project import-preview` envelope published.
  static ProjectImportChangeFacts previewFromEnvelope(Object? wire) {
    final envelope = ProjectEnvelope.decode(
      wire,
      expectedOperation: ProjectOperations.importPreview,
    );
    return ProjectImportChangeFacts.fromWire(
      envelope.outcome,
      operation: ProjectOperations.importPreview,
    );
  }

  /// Reads the `{applied, change}` body a `project import-apply` envelope
  /// published.
  static ProjectPlanImportOutcomeFacts appliedFromEnvelope(Object? wire) {
    final envelope = ProjectEnvelope.decode(
      wire,
      expectedOperation: ProjectOperations.importApply,
    );
    final change = envelope.outcome['change'];
    return ProjectPlanImportOutcomeFacts(
      applied: envelope.outcome['applied'] == true,
      change: ProjectImportChangeFacts.fromWire(
        change,
        operation: ProjectOperations.importApply,
      ),
    );
  }

  final String projectId;
  final String planId;
  final String sourceId;

  /// The state this call starts from: the revision an apply must expect.
  final int revision;

  /// The digest of the submitted document.
  final String digest;

  /// Whether the submitted document is exactly the stored revision.
  final bool replayed;

  /// Declared work items this slice did not hold.
  final List<String> added;

  /// Declared work items this slice already held.
  final List<String> unchanged;

  /// Stored work items the document omits. Retained, never deleted.
  final List<String> retained;

  final List<ProjectSourceMappingFacts> mapping;

  /// How many declared inputs the document carries.
  final int inputCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectImportChangeFacts &&
          other.projectId == projectId &&
          other.planId == planId &&
          other.sourceId == sourceId &&
          other.revision == revision &&
          other.digest == digest &&
          other.replayed == replayed &&
          _sameTexts(other.added, added) &&
          _sameTexts(other.unchanged, unchanged) &&
          _sameTexts(other.retained, retained) &&
          _sameValues(other.mapping, mapping) &&
          other.inputCount == inputCount;

  @override
  int get hashCode => Object.hash(
    projectId,
    planId,
    sourceId,
    revision,
    digest,
    replayed,
    Object.hashAll(added),
    Object.hashAll(unchanged),
    Object.hashAll(retained),
    Object.hashAll(mapping),
    inputCount,
  );
}

/// What one explicit import did.
final class ProjectPlanImportOutcomeFacts {
  const ProjectPlanImportOutcomeFacts({
    required this.applied,
    required this.change,
  });

  /// Whether durable state changed. A replay of the stored revision changes
  /// nothing, so re-submitting the same document twice is one effect.
  final bool applied;

  final ProjectImportChangeFacts change;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectPlanImportOutcomeFacts &&
          other.applied == applied &&
          other.change == change;

  @override
  int get hashCode => Object.hash(applied, change);
}

/// The consumers one blocked producer actually blocks, transitively.
final class ProjectBlockedConsumersFacts {
  ProjectBlockedConsumersFacts({
    required this.producer,
    Iterable<ProjectWorkRefFacts> blockedConsumers =
        const <ProjectWorkRefFacts>[],
  }) : blockedConsumers = List<ProjectWorkRefFacts>.unmodifiable(
         blockedConsumers,
       );

  factory ProjectBlockedConsumersFacts.fromWire(Object? wire) {
    if (wire is! Map) {
      throw ProjectGatewayFailure.malformed(
        operation: ProjectOperations.blockedConsumers,
      );
    }
    final json = wire.cast<String, Object?>();
    return ProjectBlockedConsumersFacts(
      producer: ProjectWorkRefFacts.fromWire(json['producer']),
      blockedConsumers: <ProjectWorkRefFacts>[
        for (final consumer in _objects(json['blockedConsumers']))
          ProjectWorkRefFacts.fromWire(consumer),
      ],
    );
  }

  /// Reads the body of a `project dependency blocked` envelope.
  static ProjectBlockedConsumersFacts fromEnvelope(Object? wire) {
    final envelope = ProjectEnvelope.decode(
      wire,
      expectedOperation: ProjectOperations.blockedConsumers,
    );
    return ProjectBlockedConsumersFacts.fromWire(envelope.outcome);
  }

  final ProjectWorkRefFacts producer;
  final List<ProjectWorkRefFacts> blockedConsumers;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectBlockedConsumersFacts &&
          other.producer == producer &&
          _sameValues(other.blockedConsumers, blockedConsumers);

  @override
  int get hashCode => Object.hash(producer, Object.hashAll(blockedConsumers));
}

/// One project envelope, read once.
///
/// The frame is verified before its body is used: a payload that is not a
/// project envelope is refused as [ProjectGatewayFailure] rather than read
/// leniently, so a mismatched answer cannot be presented as project facts.
final class ProjectEnvelope {
  const ProjectEnvelope({required this.outcome});

  factory ProjectEnvelope.decode(
    Object? wire, {
    required String expectedOperation,
  }) {
    if (wire is! Map) {
      throw ProjectGatewayFailure.malformed(operation: expectedOperation);
    }
    final envelope = wire.cast<String, Object?>();
    if (envelope['schema'] != projectEnvelopeSchema ||
        envelope['family'] != projectEnvelopeFamily) {
      throw ProjectGatewayFailure.malformed(operation: expectedOperation);
    }
    final status = envelope['status'];
    if (status == 'failed') {
      throw ProjectGatewayFailure.fromWire(
        operation: expectedOperation,
        failure: envelope['failure'],
      );
    }
    if (status != 'ok') {
      throw ProjectGatewayFailure.malformed(operation: expectedOperation);
    }
    final outcome = envelope['outcome'];
    if (outcome is! Map) {
      throw ProjectGatewayFailure.malformed(operation: expectedOperation);
    }
    return ProjectEnvelope(outcome: outcome.cast<String, Object?>());
  }

  /// The operation body, with the frame and any refusal already resolved.
  final Map<String, Object?> outcome;
}

/// One refused project operation.
///
/// The refusal keeps the owner's own vocabulary — `code`, `stage`, `retryable`
/// and `recovery` — so an interface branches on one stable code instead of on
/// message text. [reference] carries the public argument the refusal named: the
/// document path of a refused import, for example.
final class ProjectGatewayFailure implements Exception {
  const ProjectGatewayFailure({
    required this.operation,
    required this.code,
    this.stage = '',
    this.retryable = false,
    this.recovery = '',
    this.reference = '',
  });

  /// Reads the `failure` body one project envelope published.
  factory ProjectGatewayFailure.fromWire({
    required String operation,
    required Object? failure,
  }) {
    if (failure is! Map) {
      return ProjectGatewayFailure.malformed(operation: operation);
    }
    final body = failure.cast<String, Object?>();
    final code = body['code'];
    if (code is! String || code.trim().isEmpty) {
      return ProjectGatewayFailure.malformed(operation: operation);
    }
    final presentationArgs = body['presentationArgs'];
    return ProjectGatewayFailure(
      operation: operation,
      code: code,
      stage: (body['stage'] ?? '').toString(),
      retryable: body['retryable'] == true,
      recovery: (body['recovery'] ?? '').toString(),
      reference: presentationArgs is List && presentationArgs.isNotEmpty
          ? presentationArgs.map((value) => value.toString()).join(', ')
          : '',
    );
  }

  /// The answer could not be read as this operation's own outcome.
  factory ProjectGatewayFailure.malformed({
    required String operation,
    String reference = '',
  }) => ProjectGatewayFailure(
    operation: operation,
    code: projectOperationUnreadable,
    stage: 'client_decode',
    retryable: true,
    recovery: 'reload',
    reference: reference,
  );

  /// The operation whose answer was refused.
  final String operation;

  /// The owner's stable refusal code, or [projectOperationUnreadable].
  final String code;

  final String stage;
  final bool retryable;

  /// The recovery the owner published for this refusal.
  final String recovery;

  /// The public argument the refusal named, when it published one.
  final String reference;

  /// True when this client could not read the answer at all.
  bool get isMalformed => code == projectOperationUnreadable;

  @override
  String toString() =>
      'ProjectGatewayFailure($operation, $code'
      '${stage.isEmpty ? '' : ', $stage'}'
      '${reference.isEmpty ? '' : ', $reference'})';
}

/// Narrow native boundary of the authorized-project command family.
///
/// Every method reads one project envelope and returns its decoded outcome, or
/// throws [ProjectGatewayFailure] carrying the owner's refusal. The interface
/// deliberately excludes the routes this projection does not read — register
/// and declare — so a view can only reach the facts it presents.
abstract interface class ProjectManagementGateway {
  /// `project list`: every registered authorized project identity.
  Future<List<ProjectIdentityFacts>> listProjects();

  /// `project read <project-id>`: one identity, or null when none is
  /// registered.
  Future<ProjectIdentityFacts?> readProject(String projectId);

  /// `project import-preview --stdin-json <document>`: what one document would
  /// change, without changing anything.
  Future<ProjectImportChangeFacts> previewPlanImport(
    ProjectPlanDocument document,
  );

  /// `project import-apply --stdin-json <document> --expected-revision <n>`:
  /// apply one document over the revision the caller previewed.
  Future<ProjectPlanImportOutcomeFacts> applyPlanImport(
    ProjectPlanDocument document, {
    required int expectedRevision,
  });

  /// `project dependency list <project-id>`: every declared input with its
  /// explicit artifact state.
  Future<List<ProjectDependencyFacts>> listDependencies(String projectId);

  /// `project dependency unresolved <project-id>`: the declared inputs whose
  /// result is not materialized.
  Future<List<ProjectDependencyFacts>> listUnresolvedArtifacts(
    String projectId,
  );

  /// `project dependency blocked <project-id> <work-item-id>`: the consumers
  /// one blocked producer blocks, transitively.
  Future<ProjectBlockedConsumersFacts> listBlockedConsumers({
    required String projectId,
    required String workItemId,
  });
}

/// Reads one declared reference as the dependency read publishes it.
///
/// The declaration model itself only writes; this read-back decoder lives with
/// the facts that publish it, so a shape this client cannot name is refused by
/// the operation that produced it rather than by the declaration.
ProjectArtifactDeclaration _artifactWire(Object? wire, String operation) {
  if (wire is! Map) {
    throw ProjectGatewayFailure.malformed(operation: operation);
  }
  final json = wire.cast<String, Object?>();
  switch (json['kind']) {
    case 'local':
      return ProjectLocalArtifactDeclaration(
        producerWorkItemId: _text(json, 'producerWorkItemId', operation),
        path: _text(json, 'path', operation),
      );
    case 'cross-project':
      return ProjectCrossProjectArtifactDeclaration(
        projectId: _text(json, 'projectId', operation),
        workItemId: _text(json, 'workItemId', operation),
      );
    default:
      throw ProjectGatewayFailure.malformed(operation: operation);
  }
}

String _text(Map<String, Object?> json, String key, String operation) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw ProjectGatewayFailure.malformed(operation: operation);
  }
  return value;
}

int _integer(Object? value, String operation) {
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  throw ProjectGatewayFailure.malformed(operation: operation);
}

List<String> _texts(Object? value, String operation) {
  if (value == null) return const <String>[];
  if (value is! List) {
    throw ProjectGatewayFailure.malformed(operation: operation);
  }
  return <String>[
    for (final entry in value)
      if (entry is String)
        entry
      else
        throw ProjectGatewayFailure.malformed(operation: operation),
  ];
}

List<Map<String, Object?>> _objects(Object? value) {
  if (value == null) return const <Map<String, Object?>>[];
  if (value is! List) {
    throw ProjectGatewayFailure.malformed(
      operation: ProjectOperations.dependencies,
    );
  }
  return <Map<String, Object?>>[
    for (final entry in value)
      if (entry is Map) entry.cast<String, Object?>(),
  ];
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
