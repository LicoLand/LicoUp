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

  test('user settings change metadata is hidden from messages and titles', () {
    final message = parseAgentConversationMessage({
      'role': 'user',
      'text': '''
hi
<USERSETTINGSCHANGE>
The user changed setting Model Selection.
</USERSETTINGSCHANGE>
''',
      'createdAt': '2026-08-03T00:00:00Z',
    });

    expect(message.text, 'hi');
    expect(message.text, isNot(contains('USERSETTINGSCHANGE')));
    expect(visibleAgentConversationTitle(message.text, [message]), 'hi');
  });

  test('inline user settings metadata is removed from provider titles', () {
    const raw =
        'hi <USER_SETTINGS_CHANGE> The user changed setting. </USER_SETTINGS_CHANGE>';

    expect(visibleAgentConversationTitle(raw, const []), 'hi');
  });
}
