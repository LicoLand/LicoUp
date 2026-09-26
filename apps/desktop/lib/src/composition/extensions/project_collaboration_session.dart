/// One running project collaboration surface.
///
/// The session is the composition-layer owner: the admitted document source,
/// the prepared graph controller, the validated action port and the insert
/// preview a commit must cite. It implements the pure
/// [ProjectCollaborationSurface] the page consumes, so no lifecycle type crosses
/// into the presentation layer.
library;

import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import '../../presentation/project_collaboration/project_collaboration_surface.dart';
import '../../projections/project_collaboration/project_collaboration_source.dart';
import 'project_collaboration_action_port.dart';

/// The session of the project collaboration graph.
final class ProjectCollaborationSession implements ProjectCollaborationSurface {
  ProjectCollaborationSession({
    required PresentationRuntime runtime,
    required this.source,
    ProjectCollaborationActionOwner? owner,
    Iterable<ResourceScope> admittedScopes = const <ResourceScope>[],
  }) : graph = GraphPreparationController(runtime: runtime, source: source),
       _pinnedOrigin = ActionOrigin(scope: source.fieldGroup.resource.scope) {
    // The page dispatches under this surface's own scope; a mounted
    // contribution dispatches under the host-pinned scope it was mounted with.
    // Both are admitted, and nothing else is.
    final scopes = <ResourceScope>{
      source.fieldGroup.resource.scope,
      ...admittedScopes,
    };
    actions = ProjectCollaborationActionPort(
      pinnedOrigin: _pinnedOrigin,
      admitsOrigin: (origin) =>
          scopes.contains(origin.scope) &&
          (origin.resource == null ||
              origin.resource == source.fieldGroup.resource),
      currentRevision: () => source.snapshot?.value.document.planRevision ?? 0,
      knowsNode: (nodeId) =>
          source.snapshot?.value.document.node(nodeId) != null,
      stableKey: () => source.fieldGroup.resource.stableKey,
      owner: owner,
    );
    _receiptSubscription = actions.receiptStream.listen(_onReceipt);
  }

  /// The admitted document source.
  final ProjectCollaborationDocumentSource source;

  /// The prepared graph the renderer displays.
  final GraphPreparationController graph;

  /// The validated host action port.
  late final ProjectCollaborationActionPort actions;

  final ActionOrigin _pinnedOrigin;
  final StreamController<ProjectCollaborationReceipt> _receipts =
      StreamController<ProjectCollaborationReceipt>.broadcast(sync: true);
  final StreamController<ProjectCollaborationInsertPreview?> _previews =
      StreamController<ProjectCollaborationInsertPreview?>.broadcast(
        sync: true,
      );
  late final StreamSubscription<ProjectCollaborationReceipt>
  _receiptSubscription;
  ProjectCollaborationReceipt? _lastReceipt;
  ProjectCollaborationInsertPreview? _preview;
  bool _started = false;
  bool _disposed = false;

  @override
  GraphPreparedValue? get current => graph.current;

  @override
  bool get canRequestActions =>
      !_disposed && current != null && actions.owner != null;

  @override
  Stream<GraphPreparedValue?> get displayed => graph.displayed;

  @override
  String? get unavailableReason => graph.localUnavailableReason;

  @override
  ProjectCollaborationReceipt? get lastReceipt => _lastReceipt;

  @override
  Stream<ProjectCollaborationReceipt> get receipts => _receipts.stream;

  @override
  ProjectCollaborationInsertPreview? get insertPreview => _preview;

  @override
  Stream<ProjectCollaborationInsertPreview?> get previews => _previews.stream;

  /// Real preparation measurements of this surface.
  GraphPreparationStats get stats => graph.stats;

  /// The origin every request of this surface is dispatched with.
  ActionOrigin get pinnedOrigin => _pinnedOrigin;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    graph.start();
  }

  void _onReceipt(ProjectCollaborationReceipt receipt) {
    _lastReceipt = receipt;
    if (!_receipts.isClosed) _receipts.add(receipt);
  }

  /// Publishes a receipt a page-level control received.
  void recordReceipt(ProjectCollaborationReceipt receipt) =>
      _onReceipt(receipt);

  @override
  Future<ProjectCollaborationInsertPreview?> previewInsert({
    required String unitRef,
    required String laneId,
    required String role,
  }) async {
    final receipt = await actions.request(
      actionRef: ProjectCollaborationActions.insertPreview,
      values: <String, String>{
        'unitRef': unitRef,
        'laneId': laneId,
        'role': role,
      },
    );
    if (!receipt.accepted || receipt.previewRef == null) return null;
    final preview = ProjectCollaborationInsertPreview(
      previewRef: receipt.previewRef!,
      revision: receipt.revision,
      unitRef: unitRef,
      laneId: laneId,
      role: role,
      affectedNodeIds: receipt.affectedNodeIds,
    );
    _preview = preview;
    if (!_previews.isClosed) _previews.add(preview);
    return preview;
  }

  @override
  Future<ProjectCollaborationReceipt> commitInsert() async {
    final preview = _preview;
    if (preview == null) {
      return ProjectCollaborationReceipt(
        actionRef: ProjectCollaborationActions.insertCommit,
        accepted: false,
        code: 'no_preview',
        revision: source.snapshot?.value.document.planRevision ?? 0,
      );
    }
    final receipt = await actions.request(
      actionRef: ProjectCollaborationActions.insertCommit,
      revision: preview.revision,
      values: <String, String>{'previewRef': preview.previewRef},
    );
    if (receipt.accepted) cancelInsert();
    return receipt;
  }

  @override
  void cancelInsert() {
    if (_preview == null) return;
    _preview = null;
    if (!_previews.isClosed) _previews.add(null);
  }

  @override
  Future<ProjectCollaborationReceipt> request({
    required String actionRef,
    int? revision,
    String? nodeId,
    Map<String, String> values = const <String, String>{},
  }) => actions.request(
    actionRef: actionRef,
    revision: revision,
    nodeId: nodeId,
    values: values,
  );

  /// Stops observing and releases the port. Prepared work already admitted
  /// keeps running and installs nowhere.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _started = false;
    await _receiptSubscription.cancel();
    graph.dispose();
    if (!_receipts.isClosed) unawaited(_receipts.close());
    if (!_previews.isClosed) unawaited(_previews.close());
  }
}
