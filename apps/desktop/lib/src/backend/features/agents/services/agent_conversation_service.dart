import 'dart:convert';

import 'package:licoup/src/backend/features/agents/services/agent_conversation_archive_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';

export 'package:licoup/src/contracts/agent_conversation_models.dart';
export 'package:licoup/src/contracts/agent_dispatch_lane.dart';
export 'package:licoup/src/backend/features/agents/services/agent_conversation_archive_service.dart'
    show AgentConversationArchiveService;

/// Every dispatch opts out of a turn deadline (timeoutMs 0): the agent runs
/// until the turn completes, however long that takes.
const _unboundedDispatchTimeoutMs = 0;

Map<String, dynamic> _acceptanceDispatchFields(AgentDispatchBind bind) {
  final acceptanceMode = bind.acceptanceMode.trim();
  if (acceptanceMode.isEmpty) {
    return const {};
  }
  return {
    'acceptanceMode': acceptanceMode,
    'timeoutMs': _unboundedDispatchTimeoutMs,
  };
}

Map<String, dynamic> _bindDispatchFields(AgentDispatchBind bind) {
  return <String, dynamic>{
    if (bind.permissionMode.trim().isNotEmpty)
      'permissionMode': bind.permissionMode.trim(),
    if (bind.allowedTools.isNotEmpty)
      'allowedTools': List<String>.unmodifiable(bind.allowedTools),
    if (bind.sessionPath.trim().isNotEmpty)
      'sessionPath': bind.sessionPath.trim(),
    if (bind.workingDirectory.trim().isNotEmpty)
      'workingDirectory': bind.workingDirectory.trim(),
    if (bind.binaryPath.trim().isNotEmpty) 'binaryPath': bind.binaryPath.trim(),
    if (bind.model.trim().isNotEmpty) 'model': bind.model.trim(),
    if (bind.reasoningEffort.trim().isNotEmpty)
      'reasoningEffort': bind.reasoningEffort.trim(),
    if (bind.licoProfile.trim().isNotEmpty)
      'licoProfile': bind.licoProfile.trim(),
    if (bind.runtimeConnection.isNotEmpty)
      'runtimeConnection': bind.runtimeConnection,
  };
}

/// Backend adapter that implements the unified [AgentConversationLane] over the
/// sidecar. Conversation callers consume this contract instead of owning
/// native conversation command shapes.
class AgentConversationService implements AgentConversationLane {
  const AgentConversationService({
    AgentConversationArchiveService archiveService =
        const AgentConversationArchiveService(),
  }) : _archiveService = archiveService;

  final AgentConversationArchiveService _archiveService;

  Future<Map<String, dynamic>> previewArchiveJob({
    required AgentCommandRunner agentService,
    required String selectionMode,
    required String path,
    String query = '',
    String sourceAgentId = '',
  }) {
    return _archiveService.previewArchiveJob(
      agentService: agentService,
      selectionMode: selectionMode,
      path: path,
      query: query,
      sourceAgentId: sourceAgentId,
    );
  }

  Future<Map<String, dynamic>> createArchiveJob({
    required AgentCommandRunner agentService,
    required String selectionMode,
    required String path,
    required String planBinding,
    String query = '',
    String sourceAgentId = '',
    int? archiveParallelism,
    int maxAttempts = 2,
  }) {
    return _archiveService.createArchiveJob(
      agentService: agentService,
      selectionMode: selectionMode,
      path: path,
      planBinding: planBinding,
      query: query,
      sourceAgentId: sourceAgentId,
      archiveParallelism: archiveParallelism,
      maxAttempts: maxAttempts,
    );
  }

  Future<Map<String, dynamic>> archiveJobStatus({
    required AgentCommandRunner agentService,
    required String jobId,
  }) {
    return _archiveService.archiveJobStatus(
      agentService: agentService,
      jobId: jobId,
    );
  }

  Future<Map<String, dynamic>> archiveJobEvents({
    required AgentCommandRunner agentService,
    required String jobId,
  }) {
    return _archiveService.archiveJobEvents(
      agentService: agentService,
      jobId: jobId,
    );
  }

  Future<Map<String, dynamic>> listArchiveJobs({
    required AgentCommandRunner agentService,
  }) {
    return _archiveService.listArchiveJobs(agentService: agentService);
  }

  Future<Map<String, dynamic>> cancelArchiveJob({
    required AgentCommandRunner agentService,
    required String jobId,
  }) {
    return _archiveService.cancelArchiveJob(
      agentService: agentService,
      jobId: jobId,
    );
  }

  Future<Map<String, dynamic>> drainArchiveJobs({
    required AgentCommandRunner agentService,
    String jobId = '',
    bool once = false,
  }) {
    return _archiveService.drainArchiveJobs(
      agentService: agentService,
      jobId: jobId,
      once: once,
    );
  }

  Future<Map<String, dynamic>> collectSnapshots({
    required AgentCommandRunner agentService,
    required String topic,
    String agentId = '',
  }) {
    return _archiveService.collectSnapshots(
      agentService: agentService,
      topic: topic,
      agentId: agentId,
    );
  }

  Future<List<Map<String, dynamic>>> listSnapshotCollections({
    required AgentCommandRunner agentService,
  }) {
    return _archiveService.listSnapshotCollections(agentService: agentService);
  }

  Future<List<Map<String, dynamic>>> listArchiveProfiles({
    required AgentCommandRunner agentService,
  }) {
    return _archiveService.listArchiveProfiles(agentService: agentService);
  }

  Future<Map<String, dynamic>> runArchiveProfile({
    required AgentCommandRunner agentService,
    required String profileId,
    String trigger = 'manual',
  }) {
    return _archiveService.runArchiveProfile(
      agentService: agentService,
      profileId: profileId,
      trigger: trigger,
    );
  }

  Future<Map<String, dynamic>> verifyArchiveProfile({
    required AgentCommandRunner agentService,
    required String profileId,
  }) {
    return _archiveService.verifyArchiveProfile(
      agentService: agentService,
      profileId: profileId,
    );
  }

  Future<Map<String, dynamic>> reportArchiveProfile({
    required AgentCommandRunner agentService,
    required String profileId,
  }) {
    return _archiveService.reportArchiveProfile(
      agentService: agentService,
      profileId: profileId,
    );
  }

  Future<Map<String, dynamic>> getSnapshotRoot({
    required AgentCommandRunner agentService,
  }) {
    return _archiveService.getSnapshotRoot(agentService: agentService);
  }

  Future<Map<String, dynamic>> setSnapshotRoot({
    required AgentCommandRunner agentService,
    required String path,
  }) {
    return _archiveService.setSnapshotRoot(
      agentService: agentService,
      path: path,
    );
  }

  Future<List<AgentConversationSession>> loadSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    final arguments = ['conversations', 'list', '--agent', agentId];
    final output = bind.runtimeConnection.isNotEmpty
        ? await agentService.runCliWithStdin(
            [...arguments, '--stdin-json', 'true'],
            jsonEncode(
              _remoteHistoryRequest(
                agentId: agentId,
                sessionId: sessionId,
                limit: limit,
                offset: offset,
                bind: bind,
              ),
            ),
          )
        : await agentService.runCli([
            ...arguments,
            if (sessionId.trim().isNotEmpty) ...[
              '--session-id',
              sessionId.trim(),
            ],
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
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async* {
    final arguments = ['conversations', 'stream', '--agent', agentId];
    final events = bind.runtimeConnection.isNotEmpty
        ? agentService.streamCliJsonLinesWithStdin(
            [...arguments, '--stdin-json', 'true'],
            jsonEncode(
              _remoteHistoryRequest(
                agentId: agentId,
                sessionId: sessionId,
                limit: limit,
                offset: offset,
                bind: bind,
              ),
            ),
          )
        : agentService.streamCliJsonLines([
            ...arguments,
            if (sessionId.trim().isNotEmpty) ...[
              '--session-id',
              sessionId.trim(),
            ],
            ..._paginationArgs(limit: limit, offset: offset),
          ]);
    await for (final event in events) {
      final eventName = (event['event'] ?? '').toString();
      if ((eventName == 'session' || eventName == 'session-preview') &&
          event['session'] is Map<String, dynamic>) {
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
        ..._bindDispatchFields(bind),
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
  }) async {
    AgentDispatchTurnResult? result;
    await for (final event in sendStreaming(
      runner: runner,
      agentId: agentId,
      text: text,
      sessionId: sessionId,
      bind: bind,
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
          failureCode: ok ? '' : rawCode.toString(),
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
          failureCode: 'dispatch_stream_incomplete',
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
  }) async* {
    final request = <String, dynamic>{
      'agent': agentId,
      'text': text,
      'streamEvents': true,
      'timeoutMs': _unboundedDispatchTimeoutMs,
      if (sessionId.trim().isNotEmpty) 'sessionId': sessionId.trim(),
      ..._bindDispatchFields(bind),
      ..._acceptanceDispatchFields(bind),
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

  Future<AgentDispatchTurnResult> steer({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    required String turnId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    final normalizedAgent = agentId.trim();
    final normalizedText = text.trim();
    final normalizedSession = sessionId.trim();
    final normalizedTurn = turnId.trim();
    if (normalizedAgent.isEmpty ||
        normalizedText.isEmpty ||
        normalizedSession.isEmpty ||
        normalizedTurn.isEmpty) {
      return AgentDispatchTurnResult(
        ok: false,
        sessionId: normalizedSession,
        status: 'invalid',
        failureCode: 'dispatch_steer_input_required',
      );
    }
    try {
      final result = await runner.runCliWithStdin(
        const ['agent', 'conversation', 'steer', '--stdin-json', 'true'],
        jsonEncode(<String, dynamic>{
          'agent': normalizedAgent,
          'text': normalizedText,
          'sessionId': normalizedSession,
          'turnId': normalizedTurn,
          ..._bindDispatchFields(bind),
        }),
      );
      final ok = result['ok'] == true;
      final nested = result['error'];
      final code = nested is Map
          ? (nested['code'] ?? '').toString()
          : (result['code'] ?? '').toString();
      return AgentDispatchTurnResult(
        ok: ok,
        sessionId: (result['nativeSessionId'] ?? normalizedSession)
            .toString()
            .trim(),
        turnId: (result['turnId'] ?? '').toString().trim(),
        status: (result['status'] ?? '').toString(),
        failureCode: ok ? '' : (code.isEmpty ? 'dispatch_steer_failed' : code),
        raw: Map<String, dynamic>.from(result),
      );
    } catch (_) {
      return AgentDispatchTurnResult(
        ok: false,
        sessionId: normalizedSession,
        status: 'outcome_unknown',
        failureCode: 'dispatch_steer_outcome_unknown',
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
        failureCode: 'dispatch_cancel_session_missing',
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
        failureCode: ok ? '' : (code.isEmpty ? 'dispatch_cancel_failed' : code),
      );
    } catch (_) {
      return const AgentDispatchCancelResult(
        ok: false,
        status: 'unavailable',
        failureCode: 'dispatch_cancel_failed',
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
        failureCode: 'dispatch_cleanup_session_missing',
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
        failureCode: ok
            ? ''
            : (code.isEmpty ? 'dispatch_cleanup_failed' : code),
      );
    } catch (_) {
      return const AgentDispatchCleanupResult(
        ok: false,
        status: 'unavailable',
        failureCode: 'dispatch_cleanup_failed',
      );
    }
  }

  @override
  Future<AgentDispatchCapabilities> capabilities({
    required AgentCommandRunner runner,
    required String agentId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    final normalizedAgent = agentId.trim();
    try {
      final result = await runner.runCliWithStdin(
        const ['agent', 'conversation', 'capabilities', '--stdin-json', 'true'],
        jsonEncode({
          'agent': normalizedAgent,
          if (bind.runtimeConnection.isNotEmpty)
            'runtimeConnection': bind.runtimeConnection,
        }),
      );
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
      return AgentDispatchCapabilities(
        agentId: (result['agentId'] ?? normalizedAgent).toString(),
        laneKind: (result['laneFamily'] ?? 'unavailable').toString(),
        runtimeProtocol: (result['runtimeProtocol'] ?? '').toString(),
        blockerCodes: List.unmodifiable(nativeBlockers.toSet()),
        streaming: matrix['streaming'] == true,
        approval: matrix['approvals'] == true,
        attachments: matrix['multimodal'] == true,
        interruptSteer: matrix['interruptSteer'] == true,
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

  Map<String, dynamic> _remoteHistoryRequest({
    required String agentId,
    required String sessionId,
    required int? limit,
    required int offset,
    required AgentDispatchBind bind,
  }) {
    return <String, dynamic>{
      'agent': agentId,
      if (sessionId.trim().isNotEmpty) 'sessionId': sessionId.trim(),
      'limit': ?limit,
      if (offset > 0) 'offset': offset,
      if (bind.workingDirectory.trim().isNotEmpty)
        'workingDirectory': bind.workingDirectory.trim(),
      'runtimeConnection': bind.runtimeConnection,
    };
  }
}
