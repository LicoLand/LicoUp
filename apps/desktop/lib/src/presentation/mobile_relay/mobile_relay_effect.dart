import 'package:presentation_contract/presentation_contract.dart';

sealed class MobileRelayEffect {
  const MobileRelayEffect({this.trace});

  final TraceContext? trace;
}

final class RelayPairingReady extends MobileRelayEffect {
  const RelayPairingReady(this.pairingCode, {super.trace});

  final String pairingCode;
}

final class RelayPairingCodeCopied extends MobileRelayEffect {
  const RelayPairingCodeCopied({super.trace});
}

final class RelayPairingClaimed extends MobileRelayEffect {
  const RelayPairingClaimed({super.trace});
}

final class RelayActionRejected extends MobileRelayEffect {
  const RelayActionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}
