import 'dart:async';

/// Privacy-safe bootstrap failure events for local diagnosis.
///
/// Records carry the stable failure code, the step id, the error type, and a
/// sanitized detail head. Home-directory paths are redacted and text is
/// length-bounded; conversation content and credentials are never accepted.
final class ClientLifecycleDiagnosticRecord {
  const ClientLifecycleDiagnosticRecord({
    required this.createdAt,
    required this.code,
    required this.stepId,
    required this.errorType,
    required this.detail,
    required this.stack,
  });

  final DateTime createdAt;
  final String code;
  final String stepId;
  final String errorType;
  final String detail;
  final String stack;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'code': code,
    'stepId': stepId,
    'errorType': errorType,
    'detail': detail,
    'stack': stack,
  };

  static const String schemaVersion = 'licoup.client-lifecycle-diagnostic.v1';
}

/// Persists [ClientLifecycleDiagnosticRecord] values for post-failure
/// inspection.
abstract interface class ClientLifecycleDiagnosticSink {
  Future<void> record(ClientLifecycleDiagnosticRecord record);
}

final class NoopClientLifecycleDiagnosticSink
    implements ClientLifecycleDiagnosticSink {
  const NoopClientLifecycleDiagnosticSink();

  @override
  Future<void> record(ClientLifecycleDiagnosticRecord record) async {}
}

/// Redacts local home-directory paths and bounds [text] to [maxLength]
/// characters so diagnostics stay shareable without leaking machine layout.
String sanitizeClientLifecycleDiagnosticText(
  String text, {
  String homeDirectory = '',
  int maxLength = 320,
}) {
  var sanitized = text;
  final home = homeDirectory.trim();
  if (home.isNotEmpty) {
    sanitized = sanitized.replaceAll(home, '~');
  }
  sanitized = sanitized.replaceAll(RegExp(r'/Users/[A-Za-z0-9._-]+'), '~');
  sanitized = sanitized.replaceAll(RegExp(r'/home/[A-Za-z0-9._-]+'), '~');
  sanitized = sanitized.replaceAll(
    RegExp('[A-Za-z]:\\\\Users\\\\[A-Za-z0-9._ -]+'),
    '~',
  );
  sanitized = sanitized.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (sanitized.length <= maxLength) {
    return sanitized;
  }
  return '${sanitized.substring(0, maxLength)}…';
}
