import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_gateway.dart';

class MobileRelayPairedDevice {
  const MobileRelayPairedDevice({
    required this.id,
    required this.label,
    required this.pairingId,
    required this.mobileToken,
    required this.credentialPresent,
    required this.gatewayUrl,
  });

  final String id;
  final String label;
  final String pairingId;
  final String mobileToken;
  final bool credentialPresent;
  final String gatewayUrl;

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
      gatewayUrl: normalizeMobileRelayGatewayUrl(
        (json['gatewayUrl'] ?? '').toString(),
      ),
    );
  }
}

List<MobileRelayPairedDevice> dedupeMobileRelayPairedDevices(
  List<MobileRelayPairedDevice> devices,
) {
  final seen = <String>{};
  final dedupedReversed = <MobileRelayPairedDevice>[];
  for (final device in devices.reversed) {
    final keys = _pairedDeviceDedupeKeys(device);
    if (keys.any(seen.contains)) {
      continue;
    }
    seen.addAll(keys);
    dedupedReversed.add(device);
  }
  return dedupedReversed.reversed.toList(growable: false);
}

List<String> _pairedDeviceDedupeKeys(MobileRelayPairedDevice device) {
  final id = device.id.trim();
  final pairingId = device.pairingId.trim();
  final label = device.label.trim().toLowerCase();
  final gateway = normalizeMobileRelayGatewayUrl(
    device.gatewayUrl,
  ).toLowerCase();
  return [
    if (id.isNotEmpty) 'id:$id',
    if (pairingId.isNotEmpty) 'pairing:$pairingId',
    if (label.isNotEmpty && gateway.isNotEmpty) 'label:$label@$gateway',
  ];
}
