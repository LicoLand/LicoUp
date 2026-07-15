part of 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';

class MobileRelayPairedDevice {
  const MobileRelayPairedDevice({
    required this.id,
    required this.label,
    required this.pairingId,
    required this.mobileToken,
    required this.credentialPresent,
    required this.gatewayUrl,
    this.authorizedProviders = const [],
  });

  final String id;
  final String label;
  final String pairingId;
  final String mobileToken;
  final bool credentialPresent;
  final String gatewayUrl;
  final List<MobileRelayAuthorizedProvider> authorizedProviders;

  bool get isUsable =>
      pairingId.trim().isNotEmpty &&
      (mobileToken.trim().isNotEmpty || credentialPresent);

  factory MobileRelayPairedDevice.fromJson(Map<String, dynamic> json) {
    final pairingId = (json['pairingId'] ?? '').toString();
    final pcClientId = (json['pcClientId'] ?? json['id'] ?? '').toString();
    final label = (json['pcClientName'] ?? json['label'] ?? json['name'] ?? '')
        .toString();
    return MobileRelayPairedDevice(
      id: pcClientId.trim().isNotEmpty ? pcClientId : pairingId,
      label: label.trim().isNotEmpty ? label : 'Mac',
      pairingId: pairingId,
      mobileToken: (json['mobileToken'] ?? '').toString(),
      credentialPresent:
          json['credentialPresent'] == true ||
          json['mobileTokenPresent'] == true ||
          (json['mobileToken'] ?? '').toString().trim().isNotEmpty,
      gatewayUrl: _normalizeGatewayUrl((json['gatewayUrl'] ?? '').toString()),
      authorizedProviders: _authorizedProvidersFromJson(json),
    );
  }
}
