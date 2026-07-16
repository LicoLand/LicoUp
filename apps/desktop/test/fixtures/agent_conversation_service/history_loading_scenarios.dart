import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void registerAgentConversationHistoryLoadingScenarios() {
  test(
    'loads native agent histories through lico-client conversations list',
    () async {
      final captured = <List<String>>[];
      final agentService = AgentService(
        runCliExecutable: (executable, args, env) async {
          captured.add(List<String>.from(args));
          if (args[1] == 'list') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'sessions': [
                  _sessionJson('session-1', 'Summarize this local repo.'),
                ],
              }),
              '',
            );
          }
          return ProcessResult(0, 0, jsonEncode({'ok': true}), '');
        },
      );
      const service = AgentConversationService();

      final sessions = await service.loadSessions(
        agentService: agentService,
        agentId: 'codex',
      );

      expect(sessions, hasLength(1));
      expect(sessions.single.agentId, 'codex');
      expect(sessions.single.native, isTrue);
      expect(sessions.single.readOnly, isTrue);
      expect(sessions.single.adapterId, 'codex');
      expect(sessions.single.nativeSessionId, 'codex-session-1');
      expect(sessions.single.sourceKind, 'codex-session-store');
      expect(sessions.single.importMode, 'precise-adapter');
      expect(sessions.single.sourceTool, 'codex');
      expect(sessions.single.sourcePath, '/tmp/codex/history.jsonl');
      expect(sessions.single.messageCount, 2);
      expect(captured.single, ['conversations', 'list', '--agent', 'codex']);
    },
  );

  test('passes pagination arguments to native history list command', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({'ok': true, 'sessions': []}),
          '',
        );
      },
    );
    const service = AgentConversationService();

    await service.loadSessions(
      agentService: agentService,
      agentId: 'codex',
      limit: 50,
      offset: 100,
    );

    expect(captured.single, [
      'conversations',
      'list',
      '--agent',
      'codex',
      '--limit',
      '50',
      '--offset',
      '100',
    ]);
  });

  test(
    'streams native agent histories through lico-client conversations stream',
    () async {
      final agentService = _StreamingAgentService([
        {
          'event': 'session',
          'ok': true,
          'session': _sessionJson('session-1', 'Stream native history.'),
        },
        {'event': 'done', 'ok': true},
      ]);
      const service = AgentConversationService();

      final sessions = await service
          .streamSessions(agentService: agentService, agentId: 'codex')
          .toList();

      expect(sessions, hasLength(1));
      expect(sessions.single.title, 'Stream native history.');
      expect(agentService.captured.single, [
        'conversations',
        'stream',
        '--agent',
        'codex',
      ]);
    },
  );

  test(
    'passes pagination arguments to native history stream command',
    () async {
      final agentService = _StreamingAgentService([
        {'event': 'done', 'ok': true},
      ]);
      const service = AgentConversationService();

      await service
          .streamSessions(
            agentService: agentService,
            agentId: 'codex',
            limit: 51,
            offset: 50,
          )
          .toList();

      expect(agentService.captured.single, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '51',
        '--offset',
        '50',
      ]);
    },
  );

  test(
    'passes exact session identity to native history stream command',
    () async {
      final agentService = _StreamingAgentService([
        {'event': 'done', 'ok': true},
      ]);
      const service = AgentConversationService();

      await service
          .streamSessions(
            agentService: agentService,
            agentId: 'codex',
            sessionId: 'projection-session-1',
            limit: 1,
          )
          .toList();

      expect(agentService.captured.single, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--session-id',
        'projection-session-1',
        '--limit',
        '1',
      ]);
    },
  );
}

void main() => registerAgentConversationHistoryLoadingScenarios();

Map<String, dynamic> _sessionJson(String id, String text) {
  return {
    'id': id,
    'agentId': 'codex',
    'title': text,
    'createdAt': '2026-06-12T00:00:00Z',
    'updatedAt': '2026-06-12T00:00:01Z',
    'adapterId': 'codex',
    'nativeSessionId': 'codex-session-1',
    'sourceKind': 'codex-session-store',
    'importMode': 'precise-adapter',
    'sourceTool': 'codex',
    'sourcePath': '/tmp/codex/history.jsonl',
    'native': true,
    'readOnly': true,
    'messageCount': 2,
    'messages': [
      {
        'id': 'msg-1',
        'role': 'user',
        'text': text,
        'createdAt': '2026-06-12T00:00:00Z',
      },
      {
        'id': 'msg-2',
        'role': 'agent',
        'text': '本机展示',
        'createdAt': '2026-06-12T00:00:01Z',
      },
    ],
  };
}

class _StreamingAgentService extends AgentService {
  _StreamingAgentService(this.events);

  final List<Map<String, dynamic>> events;
  final List<List<String>> captured = [];

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) async* {
    captured.add(List<String>.from(args));
    for (final event in events) {
      yield event;
    }
  }
}
