import 'dart:async';

import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

typedef OrchestratorTestCall =
    Future<Map<String, Object?>> Function({
      required String method,
      required Map<String, Object?> params,
      String idempotencyKey,
      String clientKind,
    });

final class NativeOrchestratorClient {
  NativeOrchestratorClient({
    required NativeStdioRpcTransport transport,
    this.maxProjectedEvents = 128,
  }) : _call = _transportCall(transport) {
    _validateProjectionLimit(maxProjectedEvents);
  }

  NativeOrchestratorClient.forTesting({
    required OrchestratorTestCall call,
    this.maxProjectedEvents = 128,
  }) : _call = call {
    _validateProjectionLimit(maxProjectedEvents);
  }

  static const int _maximumProjectionLimit = 256;

  final OrchestratorTestCall _call;
  final int maxProjectedEvents;

  Future<OrchestratorPolicyProjection> registerPolicy({
    required Map<String, Object?> policy,
    required String idempotencyKey,
  }) async {
    final result = await _request(
      method: 'policy.register',
      params: {'policy': _immutableMap(policy)},
      idempotencyKey: idempotencyKey,
    );
    return OrchestratorPolicyProjection.fromJson(result);
  }

  Future<OrchestratorPolicyProjection> activatePolicy({
    required String policyRevision,
    required String idempotencyKey,
  }) async {
    final result = await _request(
      method: 'policy.activate',
      params: {'policyRevision': policyRevision},
      idempotencyKey: idempotencyKey,
    );
    return OrchestratorPolicyProjection.fromJson(result);
  }

  Future<OrchestratorWorkflowProjection> submit({
    required Map<String, Object?> intent,
    required String policyRevision,
    required String idempotencyKey,
  }) async {
    final result = await _request(
      method: 'workflow.submit',
      params: {
        'intent': _immutableMap(intent),
        'policyRevision': policyRevision,
      },
      idempotencyKey: idempotencyKey,
    );
    return OrchestratorWorkflowProjection.fromJson(result);
  }

  Future<OrchestratorWorkflowProjection> status({
    required String workflowId,
  }) async {
    final result = await _request(
      method: 'workflow.status',
      params: {'workflowId': workflowId},
    );
    return OrchestratorWorkflowProjection.fromJson(result);
  }

  Future<OrchestratorWorkflowProjection> cancel({
    required String workflowId,
    required String idempotencyKey,
  }) async {
    final result = await _request(
      method: 'workflow.cancel',
      params: {'workflowId': workflowId},
      idempotencyKey: idempotencyKey,
    );
    return OrchestratorWorkflowProjection.fromJson(result);
  }

  Future<OrchestratorWorkflowProjection> approve({
    required String workflowId,
    required String approvalId,
    required String decision,
    required String idempotencyKey,
  }) async {
    final result = await _request(
      method: 'workflow.approve',
      params: {
        'workflowId': workflowId,
        'approvalId': approvalId,
        'decision': decision,
      },
      idempotencyKey: idempotencyKey,
    );
    return OrchestratorWorkflowProjection.fromJson(result);
  }

  Future<LocalBridgeWaitProjection> waitForProgress({
    required String workflowId,
    required int afterCursor,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (afterCursor < 0 || timeout < Duration.zero) {
      throw ArgumentError('Local Bridge wait bounds are invalid.');
    }
    final result = await _request(
      method: 'workflow.wait',
      params: {
        'workflowId': workflowId,
        'afterCursor': afterCursor,
        'limit': maxProjectedEvents > 128 ? 128 : maxProjectedEvents,
        'timeoutMs': timeout.inMilliseconds.clamp(0, 30000),
      },
    );
    return LocalBridgeWaitProjection.fromJson(result);
  }

  Future<LocalBridgeMessageReceipt> sendMessage({
    required String workflowId,
    required String message,
    required String idempotencyKey,
  }) async {
    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message');
    }
    final result = await _request(
      method: 'workflow.message',
      params: {'workflowId': workflowId, 'message': message},
      idempotencyKey: idempotencyKey,
    );
    return LocalBridgeMessageReceipt.fromJson(result);
  }

  Stream<OrchestratorWorkflowProjection> subscribe({
    required String workflowId,
    int afterSequence = 0,
  }) async* {
    final result = await _request(
      method: 'workflow.events',
      params: {
        'workflowId': workflowId,
        'afterSequence': afterSequence,
        'limit': maxProjectedEvents,
      },
    );
    final rawEvents = result['events'];
    if (rawEvents is! List<Object?>) return;

    OrchestratorWorkflowProjection? backendSnapshot;
    if (rawEvents.any(
      (event) => event is Map && event['workflowId'] is! String,
    )) {
      backendSnapshot = await status(workflowId: workflowId);
    }

    final bySequence = <int, OrchestratorWorkflowProjection>{};
    for (final rawEvent in rawEvents) {
      if (rawEvent is! Map) continue;
      final projection = OrchestratorWorkflowProjection.fromJson(
        _stringKeyedMap(rawEvent),
        fallback: backendSnapshot,
      );
      if (projection.sequence <= afterSequence) continue;
      bySequence[projection.sequence] = projection;
    }
    final sequences = bySequence.keys.toList(growable: false)..sort();
    final first = sequences.length > maxProjectedEvents
        ? sequences.length - maxProjectedEvents
        : 0;
    for (var index = first; index < sequences.length; index += 1) {
      yield bySequence[sequences[index]]!;
    }
  }

  Future<Map<String, Object?>> _request({
    required String method,
    required Map<String, Object?> params,
    String idempotencyKey = '',
  }) async {
    try {
      return await _call(
        method: method,
        params: Map<String, Object?>.unmodifiable(params),
        idempotencyKey: idempotencyKey,
        clientKind: 'desktop',
      );
    } on OrchestratorClientException {
      rethrow;
    } on LicoClientRpcException catch (error) {
      throw OrchestratorClientException(code: error.code);
    } on Object {
      throw const OrchestratorClientException(code: 'service_unavailable');
    }
  }

  static OrchestratorTestCall _transportCall(
    NativeStdioRpcTransport transport,
  ) {
    return ({
      required String method,
      required Map<String, Object?> params,
      String idempotencyKey = '',
      String clientKind = 'desktop',
    }) async {
      final response = await transport
          .executeStructured('orchestrator.request', <String, dynamic>{
            'method': method,
            'params': Map<String, Object?>.unmodifiable(params),
            if (idempotencyKey.isNotEmpty) 'idempotencyKey': idempotencyKey,
            'clientKind': clientKind,
          });
      final error = response['error'];
      if (response['ok'] == false && error is Map) {
        throw OrchestratorClientException(
          code: (error['code'] ?? 'service_unavailable').toString(),
        );
      }
      final result = response['result'];
      return result is Map
          ? _stringKeyedMap(result)
          : _stringKeyedMap(response);
    };
  }

  static void _validateProjectionLimit(int value) {
    if (value < 1 || value > _maximumProjectionLimit) {
      throw ArgumentError.value(value, 'maxProjectedEvents');
    }
  }
}

final class LocalBridgeEvent {
  const LocalBridgeEvent({
    required this.cursor,
    required this.type,
    required this.state,
    this.stepId = '',
    this.agentId = '',
    this.deliveryMode = '',
    this.outputBytes = 0,
  });

  factory LocalBridgeEvent.fromJson(Map<String, Object?> json) {
    return LocalBridgeEvent(
      cursor: _readInt(json, 'cursor'),
      type: _readString(json, 'type'),
      state: _readString(json, 'state'),
      stepId: _optionalString(json, 'stepId'),
      agentId: _optionalString(json, 'agentId'),
      deliveryMode: _optionalString(json, 'deliveryMode'),
      outputBytes: _readOptionalInt(json, 'outputBytes', fallback: 0),
    );
  }

  final int cursor;
  final String type;
  final String state;
  final String stepId;
  final String agentId;
  final String deliveryMode;
  final int outputBytes;
}

final class LocalBridgeWaitProjection {
  const LocalBridgeWaitProjection({
    required this.workflowId,
    required this.events,
    required this.nextCursor,
    required this.hasMore,
    required this.cursorExpired,
    required this.timedOut,
    required this.active,
    required this.terminal,
  });

  factory LocalBridgeWaitProjection.fromJson(Map<String, Object?> json) {
    final rawEvents = json['events'];
    final events = rawEvents is List
        ? rawEvents
              .whereType<Map>()
              .map((event) => LocalBridgeEvent.fromJson(_stringKeyedMap(event)))
              .toList(growable: false)
        : const <LocalBridgeEvent>[];
    return LocalBridgeWaitProjection(
      workflowId: _readString(json, 'workflowId'),
      events: List<LocalBridgeEvent>.unmodifiable(events),
      nextCursor: _readInt(json, 'nextCursor'),
      hasMore: json['hasMore'] == true,
      cursorExpired: json['cursorExpired'] == true,
      timedOut: json['timedOut'] == true,
      active: json['active'] == true,
      terminal: json['terminal'] == true,
    );
  }

  final String workflowId;
  final List<LocalBridgeEvent> events;
  final int nextCursor;
  final bool hasMore;
  final bool cursorExpired;
  final bool timedOut;
  final bool active;
  final bool terminal;
}

final class LocalBridgeMessageReceipt {
  const LocalBridgeMessageReceipt({
    required this.workflowId,
    required this.messageId,
    required this.state,
    required this.deliveryMode,
  });

  factory LocalBridgeMessageReceipt.fromJson(Map<String, Object?> json) {
    return LocalBridgeMessageReceipt(
      workflowId: _readString(json, 'workflowId'),
      messageId: _readString(json, 'messageId'),
      state: _readString(json, 'state'),
      deliveryMode: _readString(json, 'deliveryMode'),
    );
  }

  final String workflowId;
  final String messageId;
  final String state;
  final String deliveryMode;
}

final class OrchestratorPolicyProjection {
  const OrchestratorPolicyProjection({
    required this.policyRevision,
    required this.state,
    this.digest = '',
  });

  factory OrchestratorPolicyProjection.fromJson(Map<String, Object?> json) {
    return OrchestratorPolicyProjection(
      policyRevision: _readString(
        json,
        'policyRevision',
        alternate: 'policyRevisionId',
      ),
      state: _readString(json, 'state'),
      digest: _optionalString(json, 'digest'),
    );
  }

  final String policyRevision;
  final String state;
  final String digest;

  Map<String, Object?> toJson() => Map<String, Object?>.unmodifiable({
    'policyRevision': policyRevision,
    'state': state,
    if (digest.isNotEmpty) 'digest': digest,
  });
}

final class OrchestratorWorkflowEvent {
  const OrchestratorWorkflowEvent({
    required this.sequence,
    required this.state,
  });

  final int sequence;
  final String state;

  Map<String, Object?> toJson() =>
      Map<String, Object?>.unmodifiable({'sequence': sequence, 'state': state});
}

final class OrchestratorWorkflowProjection {
  OrchestratorWorkflowProjection({
    required this.workflowId,
    required this.policyRevision,
    required this.sequence,
    required this.state,
    this.adapterDecision = '',
    Map<String, Object?>? terminalReceipt,
    List<OrchestratorWorkflowEvent> events = const [],
  }) : terminalReceipt = terminalReceipt == null
           ? null
           : _immutableMap(terminalReceipt),
       events = List<OrchestratorWorkflowEvent>.unmodifiable(events);

  factory OrchestratorWorkflowProjection.fromJson(
    Map<String, Object?> json, {
    OrchestratorWorkflowProjection? fallback,
  }) {
    final terminal = json['terminalReceipt'];
    final rawEvents = json['events'];
    return OrchestratorWorkflowProjection(
      workflowId: _optionalString(json, 'workflowId').isNotEmpty
          ? _optionalString(json, 'workflowId')
          : fallback?.workflowId ?? '',
      policyRevision:
          _optionalString(json, 'policyRevision').isNotEmpty ||
              _optionalString(json, 'policyRevisionId').isNotEmpty
          ? _readString(json, 'policyRevision', alternate: 'policyRevisionId')
          : fallback?.policyRevision ?? '',
      sequence: _readOptionalInt(
        json,
        'sequence',
        alternate: 'cursor',
        fallback: fallback?.sequence ?? 0,
      ),
      state: _optionalString(json, 'state').isNotEmpty
          ? _optionalString(json, 'state')
          : fallback?.state ?? '',
      adapterDecision: _optionalString(json, 'adapterDecision').isNotEmpty
          ? _optionalString(json, 'adapterDecision')
          : fallback?.adapterDecision ?? '',
      terminalReceipt: terminal is Map
          ? _privacyMinimalReceipt(terminal)
          : fallback?.terminalReceipt,
      events: rawEvents is List<Object?>
          ? [
              for (final event in rawEvents)
                if (event is Map) _privacyMinimalEvent(event),
            ]
          : const [],
    );
  }

  final String workflowId;
  final String policyRevision;
  final int sequence;
  final String state;
  final String adapterDecision;
  final Map<String, Object?>? terminalReceipt;
  final List<OrchestratorWorkflowEvent> events;

  Map<String, Object?> toJson() => Map<String, Object?>.unmodifiable({
    'workflowId': workflowId,
    'policyRevision': policyRevision,
    'sequence': sequence,
    'state': state,
    if (adapterDecision.isNotEmpty) 'adapterDecision': adapterDecision,
    if (terminalReceipt != null) 'terminalReceipt': terminalReceipt,
    if (events.isNotEmpty)
      'events': [for (final event in events) event.toJson()],
  });
}

final class OrchestratorClientException implements Exception {
  const OrchestratorClientException({required this.code});

  final String code;

  @override
  String toString() => 'Orchestrator request failed (code: $code).';
}

Map<String, Object?> _privacyMinimalReceipt(Map<Object?, Object?> source) {
  final json = _stringKeyedMap(source);
  return Map<String, Object?>.unmodifiable({
    if (json['state'] is String) 'state': json['state'],
    if (json['digest'] is String) 'digest': json['digest'],
    if (json['reasonCode'] is String) 'reasonCode': json['reasonCode'],
  });
}

OrchestratorWorkflowEvent _privacyMinimalEvent(Map<Object?, Object?> source) {
  final json = _stringKeyedMap(source);
  return OrchestratorWorkflowEvent(
    sequence: _readInt(json, 'sequence', alternate: 'cursor'),
    state: _readString(json, 'state', alternate: 'type'),
  );
}

Map<String, Object?> _immutableMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(source);

Map<String, Object?> _stringKeyedMap(Map<Object?, Object?> source) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in source.entries)
        if (entry.key is String) entry.key! as String: entry.value,
    });

String _readString(Map<String, Object?> json, String key, {String? alternate}) {
  final value = json[key] ?? (alternate == null ? null : json[alternate]);
  if (value is String && value.isNotEmpty) return value;
  throw const OrchestratorClientException(code: 'invalid_projection');
}

String _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is String ? value : '';
}

int _readInt(Map<String, Object?> json, String key, {String? alternate}) {
  final value = json[key] ?? (alternate == null ? null : json[alternate]);
  if (value is int && value >= 0) return value;
  throw const OrchestratorClientException(code: 'invalid_projection');
}

int _readOptionalInt(
  Map<String, Object?> json,
  String key, {
  String? alternate,
  required int fallback,
}) {
  final value = json[key] ?? (alternate == null ? null : json[alternate]);
  return value is int && value >= 0 ? value : fallback;
}
