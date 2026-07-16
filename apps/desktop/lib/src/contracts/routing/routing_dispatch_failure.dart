import 'package:flutter/foundation.dart';

/// Fail-closed disposition used by priority-fallback dispatch.
enum RoutingDispatchFailureDisposition {
  none,
  transientKnown,
  terminal,
  unknownOutcome,
}

@immutable
class RoutingDispatchFailureFacts {
  const RoutingDispatchFailureFacts({
    required this.ok,
    required this.errorCode,
    required this.transient,
    required this.outcomeKnown,
  });

  factory RoutingDispatchFailureFacts.fromEnvelope({
    required bool ok,
    required String errorCode,
    required Map<String, dynamic> envelope,
  }) {
    final nested = envelope['error'];
    final error = nested is Map
        ? Map<String, dynamic>.from(nested)
        : const <String, dynamic>{};
    return RoutingDispatchFailureFacts(
      ok: ok,
      errorCode: errorCode.trim().toLowerCase(),
      transient: envelope['transient'] == true || error['transient'] == true,
      outcomeKnown:
          envelope['outcomeKnown'] == true || error['outcomeKnown'] == true,
    );
  }

  final bool ok;
  final String errorCode;
  final bool transient;
  final bool outcomeKnown;

  RoutingDispatchFailureDisposition get disposition {
    if (ok) return RoutingDispatchFailureDisposition.none;
    if (!outcomeKnown) {
      return RoutingDispatchFailureDisposition.unknownOutcome;
    }
    if (transient) {
      return RoutingDispatchFailureDisposition.transientKnown;
    }
    return RoutingDispatchFailureDisposition.terminal;
  }
}
