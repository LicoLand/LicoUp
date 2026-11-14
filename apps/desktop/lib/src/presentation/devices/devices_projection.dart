import 'package:licoup/src/presentation/presentation_semantics.dart';

enum DevicePairingRoleView { offerer, claimer }

enum DevicePairingStateView { awaitingClaim, awaitingReply, completed, failed }

final class DevicePeerView {
  const DevicePeerView({
    required this.peerId,
    required this.label,
    required this.pairedAt,
  });

  final String peerId;
  final String label;
  final String pairedAt;

  @override
  bool operator ==(Object other) =>
      other is DevicePeerView &&
      other.peerId == peerId &&
      other.label == label &&
      other.pairedAt == pairedAt;

  @override
  int get hashCode => Object.hash(peerId, label, pairedAt);
}

final class DevicePairingView {
  const DevicePairingView({
    required this.pairingId,
    required this.role,
    required this.state,
    required this.createdAt,
  });

  final String pairingId;
  final DevicePairingRoleView role;
  final DevicePairingStateView state;
  final String createdAt;

  bool get pending =>
      state == DevicePairingStateView.awaitingClaim ||
      state == DevicePairingStateView.awaitingReply;

  @override
  bool operator ==(Object other) =>
      other is DevicePairingView &&
      other.pairingId == pairingId &&
      other.role == role &&
      other.state == state &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(pairingId, role, state, createdAt);
}

final class DeviceMessageResultView {
  const DeviceMessageResultView({
    required this.commandId,
    required this.peerId,
    required this.completed,
    required this.outputText,
    required this.completedAt,
  });

  final String commandId;
  final String peerId;
  final bool completed;

  /// The result output as display text: the agent's reply text when the
  /// output carries one, otherwise the output object as indented JSON.
  final String outputText;
  final String completedAt;

  @override
  bool operator ==(Object other) =>
      other is DeviceMessageResultView &&
      other.commandId == commandId &&
      other.peerId == peerId &&
      other.completed == completed &&
      other.outputText == outputText &&
      other.completedAt == completedAt;

  @override
  int get hashCode =>
      Object.hash(commandId, peerId, completed, outputText, completedAt);
}

/// Display-safe state of the Devices surface.
final class DevicesProjection {
  DevicesProjection({
    required this.phase,
    required this.enrolled,
    required this.station,
    required this.mailboxId,
    required this.showLegacyPairingNotice,
    required Iterable<DevicePeerView> peers,
    required Iterable<DevicePairingView> pairings,
    required Iterable<DeviceMessageResultView> results,
    this.offerPairingId = '',
    this.offerCode = '',
    this.outstandingMessageCount = 0,
    this.busy = false,
    this.errorCode = '',
  }) : peers = immutablePresentationList(peers),
       pairings = immutablePresentationList(pairings),
       results = immutablePresentationList(results);

  final PresentationPhase phase;
  final bool enrolled;
  final String station;
  final String mailboxId;
  final bool showLegacyPairingNotice;
  final List<DevicePeerView> peers;
  final List<DevicePairingView> pairings;
  final List<DeviceMessageResultView> results;
  final String offerPairingId;

  /// The copyable pairing code this device offered, or empty.
  final String offerCode;

  /// Sent agent messages whose result has not arrived yet.
  final int outstandingMessageCount;
  final bool busy;
  final String errorCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicesProjection &&
          other.phase == phase &&
          other.enrolled == enrolled &&
          other.station == station &&
          other.mailboxId == mailboxId &&
          other.showLegacyPairingNotice == showLegacyPairingNotice &&
          samePresentationList(other.peers, peers) &&
          samePresentationList(other.pairings, pairings) &&
          samePresentationList(other.results, results) &&
          other.offerPairingId == offerPairingId &&
          other.offerCode == offerCode &&
          other.outstandingMessageCount == outstandingMessageCount &&
          other.busy == busy &&
          other.errorCode == errorCode;

  @override
  int get hashCode => Object.hash(
    phase,
    enrolled,
    station,
    mailboxId,
    showLegacyPairingNotice,
    Object.hashAll(peers),
    Object.hashAll(pairings),
    Object.hashAll(results),
    offerPairingId,
    offerCode,
    outstandingMessageCount,
    busy,
    errorCode,
  );
}
