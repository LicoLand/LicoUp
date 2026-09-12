import 'dart:convert';

import 'package:licoup/src/backend/features/agents/services/agent_conversation_archive_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';

export 'package:licoup/src/contracts/agent_conversation_models.dart';
export 'package:licoup/src/contracts/agent_dispatch_lane.dart';
export 'package:licoup/src/backend/features/agents/services/agent_conversation_archive_service.dart'
    show AgentConversationArchiveService;

/// Backend adapter that implements the unified [AgentConversationLane] over the
/// sidecar. Conversation callers consume this contract instead of owning
/// native conversation command shapes.
class AgentConversationService implements AgentConversationLane {
  const AgentConversationService({
    AgentConversationNativePort? native,
    AgentConversationArchiveService archiveService =
        const AgentConversationArchiveService(),
  }) : _native = native,
       _archiveService = archiveService;

  final AgentConversationArchiveService _archiveService;
  final AgentConversationNativePort? _native;

  AgentConversationNativePort get _conversation =>
      _native ??
      (throw const NativeConversationException(
        'conversation_native_unavailable',
      ));

  Future<List<Map<String, dynamic>>> activeTurns({
    required String agentId,
    String sessionId = '',
    String conversationId = '',
    Duration waitForChange = Duration.zero,
  }) async {
    final output = await _conversation.active(
      agentId: agentId,
      sessionId: sessionId,
      conversationId: conversationId,
      waitForChange: waitForChange,
    );
    final turns = output['turns'];
    if (turns is! List) return const [];
    return [
      for (final turn in turns)
        if (turn is Map) Map<String, dynamic>.from(turn),
    ];
  }

  Stream<AgentDispatchEvent> attachActiveTurn({
    required String turnHandle,
    required String conversationId,
    int afterCursor = 0,
  }) async* {
    await for (final line in _conversation.attach(
      PersistentConversationTurnScope(
        turnHandle: turnHandle,
        conversationId: conversationId,
      ),
      afterCursor: afterCursor,
    )) {
      final eventName = (line['event'] ?? '').toString();
      if (eventName == 'done' ||
          (line.containsKey('ok') &&
              (eventName.isEmpty || eventName == 'done'))) {
        final payload = Map<String, dynamic>.from(line);
        if (line['ok'] != true && payload['terminalTransition'] is! Map) {
          final nested = line['error'];
          final error = nested is Map
              ? Map<String, dynamic>.from(nested)
              : const <String, dynamic>{};
          final code = (error['code'] ?? 'conversation_dispatch_failed')
              .toString()
              .trim();
          final stage = (error['stage'] ?? 'conversation/dispatch')
              .toString()
              .trim();
          payload['terminalTransition'] = <String, dynamic>{
            'kind': 'failed',
            'code': code.isEmpty ? 'conversation_dispatch_failed' : code,
            'stage': stage.isEmpty ? 'conversation/dispatch' : stage,
          };
        }
        yield AgentDispatchEvent(
          kind: line['ok'] == true
              ? 'dispatch.turn.completed'
              : 'dispatch.turn.failed',
          sessionId: (line['nativeSessionId'] ?? line['sessionId'] ?? '')
              .toString(),
          turnId: (line['turnId'] ?? '').toString(),
          payload: payload,
        );
        continue;
      }
      yield AgentDispatchEvent(
        kind: eventName.isEmpty ? 'dispatch.lane.event' : eventName,
        sessionId: (line['sessionId'] ?? '').toString(),
        turnId: (line['turnId'] ?? '').toString(),
        payload: line['payload'] is Map<String, dynamic>
            ? <String, dynamic>{
                ...Map<String, dynamic>.from(line['payload'] as Map),
                'cursor': line['cursor'],
                'turnHandle': line['turnHandle'],
                'conversationId': line['conversationId'],
              }
            : Map<String, dynamic>.from(line),
      );
    }
  }

  Future<AgentDispatchTurnResult> steerActiveTurn({
    required String turnHandle,
    required String conversationId,
    required String text,
  }) async {
    final handle = turnHandle.trim();
    final scope = conversationId.trim();
    final guidance = text.trim();
    if (handle.isEmpty || scope.isEmpty || guidance.isEmpty) {
      return const AgentDispatchTurnResult(
        ok: false,
        failureCode: 'dispatch_steer_input_required',
      );
    }
    try {
      final result = await _conversation.steer(
        PersistentConversationTurnScope(
          turnHandle: handle,
          conversationId: scope,
        ),
        text: guidance,
      );
      final ok = result['ok'] == true;
      final nested = result['error'];
      final code = nested is Map
          ? (nested['code'] ?? '').toString()
          : (result['code'] ?? '').toString();
      return AgentDispatchTurnResult(
        ok: ok,
        sessionId: (result['nativeSessionId'] ?? result['sessionId'] ?? '')
            .toString(),
        turnId: (result['turnId'] ?? '').toString(),
        status: (result['status'] ?? '').toString(),
        failureCode: ok ? '' : (code.isEmpty ? 'dispatch_steer_failed' : code),
        raw: Map<String, dynamic>.from(result),
      );
    } on Object {
      return const AgentDispatchTurnResult(
        ok: false,
        status: 'outcome_unknown',
        failureCode: 'dispatch_steer_outcome_unknown',
      );
    }
  }

  Future<AgentDispatchCancelResult> cancelActiveTurn({
    required String turnHandle,
    required String conversationId,
  }) async {
    final handle = turnHandle.trim();
    final scope = conversationId.trim();
    if (handle.isEmpty || scope.isEmpty) {
      return const AgentDispatchCancelResult(
        ok: false,
        status: 'unavailable',
        failureCode: 'dispatch_cancel_scope_missing',
      );
    }
    try {
      final result = await _conversation.cancel(
        PersistentConversationTurnScope(
          turnHandle: handle,
          conversationId: scope,
        ),
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
    } on Object {
      return const AgentDispatchCancelResult(
        ok: false,
        status: 'unavailable',
        failureCode: 'dispatch_cancel_failed',
      );
    }
  }

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
  }) => _loadSessions(
    agentService: agentService,
    agentId: agentId,
    sessionId: sessionId,
    limit: limit,
    offset: offset,
    bind: bind,
  );

  Future<List<AgentConversationSession>> loadSessionMessagePage({
    required AgentCommandRunner agentService,
    required String agentId,
    required String sessionId,
    String messageBefore = '',
    required int messageLimit,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _loadSessions(
    agentService: agentService,
    agentId: agentId,
    sessionId: sessionId,
    limit: 1,
    messageBefore: messageBefore,
    messageLimit: messageLimit,
    bind: bind,
  );

  Future<List<AgentConversationSession>> _loadSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    String messageBefore = '',
    int? messageLimit,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    final arguments = ['conversations', 'list', '--agent', agentId];
    final output = bind.runtimeConnection.isNotEmpty || messageLimit != null
        ? await agentService.runCliWithStdin(
            [...arguments, '--stdin-json', 'true'],
            jsonEncode(
              _remoteHistoryRequest(
                agentId: agentId,
                sessionId: sessionId,
                limit: limit,
                offset: offset,
                messageBefore: messageBefore,
                messageLimit: messageLimit,
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
            ..._messagePaginationArgs(
              messageBefore: messageBefore,
              messageLimit: messageLimit,
            ),
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
  }) => _streamSessions(
    agentService: agentService,
    agentId: agentId,
    sessionId: sessionId,
    limit: limit,
    offset: offset,
    bind: bind,
  );

  Stream<AgentConversationSession> streamSessionMessagePage({
    required AgentCommandRunner agentService,
    required String agentId,
    required String sessionId,
    String messageBefore = '',
    required int messageLimit,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _streamSessions(
    agentService: agentService,
    agentId: agentId,
    sessionId: sessionId,
    limit: 1,
    messageBefore: messageBefore,
    messageLimit: messageLimit,
    bind: bind,
  );

  Stream<AgentConversationSession> _streamSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    String messageBefore = '',
    int? messageLimit,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async* {
    final arguments = ['conversations', 'stream', '--agent', agentId];
    final events = bind.runtimeConnection.isNotEmpty || messageLimit != null
        ? agentService.streamCliJsonLinesWithStdin(
            [...arguments, '--stdin-json', 'true'],
            jsonEncode(
              _remoteHistoryRequest(
                agentId: agentId,
                sessionId: sessionId,
                limit: limit,
                offset: offset,
                messageBefore: messageBefore,
                messageLimit: messageLimit,
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
            ..._messagePaginationArgs(
              messageBefore: messageBefore,
              messageLimit: messageLimit,
            ),
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
    required String agentId,
    String sessionId = '',
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    final normalizedAgent = agentId.trim();
    final normalizedSession = sessionId.trim();
    if (normalizedAgent.isEmpty) {
      throw const AgentDispatchOpenException('agent_id_required');
    }
    final result = await _conversation.open(
      AgentConversationSessionScope(
        agentId: normalizedAgent,
        sessionId: normalizedSession,
      ),
      bind: bind,
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
    required String agentId,
    required String text,
    required String sessionId,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    AgentDispatchTurnResult? result;
    await for (final event in sendStreaming(
      agentId: agentId,
      text: text,
      sessionId: sessionId,
      attachments: attachments,
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
    required String agentId,
    required String text,
    required String sessionId,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async* {
    var streamSessionId = sessionId.trim();

    await for (final line in _conversation.send(
      AgentConversationSessionScope(agentId: agentId, sessionId: sessionId),
      text: text,
      attachments: attachments,
      bind: bind,
    )) {
      final eventName = (line['event'] ?? '').toString();
      final lineSession = (line['sessionId'] ?? '').toString().trim();
      // One native stream is one native turn: the first frame that declares
      // the session binds it, and later frames that omit identity (driver
      // chunk events) inherit the stream scope instead of fragmenting the
      // projection across the requested session id.
      if (lineSession.isNotEmpty) {
        streamSessionId = lineSession;
      }
      if (eventName == 'done' ||
          (line.containsKey('ok') &&
              (eventName.isEmpty || eventName == 'done'))) {
        final returnedSession =
            (line['nativeSessionId'] ??
                    line['threadId'] ??
                    line['sessionId'] ??
                    streamSessionId)
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
        sessionId: streamSessionId.isEmpty
            ? sessionId
            : (line['sessionId'] ?? streamSessionId).toString(),
        turnId: (line['turnId'] ?? '').toString(),
        payload: line['payload'] is Map<String, dynamic>
            ? <String, dynamic>{
                ...Map<String, dynamic>.from(line['payload'] as Map),
                if (line['turnHandle'] != null)
                  'turnHandle': line['turnHandle'],
                if (line['conversationId'] != null)
                  'conversationId': line['conversationId'],
                if (line['cursor'] != null) 'cursor': line['cursor'],
              }
            : Map<String, dynamic>.from(line),
      );
    }
  }

  Future<AgentDispatchTurnResult> steer({
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
      final result = await _conversation.steer(
        AgentSessionTurnScope(
          session: AgentConversationSessionScope(
            agentId: normalizedAgent,
            sessionId: normalizedSession,
          ),
          turnId: normalizedTurn,
        ),
        text: normalizedText,
        bind: bind,
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
  Future<AgentDispatchCancelResult> cancel({
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
      final result = await _conversation.cancel(
        AgentSessionTurnScope(
          session: AgentConversationSessionScope(
            agentId: normalizedAgent,
            sessionId: normalizedSession,
          ),
          turnId: turnId,
        ),
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
      final result = await _conversation.cleanup(
        AgentConversationSessionScope(
          agentId: normalizedAgent,
          sessionId: normalizedSession,
        ),
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
    required String agentId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    final normalizedAgent = agentId.trim();
    try {
      final result = await _conversation.capabilities(
        normalizedAgent,
        bind: bind,
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
    final error = output['error'];
    final code = error is Map
        ? (error['code'] ?? 'native_history_load_failed').toString()
        : (output['code'] ?? 'native_history_load_failed').toString();
    throw FormatException(code);
  }

  List<String> _paginationArgs({int? limit, int offset = 0}) {
    return [
      if (limit != null) ...['--limit', '$limit'],
      if (offset > 0) ...['--offset', '$offset'],
    ];
  }

  List<String> _messagePaginationArgs({
    required String messageBefore,
    required int? messageLimit,
  }) {
    return [
      if (messageBefore.trim().isNotEmpty) ...[
        '--message-before',
        messageBefore.trim(),
      ],
      if (messageLimit != null) ...['--message-limit', '$messageLimit'],
    ];
  }

  Map<String, dynamic> _remoteHistoryRequest({
    required String agentId,
    required String sessionId,
    required int? limit,
    required int offset,
    required String messageBefore,
    required int? messageLimit,
    required AgentDispatchBind bind,
  }) {
    return <String, dynamic>{
      'agent': agentId,
      if (sessionId.trim().isNotEmpty) 'sessionId': sessionId.trim(),
      'limit': ?limit,
      if (offset > 0) 'offset': offset,
      if (messageBefore.trim().isNotEmpty)
        'messageBefore': messageBefore.trim(),
      'messageLimit': ?messageLimit,
      if (bind.workingDirectory.trim().isNotEmpty)
        'workingDirectory': bind.workingDirectory.trim(),
      // An empty connection map is still a non-null JSON value; sending it
      // would route a local exact-page read into the remote VM history path.
      if (bind.runtimeConnection.isNotEmpty)
        'runtimeConnection': bind.runtimeConnection,
    };
  }
}
