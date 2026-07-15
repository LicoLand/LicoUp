part of 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';

class MobileRelayTrustPresentation {
  const MobileRelayTrustPresentation({
    required this.schemaVersion,
    required this.protocolVersion,
    required this.localFingerprint,
    required this.peerFingerprint,
    required this.safetyNumberGroups,
    required this.qrPayload,
    required this.trustState,
    required this.verificationMethod,
    required this.verified,
  });

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

  bool get blocksProtectedSend =>
      !verified || trustState == 'key_changed' || trustState == 'revoked';

  factory MobileRelayTrustPresentation.fromJson(Map<String, dynamic> json) {
    final groups = json['safetyNumberGroups'] is List
        ? (json['safetyNumberGroups'] as List)
              .map((value) => value.toString().trim())
              .where(
                (value) =>
                    value.length == 5 && RegExp(r'^\d{5}$').hasMatch(value),
              )
              .toList(growable: false)
        : const <String>[];
    return MobileRelayTrustPresentation(
      schemaVersion: (json['schemaVersion'] ?? '').toString(),
      protocolVersion: (json['protocolVersion'] ?? '').toString(),
      localFingerprint: (json['localFingerprint'] ?? '').toString(),
      peerFingerprint: (json['peerFingerprint'] ?? '').toString(),
      safetyNumberGroups: groups,
      qrPayload: (json['qrPayload'] ?? '').toString(),
      trustState: (json['trustState'] ?? 'unverified').toString(),
      verificationMethod: (json['verificationMethod'] ?? 'unverified')
          .toString(),
      verified: json['verified'] == true,
    );
  }
}
