import 'package:presentation_contract/presentation_contract.dart';

sealed class MobileRelayIntent {
  const MobileRelayIntent({this.trace});

  final TraceContext? trace;
}

final class RefreshMobileRelay extends MobileRelayIntent {
  const RefreshMobileRelay({super.trace});
}

final class RefreshRelayApprovals extends MobileRelayIntent {
  const RefreshRelayApprovals({super.trace});
}

final class ConfigureRelayStation extends MobileRelayIntent {
  const ConfigureRelayStation(this.address, {super.trace});

  final String address;
}

final class CreateRelayPairing extends MobileRelayIntent {
  const CreateRelayPairing({super.trace});
}

final class CopyRelayPairingCode extends MobileRelayIntent {
  const CopyRelayPairingCode(this.pairingCode, {super.trace});

  final String pairingCode;
}

final class ClaimRelayPairing extends MobileRelayIntent {
  const ClaimRelayPairing(this.invite, {super.trace});

  final String invite;
}

final class SelectRelayPeer extends MobileRelayIntent {
  const SelectRelayPeer(this.peerId, {super.trace});

  final String peerId;
}

final class ToggleRelayHomeEntryPinned extends MobileRelayIntent {
  const ToggleRelayHomeEntryPinned(this.entryId, {super.trace});

  final String entryId;
}

final class ReorderRelayHomePinnedEntries extends MobileRelayIntent {
  ReorderRelayHomePinnedEntries({
    required Iterable<String> pinnedEntryIds,
    required this.oldIndex,
    required this.newIndex,
    super.trace,
  }) : pinnedEntryIds = List<String>.unmodifiable(pinnedEntryIds);

  final List<String> pinnedEntryIds;
  final int oldIndex;
  final int newIndex;
}

final class ResolveRelayApproval extends MobileRelayIntent {
  const ResolveRelayApproval(this.approvalId, this.approved, {super.trace});

  final String approvalId;
  final bool approved;
}

final class PrepareRelayTransfer extends MobileRelayIntent {
  const PrepareRelayTransfer({this.peerId = '', super.trace});

  final String peerId;
}

final class SetRelayTransferSource extends MobileRelayIntent {
  const SetRelayTransferSource({
    required this.fileName,
    required this.totalSize,
    required this.mimeType,
    super.trace,
  });

  final String fileName;
  final int totalSize;
  final String mimeType;
}

final class SetRelayTransferDestination extends MobileRelayIntent {
  const SetRelayTransferDestination(this.destinationRoot, {super.trace});

  final String destinationRoot;
}

final class ConfirmRelayTransfer extends MobileRelayIntent {
  const ConfirmRelayTransfer(this.transferId, this.approved, {super.trace});

  final String transferId;
  final bool approved;
}
