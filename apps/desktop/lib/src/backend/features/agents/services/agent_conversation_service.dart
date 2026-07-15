import 'dart:convert';

import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';

export 'package:flutter_client/src/contracts/agent_conversation_models.dart';
export 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';

part 'agent_conversation_archive_service.dart';

/// Backend adapter that implements the unified [AgentDispatchLane] over the
/// sidecar. Conversation callers consume this contract instead of owning
/// native conversation command shapes.
class AgentConversationService implements AgentDispatchLane {
  const AgentConversationService();

  Future<List<AgentConversationSession>> loadSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) async {
    final output = await agentService.runCli([
      'conversations',
      'list',
      '--agent',
      agentId,
      if (sessionId.trim().isNotEmpty) ...['--session-id', sessionId.trim()],
      ..._paginationArgs(limit: limit, offset: offset),
    ]);
    return _sessionsFromOutput(output);
  }

  Stream<AgentConversationSession> streamSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) async* {
    await for (final event in agentService.streamCliJsonLines([
      'conversations',
      'stream',
      '--agent',
      agentId,
      if (sessionId.trim().isNotEmpty) ...['--session-id', sessionId.trim()],
      ..._paginationArgs(limit: limit, offset: offset),
    ])) {
      final eventName = (event['event'] ?? '').toString();
      if (eventName == 'session' && event['session'] is Map<String, dynamic>) {
        final session = AgentConversationSession.fromJson(
          event['session'] as Map<String, dynamic>,
        );
        if (session.id.isNotEmpty) {
          yield session;
        }
      } else if (eventName == 'done' && event['ok'] == false) {
        throw Exception(event['error'] ?? 'conversation stream failed');
      }
    }
  }

  @override
  Future<AgentDispatchSession> openOrResume({
    required AgentCommandRunner runner,
    required String agentId,
    String sessionId = '',
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    final normalizedAgent = agentId.trim();
    final normalizedSession = sessionId.trim();
    if (normalizedAgent.isEmpty) {
      throw const AgentDispatchOpenException('agent_id_required');
    }
    final result = await runner.runCliWithStdin(
      const ['agent', 'conversation', 'open', '--stdin-json', 'true'],
      jsonEncode(<String, dynamic>{
        'agent': normalizedAgent,
        if (normalizedSession.isNotEmpty) 'sessionId': normalizedSession,
        if (bind.sessionPath.trim().isNotEmpty)
          'sessionPath': bind.sessionPath.trim(),
        if (bind.workingDirectory.trim().isNotEmpty)
          'workingDirectory': bind.workingDirectory.trim(),
        if (bind.binaryPath.trim().isNotEmpty)
          'binaryPath': bind.binaryPath.trim(),
        if (bind.model.trim().isNotEmpty) 'model': bind.model.trim(),
        if (bind.reasoningEffort.trim().isNotEmpty)
          'reasoningEffort': bind.reasoningEffort.trim(),
      }),
    );
    if (result['ok'] != true) {
      final error = result['error'];
      final code = error is Map
          ? (error['code'] ?? 'dispatch_open_failed').toString()
          : 'dispatch_open_failed';
      throw AgentDispatchOpenException(code);
    }
    final returnedSession =
        (result['nativeSessionId'] ??
                result['sessionId'] ??
                result['threadId'] ??
                '')
            .toString()
            .trim();
    if (normalizedSession.isNotEmpty && returnedSession.isEmpty) {
      throw const AgentDispatchOpenException('dispatch_session_id_missing');
    }
    if (normalizedSession.isNotEmpty && returnedSession != normalizedSession) {
      throw const AgentDispatchOpenException(
        'dispatch_resume_session_identity_mismatch',
      );
    }
    return AgentDispatchSession(
      sessionId: returnedSession,
      threadId: (result['threadId'] ?? returnedSession).toString().trim(),
      agentId: normalizedAgent,
    );
  }

  @override
  Future<AgentDispatchTurnResult> send({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  }) async {
    AgentDispatchTurnResult? result;
    await for (final event in sendStreaming(
      runner: runner,
      agentId: agentId,
      text: text,
      sessionId: sessionId,
      bind: bind,
      conversationReadiness: conversationReadiness,
      requireReady: requireReady,
    )) {
      if (event.kind == 'dispatch.turn.completed' ||
          event.kind == 'dispatch.turn.failed') {
        final raw = Map<String, dynamic>.from(event.payload);
        final ok = raw['ok'] == true;
        final nested = raw['error'];
        final rawCode = nested is Map
            ? (nested['code'] ?? '')
            : (raw['code'] ?? '');
        result = AgentDispatchTurnResult(
          ok: ok,
          sessionId: event.sessionId,
          turnId: event.turnId,
          status: (raw['turnStatus'] ?? raw['status'] ?? '').toString(),
          errorCode: ok ? '' : rawCode.toString(),
          errorMessage: ok
              ? ''
              : (nested is Map ? (nested['message'] ?? '') : '').toString(),
          raw: raw,
        );
      }
    }
    return result ??
        AgentDispatchTurnResult(
          ok: false,
          sessionId: sessionId.trim(),
          errorCode: 'dispatch_stream_incomplete',
          errorMessage: 'Send stream ended without a terminal turn event.',
          raw: const <String, dynamic>{
            'ok': false,
            'code': 'dispatch_stream_incomplete',
          },
        );
  }

  /// Progressive send: emits `agent.message.chunk` / completed events, then a
  /// terminal `dispatch.turn.completed` or `dispatch.turn.failed` event.
  @override
  Stream<AgentDispatchEvent> sendStreaming({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  }) async* {
    final readiness = conversationReadiness.trim().isEmpty
        ? 'unverified'
        : conversationReadiness.trim();
    if (requireReady && readiness != 'ready') {
      final code = 'native_conversation_parity_$readiness';
      yield AgentDispatchEvent(
        kind: 'dispatch.turn.failed',
        sessionId: sessionId.trim(),
        payload: <String, dynamic>{
          'ok': false,
          'code': code,
          'error': <String, dynamic>{'code': code},
          'turnStatus': 'blocked',
        },
      );
      return;
    }

    final request = <String, dynamic>{
      'agent': agentId,
      'text': text,
      'streamEvents': true,
      if (sessionId.trim().isNotEmpty) 'sessionId': sessionId.trim(),
      if (bind.sessionPath.trim().isNotEmpty)
        'sessionPath': bind.sessionPath.trim(),
      if (bind.workingDirectory.trim().isNotEmpty)
        'workingDirectory': bind.workingDirectory.trim(),
      if (bind.binaryPath.trim().isNotEmpty)
        'binaryPath': bind.binaryPath.trim(),
      if (bind.model.trim().isNotEmpty) 'model': bind.model.trim(),
      if (bind.reasoningEffort.trim().isNotEmpty)
        'reasoningEffort': bind.reasoningEffort.trim(),
      if (bind.acceptanceMode.trim().isNotEmpty)
        'acceptanceMode': bind.acceptanceMode.trim(),
    };

    await for (final line in runner.streamCliJsonLinesWithStdin([
      'agent',
      'conversation',
      'send',
      '--stdin-json',
      'true',
      '--stream-events',
      'true',
    ], jsonEncode(request))) {
      final eventName = (line['event'] ?? '').toString();
      if (eventName == 'done' ||
          (line.containsKey('ok') &&
              (eventName.isEmpty || eventName == 'done'))) {
        final returnedSession =
            (line['nativeSessionId'] ??
                    line['threadId'] ??
                    line['sessionId'] ??
                    sessionId)
                .toString()
                .trim();
        yield AgentDispatchEvent(
          kind: line['ok'] == true
              ? 'dispatch.turn.completed'
              : 'dispatch.turn.failed',
          sessionId: returnedSession,
          turnId: (line['turnId'] ?? '').toString(),
          payload: Map<String, dynamic>.from(line),
        );
        continue;
      }
      yield AgentDispatchEvent(
        kind: eventName.isEmpty ? 'dispatch.lane.event' : eventName,
        sessionId: (line['sessionId'] ?? sessionId).toString(),
        turnId: (line['turnId'] ?? '').toString(),
        payload: line['payload'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(line['payload'] as Map)
            : Map<String, dynamic>.from(line),
      );
    }
  }

  @override
  Stream<AgentDispatchEvent> stream({
    required AgentCommandRunner runner,
    required String agentId,
    required String sessionId,
    String turnId = '',
  }) async* {
    // Progressive turn echo is bound to send (--stream-events). This method
    // advertises the transport so callers share one stream API.
    yield AgentDispatchEvent(
      kind: 'dispatch.lane.bound',
      sessionId: sessionId.trim(),
      turnId: turnId.trim(),
      payload: <String, dynamic>{
        'agentId': agentId.trim(),
        'streamTransport': 'stdio_ndjson_on_send',
        'status': 'bound_on_send',
      },
    );
  }

  @override
  Future<AgentDispatchCancelResult> cancel({
    required AgentCommandRunner runner,
    required String agentId,
    required String sessionId,
    String turnId = '',
  }) async {
    final normalizedAgent = agentId.trim();
    final normalizedSession = sessionId.trim();
    if (normalizedAgent.isEmpty || normalizedSession.isEmpty) {
      return const AgentDispatchCancelResult(
        ok: false,
        status: 'unavailable',
        errorCode: 'dispatch_cancel_session_missing',
      );
    }
    try {
      final result = await runner.runCliWithStdin(
        const ['agent', 'conversation', 'cancel', '--stdin-json', 'true'],
        jsonEncode({
          'agent': normalizedAgent,
          'sessionId': normalizedSession,
          if (turnId.trim().isNotEmpty) 'turnId': turnId.trim(),
        }),
      );
      final ok = result['ok'] == true;
      final nested = result['error'];
      final code = nested is Map
          ? (nested['code'] ?? '').toString()
          : (result['code'] ?? '').toString();
      return AgentDispatchCancelResult(
        ok: ok,
        status: (result['status'] ?? '').toString(),
        errorCode: ok ? '' : (code.isEmpty ? 'dispatch_cancel_failed' : code),
      );
    } catch (_) {
      return const AgentDispatchCancelResult(
        ok: false,
        status: 'unavailable',
        errorCode: 'dispatch_cancel_failed',
      );
    }
  }

  @override
  Future<AgentDispatchCleanupResult> cleanup({
    required AgentCommandRunner runner,
    required String agentId,
    required String sessionId,
  }) async {
    final normalizedAgent = agentId.trim();
    final normalizedSession = sessionId.trim();
    if (normalizedAgent.isEmpty || normalizedSession.isEmpty) {
      return const AgentDispatchCleanupResult(
        ok: false,
        status: 'unavailable',
        errorCode: 'dispatch_cleanup_session_missing',
      );
    }
    try {
      final result = await runner.runCliWithStdin(
        const ['agent', 'conversation', 'cleanup', '--stdin-json', 'true'],
        jsonEncode({'agent': normalizedAgent, 'sessionId': normalizedSession}),
      );
      final ok = result['ok'] == true;
      final nested = result['error'];
      final code = nested is Map
          ? (nested['code'] ?? '').toString()
          : (result['code'] ?? '').toString();
      return AgentDispatchCleanupResult(
        ok: ok,
        status: (result['status'] ?? '').toString(),
        errorCode: ok ? '' : (code.isEmpty ? 'dispatch_cleanup_failed' : code),
      );
    } catch (_) {
      return const AgentDispatchCleanupResult(
        ok: false,
        status: 'unavailable',
        errorCode: 'dispatch_cleanup_failed',
      );
    }
  }

  @override
  Future<AgentDispatchCapabilities> capabilities({
    required AgentCommandRunner runner,
    required String agentId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
  }) async {
    final normalizedAgent = agentId.trim();
    final readiness = conversationReadiness.trim().isEmpty
        ? 'unverified'
        : conversationReadiness.trim();
    try {
      final result = await runner.runCliWithStdin(const [
        'agent',
        'conversation',
        'capabilities',
        '--stdin-json',
        'true',
      ], jsonEncode({'agent': normalizedAgent}));
      if (result['ok'] != true || result['capabilities'] is! Map) {
        throw const FormatException('native capabilities unavailable');
      }
      final matrix = Map<String, dynamic>.from(result['capabilities'] as Map);
      final nativeBlockers =
          (result['blockerCodes'] as List?)
              ?.whereType<String>()
              .where((code) => code.isNotEmpty)
              .toList(growable: true) ??
          <String>[];
      if (readiness != 'ready') {
        nativeBlockers.add('native_conversation_parity_$readiness');
      }
      return AgentDispatchCapabilities(
        agentId: (result['agentId'] ?? normalizedAgent).toString(),
        laneKind: (result['laneFamily'] ?? 'unavailable').toString(),
        runtimeProtocol: (result['runtimeProtocol'] ?? '').toString(),
        blockerCodes: List.unmodifiable(nativeBlockers.toSet()),
        streaming: matrix['streaming'] == true,
        approval: matrix['approvals'] == true,
        attachments: matrix['multimodal'] == true,
        interruptSteer: matrix['cancel'] == true,
        usageStatus: matrix['usageStatus'] == true,
        exactResume: matrix['exactResume'] == true,
      );
    } catch (_) {
      return AgentDispatchCapabilities(
        agentId: normalizedAgent,
        laneKind: 'unavailable',
        blockerCodes: <String>['native_capabilities_unavailable'],
      );
    }
  }

  List<AgentConversationSession> _sessionsFromOutput(
    Map<String, dynamic> output,
  ) {
    if (output['ok'] == true && output['sessions'] is List) {
      return (output['sessions'] as List)
          .whereType<Map<String, dynamic>>()
          .map(AgentConversationSession.fromJson)
          .where((session) => session.id.isNotEmpty)
          .toList();
    }
    return const [];
  }

  List<String> _paginationArgs({int? limit, int offset = 0}) {
    return [
      if (limit != null) ...['--limit', '$limit'],
      if (offset > 0) ...['--offset', '$offset'],
    ];
  }
}
