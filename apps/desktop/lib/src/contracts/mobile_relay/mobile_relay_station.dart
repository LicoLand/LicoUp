String? canonicalMobileRelayStationOrigin(String value) {
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

String normalizeMobileRelayStationBaseUrl(String value) {
  return canonicalMobileRelayStationOrigin(value) ?? '';
}
