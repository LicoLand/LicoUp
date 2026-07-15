part 'mobile_relay_paired_device.dart';
part 'mobile_relay_trust_presentation.dart';
part 'mobile_relay_config.dart';
part 'mobile_relay_authorized_provider.dart';
part 'mobile_relay_command.dart';

const String licoDefaultMobileRelayGatewayUrl = 'https://app.licoarc.com';
const Set<String> _legacyDefaultMobileRelayGatewayUrls = {
  'https://relay.licolite.com',
  'https://api.licolite.app',
};
const Set<String> _ephemeralCustomMobileRelayGatewayHostSuffixes = {
  '.trycloudflare.com',
};

String? canonicalMobileRelayGatewayOrigin(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty ||
      trimmed.contains('\\') ||
      RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(trimmed)) {
    return null;
  }
  final schemeSeparator = trimmed.indexOf('://');
  if (schemeSeparator <= 0) {
    return null;
  }
  final rawScheme = trimmed.substring(0, schemeSeparator).toLowerCase();
  final afterScheme = trimmed.substring(schemeSeparator + 3);
  if (!const {'https', 'http'}.contains(rawScheme) ||
      afterScheme.startsWith(RegExp(r'[/#?]'))) {
    return null;
  }
  final authority = afterScheme.split(RegExp(r'[/#?]')).first;
  if (authority.isEmpty || authority.contains('@') || authority.contains('%')) {
    return null;
  }

  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.isAbsolute ||
      !uri.hasAuthority ||
      uri.scheme.toLowerCase() != rawScheme ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.hasQuery ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.endsWith('.') || host.contains('%')) {
    return null;
  }
  if (rawScheme == 'http' &&
      !const {'localhost', '127.0.0.1', '::1'}.contains(host)) {
    return null;
  }

  int? explicitPort;
  try {
    if (uri.hasPort) {
      explicitPort = uri.port;
      if (explicitPort == 0) {
        return null;
      }
    }
  } on FormatException {
    return null;
  }
  final omitDefaultPort =
      (rawScheme == 'https' && explicitPort == 443) ||
      (rawScheme == 'http' && explicitPort == 80);
  final canonicalHost = host.contains(':') ? '[$host]' : host;
  final portSuffix = explicitPort == null || omitDefaultPort
      ? ''
      : ':$explicitPort';
  return '$rawScheme://$canonicalHost$portSuffix';
}

String _normalizeGatewayUrl(String value) {
  return canonicalMobileRelayGatewayOrigin(value) ?? '';
}

String _nonEmptyGatewayUrl(String? value, String fallback) {
  final normalized = _normalizeGatewayUrl(value ?? '');
  return normalized.isEmpty ? fallback : normalized;
}

String _defaultGatewayUrl(String? value, String fallback) {
  final normalized = _nonEmptyGatewayUrl(value, fallback);
  return _legacyDefaultMobileRelayGatewayUrls.contains(normalized)
      ? fallback
      : normalized;
}

bool mobileRelayGatewayIsEphemeralCustom(String value) {
  final canonical = canonicalMobileRelayGatewayOrigin(value);
  if (canonical == null) {
    return false;
  }
  final host = Uri.parse(canonical).host.toLowerCase();
  return _ephemeralCustomMobileRelayGatewayHostSuffixes.any(host.endsWith);
}
