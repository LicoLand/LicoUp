import 'dart:convert';

import 'package:licoup/src/application/features/devices/devices_controller.dart';
import 'package:licoup/src/contracts/devices/devices_models.dart';
import 'package:licoup/src/presentation/devices/devices_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/application_projection_source.dart';

/// Projects the [DevicesController] state into the display-safe
/// [DevicesProjection]; equal snapshots are suppressed.
ApplicationProjectionSource<DevicesProjection> devicesProjectionSource(
  DevicesController controller,
) => ApplicationProjectionSource<DevicesProjection>(
  changes: controller.changes,
  read: () => devicesProjectionOf(controller),
);

DevicesProjection devicesProjectionOf(DevicesController controller) {
  final status = controller.status;
  final offer = controller.offer;
  final results = [...controller.results]
    ..sort((left, right) => right.completedAt.compareTo(left.completedAt));
  return DevicesProjection(
    phase: !controller.loaded
        ? (controller.busy ? PresentationPhase.loading : PresentationPhase.idle)
        : controller.busy
        ? PresentationPhase.applying
        : PresentationPhase.ready,
    enrolled: status.enrolled,
    station: status.station,
    mailboxId: status.mailboxId,
    showLegacyPairingNotice: controller.showLegacyPairingNotice,
    peers: [
      for (final peer in status.peers)
        DevicePeerView(
          peerId: peer.peerId,
          label: peer.label,
          pairedAt: peer.pairedAt,
        ),
    ],
    pairings: [
      for (final pairing in status.pairings)
        DevicePairingView(
          pairingId: pairing.pairingId,
          role: switch (pairing.role) {
            DevicePairingRole.offerer => DevicePairingRoleView.offerer,
            DevicePairingRole.claimer => DevicePairingRoleView.claimer,
          },
          state: switch (pairing.state) {
            DevicePairingState.awaitingClaim =>
              DevicePairingStateView.awaitingClaim,
            DevicePairingState.awaitingReply =>
              DevicePairingStateView.awaitingReply,
            DevicePairingState.completed => DevicePairingStateView.completed,
            DevicePairingState.failed => DevicePairingStateView.failed,
          },
          createdAt: pairing.createdAt,
        ),
    ],
    results: [
      for (final result in results)
        DeviceMessageResultView(
          commandId: result.commandId,
          peerId: result.peerId,
          completed: result.status == DeviceMessageStatus.completed,
          outputText: _outputText(result.output),
          completedAt: result.completedAt,
        ),
    ],
    offerPairingId: offer?.pairingId ?? '',
    offerCode: offer?.code ?? '',
    outstandingMessageCount: controller.outstandingCommandIds.length,
    busy: controller.busy,
    errorCode: controller.errorCode,
  );
}

String _outputText(Map<String, Object?> output) {
  for (final key in const ['text', 'reply', 'message']) {
    final value = output[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return const JsonEncoder.withIndent('  ').convert(output);
}
