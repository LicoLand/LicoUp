import 'dart:convert';

/// Pure codec for the explicit Mobile Relay pairing handoff.
abstract final class MobilePairingInviteCodec {
  static const int _maximumEncodedLength = 128 * 1024;
  static const int _maximumDecodedLength = 96 * 1024;

  static Map<String, dynamic> decode(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > _maximumEncodedLength) {
      throw const FormatException('Invalid pairing invite.');
    }
    final direct = _tryDecodeJson(trimmed);
    if (direct != null) {
      return direct;
    }

    final token = _extractToken(trimmed);
    if (token != null) {
      final decoded = _tryDecodeJson(_decodeToken(token));
      if (decoded != null) {
        return decoded;
      }
    }

    final encoded = _tryDecodeJson(_decodeToken(trimmed));
    if (encoded != null) {
      return encoded;
    }
    throw const FormatException('Invalid pairing invite.');
  }

  static String encodeLink(Map<String, dynamic> invite) {
    if (invite.isEmpty) {
      throw const FormatException('Invalid pairing invite.');
    }
    final payload = jsonEncode(invite);
    if (payload.length > _maximumDecodedLength) {
      throw const FormatException('Invalid pairing invite.');
    }
    final token = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    return Uri(
      scheme: 'licoarc',
      host: 'pair',
      queryParameters: {'invite': token},
    ).toString();
  }

  static Map<String, dynamic>? _tryDecodeJson(String value) {
    if (value.isEmpty || value.length > _maximumDecodedLength) {
      return null;
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map && decoded.isNotEmpty) {
        return Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.from(decoded),
        );
      }
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
    return null;
  }

  static String? _extractToken(String value) {
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

  static String _decodeToken(String token) {
    final normalized = token.trim().replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty || normalized.length > _maximumEncodedLength) {
      return '';
    }
    try {
      final padded = normalized.padRight(
        normalized.length + (4 - normalized.length % 4) % 4,
        '=',
      );
      final decoded = utf8.decode(base64Url.decode(padded));
      return decoded.length <= _maximumDecodedLength ? decoded : '';
    } on FormatException {
      return '';
    }
  }
}
