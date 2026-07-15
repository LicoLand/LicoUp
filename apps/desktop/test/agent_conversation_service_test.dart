import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('filters background instruction blocks from visible conversations', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-context',
      'agentId': 'codex',
      'title':
          '<apps_instructions>\n# Apps (Connectors)\nDo not show this.\n</appsinstructions>',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:01Z',
      'messages': [
        {
          'id': 'msg-context',
          'role': 'user',
          'text':
              '<apps_instructions>\n# Apps (Connectors)\nConnector instructions.\n</appsinstructions>',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-system',
          'role': 'system',
          'text': 'You are Codex, a coding agent.',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-user',
          'role': 'user',
          'text':
              '# Files mentioned by the user:\n\n## clip.png: ${['', 'private', 'tmp', 'clip.png'].join('/')}\n\n## My request for Codex:\n真正的用户问题\n<image name=[Image #1] path="${['', 'private', 'tmp', 'clip.png'].join('/')}">\nprivate image metadata\n</image>',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': '真正的回答',
          'createdAt': '2026-06-12T00:00:02Z',
        },
      ],
    });

    expect(session.title, '真正的用户问题');
    expect(session.messageCount, 2);
    expect(session.messages.map((message) => message.text), [
      '真正的用户问题',
      '真正的回答',
    ]);
    expect(
      session.messages.any(
        (message) =>
            message.text.contains('Apps (Connectors)') ||
            message.text.contains(
              ['', 'private', 'tmp', 'clip.png'].join('/'),
            ) ||
            message.text.contains('You are Codex'),
      ),
      isFalse,
    );
  });

  test('decodes Antigravity protocol wrappers from native history', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-antigravity-protocol',
      'agentId': 'antigravity',
      'adapterId': 'antigravity',
      'sourceClient': 'antigravity',
      'hostApp': 'antigravity',
      'title': '<USER_REQUEST> 请找到本项目的开发规则文档入口 </USER_REQUEST>',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:03Z',
      'messages': [
        {
          'id': 'msg-user',
          'role': 'user',
          'text': '''
<SYSTEM_MESSAGE>
Hidden Antigravity runtime context.
</SYSTEM_MESSAGE>
<USER_REQUEST>请找到本项目的开发规则文档入口</USER_REQUEST>''',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-system-boilerplate',
          'role': 'agent',
          'text':
              'The following is a <SYSTEM_MESSAGE> not actually sent by the user. It is provided by the system as important information to pay attention to.',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-file-view',
          'role': 'view_file',
          'text': '''
2255 │ "coverageContribution": false,
2256 │ "artifacts": [],
2257 │ "command": "npm"
2258 │ "args": [
2259 │   "run",
2260 │   "verify"
2261 │ ]''',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-command',
          'role': 'run_command',
          'text': 'npm run verify\nPASS 133 tests',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-agent',
          'role': 'planner_response',
          'text': '开发规则入口在仓库根目录的 AGENTS.md。',
          'createdAt': '2026-06-12T00:00:02Z',
        },
      ],
    });

    expect(session.title, '请找到本项目的开发规则文档入口');
    expect(session.messageCount, 4);
    expect(session.messages[0].text, '请找到本项目的开发规则文档入口');
    expect(session.messages[1].kind, AgentConversationMessageKind.toolCall);
    expect(session.messages[1].cardTitle, 'Tool call');
    expect(session.messages[2].kind, AgentConversationMessageKind.toolCall);
    expect(session.messages[3].text, '开发规则入口在仓库根目录的 AGENTS.md。');
    expect(
      session.messages.any(
        (message) =>
            message.text.contains('<USER_REQUEST>') ||
            message.text.contains('<SYSTEM_MESSAGE>') ||
            message.text.contains('not actually sent by the user') ||
            message.text.contains('coverageContribution') ||
            message.text.contains('npm run verify') ||
            message.text.contains('2255'),
      ),
      isFalse,
    );
  });

  test('filters generated classifier notices from user messages', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-classifier-notice',
      'agentId': 'codex',
      'title':
          'deepseek-v4-pro[1m] is temporarily unavailable, so auto mode cannot determine the safety of Bash right now.',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:03Z',
      'messages': [
        {
          'id': 'msg-user-notice',
          'role': 'user',
          'text': '''
deepseek-v4-pro[1m] is temporarily unavailable, so auto mode cannot determine the safety of Bash right now. Wait briefly and then try this action again. If it keeps failing, continue with other tasks that don't require this action and come back to it later. Note: reading files, searching code, and other read-only operations do not require the classifier and can still be used.''',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-user-real',
          'role': 'user',
          'text': '帮我运行完整验证',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': '我会继续验证。',
          'createdAt': '2026-06-12T00:00:02Z',
        },
      ],
    });

    expect(session.title, '帮我运行完整验证');
    expect(session.messageCount, 2);
    expect(session.messages.map((message) => message.text), [
      '帮我运行完整验证',
      '我会继续验证。',
    ]);
    expect(
      session.messages.any(
        (message) =>
            message.text.contains('deepseek-v4-pro') ||
            message.text.contains('classifier'),
      ),
      isFalse,
    );
  });

  test('keeps unmarked reasoning redacted as a structured event', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-reasoning',
      'agentId': 'codex',
      'title': 'Inspect the implementation',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:02Z',
      'messages': [
        {
          'id': 'msg-user',
          'role': 'user',
          'text': 'Inspect the implementation',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-reasoning',
          'role': 'reasoning',
          'text': 'Private chain of thought must not become assistant text.',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': 'Visible final answer',
          'createdAt': '2026-06-12T00:00:02Z',
        },
      ],
    });

    expect(session.messages, hasLength(3));
    expect(session.messages[0].text, 'Inspect the implementation');
    expect(session.messages[1].kind, AgentConversationMessageKind.reasoning);
    expect(session.messages[1].cardType, 'reasoning');
    expect(session.messages[1].cardTitle, 'Reasoning');
    expect(session.messages[1].collapsed, isTrue);
    expect(session.messages[1].providerSummary, isFalse);
    expect(session.messages[1].text, isEmpty);
    expect(
      session.messages[1].text,
      isNot(contains('Private chain of thought')),
    );
    expect(session.messages[2].text, 'Visible final answer');
  });

  test('shows only explicit safe provider reasoning summaries', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-reasoning-summary',
      'agentId': 'codex',
      'title': 'Inspect the implementation',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:03Z',
      'messages': [
        {
          'id': 'msg-summary',
          'role': 'reasoning',
          'providerSummary': true,
          'text':
              'Inspected ${['', 'workspace', 'private', 'source.rs'].join('/')} and confirmed cleanup; api_key=${['fixture', 'value'].join('-')}.',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-raw-json',
          'role': 'reasoning',
          'providerSummary': true,
          'text': '{"summary":"must not render raw JSON"}',
          'createdAt': '2026-06-12T00:00:02Z',
        },
        {
          'id': 'msg-reasoning-trace',
          'role': 'reasoning',
          'providerSummary': true,
          'text': 'Chain of thought: private intermediate reasoning.',
          'createdAt': '2026-06-12T00:00:03Z',
        },
      ],
    });

    expect(session.messages, hasLength(3));
    expect(session.messages[0].providerSummary, isTrue);
    expect(session.messages[0].text, contains('Inspected [local path hidden]'));
    expect(session.messages[0].text, contains('api_key: [redacted]'));
    expect(session.messages[0].text, isNot(contains('secret-value')));
    expect(session.messages[1].text, isEmpty);
    expect(session.messages[2].text, isEmpty);
    expect(session.messages[0].toJson()['providerSummary'], isTrue);
  });

  test('fails closed for namespaced structured event types', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-namespaced-events',
      'agentId': 'codex',
      'messages': [
        {
          'id': 'reasoning-delta',
          'role': 'assistant',
          'cardType': 'reasoning.delta',
          'text': 'Private chain of thought.',
        },
        {
          'id': 'tool-call',
          'role': 'assistant',
          'cardType': 'tool.call',
          'text':
              'client_secret=${['fixture', 'value'].join('-')} ${['..', 'private', 'input.txt'].join('/')}',
        },
        {
          'id': 'runtime-error',
          'role': 'assistant',
          'cardType': 'runtime.error',
          'text':
              '''Failed to resume session short-session; Session ID: sess-123; Session ID 'sess-789'; session is sess-456; thread_id=short-thread; AWS_ACCESS_KEY_ID=${['FAKEACCESS', '123456'].join()}; awsAccessKeyId=${['FAKEACCESS', '654321'].join()}; awsSecretAccessKey=${['short', 'value'].join('-')}; githubToken=${['private', 'token'].join('-')}; signingKey=${['short', 'key'].join('-')}; payload "access_token":"${['short', 'secret'].join('-')}"; cwd project/private; cwd 项目/private; cwd My Project/private; failed under project/other-private; file://server/share; ${['', 'root', 'private', 'file.txt'].join('/')} ${['', '', 'server', 'share', 'private.txt'].join(String.fromCharCode(92))} src/private.dart''',
        },
        {
          'id': 'unknown-event',
          'role': 'assistant',
          'cardType': 'vendor.lifecycle.notice',
          'text': 'conversation_id=private-conversation',
        },
        {
          'id': 'system-tool',
          'role': 'system',
          'cardType': 'tool-call',
          'text': 'password=private-password',
        },
        {
          'id': 'unicode-event',
          'role': 'assistant',
          'cardType': '错误详情',
          'text': 'conversation private-conversation-2',
        },
      ],
    });

    expect(session.messages.map((message) => message.kind), [
      AgentConversationMessageKind.reasoning,
      AgentConversationMessageKind.toolCall,
      AgentConversationMessageKind.error,
      AgentConversationMessageKind.event,
      AgentConversationMessageKind.toolCall,
      AgentConversationMessageKind.event,
    ]);
    expect(session.messages[0].text, isEmpty);
    expect(session.messages[1].text, isEmpty);
    expect(session.messages[4].text, isEmpty);
    final serialized = session.messages.map((message) => message.text).join();
    for (final privateValue in [
      'short-session',
      'short-thread',
      'private-token',
      'private-conversation',
      '/root/private',
      r'\\server\share',
      'src/private.dart',
      'private-password',
      'short-value',
      'project/private',
      'private-conversation-2',
      'sess-123',
      'sess-456',
      'FAKEACCESS123456',
      'FAKEACCESS654321',
      'project/other-private',
      'sess-789',
      'short-key',
      'short-secret',
      'file://server/share',
      '项目',
      'My Project',
    ]) {
      expect(serialized, isNot(contains(privateValue)));
    }
  });

  test('bounds nested history trees and keeps parsed lists immutable', () {
    Map<String, dynamic> nested = {
      'id': 'leaf',
      'role': 'event',
      'cardType': 'event',
      'text': 'Leaf event',
    };
    for (var depth = 0; depth < 100; depth++) {
      nested = {
        'id': 'node-$depth',
        'role': 'event',
        'cardType': 'event',
        'text': 'Nested event',
        'messages': [nested],
      };
    }
    final session = AgentConversationSession.fromJson({
      'id': 'bounded-session',
      'agentId': 'codex',
      'messages': [nested],
    });

    var depth = 0;
    var cursor = session.messages.single;
    while (cursor.childMessages.isNotEmpty) {
      depth += 1;
      cursor = cursor.childMessages.single;
    }
    expect(depth, lessThanOrEqualTo(16));
    expect(session.messageTreeTruncated, isTrue);
    expect(session.messages.single.childMessagesTruncated, isTrue);
    expect(() => session.messages.add(cursor), throwsUnsupportedError);
    expect(
      () => session.messages.single.childMessages.add(cursor),
      throwsUnsupportedError,
    );
  });

  test(
    'preserves final top-level messages when nested process budget is full',
    () {
      final session = AgentConversationSession.fromJson({
        'id': 'session-budget',
        'agentId': 'codex',
        'messages': [
          {
            'id': 'large-process',
            'role': 'event',
            'cardType': 'event',
            'text': 'Bounded process',
            'messages': [
              for (var index = 0; index < 5000; index += 1)
                {
                  'id': 'operation-$index',
                  'role': 'event',
                  'cardType': 'event',
                  'text': 'Safe operation',
                },
            ],
          },
          {
            'id': 'final-answer',
            'role': 'assistant',
            'text': 'Final answer remains visible.',
          },
        ],
      });

      expect(session.messages, hasLength(2));
      expect(session.messages.last.id, 'final-answer');
      expect(session.messages.last.text, 'Final answer remains visible.');
      expect(session.messageTreeTruncated, isTrue);
      expect(session.messages.first.childMessagesTruncated, isTrue);
      expect(
        session.messages.first.childMessages.length,
        lessThanOrEqualTo(4096),
      );
      expect(session.sourceMessageCount, 2);
    },
  );

  test(
    'marks bounded top-level history without hiding the truncation fact',
    () {
      final session = AgentConversationSession.fromJson({
        'id': 'session-history-bound',
        'agentId': 'codex',
        'messages': [
          for (var index = 0; index < 2003; index += 1)
            {
              'id': 'message-$index',
              'role': 'assistant',
              'text': 'Visible answer $index',
            },
        ],
      });

      expect(session.historyTruncated, isTrue);
      expect(session.sourceMessageCount, 2003);
      expect(session.messageCount, 2000);
      expect(session.messages.first.id, 'message-3');
      expect(session.messages.last.id, 'message-2002');
    },
  );

  test('projected message identity excludes mutable streamed text', () {
    AgentConversationSession parse(String text) =>
        AgentConversationSession.fromJson({
          'id': 'stable-session',
          'agentId': 'codex',
          'messages': [
            {
              'role': 'assistant',
              'createdAt': '2026-06-12T00:00:00Z',
              'text': text,
            },
            {
              'id': 'duplicate-id',
              'role': 'event',
              'cardType': 'event',
              'createdAt': '2026-06-12T00:00:01Z',
              'text': 'First duplicate',
            },
            {
              'id': 'duplicate-id',
              'role': 'event',
              'cardType': 'event',
              'createdAt': '2026-06-12T00:00:02Z',
              'text': 'Second duplicate',
            },
          ],
        });

    final before = parse('Partial');
    final after = parse('Partial response completed.');
    expect(before.messages.first.id, after.messages.first.id);
    expect(
      before.messages.first.stableIdentity,
      after.messages.first.stableIdentity,
    );
    expect(
      before.messages[1].stableIdentity,
      isNot(before.messages[2].stableIdentity),
    );
  });

  test('history preview never discloses a trailing process detail', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-preview',
      'agentId': 'codex',
      'messages': [
        {'id': 'user', 'role': 'user', 'text': 'Safe visible prompt'},
        {
          'id': 'error',
          'role': 'error',
          'cardType': 'error',
          'text': 'session_id=private-session',
        },
      ],
    });

    expect(session.preview, 'Safe visible prompt');
    expect(session.preview, isNot(contains('private-session')));
  });

  test('normalizes structured native events and redacts unsafe details', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-events',
      'agentId': 'codex',
      'title': 'Inspect native events',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:06Z',
      'messages': [
        {
          'id': 'msg-user',
          'role': 'user',
          'text': 'Inspect native events',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-tool-call',
          'role': 'function_call',
          'cardTitle': 'exec_command',
          'text': jsonEncode({
            'cmd':
                'read ${['', 'workspace', 'private', 'source.rs'].join('/')}',
            'access_token': ['fixture', 'value'].join('-'),
          }),
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-tool-result',
          'role': 'function_call_output',
          'text': jsonEncode({
            'ok': true,
            'path': ['', 'workspace', 'private', 'source.rs'].join('/'),
            'api_key': ['fixture', 'value'].join('-'),
          }),
          'createdAt': '2026-06-12T00:00:02Z',
        },
        {
          'id': 'msg-metadata',
          'role': 'metadata',
          'text': jsonEncode({
            'cwd': ['', 'workspace', 'private', 'project'].join('/'),
            'credential': ['fixture', 'value'].join('-'),
          }),
          'createdAt': '2026-06-12T00:00:03Z',
        },
        {
          'id': 'msg-error',
          'role': 'error',
          'text':
              'Operation failed under ${['', 'workspace', 'private', 'project'].join('/')} with api_key=${['fixture', 'value'].join('-')}',
          'createdAt': '2026-06-12T00:00:04Z',
        },
        {
          'id': 'msg-event',
          'role': 'lifecycle_notice',
          'text':
              'Cleanup started under ${['', 'workspace', 'private', 'project'].join('/')}.',
          'createdAt': '2026-06-12T00:00:05Z',
        },
        {
          'id': 'msg-agent',
          'role': 'assistant',
          'text': 'Cleanup completed.',
          'createdAt': '2026-06-12T00:00:06Z',
        },
      ],
    });

    expect(session.messages.map((message) => message.kind), [
      AgentConversationMessageKind.user,
      AgentConversationMessageKind.toolCall,
      AgentConversationMessageKind.toolResult,
      AgentConversationMessageKind.metadata,
      AgentConversationMessageKind.error,
      AgentConversationMessageKind.event,
      AgentConversationMessageKind.assistant,
    ]);
    expect(session.messages[1].cardType, 'tool-call');
    expect(session.messages[1].cardTitle, 'exec_command');
    expect(session.messages[2].cardType, 'tool-result');
    expect(session.messages[3].collapsed, isTrue);
    expect(session.messages[4].collapsed, isFalse);
    final visible = session.messages.map((message) => message.text).join('\n');
    expect(visible, isNot(contains('{"')));
    expect(visible, isNot(contains('secret-value')));
    expect(visible, isNot(contains('/workspace/private')));
    expect(visible, contains('[local path hidden]'));
    expect(
      session.messages[4].kind,
      isNot(AgentConversationMessageKind.assistant),
    );
    expect(
      session.messages[5].kind,
      isNot(AgentConversationMessageKind.assistant),
    );
  });

  test('filters structured runtime results and automation checklists', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-structured-result',
      'agentId': 'codex',
      'title': '"ok": true,\n"command": "node --test"',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:04Z',
      'messages': [
        {
          'id': 'msg-structured-result',
          'role': 'user',
          'text': '''
"ok": true,
"command": "node --test --experimental-test-coverage",
"args": ["node", "--test"],
"sideEffects": "none",
"timeoutClass": "standard",
"requiredServices": [],
"profiles": ["external"]''',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-automation-checklist',
          'role': 'user',
          'text': '''
- [ ] confirm classifier approval state
- [ ] check sandbox policy before tool call
- [x] record local command timeoutClass''',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-real-user',
          'role': 'user',
          'text': '''
- [ ] 保留这个用户真正写的清单
- [ ] 第二条用户清单''',
          'createdAt': '2026-06-12T00:00:02Z',
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': '收到。',
          'createdAt': '2026-06-12T00:00:03Z',
        },
      ],
    });

    expect(session.title, '- [ ] 保留这个用户真正写的清单');
    expect(session.messageCount, 2);
    expect(session.messages.map((message) => message.text), [
      '- [ ] 保留这个用户真正写的清单\n- [ ] 第二条用户清单',
      '收到。',
    ]);
    expect(
      session.messages.any(
        (message) =>
            message.text.contains('"ok": true') ||
            message.text.contains('timeoutClass') ||
            message.text.contains('classifier') ||
            message.text.contains('sandbox policy'),
      ),
      isFalse,
    );
  });

  test('keeps delegated subagent cards inside visible conversations', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-subagent-card',
      'agentId': 'codex',
      'title': 'Run the security scan',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:03Z',
      'messages': [
        {
          'id': 'msg-user',
          'role': 'user',
          'text': 'Run the security scan',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-worker',
          'role': 'subagent',
          'cardType': 'subagent',
          'cardTitle': 'discovery worker round-05/worker-03',
          'text': 'Worker found one candidate finding.',
          'createdAt': '2026-06-12T00:00:01Z',
          'messages': [
            {
              'id': 'msg-worker-output',
              'role': 'agent',
              'text': 'Worker found one candidate finding.',
              'createdAt': '2026-06-12T00:00:02Z',
            },
          ],
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': 'Coordinator merged the result.',
          'createdAt': '2026-06-12T00:00:03Z',
        },
        {
          'id': 'msg-worker-prompt',
          'role': 'subagent_prompt',
          'text':
              'You are discovery worker round-05/worker-03 for a Codex Security Deep Security Scan.',
          'createdAt': '2026-06-12T00:00:01Z',
        },
      ],
    });

    expect(session.messageCount, 3);
    expect(session.messages[1].isSubagentCard, isTrue);
    expect(
      session.messages[1].cardTitle,
      'discovery worker round-05/worker-03',
    );
    expect(
      session.messages[1].childMessages.single.text,
      'Worker found one candidate finding.',
    );
    expect(
      session.messages.any((message) => message.role == 'subagent_prompt'),
      isFalse,
    );
  });

  test(
    'sends messages through AgentDispatchLane stdin JSON contract',
    () async {
      final agentService = _StdinAgentService();
      const service = AgentConversationService();

      final turn = await service.send(
        runner: agentService,
        agentId: 'codex',
        text: 'Hello Codex',
        sessionId: 'native-session-1',
        bind: AgentDispatchBind(
          sessionPath: ['', 'private', 'session.jsonl'].join('/'),
          workingDirectory: '/workspace/project',
          binaryPath: '/tools/codex',
          model: 'gpt-5.5',
          reasoningEffort: 'xhigh',
          acceptanceMode: 'dispatch-lane-unified-1',
        ),
        conversationReadiness: 'ready',
      );

      expect(turn.ok, isTrue);
      expect(turn.raw['mode'], 'runtime-adapter');
      expect(agentService.capturedArgs.single, [
        'agent',
        'conversation',
        'send',
        '--stdin-json',
        'true',
        '--stream-events',
        'true',
      ]);
      expect(jsonDecode(agentService.capturedStdin.single), {
        'agent': 'codex',
        'text': 'Hello Codex',
        'streamEvents': true,
        'sessionId': 'native-session-1',
        'sessionPath': ['', 'private', 'session.jsonl'].join('/'),
        'workingDirectory': '/workspace/project',
        'binaryPath': '/tools/codex',
        'model': 'gpt-5.5',
        'reasoningEffort': 'xhigh',
        'acceptanceMode': 'dispatch-lane-unified-1',
      });
    },
  );

  test('dispatch lane rejects send when readiness is not ready', () async {
    final agentService = _StdinAgentService();
    const service = AgentConversationService();

    final turn = await service.send(
      runner: agentService,
      agentId: 'codex',
      text: 'blocked',
      sessionId: '',
      conversationReadiness: 'unverified',
    );

    expect(turn.ok, isFalse);
    expect(turn.errorCode, 'native_conversation_parity_unverified');
    expect(agentService.capturedArgs, isEmpty);
  });

  test(
    'dispatch lane covers openOrResume stream cancel and capabilities',
    () async {
      final agentService = _StdinAgentService();
      const service = AgentConversationService();

      final session = await service.openOrResume(
        runner: agentService,
        agentId: 'codex',
        sessionId: 'native-1',
      );
      expect(session.sessionId, 'native-1');
      expect(session.agentId, 'codex');
      expect(agentService.capturedArgs.single, [
        'agent',
        'conversation',
        'open',
        '--stdin-json',
        'true',
      ]);
      expect(jsonDecode(agentService.capturedStdin.single), {
        'agent': 'codex',
        'sessionId': 'native-1',
      });

      final events = await service
          .stream(runner: agentService, agentId: 'codex', sessionId: 'native-1')
          .toList();
      expect(events, isNotEmpty);
      expect(events.first.kind, 'dispatch.lane.bound');

      final cancel = await service.cancel(
        runner: agentService,
        agentId: 'codex',
        sessionId: 'native-1',
        turnId: 'turn-1',
      );
      expect(cancel.ok, isFalse);
      expect(cancel.errorCode, 'dispatch_cancel_unsupported');
      expect(agentService.capturedArgs.last, [
        'agent',
        'conversation',
        'cancel',
        '--stdin-json',
        'true',
      ]);
      expect(jsonDecode(agentService.capturedStdin.last), {
        'agent': 'codex',
        'sessionId': 'native-1',
        'turnId': 'turn-1',
      });

      final cleanup = await service.cleanup(
        runner: agentService,
        agentId: 'codex',
        sessionId: 'native-1',
      );
      expect(cleanup.ok, isTrue);
      expect(agentService.capturedArgs.last, [
        'agent',
        'conversation',
        'cleanup',
        '--stdin-json',
        'true',
      ]);

      final caps = await service.capabilities(
        runner: agentService,
        agentId: 'codex',
        conversationReadiness: 'ready',
      );
      expect(caps.agentId, 'codex');
      expect(caps.exactResume, isTrue);
      expect(caps.runtimeProtocol, 'codex-app-server');
      expect(caps.blockerCodes, isEmpty);
    },
  );

  test('dispatch lane fails closed when exact resume is rejected', () async {
    const service = AgentConversationService();
    final runner = _OpenResultAgentService({
      'ok': false,
      'error': {'code': 'native_session_not_found'},
    });

    await expectLater(
      service.openOrResume(
        runner: runner,
        agentId: 'codex',
        sessionId: 'native-1',
      ),
      throwsA(
        isA<AgentDispatchOpenException>().having(
          (error) => error.code,
          'code',
          'native_session_not_found',
        ),
      ),
    );
  });

  test('dispatch lane rejects empty or changed resume identity', () async {
    const service = AgentConversationService();

    for (final response in [
      {'ok': true, 'nativeSessionId': ''},
      {'ok': true, 'nativeSessionId': 'different-session'},
    ]) {
      await expectLater(
        service.openOrResume(
          runner: _OpenResultAgentService(response),
          agentId: 'codex',
          sessionId: 'native-1',
        ),
        throwsA(isA<AgentDispatchOpenException>()),
      );
    }
  });

  test('collects native conversation snapshots by topic and agent', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({
            'ok': true,
            'status': 'materialized',
            'selectedCount': 1,
          }),
          '',
        );
      },
    );
    const service = AgentConversationService();

    final result = await service.collectSnapshots(
      agentService: agentService,
      agentId: 'codex',
      topic: ' codex spark ',
    );

    expect(result['status'], 'materialized');
    expect(captured.single, [
      'snapshots',
      'collect',
      '--topic',
      'codex spark',
      '--curation',
      'true',
      '--agent',
      'codex',
    ]);
  });

  test('creates and drains native conversation archive jobs', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({
            'ok': true,
            'jobId': 'archive-job-1',
            'status': args.contains('drain') ? 'drained' : 'queued',
          }),
          '',
        );
      },
    );
    const service = AgentConversationService();

    final created = await service.createArchiveJob(
      agentService: agentService,
      keywords: ' Pact, Pactium ',
      path: ' /tmp/pactium ',
    );
    await service.archiveJobStatus(
      agentService: agentService,
      jobId: 'archive-job-1',
    );
    await service.archiveJobEvents(
      agentService: agentService,
      jobId: 'archive-job-1',
    );
    await service.drainArchiveJobs(
      agentService: agentService,
      jobId: 'archive-job-1',
    );

    expect(created['jobId'], 'archive-job-1');
    expect(captured[0], [
      'snapshots',
      'archive',
      'jobs',
      'create',
      '--keywords',
      'Pact, Pactium',
      '--path',
      '/tmp/pactium',
      '--curation',
      'true',
      '--max-attempts',
      '2',
    ]);
    expect(captured[1], [
      'snapshots',
      'archive',
      'jobs',
      'status',
      '--job-id',
      'archive-job-1',
    ]);
    expect(captured[2], [
      'snapshots',
      'archive',
      'jobs',
      'events',
      '--job-id',
      'archive-job-1',
    ]);
    expect(captured[3], [
      'snapshots',
      'archive',
      'jobs',
      'drain',
      '--job-id',
      'archive-job-1',
    ]);
  });

  test('manages snapshot root collections and bridge commands', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        if (args.length >= 3 && args[1] == 'collections') {
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'collections': [
                {'topicKey': 'codex-spark'},
              ],
            }),
            '',
          );
        }
        if (args.length >= 3 && args[1] == 'profiles') {
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'profiles': [
                {'profileId': 'licolite'},
              ],
            }),
            '',
          );
        }
        return ProcessResult(
          0,
          0,
          jsonEncode({'ok': true, 'snapshotRoot': '/tmp/archive'}),
          '',
        );
      },
    );
    const service = AgentConversationService();

    await service.getSnapshotRoot(agentService: agentService);
    await service.setSnapshotRoot(
      agentService: agentService,
      path: '/tmp/archive',
    );
    final collections = await service.listSnapshotCollections(
      agentService: agentService,
    );
    await service.ensureSnapshotBridge(
      agentService: agentService,
      agentId: 'codex',
      configPath: '/tmp/codex.toml',
    );
    await service.getPreferredSnapshotCurator(agentService: agentService);
    await service.setPreferredSnapshotCurator(
      agentService: agentService,
      target: 'codex',
    );
    await service.setPreferredSnapshotCurator(
      agentService: agentService,
      target: '',
    );
    final profiles = await service.listArchiveProfiles(
      agentService: agentService,
    );
    await service.runArchiveProfile(
      agentService: agentService,
      profileId: 'licolite',
      trigger: 'agent',
    );
    await service.verifyArchiveProfile(
      agentService: agentService,
      profileId: 'licolite',
    );
    await service.reportArchiveProfile(
      agentService: agentService,
      profileId: 'licolite',
    );

    expect(collections.single['topicKey'], 'codex-spark');
    expect(profiles.single['profileId'], 'licolite');
    expect(captured[0], ['snapshots', 'root', 'get']);
    expect(captured[1], ['snapshots', 'root', 'set', '--path', '/tmp/archive']);
    expect(captured[2], ['snapshots', 'collections', 'list']);
    expect(captured[3], [
      'snapshots',
      'bridge',
      'ensure',
      '--target',
      'codex',
      '--config-path',
      '/tmp/codex.toml',
    ]);
    expect(captured[4], ['snapshots', 'curator', 'get']);
    expect(captured[5], ['snapshots', 'curator', 'set', '--target', 'codex']);
    expect(captured[6], ['snapshots', 'curator', 'set', '--clear', 'true']);
    expect(captured[7], ['snapshots', 'profiles', 'list']);
    expect(captured[8], [
      'snapshots',
      'archive',
      'run',
      '--profile',
      'licolite',
      '--trigger',
      'agent',
      '--curation',
      'true',
    ]);
    expect(captured[9], [
      'snapshots',
      'archive',
      'verify',
      '--profile',
      'licolite',
    ]);
    expect(captured[10], [
      'snapshots',
      'archive',
      'report',
      '--profile',
      'licolite',
    ]);
  });
}

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

class _StdinAgentService extends AgentService {
  final List<List<String>> capturedArgs = [];
  final List<String> capturedStdin = [];

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    capturedArgs.add(List<String>.from(args));
    capturedStdin.add(stdinText);
    if (args.contains('open')) {
      final request = jsonDecode(stdinText) as Map<String, dynamic>;
      final sessionId = (request['sessionId'] ?? '').toString();
      return {
        'ok': true,
        'nativeSessionId': sessionId,
        'sessionId': sessionId,
        'threadId': sessionId,
      };
    }
    if (args.contains('cancel')) {
      return {
        'ok': false,
        'status': 'unsupported',
        'error': {
          'code': 'dispatch_cancel_unsupported',
          'stage': 'turn/cancel',
        },
      };
    }
    if (args.contains('cleanup')) {
      return {'ok': true, 'status': 'cleaned'};
    }
    if (args.contains('capabilities')) {
      return {
        'ok': true,
        'agentId': 'codex',
        'laneFamily': 'app-server',
        'runtimeProtocol': 'codex-app-server',
        'blockerCodes': <String>[],
        'capabilities': {
          'streaming': true,
          'exactResume': true,
          'cancel': false,
          'approvals': false,
          'multimodal': false,
          'usageStatus': false,
        },
      };
    }
    return {
      'ok': true,
      'mode': 'runtime-adapter',
      'adapterId': 'codex',
      'runtimeProtocol': 'codex-app-server',
    };
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    capturedArgs.add(List<String>.from(args));
    capturedStdin.add(stdinText);
    yield {
      'event': 'done',
      'ok': true,
      'mode': 'runtime-adapter',
      'adapterId': 'codex',
      'runtimeProtocol': 'codex-app-server',
      'nativeSessionId': 'thread-stream-1',
      'sessionId': 'thread-stream-1',
      'threadId': 'thread-stream-1',
      'turnId': 'turn-1',
      'turnStatus': 'completed',
      'output': 'streamed reply',
    };
  }
}

class _OpenResultAgentService extends AgentService {
  _OpenResultAgentService(this.result);

  final Map<String, dynamic> result;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async => result;
}
