part of 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';

class MobileRelayAuthorizedProvider {
  const MobileRelayAuthorizedProvider({
    required this.providerId,
    required this.label,
    required this.credentialPresent,
    this.accountId = '',
    this.profileId = '',
    this.credentialKind = 'api-key',
    this.authKind = '',
    this.sourceMode = '',
    this.source = '',
  });

  final String providerId;
  final String label;
  final bool credentialPresent;
  final String accountId;
  final String profileId;
  final String credentialKind;
  final String authKind;
  final String sourceMode;
  final String source;

  factory MobileRelayAuthorizedProvider.fromJson(Map<String, dynamic> json) {
    final providerId = _normalizeProviderId(
      (json['providerId'] ??
              json['provider'] ??
              json['target'] ??
              json['id'] ??
              '')
          .toString(),
    );
    final credentialKind =
        (json['credentialKind'] ?? json['authKind'] ?? 'api-key').toString();
    return MobileRelayAuthorizedProvider(
      providerId: providerId,
      label: (json['label'] ?? json['name'] ?? providerId).toString(),
      credentialPresent: json['credentialPresent'] != false,
      accountId: (json['accountId'] ?? json['mobileAccountId'] ?? '')
          .toString(),
      profileId: (json['profileId'] ?? json['profile'] ?? json['id'] ?? '')
          .toString(),
      credentialKind: credentialKind,
      authKind: (json['authKind'] ?? credentialKind).toString(),
      sourceMode: (json['sourceMode'] ?? json['source'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'providerId': providerId,
      'label': label,
      'credentialPresent': credentialPresent,
      if (accountId.trim().isNotEmpty) 'accountId': accountId,
      if (profileId.trim().isNotEmpty) 'profileId': profileId,
      if (credentialKind.trim().isNotEmpty) 'credentialKind': credentialKind,
      if (authKind.trim().isNotEmpty) 'authKind': authKind,
      if (sourceMode.trim().isNotEmpty) 'sourceMode': sourceMode,
      if (source.trim().isNotEmpty) 'source': source,
    };
  }
}

List<MobileRelayAuthorizedProvider> _authorizedProvidersFromJson(
  Map<String, dynamic> json,
) {
  final values = <MobileRelayAuthorizedProvider>[];
  for (final key in [
    'authorizedProviders',
    'desktopAuthorizedProviders',
    'modelProviders',
  ]) {
    final raw = json[key];
    if (raw is List) {
      values.addAll(
        raw.whereType<Map>().map(
          (item) => MobileRelayAuthorizedProvider.fromJson(
            Map<String, dynamic>.from(item),
          ),
        ),
      );
    }
  }
  final byAccount = <String, MobileRelayAuthorizedProvider>{};
  for (final provider in values) {
    if (provider.providerId.trim().isEmpty || !provider.credentialPresent) {
      continue;
    }
    final profileKey = provider.profileId.trim().isNotEmpty
        ? provider.profileId.trim()
        : provider.accountId.trim().isNotEmpty
        ? provider.accountId.trim()
        : provider.providerId;
    byAccount['${provider.providerId}:$profileKey'] = provider;
  }
  return List<MobileRelayAuthorizedProvider>.unmodifiable(byAccount.values);
}

String _normalizeProviderId(String value) {
  final normalized = value.trim().toLowerCase().replaceAll('_', '-');
  return switch (normalized) {
    'openai' || 'chat-gpt' || 'gpt' => 'chatgpt',
    'google' || 'google-gemini' => 'gemini',
    'moonshot' || 'moonshot-ai' => 'kimi',
    'deep-seek' => 'deepseek',
    _ => normalized,
  };
}

List<MobileRelayPairedDevice> _dedupePairedDevices(
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
  final gateway = _normalizeGatewayUrl(device.gatewayUrl).toLowerCase();
  return [
    if (id.isNotEmpty) 'id:$id',
    if (pairingId.isNotEmpty) 'pairing:$pairingId',
    if (label.isNotEmpty && gateway.isNotEmpty) 'label:$label@$gateway',
  ];
}
