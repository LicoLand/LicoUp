import 'package:licoup/src/contracts/mobile_relay/mobile_relay_paired_device.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_station.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_trust_presentation.dart';

class MobileRelayConfig {
  const MobileRelayConfig({
    required this.schemaVersion,
    required this.stationBaseUrl,
    required this.pcClientId,
    required this.pcClientName,
    required this.pairingId,
    required this.pcToken,
    required this.mobileToken,
    required this.lastPairingCode,
    required this.lastPairingExpiresAt,
    required this.paired,
    required this.relayEnabled,
    required this.pollIntervalSeconds,
    required this.pcTokenPresent,
    required this.mobileTokenPresent,
    this.pairedDevices = const [],
    this.trustPresentation,
  });

  static const currentSchemaVersion = 2;

  final int schemaVersion;
  final String stationBaseUrl;
  final String pcClientId;
  final String pcClientName;
  final String pairingId;
  final String pcToken;
  final String mobileToken;
  final String lastPairingCode;
  final String lastPairingExpiresAt;
  final bool paired;
  final bool relayEnabled;
  final int pollIntervalSeconds;
  final bool pcTokenPresent;
  final bool mobileTokenPresent;
  final List<MobileRelayPairedDevice> pairedDevices;
  final MobileRelayTrustPresentation? trustPresentation;

  bool get hasPairing =>
      pairingId.trim().isNotEmpty &&
      (pcToken.trim().isNotEmpty ||
          mobileToken.trim().isNotEmpty ||
          pcTokenPresent ||
          mobileTokenPresent ||
          _selectedPairedDeviceCredentialPresent);

  bool get _selectedPairedDeviceCredentialPresent {
    final selectedPairingId = pairingId.trim();
    if (selectedPairingId.isEmpty) {
      return false;
    }
    return pairedDevices.any(
      (device) =>
          device.pairingId.trim() == selectedPairingId && device.isUsable,
    );
  }

  bool get hasPairedDeviceEcho =>
      pairingId.trim().isNotEmpty &&
      (paired ||
          pcClientId.trim().isNotEmpty ||
          pcClientName.trim().isNotEmpty ||
          hasPairing);

  factory MobileRelayConfig.defaults({String? pcClientName}) {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final normalizedPcClientName = (pcClientName ?? '').trim();
    return MobileRelayConfig(
      schemaVersion: currentSchemaVersion,
      stationBaseUrl: '',
      pcClientId: 'pc_$now',
      pcClientName: normalizedPcClientName.isEmpty
          ? 'LicoUp'
          : normalizedPcClientName,
      pairingId: '',
      pcToken: '',
      mobileToken: '',
      lastPairingCode: '',
      lastPairingExpiresAt: '',
      paired: false,
      relayEnabled: false,
      pollIntervalSeconds: 5,
      pcTokenPresent: false,
      mobileTokenPresent: false,
      pairedDevices: const [],
    );
  }

  factory MobileRelayConfig.fromJson(
    Map<String, dynamic> json, {
    String? pcClientName,
  }) {
    final defaults = MobileRelayConfig.defaults(pcClientName: pcClientName);
    return MobileRelayConfig(
      schemaVersion:
          (json['schemaVersion'] as num?)?.toInt() ?? currentSchemaVersion,
      stationBaseUrl: normalizeMobileRelayStationBaseUrl(
        (json['stationBaseUrl'] ?? '').toString(),
      ),
      pcClientId: (json['pcClientId'] ?? defaults.pcClientId).toString(),
      pcClientName: (json['pcClientName'] ?? defaults.pcClientName).toString(),
      pairingId: (json['pairingId'] ?? '').toString(),
      pcToken: (json['pcToken'] ?? '').toString(),
      mobileToken: (json['mobileToken'] ?? '').toString(),
      lastPairingCode: (json['lastPairingCode'] ?? '').toString(),
      lastPairingExpiresAt: (json['lastPairingExpiresAt'] ?? '').toString(),
      paired: json['paired'] == true,
      relayEnabled: json['relayEnabled'] == true,
      pollIntervalSeconds:
          (json['pollIntervalSeconds'] as num?)?.toInt().clamp(3, 60) ?? 5,
      pcTokenPresent:
          json['pcTokenPresent'] == true ||
          (json['pcToken'] ?? '').toString().trim().isNotEmpty,
      mobileTokenPresent:
          json['mobileTokenPresent'] == true ||
          (json['mobileToken'] ?? '').toString().trim().isNotEmpty,
      pairedDevices: json['pairedDevices'] is List
          ? (json['pairedDevices'] as List)
                .whereType<Map>()
                .map(
                  (item) => MobileRelayPairedDevice.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
      trustPresentation: json['deviceTrustPresentation'] is Map
          ? MobileRelayTrustPresentation.fromJson(
              Map<String, dynamic>.from(json['deviceTrustPresentation'] as Map),
            )
          : null,
    );
  }

  MobileRelayConfig copyWith({
    String? stationBaseUrl,
    String? pcClientId,
    String? pcClientName,
    String? pairingId,
    String? pcToken,
    String? mobileToken,
    String? lastPairingCode,
    String? lastPairingExpiresAt,
    bool? paired,
    bool? relayEnabled,
    int? pollIntervalSeconds,
    bool? pcTokenPresent,
    bool? mobileTokenPresent,
    List<MobileRelayPairedDevice>? pairedDevices,
    MobileRelayTrustPresentation? trustPresentation,
  }) {
    return MobileRelayConfig(
      schemaVersion: schemaVersion,
      stationBaseUrl: normalizeMobileRelayStationBaseUrl(
        stationBaseUrl ?? this.stationBaseUrl,
      ),
      pcClientId: pcClientId ?? this.pcClientId,
      pcClientName: pcClientName ?? this.pcClientName,
      pairingId: pairingId ?? this.pairingId,
      pcToken: pcToken ?? this.pcToken,
      mobileToken: mobileToken ?? this.mobileToken,
      lastPairingCode: lastPairingCode ?? this.lastPairingCode,
      lastPairingExpiresAt: lastPairingExpiresAt ?? this.lastPairingExpiresAt,
      paired: paired ?? this.paired,
      relayEnabled: relayEnabled ?? this.relayEnabled,
      pollIntervalSeconds: (pollIntervalSeconds ?? this.pollIntervalSeconds)
          .clamp(3, 60),
      pcTokenPresent:
          pcTokenPresent ??
          (this.pcTokenPresent || (pcToken ?? this.pcToken).trim().isNotEmpty),
      mobileTokenPresent:
          mobileTokenPresent ??
          (this.mobileTokenPresent ||
              (mobileToken ?? this.mobileToken).trim().isNotEmpty),
      pairedDevices: pairedDevices ?? this.pairedDevices,
      trustPresentation: trustPresentation ?? this.trustPresentation,
    );
  }

  List<MobileRelayPairedDevice> get deviceTabs {
    if (pairedDevices.isNotEmpty) {
      return dedupeMobileRelayPairedDevices(pairedDevices);
    }
    if (!hasPairedDeviceEcho) {
      return const [];
    }
    return [
      MobileRelayPairedDevice(
        id: pcClientId.trim().isNotEmpty ? pcClientId : pairingId,
        label: pcClientName.trim().isNotEmpty ? pcClientName : 'Mac',
        pairingId: pairingId,
        mobileToken: mobileToken,
        credentialPresent: mobileTokenPresent || mobileToken.trim().isNotEmpty,
        stationBaseUrl: stationBaseUrl,
      ),
    ];
  }
}
