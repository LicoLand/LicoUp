part of 'package:flutter_client/src/application/controller/client_controller.dart';

class MobilePairingPresentation {
  const MobilePairingPresentation({
    required this.pairingCode,
    required this.inviteText,
  });

  final String pairingCode;
  final String inviteText;

  bool get isEmpty => pairingCode.isEmpty && inviteText.isEmpty;
}
