import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void registerAgentConversationHistoryLoadingScenarios() {
  test(
    'loads native agent histories through licoup conversations list',
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
      expect(sessions.single.sourcePath, 'test-data/codex/history.jsonl');
      expect(sessions.single.messageCount, 2);
      expect(captured.single, ['conversations', 'list', '--agent', 'codex']);
    },
  );

  test(
    'VM history queries keep connection and session identity on stdin',
    () async {
      final runner = _PrivateHistoryRunner();
      const service = AgentConversationService();
      final workingDirectory = _guestPath(['srv', 'project']);
      final bind = AgentDispatchBind(
        workingDirectory: workingDirectory,
        runtimeConnection: {
          'kind': 'ssh',
          'host': 'vm.example',
          'remoteExecutable': 'openclaw',
          'workingDirectory': workingDirectory,
        },
      );

      await service.loadSessions(
        agentService: runner,
        agentId: 'openclaw',
        sessionId: 'remote-session-1',
        limit: 1,
        bind: bind,
      );
      await service
          .streamSessions(
            agentService: runner,
            agentId: 'openclaw',
            sessionId: 'remote-session-1',
            limit: 1,
            bind: bind,
          )
          .toList();

      expect(runner.arguments, hasLength(2));
      for (final arguments in runner.arguments) {
        expect(arguments, containsAll(['--stdin-json', 'true']));
        expect(arguments.join(' '), isNot(contains('vm.example')));
        expect(arguments.join(' '), isNot(contains('remote-session-1')));
      }
      for (final stdin in runner.stdin) {
        final payload = jsonDecode(stdin) as Map<String, dynamic>;
        expect(payload['sessionId'], 'remote-session-1');
        expect(
          (payload['runtimeConnection'] as Map<String, dynamic>)['host'],
          'vm.example',
        );
      }
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
    'streams native agent histories through licoup conversations stream',
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

  test('projects progressive native history preview frames', () async {
    final agentService = _StreamingAgentService([
      {
        'event': 'session-preview',
        'ok': true,
        'milestone': 3,
        'session': _sessionJson('session-preview-1', 'Preview native history.'),
      },
      {'event': 'done', 'ok': true},
    ]);
    const service = AgentConversationService();

    final sessions = await service
        .streamSessions(agentService: agentService, agentId: 'codex')
        .toList();

    expect(sessions, hasLength(1));
    expect(sessions.single.title, 'Preview native history.');
  });

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

String _guestPath(List<String> segments) => ['', ...segments].join('/');

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
    'sourcePath': 'test-data/codex/history.jsonl',
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

class _PrivateHistoryRunner implements AgentCommandRunner {
  final List<List<String>> arguments = [];
  final List<String> stdin = [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnsupportedError('public argv transport is not expected');

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    arguments.add(List<String>.unmodifiable(args));
    stdin.add(stdinText);
    return const {'ok': true, 'sessions': <Map<String, dynamic>>[]};
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      throw UnsupportedError('public argv transport is not expected');

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    arguments.add(List<String>.unmodifiable(args));
    stdin.add(stdinText);
    yield const {'event': 'done', 'ok': true};
  }
}
