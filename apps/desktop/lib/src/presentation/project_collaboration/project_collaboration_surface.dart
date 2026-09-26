/// Pure values and ports of the project collaboration surface.
///
/// Nothing here owns a lifecycle: this file describes what the feature page may
/// ask for and what the native owner answers with. The admitted source, the
/// prepared graph controller and the validated action port live in the
/// composition layer, which implements [ProjectCollaborationSurface] and hands
/// it to the page.
library;

import 'package:presentation_contract/presentation_contract.dart';

/// The action references a project collaboration document may publish.
abstract final class ProjectCollaborationActions {
  /// Read-only observation of one unit.
  static const String observe = 'licoup.action/unit-observe';

  /// Managed observation with takeover of the original writer's gap.
  static const String manage = 'licoup.action/unit-manage';

  /// Explicit takeover request, confirmed by the user before dispatch.
  static const String takeover = 'licoup.action/unit-takeover';

  /// Pause request; the native owner answers with its own receipt.
  static const String pause = 'licoup.action/unit-pause';

  /// Cancel request; the native owner answers with its own receipt.
  static const String cancel = 'licoup.action/unit-cancel';

  /// Preview one insertion without changing anything.
  static const String insertPreview = 'licoup.action/graph-insert-preview';

  /// Commit a previewed insertion at exactly the previewed revision.
  static const String insertCommit = 'licoup.action/graph-insert-commit';
}

/// One response of the native owner to an action the interface requested.
final class ProjectCollaborationReceipt {
  const ProjectCollaborationReceipt({
    required this.actionRef,
    required this.accepted,
    required this.code,
    required this.revision,
    this.nodeId,
    this.previewRef,
    this.affectedNodeIds = const <String>[],
    this.detail,
  });

  final String actionRef;
  final bool accepted;

  /// Stable outcome code: `accepted`, or a refusal such as `stale_revision`,
  /// `conflicting_writer`, `authority_missing`, `unknown_node`, or
  /// `project_collaboration_unavailable`.
  final String code;

  /// Plan/run revision the owner answered for.
  final int revision;

  final String? nodeId;
  final String? previewRef;
  final List<String> affectedNodeIds;
  final String? detail;

  @override
  String toString() =>
      'ProjectCollaborationReceipt($actionRef, $code, rev $revision)';
}

/// One inserted-unit preview the owner issued.
final class ProjectCollaborationInsertPreview {
  const ProjectCollaborationInsertPreview({
    required this.previewRef,
    required this.revision,
    required this.unitRef,
    required this.laneId,
    required this.role,
    required this.affectedNodeIds,
  });

  /// Opaque reference of the previewed insertion. A commit must cite it.
  final String previewRef;

  /// Revision the preview was computed against.
  final int revision;

  final String unitRef;
  final String laneId;
  final String role;

  /// Real nodes the insertion would move or re-gate.
  final List<String> affectedNodeIds;

  @override
  String toString() =>
      'ProjectCollaborationInsertPreview($previewRef, rev $revision)';
}

/// One request the host port validates before any owner sees it.
final class ProjectCollaborationActionRequest {
  const ProjectCollaborationActionRequest({
    required this.actionRef,
    required this.origin,
    required this.revision,
    this.nodeId,
    this.values = const <String, String>{},
  });

  final String actionRef;
  final ActionOrigin origin;
  final int revision;
  final String? nodeId;
  final Map<String, String> values;

  @override
  String toString() =>
      'ProjectCollaborationActionRequest($actionRef, rev $revision)';
}

/// The native owner of the graph actions.
///
/// The native producer implements this; until it is installed the composition
/// injects nothing and every action is refused with
/// `project_collaboration_unavailable` instead of being answered by a stand-in.
abstract interface class ProjectCollaborationActionOwner {
  Future<ProjectCollaborationReceipt> perform(
    ProjectCollaborationActionRequest request,
  );
}

/// What the project collaboration page may ask the host for.
///
/// Implemented by the composition, which owns the admitted source, the prepared
/// controller and the validated port. The page never reaches a runtime, a store
/// or a source through this surface.
abstract interface class ProjectCollaborationSurface {
  /// The installed prepared graph, or null while loading or withdrawn.
  GraphPreparedValue? get current;

  /// Whether an admitted graph and an installed action owner are available.
  /// This is UI availability, not authorization; requests still pass through
  /// the existing origin, revision and native-owner checks.
  bool get canRequestActions;

  /// Every installed prepared graph and every withdrawal, in order.
  Stream<GraphPreparedValue?> get displayed;

  /// A host-local reason nothing can be shown, or null.
  String? get unavailableReason;

  /// The most recent native receipt, or null.
  ProjectCollaborationReceipt? get lastReceipt;

  /// Every native receipt, in order.
  Stream<ProjectCollaborationReceipt> get receipts;

  /// The insertion preview awaiting a commit, or null.
  ProjectCollaborationInsertPreview? get insertPreview;

  /// Every insertion preview change, in order.
  Stream<ProjectCollaborationInsertPreview?> get previews;

  /// Previews one insertion without changing anything.
  Future<ProjectCollaborationInsertPreview?> previewInsert({
    required String unitRef,
    required String laneId,
    required String role,
  });

  /// Commits exactly the previewed insertion.
  Future<ProjectCollaborationReceipt> commitInsert();

  /// Drops the preview; nothing was committed and nothing is undone.
  void cancelInsert();

  /// Dispatches one validated request and returns the native receipt.
  Future<ProjectCollaborationReceipt> request({
    required String actionRef,
    int? revision,
    String? nodeId,
    Map<String, String> values,
  });
}
