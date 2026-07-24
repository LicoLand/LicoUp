import 'package:licoup/src/contracts/agent_conversation_message.dart';
import 'package:licoup/src/contracts/agent_conversation_message_parser.dart';
import 'package:licoup/src/contracts/agent_conversation_privacy_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('privacy projection removes generated local context from user text', () {
    final message = parseAgentConversationMessage({
      'role': 'user',
      'text': '''
<environment_context>
private machine context
</environment_context>
Visible request
''',
      'createdAt': '2026-07-15T00:00:00Z',
    });

    expect(message.text, 'Visible request');
    expect(message.text, isNot(contains('private machine context')));
  });

  test('structured projection shows local payloads verbatim', () {
    final secretValue = ['synthetic', 'secret', 'value'].join('-');
    final message = parseAgentConversationMessage({
      'role': 'tool_result',
      'cardType': 'tool-result',
      'text': '{"token":"$secretValue","status":"ready"}',
      'createdAt': '2026-07-15T00:00:00Z',
    });

    expect(message.kind, AgentConversationMessageKind.toolResult);
    expect(message.text, '{"token":"$secretValue","status":"ready"}');
  });

  test('title projection falls back to visible user-authored content', () {
    final title = visibleAgentConversationTitle(
      '<environment_context>private</environment_context>',
      const [
        AgentConversationMessage(
          id: 'message-1',
          role: 'user',
          text: 'Visible title',
          createdAt: '2026-07-15T00:00:00Z',
        ),
      ],
    );

    expect(title, 'Visible title');
  });
}
