import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Stable identity of one work item across the whole plan surface.
///
/// A work item identity is unique inside its project, so the local arrangement
/// keys on the pair. Both the facts and the local layout derive their key here,
/// so a placement cannot name a work item the facts do not.
String projectWorkItemKey(String projectId, String workItemId) =>
    '$projectId/$workItemId';

/// Why a runtime fact has no value in this projection.
///
/// The project command family reports declarations and durable membership. It
/// publishes no run, no completion and no acceptance: those are established by
/// the work owner that observed them, and the imported model has no field that
/// could carry one. A renderer must show that absence rather than treat silence
/// as a status, so the projection carries it as a value.
enum ProjectRuntimeObservation { notObserved }

/// Whether this client holds the source declaration for one durable work item.
enum ProjectDeclarationState {
  /// The held plan document declares the outcome and acceptance shown.
  held,

  /// The durable facts name the work item and no held declaration does, so its
  /// outcome and acceptance were not observed. Not the same as an empty
  /// outcome.
  notHeld,
}

/// Durable membership, as the last import receipt reported it.
enum ProjectDurableMembership {
  /// The receipt listed the declaration as newly added.
  added,

  /// The receipt listed the declaration as already held.
  unchanged,

  /// The durable slice holds the work item and the submitted document omitted
  /// it. Retained, never deleted.
  retained,

  /// No import receipt was read for this project, so durable membership is not
  /// observed. Not the same as absent.
  notObserved,
}

/// The explicit state of one declared input in this projection.
///
/// The durable states are the owner's own; [notApplied] is this client's. A held
/// declaration can name an input no apply has stored yet, and an input whose
/// state was never read is an absence rather than a satisfied one.
enum ProjectInputState {
  materialized('materialized'),
  missing('missing'),
  unavailable('unavailable'),
  notApplied('not-applied');

  const ProjectInputState(this.wireName);

  final String wireName;

  static ProjectInputState fromArtifactState(ProjectArtifactState state) {
    switch (state) {
      case ProjectArtifactState.materialized:
        return ProjectInputState.materialized;
      case ProjectArtifactState.missing:
        return ProjectInputState.missing;
      case ProjectArtifactState.unavailable:
        return ProjectInputState.unavailable;
    }
  }
}

/// Why one work item is not startable, or that nothing declared blocks it.
enum ProjectBlockingReason {
  /// Every declared input's result is materialized.
  none,

  /// A declared input's result does not exist at the declared location.
  missingArtifact,

  /// A declared input's location cannot be reached inside the declared
  /// authority.
  unavailableArtifact,

  /// A held declaration names an input no apply has stored, so its result state
  /// was never read.
  unappliedInput,

  /// No dependency facts were read for this project, so blocking is not
  /// observed. Not the same as "nothing blocks".
  notObserved,
}

/// One declared input of a work item, with its explicit artifact state.
final class ProjectDeclaredInputFacts {
  const ProjectDeclaredInputFacts({
    required this.producer,
    required this.artifact,
    required this.state,
    this.dependencySequence,
  });

  /// The work item that produces the result.
  final ProjectWorkRefFacts producer;

  /// The reference exactly as it was declared, on either shape.
  final ProjectArtifactDeclaration artifact;

  /// The explicit state of this reference in this projection.
  final ProjectInputState state;

  /// The durable declaration's sequence, or null when no apply has stored it.
  final int? dependencySequence;

  bool get isMaterialized => state == ProjectInputState.materialized;

  /// Renderer-facing label of the declared result: the location inside the
  /// declaring project's authorized root, or the cross-project work item.
  String get artifactLabel {
    final declared = artifact;
    if (declared is ProjectLocalArtifactDeclaration) return declared.path;
    return '${declared.producerProjectId}/${declared.producerWorkItemId}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectDeclaredInputFacts &&
          other.producer == producer &&
          other.artifact == artifact &&
          other.state == state &&
          other.dependencySequence == dependencySequence;

  @override
  int get hashCode =>
      Object.hash(producer, artifact, state, dependencySequence);
}

/// The declared inputs of one work item, or the explicit absence of that read.
final class ProjectDeclaredInputsFacts {
  factory ProjectDeclaredInputsFacts.observed(
    Iterable<ProjectDeclaredInputFacts> inputs,
  ) => ProjectDeclaredInputsFacts._(
    List<ProjectDeclaredInputFacts>.unmodifiable(inputs),
    true,
  );

  const ProjectDeclaredInputsFacts.notObserved()
    : inputs = const <ProjectDeclaredInputFacts>[],
      observed = false;

  const ProjectDeclaredInputsFacts._(this.inputs, this.observed);

  final List<ProjectDeclaredInputFacts> inputs;

  /// False when no dependency facts were read for this project at all.
  final bool observed;

  /// The inputs whose result this projection did not see materialized.
  List<ProjectDeclaredInputFacts> get unsatisfied =>
      List.unmodifiable(inputs.where((input) => !input.isMaterialized));

  /// Why this work item is not startable, as the read facts report it.
  ProjectBlockingReason get blockingReason {
    if (!observed) return ProjectBlockingReason.notObserved;
    for (final input in inputs) {
      switch (input.state) {
        case ProjectInputState.unavailable:
          return ProjectBlockingReason.unavailableArtifact;
        case ProjectInputState.missing:
          return ProjectBlockingReason.missingArtifact;
        case ProjectInputState.notApplied:
          return ProjectBlockingReason.unappliedInput;
        case ProjectInputState.materialized:
          break;
      }
    }
    return ProjectBlockingReason.none;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectDeclaredInputsFacts &&
          other.observed == observed &&
          samePresentationList(other.inputs, inputs);

  @override
  int get hashCode => Object.hash(observed, Object.hashAll(inputs));
}

/// The work items one producer actually blocks, or the explicit absence of that
/// answer.
final class ProjectDependentsFacts {
  factory ProjectDependentsFacts.observed(
    Iterable<ProjectWorkRefFacts> dependents,
  ) => ProjectDependentsFacts._(
    List<ProjectWorkRefFacts>.unmodifiable(dependents),
    true,
  );

  const ProjectDependentsFacts.notObserved()
    : dependents = const <ProjectWorkRefFacts>[],
      observed = false;

  const ProjectDependentsFacts._(this.dependents, this.observed);

  final List<ProjectWorkRefFacts> dependents;

  /// False when this producer's dependents were never read. An observed empty
  /// list means the producer blocks nobody.
  final bool observed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectDependentsFacts &&
          other.observed == observed &&
          samePresentationList(other.dependents, dependents);

  @override
  int get hashCode => Object.hash(observed, Object.hashAll(dependents));
}

/// One work item's facts, and nothing else.
///
/// This value carries no coordinate, no order and no selection: it is the one
/// fact set both the list view and the graph view read, so the two views cannot
/// disagree about the executor, the declared result, the blocking reason or the
/// real dependents.
final class ProjectWorkItemFacts {
  ProjectWorkItemFacts({
    required this.projectId,
    required this.workItemId,
    required this.declarationState,
    required this.durableMembership,
    required this.declaredOutcome,
    Iterable<String> declaredAcceptance = const <String>[],
    required this.sourceAnchor,
    required this.inputs,
    required this.dependents,
    this.run = ProjectRuntimeObservation.notObserved,
    this.completion = ProjectRuntimeObservation.notObserved,
    this.acceptance = ProjectRuntimeObservation.notObserved,
  }) : declaredAcceptance = List<String>.unmodifiable(declaredAcceptance);

  final String projectId;
  final String workItemId;

  /// Whether a held declaration covers this work item.
  final ProjectDeclarationState declarationState;

  /// What the last import receipt reported about durable membership.
  final ProjectDurableMembership durableMembership;

  /// The outcome the source document declares. Never a run result.
  final String declaredOutcome;

  /// The criteria the work will be judged by. Declarations, not evidence.
  final List<String> declaredAcceptance;

  /// The anchor the declaration was read from, or '' when none is held.
  final String sourceAnchor;

  final ProjectDeclaredInputsFacts inputs;
  final ProjectDependentsFacts dependents;

  /// The run of this work item. No project route publishes one, so the only
  /// value is [ProjectRuntimeObservation.notObserved].
  final ProjectRuntimeObservation run;

  /// The completion of this work item, for the same reason.
  final ProjectRuntimeObservation completion;

  /// Whether the declared criteria were accepted, for the same reason.
  final ProjectRuntimeObservation acceptance;

  /// Stable identity of this work item across the plan surface.
  String get key => projectWorkItemKey(projectId, workItemId);

  ProjectBlockingReason get blockingReason => inputs.blockingReason;

  /// True when a declared input was read and is not materialized.
  bool get isBlocked => switch (blockingReason) {
    ProjectBlockingReason.missingArtifact ||
    ProjectBlockingReason.unavailableArtifact ||
    ProjectBlockingReason.unappliedInput => true,
    ProjectBlockingReason.none || ProjectBlockingReason.notObserved => false,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectWorkItemFacts &&
          other.projectId == projectId &&
          other.workItemId == workItemId &&
          other.declarationState == declarationState &&
          other.durableMembership == durableMembership &&
          other.declaredOutcome == declaredOutcome &&
          samePresentationList(other.declaredAcceptance, declaredAcceptance) &&
          other.sourceAnchor == sourceAnchor &&
          other.inputs == inputs &&
          other.dependents == dependents &&
          other.run == run &&
          other.completion == completion &&
          other.acceptance == acceptance;

  @override
  int get hashCode => Object.hash(
    projectId,
    workItemId,
    declarationState,
    durableMembership,
    declaredOutcome,
    Object.hashAll(declaredAcceptance),
    sourceAnchor,
    inputs,
    dependents,
    run,
    completion,
    acceptance,
  );
}

/// What one explicit import changed, or would change.
///
/// The receipt is the owner's own change report: the revision and digest it
/// read, whether the submitted document was already the stored revision, and
/// the work items it added, left unchanged and retained.
final class ProjectImportReceiptProjection {
  ProjectImportReceiptProjection({
    required this.kind,
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
    this.applied = false,
  }) : added = List<String>.unmodifiable(added),
       unchanged = List<String>.unmodifiable(unchanged),
       retained = List<String>.unmodifiable(retained),
       mapping = List<ProjectSourceMappingFacts>.unmodifiable(mapping);

  factory ProjectImportReceiptProjection.previewed(
    ProjectImportChangeFacts change,
  ) => ProjectImportReceiptProjection._of(
    ProjectImportReceiptKind.previewed,
    change,
    applied: false,
  );

  factory ProjectImportReceiptProjection.applied(
    ProjectImportChangeFacts change, {
    required bool applied,
  }) => ProjectImportReceiptProjection._of(
    ProjectImportReceiptKind.applied,
    change,
    applied: applied,
  );

  factory ProjectImportReceiptProjection._of(
    ProjectImportReceiptKind kind,
    ProjectImportChangeFacts change, {
    required bool applied,
  }) => ProjectImportReceiptProjection(
    kind: kind,
    projectId: change.projectId,
    planId: change.planId,
    sourceId: change.sourceId,
    revision: change.revision,
    digest: change.digest,
    replayed: change.replayed,
    added: change.added,
    unchanged: change.unchanged,
    retained: change.retained,
    mapping: change.mapping,
    inputCount: change.inputCount,
    applied: applied,
  );

  final ProjectImportReceiptKind kind;
  final String projectId;
  final String planId;
  final String sourceId;
  final int revision;
  final String digest;
  final bool replayed;
  final List<String> added;
  final List<String> unchanged;
  final List<String> retained;
  final List<ProjectSourceMappingFacts> mapping;
  final int inputCount;

  /// True only for an applied receipt whose apply changed durable state.
  final bool applied;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectImportReceiptProjection &&
          other.kind == kind &&
          other.projectId == projectId &&
          other.planId == planId &&
          other.sourceId == sourceId &&
          other.revision == revision &&
          other.digest == digest &&
          other.replayed == replayed &&
          samePresentationList(other.added, added) &&
          samePresentationList(other.unchanged, unchanged) &&
          samePresentationList(other.retained, retained) &&
          samePresentationList(other.mapping, mapping) &&
          other.inputCount == inputCount &&
          other.applied == applied;

  @override
  int get hashCode => Object.hash(
    kind,
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
    applied,
  );
}

/// Whether one receipt reported what an import would do, or what it did.
enum ProjectImportReceiptKind { previewed, applied }

/// One project card: its declared identity, its plan and its receipts.
final class ProjectCardProjection {
  ProjectCardProjection({
    required this.projectId,
    required this.displayName,
    required this.authorizedRoot,
    required this.authorityKind,
    required this.authorityReference,
    required this.workspaceId,
    required this.planId,
    required this.registrationSequence,
    Iterable<ProjectWorkItemFacts> workItems = const <ProjectWorkItemFacts>[],
    Iterable<ProjectImportReceiptProjection> importReceipts =
        const <ProjectImportReceiptProjection>[],
  }) : workItems = List<ProjectWorkItemFacts>.unmodifiable(workItems),
       importReceipts = List<ProjectImportReceiptProjection>.unmodifiable(
         importReceipts,
       );

  final String projectId;
  final String displayName;

  /// The root the registration declares, kept as the declaration it is.
  final String authorizedRoot;

  final String authorityKind;
  final String authorityReference;
  final String workspaceId;
  final String planId;
  final int registrationSequence;

  /// Every work item the held declarations and the durable facts name, in the
  /// canonical order: declaration order first, then the durable identities the
  /// declarations do not cover.
  final List<ProjectWorkItemFacts> workItems;

  /// The import receipts for this project, oldest first.
  final List<ProjectImportReceiptProjection> importReceipts;

  /// The renderer-facing label of [authorizedRoot].
  String get authorizedRootLabel => projectRootLabel(authorizedRoot);

  ProjectWorkItemFacts? workItem(String workItemId) {
    for (final item in workItems) {
      if (item.workItemId == workItemId) return item;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectCardProjection &&
          other.projectId == projectId &&
          other.displayName == displayName &&
          other.authorizedRoot == authorizedRoot &&
          other.authorityKind == authorityKind &&
          other.authorityReference == authorityReference &&
          other.workspaceId == workspaceId &&
          other.planId == planId &&
          other.registrationSequence == registrationSequence &&
          samePresentationList(other.workItems, workItems) &&
          samePresentationList(other.importReceipts, importReceipts);

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
    Object.hashAll(workItems),
    Object.hashAll(importReceipts),
  );
}

/// The durable project facts, projected once for every view.
///
/// This value carries no coordinate and no view order. List order and canvas
/// positions live in the separate local layout state, so a drag or a view
/// switch cannot change what this projection says.
final class ProjectsProjection {
  ProjectsProjection({
    Iterable<ProjectCardProjection> projects = const <ProjectCardProjection>[],
    required this.phase,
    this.notice,
    this.failureCode = '',
  }) : projects = List<ProjectCardProjection>.unmodifiable(projects);

  final List<ProjectCardProjection> projects;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  /// The stable refusal code of the last failed read, when one was recorded.
  final String failureCode;

  ProjectCardProjection? project(String projectId) {
    for (final card in projects) {
      if (card.projectId == projectId) return card;
    }
    return null;
  }

  /// The first project the surface can present, when one is registered.
  ProjectCardProjection? get firstProject =>
      projects.isEmpty ? null : projects.first;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectsProjection &&
          samePresentationList(other.projects, projects) &&
          other.phase == phase &&
          other.notice == notice &&
          other.failureCode == failureCode;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(projects), phase, notice, failureCode);
}
