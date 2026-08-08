/// Display model for the explicit, one-time device-pairing surface.
///
/// The encoded invite remains scoped to the QR workspace and must never be
/// copied into diagnostics, generic action results, or error messages.
final class MobilePairingPresentation {
  const MobilePairingPresentation({
    required this.pairingCode,
    required this.inviteText,
  });

  final String pairingCode;
  final String inviteText;

  bool get isEmpty => pairingCode.isEmpty && inviteText.isEmpty;
}
