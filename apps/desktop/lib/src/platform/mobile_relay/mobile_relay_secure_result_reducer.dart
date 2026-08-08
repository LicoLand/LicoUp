import 'dart:convert';

const int _secureAgentSessionListMaximum = 20;
const int _secureAgentSessionListMaximumBytes = 2 * 1024 * 1024;
const int _secureAgentSessionListMaximumMessages = 2000;
const int _secureAgentMessageMaximumDepth = 8;
const int _secureAgentMessageMaximumTextLength = 256 * 1024;

/// Reduces one Secure Relay result poll into a verified completion.
///
/// A `null` return value means the command is still pending. Successful
/// completions retain the opened result for the conversation consumer. Failed
/// completions expose only a bounded error code and never return decrypted
/// error details.
Map<String, dynamic>? resolveSecureRelayPollResult({
  required Map<String, dynamic> created,
  required Map<String, dynamic> polled,
}) {
  final expectedBinding = _secureRelayMap(created['secureCommandBinding']);
  final expectedPayloadCommandId = (expectedBinding?['payloadCommandId'] ?? '')
      .toString()
      .trim();
  final expectedIdempotencyKey = (expectedBinding?['idempotencyKey'] ?? '')
      .toString()
      .trim();
  final expectedCommandKind = (expectedBinding?['commandKind'] ?? '')
      .toString()
      .trim();
  if (created['ok'] != true ||
      expectedPayloadCommandId.isEmpty ||
      expectedIdempotencyKey.isEmpty ||
      !_secureRelayCommandKinds.contains(expectedCommandKind)) {
    return _secureRelayFailure('secure_relay_command_binding_invalid');
  }
  final openedValue = polled['openedResult'];
  final opened = _secureRelayMap(openedValue);

  if (opened == null) {
    if (polled['ok'] == false) {
      return _secureRelayFailure(
        _redactedSecureRelayErrorCode(
          polled['errorCode'],
          fallback: 'secure_relay_result_fetch_failed',
        ),
      );
    }
    if (openedValue != null) {
      return _secureRelayFailure('secure_relay_result_invalid');
    }
    if (polled['ok'] == true &&
        polled['pending'] == true &&
        polled['bodyRedacted'] == true) {
      return null;
    }
    return _secureRelayFailure('secure_relay_result_invalid');
  }
  final resultReceiptId = (polled['resultReceiptId'] ?? '').toString().trim();
  if (polled['ok'] != true ||
      polled['pending'] != false ||
      polled['bodyRedacted'] != true ||
      resultReceiptId.isEmpty) {
    return _secureRelayFailure('secure_relay_result_invalid');
  }

  final execution = _secureRelayMap(opened['execution']);
  if (execution == null) {
    return _secureRelayFailure('secure_relay_result_invalid');
  }
  if ((execution['commandId'] ?? '').toString().trim() !=
          expectedPayloadCommandId ||
      (execution['idempotencyKey'] ?? '').toString().trim() !=
          expectedIdempotencyKey) {
    return _secureRelayFailure('secure_relay_command_binding_mismatch');
  }
  final outcome = (execution['outcome'] ?? '').toString().trim().toLowerCase();
  if (outcome == 'error') {
    return _secureRelayFailure(
      _redactedSecureRelayErrorCode(
        execution['errorCode'],
        fallback: 'secure_relay_execution_failed',
      ),
    );
  }
  if (outcome != 'result') {
    return _secureRelayFailure('secure_relay_result_invalid');
  }

  final executionOutput = _secureRelayMap(execution['output']);
  if (executionOutput == null) {
    return _secureRelayFailure('secure_relay_result_invalid');
  }
  if (executionOutput['ok'] != true) {
    return _secureRelayFailure(
      _redactedSecureRelayErrorCode(
        executionOutput['errorCode'] ?? executionOutput['code'],
        fallback: 'secure_relay_execution_output_failed',
      ),
    );
  }
  final runtimeOutput = _secureRelayMap(executionOutput['output']);
  if (runtimeOutput == null) {
    return _secureRelayFailure('secure_relay_result_invalid');
  }
  final commandKind = (executionOutput['commandKind'] ?? '').toString().trim();
  if (commandKind != expectedCommandKind) {
    return _secureRelayFailure('secure_relay_command_kind_mismatch');
  }
  if (runtimeOutput['ok'] != true) {
    if (!runtimeOutput.containsKey('ok')) {
      return _secureRelayFailure('secure_relay_result_invalid');
    }
    return _secureRelayFailure(
      _redactedSecureRelayErrorCode(
        runtimeOutput['errorCode'] ?? runtimeOutput['code'],
        fallback: 'secure_relay_runtime_failed',
      ),
    );
  }

  return {...created, 'ok': true, 'result': polled};
}

const Set<String> _secureRelayCommandKinds = {
  'agent.message.send',
  'agent.sessions.list',
  'agent.sessions.describe',
};

/// Extracts the read-only native conversation list from a verified Secure
/// Relay completion while rejecting cross-command, cross-agent, and ambiguous
/// continuity projections.
Map<String, dynamic> resolveSecureAgentSessionListResult({
  required Map<String, dynamic> result,
  required String agentId,
  String commandKind = 'agent.sessions.list',
}) {
  final normalizedAgent = agentId.trim();
  final normalizedCommand = commandKind.trim();
  if (normalizedAgent.isEmpty) {
    return const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_agent_id_missing',
    };
  }
  if (normalizedCommand != 'agent.sessions.list' &&
      normalizedCommand != 'agent.sessions.describe') {
    return const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_result_invalid',
    };
  }
  if (result['ok'] != true) {
    return _secureRelayFailure(
      _redactedSecureRelayErrorCode(
        result['errorCode'] ?? result['code'],
        fallback: 'secure_agent_sessions_list_failed',
      ),
    );
  }
  final polled = _secureRelayMap(result['result']);
  final opened = _secureRelayMap(polled?['openedResult']);
  final execution = _secureRelayMap(opened?['execution']);
  final executionOutput = _secureRelayMap(execution?['output']);
  final runtimeOutput = _secureRelayMap(executionOutput?['output']);
  if (execution?['outcome'] != 'result' ||
      executionOutput?['ok'] != true ||
      executionOutput?['commandKind'] != normalizedCommand ||
      runtimeOutput?['ok'] != true ||
      runtimeOutput?['mode'] != 'native-history' ||
      runtimeOutput?['importMode'] != 'precise-adapter' ||
      runtimeOutput?['readOnly'] != true ||
      (runtimeOutput?['agentId'] ?? '').toString().trim() != normalizedAgent) {
    return _secureRelayFailure('secure_agent_sessions_result_invalid');
  }
  final rawSessions = runtimeOutput?['sessions'];
  final page = _secureRelayMap(runtimeOutput?['page']);
  if (rawSessions is! List ||
      rawSessions.length > _secureAgentSessionListMaximum ||
      page == null ||
      page['hasMore'] is! bool) {
    return _secureRelayFailure('secure_agent_sessions_result_invalid');
  }
  try {
    if (utf8.encode(jsonEncode(rawSessions)).length >
        _secureAgentSessionListMaximumBytes) {
      return _secureRelayFailure('secure_agent_sessions_payload_too_large');
    }
  } on Object {
    return _secureRelayFailure('secure_agent_sessions_result_invalid');
  }
  final messageBudget = _SecureAgentMessageBudget();
  final sessionsByProjectionId = <String, Map<String, dynamic>>{};
  final sessionsByNativeId = <String, Map<String, dynamic>>{};
  for (final rawSession in rawSessions) {
    final session = _secureRelayMap(rawSession);
    final projectionId = (session?['id'] ?? '').toString().trim();
    final nativeSessionId = (session?['nativeSessionId'] ?? '')
        .toString()
        .trim();
    final sessionAgent = (session?['agentId'] ?? '').toString().trim();
    if (session == null ||
        projectionId.isEmpty ||
        nativeSessionId.isEmpty ||
        sessionAgent != normalizedAgent ||
        session['native'] != true ||
        session['readOnly'] != true) {
      return _secureRelayFailure('secure_agent_sessions_result_invalid');
    }
    final projection = _secureAgentSessionProjection(
      session,
      normalizedAgent,
      messageBudget,
    );
    if (projection == null) {
      return _secureRelayFailure('secure_agent_sessions_result_invalid');
    }
    final duplicateProjection = sessionsByProjectionId[projectionId];
    if (duplicateProjection != null) {
      if (jsonEncode(duplicateProjection) != jsonEncode(projection)) {
        return _secureRelayFailure('secure_agent_sessions_result_invalid');
      }
      continue;
    }
    sessionsByProjectionId[projectionId] = projection;
    final duplicateNative = sessionsByNativeId[nativeSessionId];
    sessionsByNativeId[nativeSessionId] = duplicateNative == null
        ? projection
        : _preferredSecureAgentSessionProjection(duplicateNative, projection);
  }
  final sessions = sessionsByNativeId.values.toList(growable: false)
    ..sort(_compareSecureAgentSessionProjection);
  return {
    'ok': true,
    'agentId': normalizedAgent,
    'sessions': List<Map<String, dynamic>>.unmodifiable(sessions),
    'hasMore': page['hasMore'] == true,
  };
}

Map<String, dynamic>? _secureAgentSessionProjection(
  Map<String, dynamic> session,
  String agentId,
  _SecureAgentMessageBudget messageBudget,
) {
  final id = session['id'];
  final nativeSessionId = session['nativeSessionId'];
  final sessionAgentId = session['agentId'];
  final title = session['title'];
  final createdAt = session['createdAt'];
  final updatedAt = session['updatedAt'];
  final adapterId = session['adapterId'];
  final rawMessages = session['messages'];
  if (id is! String ||
      id.trim().isEmpty ||
      id.length > 1024 ||
      nativeSessionId is! String ||
      nativeSessionId.trim().isEmpty ||
      nativeSessionId.length > 4096 ||
      sessionAgentId is! String ||
      sessionAgentId.trim() != agentId ||
      title is! String ||
      title.length > 4096 ||
      createdAt is! String ||
      createdAt.length > 128 ||
      updatedAt is! String ||
      updatedAt.length > 128 ||
      adapterId is! String ||
      adapterId.trim().isEmpty ||
      adapterId.length > 128 ||
      rawMessages is! List) {
    return null;
  }
  final messages = <Map<String, dynamic>>[];
  for (final rawMessage in rawMessages) {
    final message = _secureAgentMessageProjection(
      rawMessage,
      messageBudget,
      depth: 0,
    );
    if (message == null) {
      return null;
    }
    messages.add(message);
  }
  return {
    'id': id.trim(),
    'nativeSessionId': nativeSessionId.trim(),
    'agentId': sessionAgentId.trim(),
    'adapterId': adapterId.trim(),
    'title': title,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'native': true,
    'readOnly': true,
    'messageCount': messages.length,
    'messages': List<Map<String, dynamic>>.unmodifiable(messages),
  };
}

Map<String, dynamic>? _secureAgentMessageProjection(
  Object? rawMessage,
  _SecureAgentMessageBudget budget, {
  required int depth,
}) {
  if (depth > _secureAgentMessageMaximumDepth ||
      budget.count >= _secureAgentSessionListMaximumMessages) {
    return null;
  }
  final message = _secureRelayMap(rawMessage);
  final id = message?['id'];
  final role = message?['role'];
  final text = message?['text'];
  final createdAt = message?['createdAt'];
  if (message == null ||
      id is! String ||
      id.length > 1024 ||
      role is! String ||
      role.trim().isEmpty ||
      role.length > 64 ||
      text is! String ||
      text.length > _secureAgentMessageMaximumTextLength ||
      createdAt is! String ||
      createdAt.length > 128) {
    return null;
  }
  budget.count += 1;
  final projection = <String, dynamic>{
    'id': id,
    'role': role,
    'text': text,
    'createdAt': createdAt,
  };
  for (final key in ['cardType', 'cardTitle', 'cardSubtitle']) {
    final value = message[key];
    if (value == null) {
      continue;
    }
    if (value is! String || value.length > 4096) {
      return null;
    }
    if (value.isNotEmpty) {
      projection[key] = value;
    }
  }
  final collapsed = message['collapsed'];
  if (collapsed != null && collapsed is! bool) {
    return null;
  }
  if (collapsed == false) {
    projection['collapsed'] = false;
  }
  final rawChildren = message['messages'];
  if (rawChildren != null) {
    if (rawChildren is! List) {
      return null;
    }
    final children = <Map<String, dynamic>>[];
    for (final rawChild in rawChildren) {
      final child = _secureAgentMessageProjection(
        rawChild,
        budget,
        depth: depth + 1,
      );
      if (child == null) {
        return null;
      }
      children.add(child);
    }
    if (children.isNotEmpty) {
      projection['messages'] = List<Map<String, dynamic>>.unmodifiable(
        children,
      );
    }
  }
  return projection;
}

Map<String, dynamic> _preferredSecureAgentSessionProjection(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftUpdatedAt = DateTime.tryParse(left['updatedAt'] as String);
  final rightUpdatedAt = DateTime.tryParse(right['updatedAt'] as String);
  if (leftUpdatedAt != null && rightUpdatedAt != null) {
    final compared = leftUpdatedAt.compareTo(rightUpdatedAt);
    if (compared != 0) {
      return compared > 0 ? left : right;
    }
  } else if (leftUpdatedAt != null) {
    return left;
  } else if (rightUpdatedAt != null) {
    return right;
  }
  return (left['id'] as String).compareTo(right['id'] as String) <= 0
      ? left
      : right;
}

int _compareSecureAgentSessionProjection(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftUpdatedAt = DateTime.tryParse(left['updatedAt'] as String);
  final rightUpdatedAt = DateTime.tryParse(right['updatedAt'] as String);
  if (leftUpdatedAt != null && rightUpdatedAt != null) {
    final compared = rightUpdatedAt.compareTo(leftUpdatedAt);
    if (compared != 0) {
      return compared;
    }
  } else if (leftUpdatedAt != null) {
    return -1;
  } else if (rightUpdatedAt != null) {
    return 1;
  }
  return (left['id'] as String).compareTo(right['id'] as String);
}

class _SecureAgentMessageBudget {
  int count = 0;
}

Map<String, dynamic> _secureRelayFailure(String errorCode) {
  return {'ok': false, 'errorCode': errorCode};
}

Map<String, dynamic>? _secureRelayMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    try {
      return Map<String, dynamic>.from(value);
    } on TypeError {
      return null;
    }
  }
  return null;
}

String _redactedSecureRelayErrorCode(
  Object? value, {
  required String fallback,
}) {
  final candidate = value is String ? value.trim() : '';
  if (candidate.isEmpty || candidate.length > 64) {
    return fallback;
  }
  if (!RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(candidate)) {
    return fallback;
  }
  return candidate;
}
