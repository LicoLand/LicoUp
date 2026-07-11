import 'dart:convert';

import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';

export 'package:flutter_client/src/contracts/agent_conversation_models.dart';
export 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';

part 'agent_conversation_archive_service.dart';

/// Backend adapter that implements the unified [AgentDispatchLane] over the
/// sidecar. Conversation callers must use this lane; they must not invoke
/// `runCliWithStdin(['agent','message','send',…])` directly.
class AgentConversationService implements AgentDispatchLane {
  const AgentConversationService();

  Future<List<AgentConversationSession>> loadSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    int? limit,
    int offset = 0,
  }) async {
    final output = await agentService.runCli([
      'conversations',
      'list',
      '--agent',
      agentId,
      ..._paginationArgs(limit: limit, offset: offset),
    ]);
    return _sessionsFromOutput(output);
  }

  Stream<AgentConversationSession> streamSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    int? limit,
    int offset = 0,
  }) async* {
    await for (final event in agentService.streamCliJsonLines([
      'conversations',
      'stream',
      '--agent',
      agentId,
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
      return const AgentDispatchSession(sessionId: '');
    }
    // Session bind is owned by the sidecar on first send when sessionId is
    // empty (create) or non-empty (exact resume). This method records the
    // caller intent without a parallel protocol fork.
    return AgentDispatchSession(
      sessionId: normalizedSession,
      threadId: normalizedSession,
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
    final readiness = conversationReadiness.trim().isEmpty
        ? 'unverified'
        : conversationReadiness.trim();
    if (requireReady && readiness != 'ready') {
      final code = 'native_conversation_parity_$readiness';
      return AgentDispatchTurnResult(
        ok: false,
        sessionId: sessionId.trim(),
        errorCode: code,
        errorMessage: 'Send blocked: adapter readiness is $readiness.',
        raw: <String, dynamic>{
          'ok': false,
          'code': code,
          'error': <String, dynamic>{'code': code},
        },
      );
    }

    final request = <String, dynamic>{
      'agent': agentId,
      'text': text,
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
    };
    final output = await runner.runCliWithStdin([
      'agent',
      'message',
      'send',
      '--stdin-json',
      'true',
    ], jsonEncode(request));
    final ok = output['ok'] == true;
    final returnedSession = (output['nativeSessionId'] ??
            output['threadId'] ??
            output['sessionId'] ??
            sessionId)
        .toString()
        .trim();
    final nested = output['error'];
    final rawCode = nested is Map
        ? (nested['code'] ?? '')
        : (output['code'] ?? '');
    return AgentDispatchTurnResult(
      ok: ok,
      sessionId: returnedSession,
      turnId: (output['turnId'] ?? '').toString(),
      status: (output['turnStatus'] ?? output['status'] ?? '').toString(),
      errorCode: ok ? '' : rawCode.toString(),
      errorMessage: ok
          ? ''
          : (nested is Map ? (nested['message'] ?? '') : '').toString(),
      raw: Map<String, dynamic>.from(output),
    );
  }

  @override
  Stream<AgentDispatchEvent> stream({
    required AgentCommandRunner runner,
    required String agentId,
    required String sessionId,
    String turnId = '',
  }) async* {
    // Until native `agent.conversation.stream` RPC lands, surface a bounded
    // lane lifecycle event so callers share one stream API without forking.
    yield AgentDispatchEvent(
      kind: 'dispatch.lane.bound',
      sessionId: sessionId.trim(),
      turnId: turnId.trim(),
      payload: <String, dynamic>{
        'agentId': agentId.trim(),
        'streamTransport': 'pending_stdio_rpc',
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
    // Cancel becomes a first-class sidecar RPC in the Rust lane node. Until
    // then, fail closed with an actionable code instead of process-kill from UI.
    return AgentDispatchCancelResult(
      ok: false,
      status: 'unavailable',
      errorCode: 'dispatch_cancel_pending_rpc',
    );
  }

  @override
  Future<AgentDispatchCapabilities> capabilities({
    required AgentCommandRunner runner,
    required String agentId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
  }) async {
    final readiness = conversationReadiness.trim().isEmpty
        ? 'unverified'
        : conversationReadiness.trim();
    final ready = readiness == 'ready';
    return AgentDispatchCapabilities(
      agentId: agentId.trim(),
      laneKind: ready ? 'official-local' : 'fail-closed',
      runtimeProtocol: '',
      blockerCodes: ready
          ? const <String>[]
          : <String>['native_conversation_parity_$readiness'],
      streaming: ready,
      exactResume: ready,
    );
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
