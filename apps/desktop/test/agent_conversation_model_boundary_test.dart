import 'dart:io';

import 'package:flutter_client/src/contracts/agent_conversation_message.dart';
import 'package:flutter_client/src/contracts/agent_conversation_message_parser.dart';
import 'package:flutter_client/src/contracts/agent_conversation_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation contracts keep a one-way dependency graph', () {
    const root = 'lib/src/contracts';
    final message = File(
      '$root/agent_conversation_message.dart',
    ).readAsStringSync();
    final parser = File(
      '$root/agent_conversation_message_parser.dart',
    ).readAsStringSync();
    final privacy = File(
      '$root/agent_conversation_privacy_projection.dart',
    ).readAsStringSync();
    final semantic = File(
      '$root/agent_conversation_semantic.dart',
    ).readAsStringSync();
    final session = File(
      '$root/agent_conversation_session.dart',
    ).readAsStringSync();
    final models = File(
      '$root/agent_conversation_models.dart',
    ).readAsStringSync();

    expect(message, isNot(contains('agent_conversation_semantic.dart')));
    expect(message, isNot(contains('agent_conversation_session.dart')));
    expect(message, isNot(contains('agent_conversation_message_parser.dart')));
    expect(parser, contains("import 'agent_conversation_message.dart';"));
    expect(
      parser,
      contains("import 'agent_conversation_privacy_projection.dart';"),
    );
    expect(privacy, contains("import 'agent_conversation_message.dart';"));
    expect(privacy, isNot(contains('agent_conversation_message_parser.dart')));
    expect(semantic, contains("import 'agent_conversation_message.dart';"));
    expect(
      semantic,
      contains("import 'agent_conversation_message_parser.dart';"),
    );
    expect(semantic, isNot(contains('agent_conversation_session.dart')));
    expect(session, contains("import 'agent_conversation_message.dart';"));
    expect(
      session,
      contains("import 'agent_conversation_message_parser.dart';"),
    );
    expect(session, contains("import 'agent_conversation_semantic.dart';"));
    expect(models, isNot(contains(RegExp(r'^(class|enum) ', multiLine: true))));
    expect(models, contains("export 'agent_conversation_message.dart';"));
    expect(
      models,
      contains("export 'agent_conversation_message_parser.dart';"),
    );
    expect(models, contains("export 'agent_conversation_semantic.dart';"));
    expect(models, contains("export 'agent_conversation_session.dart';"));
  });

  test('message batch owns bounded parsing independently from sessions', () {
    final rawMessages = List<Map<String, dynamic>>.generate(
      2001,
      (index) => {
        'id': 'message-$index',
        'role': 'user',
        'text': 'message $index',
        'createdAt': '2026-07-15T00:00:00Z',
      },
      growable: false,
    );

    final parsed = parseAgentConversationMessages(
      rawMessages,
      sessionId: 'session-1',
      agentId: 'local-agent',
    );

    expect(parsed.messages, hasLength(2000));
    expect(parsed.messages.first.id, 'message-1');
    expect(parsed.messages.last.id, 'message-2000');
    expect(parsed.historyTruncated, isTrue);
    expect(parsed.messageTreeTruncated, isFalse);
  });

  test('session composes message projection without owning its parser', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-1',
      'agentId': 'local-agent',
      'title': '<environment_context>private</environment_context>',
      'createdAt': '2026-07-15T00:00:00Z',
      'updatedAt': '2026-07-15T00:00:01Z',
      'messages': [
        {
          'id': 'message-1',
          'role': 'user',
          'text': 'Visible local request',
          'createdAt': '2026-07-15T00:00:00Z',
        },
      ],
    });

    expect(session.title, 'Visible local request');
    expect(session.preview, 'Visible local request');
    expect(session.messages.single.kind, AgentConversationMessageKind.user);
  });
}
