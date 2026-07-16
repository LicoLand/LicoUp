import 'dart:convert';

import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void registerAgentConversationStructuredEventScenarios() {
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
}

void main() => registerAgentConversationStructuredEventScenarios();
