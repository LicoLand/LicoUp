import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Pairing and status values consumed by the panel body and its pairing card.
/// Peer, transfer, and approval updates install without rebuilding them.
final class MobileRelayPairingInputs {
  const MobileRelayPairingInputs({
    required this.pairingCode,
    required this.pairingInvite,
    required this.pairingId,
    required this.pairingExpiresLabel,
    required this.stationLabel,
    required this.paired,
    required this.busy,
    required this.polling,
    required this.mobileRuntime,
    required this.stationConfigured,
    required this.authorizationRequired,
    required this.phase,
    required this.notice,
  });

  factory MobileRelayPairingInputs.fromProjection(
    MobileRelayProjection projection,
  ) => MobileRelayPairingInputs(
    pairingCode: projection.pairingCode,
    pairingInvite: projection.pairingInvite,
    pairingId: projection.pairingId,
    pairingExpiresLabel: projection.pairingExpiresLabel,
    stationLabel: projection.stationLabel,
    paired: projection.paired,
    busy: projection.busy,
    polling: projection.polling,
    mobileRuntime: projection.mobileRuntime,
    stationConfigured: projection.stationConfigured,
    authorizationRequired: projection.authorizationRequired,
    phase: projection.phase,
    notice: projection.notice,
  );

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
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MobileRelayPairingInputs &&
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
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
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
    phase,
    notice,
  );
}

/// Device-trust evidence. The card renders only while trust is present.
final class MobileRelayTrustInputs {
  const MobileRelayTrustInputs({required this.trust});

  factory MobileRelayTrustInputs.fromProjection(
    MobileRelayProjection projection,
  ) => MobileRelayTrustInputs(trust: projection.trust);

  final RelayTrustProjection? trust;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MobileRelayTrustInputs && other.trust == trust;

  @override
  int get hashCode => trust.hashCode;
}

/// Remote approval requests and the shared mobile relay busy flag.
final class MobileRelayApprovalsInputs {
  MobileRelayApprovalsInputs({
    required Iterable<RelayApprovalProjection> approvals,
    required this.busy,
  }) : approvals = immutablePresentationList(approvals);

  factory MobileRelayApprovalsInputs.fromProjection(
    MobileRelayProjection projection,
  ) => MobileRelayApprovalsInputs(
    approvals: projection.approvals,
    busy: projection.busy,
  );

  final List<RelayApprovalProjection> approvals;
  final bool busy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MobileRelayApprovalsInputs &&
          samePresentationList(other.approvals, approvals) &&
          other.busy == busy;

  @override
  int get hashCode => Object.hash(Object.hashAll(approvals), busy);
}

/// File-sync queue, its current draft, and the shared busy flag.
final class MobileRelayTransfersInputs {
  MobileRelayTransfersInputs({
    required Iterable<RelayTransferProjection> transfers,
    required this.draft,
    required this.busy,
  }) : transfers = immutablePresentationList(transfers);

  factory MobileRelayTransfersInputs.fromProjection(
    MobileRelayProjection projection,
  ) => MobileRelayTransfersInputs(
    transfers: projection.transfers,
    draft: projection.draftTransfer,
    busy: projection.busy,
  );

  final List<RelayTransferProjection> transfers;
  final RelayTransferProjection? draft;
  final bool busy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MobileRelayTransfersInputs &&
          samePresentationList(other.transfers, transfers) &&
          other.draft == draft &&
          other.busy == busy;

  @override
  int get hashCode => Object.hash(Object.hashAll(transfers), draft, busy);
}

/// Negotiated secure-mesh capabilities, compared by the projection's own
/// identity semantics.
final class MobileRelayCapabilitiesInputs {
  const MobileRelayCapabilitiesInputs({required this.capabilities});

  factory MobileRelayCapabilitiesInputs.fromProjection(
    MobileRelayProjection projection,
  ) => MobileRelayCapabilitiesInputs(
    capabilities: projection.secureMeshCapabilities,
  );

  final SecureMeshCapabilityProjection? capabilities;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MobileRelayCapabilitiesInputs &&
          identical(other.capabilities, capabilities);

  @override
  int get hashCode => identityHashCode(capabilities);
}

/// Peer and ordering values consumed by the mobile agents home and list.
final class MobileRelayHomeInputs {
  MobileRelayHomeInputs({
    required Iterable<RelayPeerProjection> peers,
    required Iterable<String> homeEntryOrder,
    required Iterable<String> pinnedHomeEntryIds,
    required this.mobileRuntime,
  }) : peers = immutablePresentationList(peers),
       homeEntryOrder = immutablePresentationList(homeEntryOrder),
       pinnedHomeEntryIds = immutablePresentationList(pinnedHomeEntryIds);

  factory MobileRelayHomeInputs.fromProjection(
    MobileRelayProjection projection,
  ) => MobileRelayHomeInputs(
    peers: projection.peers,
    homeEntryOrder: projection.homeEntryOrder,
    pinnedHomeEntryIds: projection.pinnedHomeEntryIds,
    mobileRuntime: projection.mobileRuntime,
  );

  final List<RelayPeerProjection> peers;
  final List<String> homeEntryOrder;
  final List<String> pinnedHomeEntryIds;
  final bool mobileRuntime;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MobileRelayHomeInputs &&
          samePresentationList(other.peers, peers) &&
          samePresentationList(other.homeEntryOrder, homeEntryOrder) &&
          samePresentationList(other.pinnedHomeEntryIds, pinnedHomeEntryIds) &&
          other.mobileRuntime == mobileRuntime;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(peers),
    Object.hashAll(homeEntryOrder),
    Object.hashAll(pinnedHomeEntryIds),
    mobileRuntime,
  );
}
