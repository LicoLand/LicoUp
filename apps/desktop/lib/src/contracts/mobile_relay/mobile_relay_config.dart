part of 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';

class MobileRelayConfig {
  const MobileRelayConfig({
    required this.schemaVersion,
    required this.defaultGatewayUrl,
    required this.useCustomGateway,
    required this.customGatewayUrl,
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
    this.authorizedProviders = const [],
    this.trustPresentation,
  });

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final String defaultGatewayUrl;
  final bool useCustomGateway;
  final String customGatewayUrl;
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
  final List<MobileRelayAuthorizedProvider> authorizedProviders;
  final MobileRelayTrustPresentation? trustPresentation;

  String get effectiveGatewayUrl {
    final custom = _normalizeGatewayUrl(customGatewayUrl);
    final fallback = _nonEmptyGatewayUrl(
      defaultGatewayUrl,
      licoDefaultMobileRelayGatewayUrl,
    );
    return useCustomGateway &&
            custom.isNotEmpty &&
            !mobileRelayGatewayIsEphemeralCustom(custom)
        ? custom
        : fallback;
  }

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

  factory MobileRelayConfig.defaults({
    String? defaultGatewayUrl,
    String? pcClientName,
  }) {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final normalizedPcClientName = (pcClientName ?? '').trim();
    return MobileRelayConfig(
      schemaVersion: currentSchemaVersion,
      defaultGatewayUrl: _nonEmptyGatewayUrl(
        defaultGatewayUrl,
        licoDefaultMobileRelayGatewayUrl,
      ),
      useCustomGateway: false,
      customGatewayUrl: '',
      pcClientId: 'pc_$now',
      pcClientName: normalizedPcClientName.isEmpty
          ? 'Lico Arc'
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
      authorizedProviders: const [],
    );
  }

  factory MobileRelayConfig.fromJson(
    Map<String, dynamic> json, {
    String? defaultGatewayUrl,
    String? pcClientName,
  }) {
    final defaults = MobileRelayConfig.defaults(
      defaultGatewayUrl: defaultGatewayUrl,
      pcClientName: pcClientName,
    );
    final authorizedProviders = _authorizedProvidersFromJson(json);
    final customGatewayUrl = _normalizeGatewayUrl(
      (json['customGatewayUrl'] ?? '').toString(),
    );
    final customGatewayIsEphemeral = mobileRelayGatewayIsEphemeralCustom(
      customGatewayUrl,
    );
    return MobileRelayConfig(
      schemaVersion:
          (json['schemaVersion'] as num?)?.toInt() ?? currentSchemaVersion,
      defaultGatewayUrl: _defaultGatewayUrl(
        json['defaultGatewayUrl']?.toString(),
        defaults.defaultGatewayUrl,
      ),
      useCustomGateway:
          json['useCustomGateway'] == true &&
          customGatewayUrl.isNotEmpty &&
          !customGatewayIsEphemeral,
      customGatewayUrl: customGatewayIsEphemeral ? '' : customGatewayUrl,
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
      authorizedProviders: authorizedProviders,
      trustPresentation: json['deviceTrustPresentation'] is Map
          ? MobileRelayTrustPresentation.fromJson(
              Map<String, dynamic>.from(json['deviceTrustPresentation'] as Map),
            )
          : null,
    );
  }

  MobileRelayConfig copyWith({
    String? defaultGatewayUrl,
    bool? useCustomGateway,
    String? customGatewayUrl,
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
    List<MobileRelayAuthorizedProvider>? authorizedProviders,
    MobileRelayTrustPresentation? trustPresentation,
  }) {
    final nextCustomGatewayUrl = _normalizeGatewayUrl(
      customGatewayUrl ?? this.customGatewayUrl,
    );
    final nextCustomGatewayIsEphemeral = mobileRelayGatewayIsEphemeralCustom(
      nextCustomGatewayUrl,
    );
    return MobileRelayConfig(
      schemaVersion: schemaVersion,
      defaultGatewayUrl: _defaultGatewayUrl(
        defaultGatewayUrl ?? this.defaultGatewayUrl,
        licoDefaultMobileRelayGatewayUrl,
      ),
      useCustomGateway:
          (useCustomGateway ?? this.useCustomGateway) &&
          nextCustomGatewayUrl.isNotEmpty &&
          !nextCustomGatewayIsEphemeral,
      customGatewayUrl: nextCustomGatewayIsEphemeral
          ? ''
          : nextCustomGatewayUrl,
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
      authorizedProviders: authorizedProviders ?? this.authorizedProviders,
      trustPresentation: trustPresentation ?? this.trustPresentation,
    );
  }

  List<MobileRelayPairedDevice> get deviceTabs {
    if (pairedDevices.isNotEmpty) {
      return _dedupePairedDevices(pairedDevices);
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
        gatewayUrl: effectiveGatewayUrl,
        authorizedProviders: authorizedProviders,
      ),
    ];
  }
}
