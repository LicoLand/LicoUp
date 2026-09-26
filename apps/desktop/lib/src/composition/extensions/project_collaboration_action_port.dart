/// The validated host port of the project collaboration actions.
///
/// It validates origin, revision, node identity and idempotency before any
/// owner sees a request, and it records the owner's own answer. It never
/// mutates projected state and never invents a receipt: when no native owner is
/// installed every request is refused with
/// `project_collaboration_unavailable`.
library;

import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import '../../presentation/project_collaboration/project_collaboration_surface.dart';

/// Host port of the project collaboration actions.
final class ProjectCollaborationActionPort implements ExtensionUiActionPort {
  ProjectCollaborationActionPort({
    required ActionOrigin pinnedOrigin,
    required bool Function(ActionOrigin origin) admitsOrigin,
    required int Function() currentRevision,
    required bool Function(String nodeId) knowsNode,
    required String Function() stableKey,
    this.owner,
  }) : _pinnedOrigin = pinnedOrigin,
       _admitsOrigin = admitsOrigin,
       _currentRevision = currentRevision,
       _knowsNode = knowsNode,
       _stableKey = stableKey;

  /// The origin this surface dispatches its own requests under.
  final ActionOrigin _pinnedOrigin;

  final bool Function(ActionOrigin origin) _admitsOrigin;
  final int Function() _currentRevision;
  final bool Function(String nodeId) _knowsNode;
  final String Function() _stableKey;

  /// The native owner, or null when the runtime is not installed.
  final ProjectCollaborationActionOwner? owner;

  final Set<String> _inFlight = <String>{};
  final List<ProjectCollaborationReceipt> _receipts =
      <ProjectCollaborationReceipt>[];
  final StreamController<ProjectCollaborationReceipt> _receiptStream =
      StreamController<ProjectCollaborationReceipt>.broadcast(sync: true);

  /// Every receipt this port answered with, oldest first.
  List<ProjectCollaborationReceipt> get receipts =>
      List<ProjectCollaborationReceipt>.unmodifiable(_receipts);

  /// Every receipt as it is answered.
  Stream<ProjectCollaborationReceipt> get receiptStream =>
      _receiptStream.stream;

  @override
  Future<void> dispatch(ExtensionUiActionInvocation invocation) async {
    final revision = int.tryParse(invocation.values['revision'] ?? '');
    final nodeId = invocation.values['nodeId'];
    if (!_admitsOrigin(invocation.origin)) {
      _record(
        _refusal(invocation.actionRef, 'origin_mismatch', revision, nodeId),
      );
      return;
    }
    if (revision == null || revision != _currentRevision()) {
      // A stale request is refused instead of being applied to a newer plan.
      _record(
        _refusal(invocation.actionRef, 'stale_revision', revision, nodeId),
      );
      return;
    }
    if (nodeId != null && !_knowsNode(nodeId)) {
      _record(_refusal(invocation.actionRef, 'unknown_node', revision, nodeId));
      return;
    }
    final key = '${invocation.actionRef}|${nodeId ?? ''}|$revision';
    if (!_inFlight.add(key)) {
      _record(
        _refusal(invocation.actionRef, 'duplicate_action', revision, nodeId),
      );
      return;
    }
    try {
      final current = owner;
      if (current == null) {
        _record(
          _refusal(
            invocation.actionRef,
            'project_collaboration_unavailable',
            revision,
            nodeId,
          ),
        );
        return;
      }
      _record(
        await current.perform(
          ProjectCollaborationActionRequest(
            actionRef: invocation.actionRef,
            origin: invocation.origin,
            revision: revision,
            nodeId: nodeId,
            values: invocation.values,
          ),
        ),
      );
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Dispatches a host-level request without going through a contribution.
  ///
  /// The page's own controls use this; the same validation and the same receipt
  /// shape apply, so a page control and a mounted contribution can never
  /// disagree about what the native owner accepted.
  Future<ProjectCollaborationReceipt> request({
    required String actionRef,
    int? revision,
    String? nodeId,
    Map<String, String> values = const <String, String>{},
  }) async {
    final resolved = <String, String>{
      ...values,
      'revision': '${revision ?? _currentRevision()}',
    };
    if (nodeId != null) resolved['nodeId'] = nodeId;
    await dispatch(
      ExtensionUiActionInvocation(
        actionRef: actionRef,
        contributionId: _stableKey(),
        kind: ExtensionContributionKind.resourceView,
        origin: _pinnedOrigin,
        values: resolved,
      ),
    );
    return _receipts.last;
  }

  /// Releases the receipt stream. The port keeps no other resource.
  Future<void> close() => _receiptStream.close();

  ProjectCollaborationReceipt _refusal(
    String actionRef,
    String code,
    int? revision,
    String? nodeId,
  ) => ProjectCollaborationReceipt(
    actionRef: actionRef,
    accepted: false,
    code: code,
    revision: revision ?? _currentRevision(),
    nodeId: nodeId,
  );

  void _record(ProjectCollaborationReceipt receipt) {
    _receipts.add(receipt);
    if (!_receiptStream.isClosed) _receiptStream.add(receipt);
  }
}
