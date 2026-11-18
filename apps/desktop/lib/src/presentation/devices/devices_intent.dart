import 'package:presentation_contract/presentation_contract.dart';

sealed class DevicesIntent {
  const DevicesIntent({this.trace});

  final TraceContext? trace;
}

final class RefreshDevices extends DevicesIntent {
  const RefreshDevices({super.trace});
}

final class EnrollDevice extends DevicesIntent {
  const EnrollDevice({
    required this.station,
    required this.invitation,
    this.caPem = '',
    super.trace,
  });

  final String station;
  final String invitation;
  final String caPem;
}

final class OfferDevicePairing extends DevicesIntent {
  const OfferDevicePairing({this.label = '', super.trace});

  final String label;
}

final class CopyDevicePairingCode extends DevicesIntent {
  const CopyDevicePairingCode({super.trace});
}

final class DismissDevicePairingCode extends DevicesIntent {
  const DismissDevicePairingCode({super.trace});
}

final class ClaimDevicePairing extends DevicesIntent {
  const ClaimDevicePairing({required this.code, this.label = '', super.trace});

  final String code;
  final String label;
}

final class CancelDevicePairing extends DevicesIntent {
  const CancelDevicePairing(this.pairingId, {super.trace});

  final String pairingId;
}

final class UnpairDevice extends DevicesIntent {
  const UnpairDevice(this.peerId, {super.trace});

  final String peerId;
}

final class SendDeviceMessage extends DevicesIntent {
  const SendDeviceMessage({
    required this.peerId,
    required this.agent,
    required this.body,
    super.trace,
  });

  final String peerId;
  final String agent;
  final String body;
}

final class AcknowledgeLegacyPairingNotice extends DevicesIntent {
  const AcknowledgeLegacyPairingNotice({super.trace});
}
