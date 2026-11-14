import 'package:presentation_contract/presentation_contract.dart';

sealed class DevicesEffect {
  const DevicesEffect({this.trace});

  final TraceContext? trace;
}

/// One completed Devices action, named by its stable reason code.
final class DevicesActionCompleted extends DevicesEffect {
  const DevicesActionCompleted(this.action, {super.trace});

  final DevicesAction action;
}

/// One refused or failed Devices action with the stable failure code.
final class DevicesActionRejected extends DevicesEffect {
  const DevicesActionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}

enum DevicesAction {
  enrolled,
  pairingCodeCopied,
  pairingClaimed,
  pairingCancelled,
  unpaired,
  messageSent,
}
