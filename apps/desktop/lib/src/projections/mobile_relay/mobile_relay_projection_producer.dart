import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_station.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Projects only display-safe Mobile Relay state from its two smallest owners.
final class MobileRelayProjectionProducer
    implements ProjectionSource<MobileRelayProjection> {
  MobileRelayProjectionProducer({
    required MobileRelayController relay,
    required SecureMeshController secureMesh,
    required MobileHomeLayoutController homeLayout,
    required bool Function() readMobileRuntime,
  }) : _relay = relay,
       _secureMesh = secureMesh,
       _homeLayout = homeLayout,
       _readMobileRuntime = readMobileRuntime,
       _current = _snapshot(
         relay,
         secureMesh,
         homeLayout,
         readMobileRuntime(),
       ) {
    _subscriptions = [
      _relay.changes.listen(_handleChange),
      _secureMesh.changes.listen(_handleChange),
      _homeLayout.changes.listen(_handleChange),
    ];
  }

  final MobileRelayController _relay;
  final SecureMeshController _secureMesh;
  final MobileHomeLayoutController _homeLayout;
  final bool Function() _readMobileRuntime;
  final StreamController<ProjectionUpdate<MobileRelayProjection>> _changes =
      StreamController<ProjectionUpdate<MobileRelayProjection>>.broadcast(
        sync: true,
      );
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  MobileRelayProjection _current;
  bool _disposed = false;

  @override
  MobileRelayProjection get current => _current;

  @override
  Stream<ProjectionUpdate<MobileRelayProjection>> get changes =>
      _changes.stream;

  void refreshEnvironment() => _publishIfChanged();

  void _handleChange(ApplicationChange change) {
    _publishIfChanged(change.cause);
  }

  void _publishIfChanged([ApplicationCause? cause]) {
    if (_disposed) return;
    final next = _snapshot(
      _relay,
      _secureMesh,
      _homeLayout,
      _readMobileRuntime(),
    );
    if (next == _current) return;
    _current = next;
    _changes.add(
      ProjectionUpdate(
        next,
        trace: cause?.traceId == null
            ? null
            : TraceContext(traceId: cause!.traceId),
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await closeBroadcastController(_changes);
  }

  static MobileRelayProjection _snapshot(
    MobileRelayController relay,
    SecureMeshController secureMesh,
    MobileHomeLayoutController homeLayout,
    bool mobileRuntime,
  ) {
    final config = relay.config;
    final pairing = relay.pairingPresentation;
    final draft = secureMesh.fileDraft;
    final transfers = <RelayTransferProjection>[
      for (final transfer in secureMesh.fileTransfers)
        _transferProjection(transfer, draft: transfer.id == draft?.id),
      if (draft != null &&
          !secureMesh.fileTransfers.any((transfer) => transfer.id == draft.id))
        _transferProjection(draft, draft: true),
    ];
    final failureCode = _failureCode(secureMesh, draft);
    final station = canonicalMobileRelayStationOrigin(config.stationBaseUrl);
    return MobileRelayProjection(
      peers: [
        for (final device in config.deviceTabs)
          RelayPeerProjection(
            id: device.id,
            displayName: device.label,
            connected: device.isUsable,
            selected:
                device.id == config.pcClientId ||
                device.pairingId == config.pairingId,
            pairingId: device.pairingId,
            stationLabel: device.stationBaseUrl,
            pinned: homeLayout.layout.isPinned('device:${device.id}'),
          ),
      ],
      approvals: [
        for (final approval in secureMesh.approvalInbox)
          RelayApprovalProjection(
            id: approval.pendingOperationId,
            capabilityLabel: approval.riskLevel,
            requesterLabel: approval.requesterAgentId,
            resolvable:
                approval.isPending &&
                secureMesh.canResolveApproval(approval.pendingOperationId),
            summary: approval.displaySummary,
            expiresLabel: approval.expiresAt,
            requestedToolLabels: List<String>.unmodifiable(
              approval.requestedTools,
            ),
            state: _approvalState(approval),
          ),
      ],
      transfers: transfers,
      pairingCode: pairing?.pairingCode ?? '',
      pairingInvite: pairing?.inviteText ?? '',
      pairingId: config.pairingId,
      pairingExpiresLabel: config.lastPairingExpiresAt.trim().isNotEmpty
          ? config.lastPairingExpiresAt
          : (relay.actionResult?['expiresAt']?.toString() ?? ''),
      stationLabel: config.stationBaseUrl,
      paired: config.paired,
      busy: relay.busy || secureMesh.busy,
      polling: relay.polling,
      mobileRuntime: mobileRuntime,
      stationConfigured: station != null,
      authorizationRequired: relay.authorizationRequired,
      draftTransferId: draft?.id ?? '',
      trust: config.trustPresentation == null
          ? null
          : RelayTrustProjection(
              schemaVersion: config.trustPresentation!.schemaVersion,
              protocolVersion: config.trustPresentation!.protocolVersion,
              localFingerprint: config.trustPresentation!.localFingerprint,
              peerFingerprint: config.trustPresentation!.peerFingerprint,
              safetyNumberGroups: config.trustPresentation!.safetyNumberGroups,
              qrPayload: config.trustPresentation!.qrPayload,
              trustState: config.trustPresentation!.trustState,
              verificationMethod: config.trustPresentation!.verificationMethod,
              verified: config.trustPresentation!.verified,
            ),
      secureMeshCapabilities: secureMesh.capabilityProjection,
      homeEntryOrder: homeLayout.layout.order,
      pinnedHomeEntryIds: homeLayout.layout.pinnedEntryIds.toList()..sort(),
      phase: failureCode.isNotEmpty
          ? PresentationPhase.failed
          : relay.busy || secureMesh.busy
          ? PresentationPhase.applying
          : PresentationPhase.ready,
      notice: failureCode.isEmpty
          ? null
          : PresentationNotice(
              id: 'mobile-relay-failure',
              title: 'Mobile relay action failed',
              message: 'Review the action and try again.',
              severity: PresentationNoticeSeverity.error,
              reasonCode: failureCode,
            ),
    );
  }

  static RelayTransferProjection _transferProjection(
    SecureMeshFileSyncTransfer transfer, {
    required bool draft,
  }) => RelayTransferProjection(
    id: transfer.id,
    fileLabel: transfer.fileName,
    destinationLabel: transfer.destinationRoot,
    progress: switch (transfer.status) {
      SecureMeshFileSyncStatus.drafting => 0,
      SecureMeshFileSyncStatus.evaluating => 0.5,
      SecureMeshFileSyncStatus.awaitingConfirmation ||
      SecureMeshFileSyncStatus.confirmed ||
      SecureMeshFileSyncStatus.rejected ||
      SecureMeshFileSyncStatus.failed => 1,
    },
    stateLabel: transfer.status.name,
    totalBytes: transfer.totalSize,
    chunkCount: transfer.chunkCount,
    awaitsConfirmation: transfer.awaitsConfirmation,
    draft: draft,
  );

  static RelayApprovalState _approvalState(SecureMeshApprovalRequest request) {
    return switch (request.status) {
      SecureMeshApprovalStatus.pending => RelayApprovalState.pending,
      SecureMeshApprovalStatus.resolved =>
        request.decision == SecureMeshApprovalDecision.allow
            ? RelayApprovalState.allowed
            : RelayApprovalState.denied,
      SecureMeshApprovalStatus.expired => RelayApprovalState.expired,
      SecureMeshApprovalStatus.failed => RelayApprovalState.failed,
    };
  }

  static String _failureCode(
    SecureMeshController secureMesh,
    SecureMeshFileSyncTransfer? draft,
  ) {
    final statusCode = secureMesh.status?['errorCode']?.toString().trim() ?? '';
    if (statusCode.isNotEmpty) return statusCode;
    final actionCode =
        secureMesh.approvalLastAction?['errorCode']?.toString().trim() ?? '';
    if (actionCode.isNotEmpty) return actionCode;
    return draft?.errorCode.trim() ?? '';
  }
}
