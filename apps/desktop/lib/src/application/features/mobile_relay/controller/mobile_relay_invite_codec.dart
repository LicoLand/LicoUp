part of 'package:flutter_client/src/application/controller/client_controller.dart';

Map<String, dynamic> _decodeMobilePairingInvite(String value) {
  final trimmed = value.trim();
  final direct = _tryDecodeInviteJson(trimmed);
  if (direct != null) {
    return direct;
  }

  final token = _extractInviteToken(trimmed);
  if (token != null) {
    final decoded = _tryDecodeInviteJson(_decodeBase64UrlToken(token));
    if (decoded != null) {
      return decoded;
    }
  }

  final encoded = _tryDecodeInviteJson(_decodeBase64UrlToken(trimmed));
  if (encoded != null) {
    return encoded;
  }

  throw const FormatException('Invalid pairing invite.');
}

String _encodeMobilePairingInviteLink(Map<String, dynamic> invite) {
  final payload = jsonEncode(invite);
  final token = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
  return Uri(
    scheme: 'licoarc',
    host: 'pair',
    queryParameters: {'invite': token},
  ).toString();
}

Map<String, dynamic>? _tryDecodeInviteJson(String value) {
  if (value.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } on FormatException {
    return null;
  }
  return null;
}

String? _extractInviteToken(String value) {
  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasQuery) {
    final token =
        uri.queryParameters['invite'] ??
        uri.queryParameters['token'] ??
        uri.queryParameters['pairing'];
    if (token != null && token.trim().isNotEmpty) {
      return token.trim();
    }
  }
  const prefixes = ['licoarc-pair:', 'licoarc://pair/', 'arc-pair:'];
  for (final prefix in prefixes) {
    if (value.startsWith(prefix)) {
      final token = value.substring(prefix.length).trim();
      if (token.isNotEmpty) {
        return token;
      }
    }
  }
  return null;
}

String _decodeBase64UrlToken(String token) {
  final normalized = token.trim().replaceAll(RegExp(r'\s+'), '');
  if (normalized.isEmpty) {
    return '';
  }
  try {
    final padded = normalized.padRight(
      normalized.length + (4 - normalized.length % 4) % 4,
      '=',
    );
    return utf8.decode(base64Url.decode(padded));
  } on FormatException {
    return '';
  }
}
