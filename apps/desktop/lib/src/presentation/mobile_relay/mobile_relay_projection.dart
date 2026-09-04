import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

final class RelayPeerProjection {
  const RelayPeerProjection({
    required this.id,
    required this.displayName,
    required this.connected,
    required this.selected,
    this.pairingId = '',
    this.stationLabel = '',
    this.pinned = false,
  });

  final String id;
  final String displayName;
  final bool connected;
  final bool selected;
  final String pairingId;
  final String stationLabel;
  final bool pinned;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelayPeerProjection &&
          other.id == id &&
          other.displayName == displayName &&
          other.connected == connected &&
          other.selected == selected &&
          other.pairingId == pairingId &&
          other.stationLabel == stationLabel &&
          other.pinned == pinned;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    connected,
    selected,
    pairingId,
    stationLabel,
    pinned,
  );
}

enum RelayApprovalState { pending, allowed, denied, expired, failed }

final class RelayApprovalProjection {
  const RelayApprovalProjection({
    required this.id,
    required this.capabilityLabel,
    required this.requesterLabel,
    required this.resolvable,
    this.summary = '',
    this.expiresLabel = '',
    this.requestedToolLabels = const [],
    this.state = RelayApprovalState.pending,
  });

  final String id;
  final String capabilityLabel;
  final String requesterLabel;
  final bool resolvable;
  final String summary;
  final String expiresLabel;
  final List<String> requestedToolLabels;
  final RelayApprovalState state;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelayApprovalProjection &&
          other.id == id &&
          other.capabilityLabel == capabilityLabel &&
          other.requesterLabel == requesterLabel &&
          other.resolvable == resolvable &&
          other.summary == summary &&
          other.expiresLabel == expiresLabel &&
          samePresentationList(
            other.requestedToolLabels,
            requestedToolLabels,
          ) &&
          other.state == state;

  @override
  int get hashCode => Object.hash(
    id,
    capabilityLabel,
    requesterLabel,
    resolvable,
    summary,
    expiresLabel,
    Object.hashAll(requestedToolLabels),
    state,
  );
}

final class RelayTransferProjection {
  const RelayTransferProjection({
    required this.id,
    required this.fileLabel,
    required this.destinationLabel,
    required this.progress,
    required this.stateLabel,
    this.totalBytes = 0,
    this.chunkCount = 0,
    this.awaitsConfirmation = false,
    this.draft = false,
  });

  final String id;
  final String fileLabel;
  final String destinationLabel;
  final double progress;
  final String stateLabel;
  final int totalBytes;
  final int chunkCount;
  final bool awaitsConfirmation;
  final bool draft;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelayTransferProjection &&
          other.id == id &&
          other.fileLabel == fileLabel &&
          other.destinationLabel == destinationLabel &&
          other.progress == progress &&
          other.stateLabel == stateLabel &&
          other.totalBytes == totalBytes &&
          other.chunkCount == chunkCount &&
          other.awaitsConfirmation == awaitsConfirmation &&
          other.draft == draft;

  @override
  int get hashCode => Object.hash(
    id,
    fileLabel,
    destinationLabel,
    progress,
    stateLabel,
    totalBytes,
    chunkCount,
    awaitsConfirmation,
    draft,
  );
}

final class RelayTrustProjection {
  RelayTrustProjection({
    required this.schemaVersion,
    required this.protocolVersion,
    required this.localFingerprint,
    required this.peerFingerprint,
    required Iterable<String> safetyNumberGroups,
    required this.qrPayload,
    required this.trustState,
    required this.verificationMethod,
    required this.verified,
  }) : safetyNumberGroups = immutablePresentationList(safetyNumberGroups);

  final String schemaVersion;
  final String protocolVersion;
  final String localFingerprint;
  final String peerFingerprint;
  final List<String> safetyNumberGroups;
  final String qrPayload;
  final String trustState;
  final String verificationMethod;
  final bool verified;

  String get safetyNumber => safetyNumberGroups.join(' ');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelayTrustProjection &&
          other.schemaVersion == schemaVersion &&
          other.protocolVersion == protocolVersion &&
          other.localFingerprint == localFingerprint &&
          other.peerFingerprint == peerFingerprint &&
          samePresentationList(other.safetyNumberGroups, safetyNumberGroups) &&
          other.qrPayload == qrPayload &&
          other.trustState == trustState &&
          other.verificationMethod == verificationMethod &&
          other.verified == verified;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    protocolVersion,
    localFingerprint,
    peerFingerprint,
    Object.hashAll(safetyNumberGroups),
    qrPayload,
    trustState,
    verificationMethod,
    verified,
  );
}

final class MobileRelayProjection {
  MobileRelayProjection({
    required Iterable<RelayPeerProjection> peers,
    required Iterable<RelayApprovalProjection> approvals,
    required Iterable<RelayTransferProjection> transfers,
    required this.pairingCode,
    required this.stationLabel,
    required this.phase,
    this.pairingInvite = '',
    this.pairingId = '',
    this.pairingExpiresLabel = '',
    this.paired = false,
    this.busy = false,
    this.polling = false,
    this.mobileRuntime = false,
    this.stationConfigured = false,
    this.authorizationRequired = false,
    this.draftTransferId = '',
    this.trust,
    this.secureMeshCapabilities,
    Iterable<String> homeEntryOrder = const [],
    Iterable<String> pinnedHomeEntryIds = const [],
    this.notice,
  }) : peers = immutablePresentationList(peers),
       approvals = immutablePresentationList(approvals),
       transfers = immutablePresentationList(transfers),
       homeEntryOrder = immutablePresentationList(homeEntryOrder),
       pinnedHomeEntryIds = immutablePresentationList(pinnedHomeEntryIds);

  final List<RelayPeerProjection> peers;
  final List<RelayApprovalProjection> approvals;
  final List<RelayTransferProjection> transfers;
  final String pairingCode;
  final String pairingInvite;
  final String pairingId;
  final String pairingExpiresLabel;
  final String stationLabel;
  final bool paired;
  final bool busy;
  final bool polling;
  final bool mobileRuntime;
  final bool stationConfigured;
  final bool authorizationRequired;
  final String draftTransferId;
  final RelayTrustProjection? trust;
  final SecureMeshCapabilityProjection? secureMeshCapabilities;
  final List<String> homeEntryOrder;
  final List<String> pinnedHomeEntryIds;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  RelayTransferProjection? get draftTransfer {
    for (final transfer in transfers) {
      if (transfer.id == draftTransferId && transfer.draft) return transfer;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MobileRelayProjection &&
          samePresentationList(other.peers, peers) &&
          samePresentationList(other.approvals, approvals) &&
          samePresentationList(other.transfers, transfers) &&
          other.pairingCode == pairingCode &&
          other.pairingInvite == pairingInvite &&
          other.pairingId == pairingId &&
          other.pairingExpiresLabel == pairingExpiresLabel &&
          other.stationLabel == stationLabel &&
          other.paired == paired &&
          other.busy == busy &&
          other.polling == polling &&
          other.mobileRuntime == mobileRuntime &&
          other.stationConfigured == stationConfigured &&
          other.authorizationRequired == authorizationRequired &&
          other.draftTransferId == draftTransferId &&
          other.trust == trust &&
          identical(other.secureMeshCapabilities, secureMeshCapabilities) &&
          samePresentationList(other.homeEntryOrder, homeEntryOrder) &&
          samePresentationList(other.pinnedHomeEntryIds, pinnedHomeEntryIds) &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hashAll([
    Object.hashAll(peers),
    Object.hashAll(approvals),
    Object.hashAll(transfers),
    pairingCode,
    pairingInvite,
    pairingId,
    pairingExpiresLabel,
    stationLabel,
    paired,
    busy,
    polling,
    mobileRuntime,
    stationConfigured,
    authorizationRequired,
    draftTransferId,
    trust,
    identityHashCode(secureMeshCapabilities),
    Object.hashAll(homeEntryOrder),
    Object.hashAll(pinnedHomeEntryIds),
    phase,
    notice,
  ]);
}
