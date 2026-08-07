import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'completed live turn is hidden once readback contains the same suffix',
    () {
      final persisted = [
        _message('native-user', 'user', 'hello'),
        _message('native-assistant', 'assistant', 'world'),
      ];
      final live = [
        _message('live-user', 'user', 'hello'),
        _message('live-assistant', 'assistant', 'world'),
      ];

      final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

      expect(merged.map((message) => message.id), [
        'native-user',
        'native-assistant',
      ]);
    },
  );

  test('in-flight repeated user message remains visible', () {
    final persisted = [_message('native-user', 'user', 'repeat')];
    final live = [_message('live-user', 'user', 'repeat')];

    final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

    expect(merged.map((message) => message.id), ['native-user', 'live-user']);
  });

  test('different completed live turn is appended', () {
    final persisted = [
      _message('native-user', 'user', 'old'),
      _message('native-assistant', 'assistant', 'answer'),
    ];
    final live = [
      _message('live-user', 'user', 'new'),
      _message('live-assistant', 'assistant', 'reply'),
    ];

    final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

    expect(merged.map((message) => message.id), [
      'native-user',
      'native-assistant',
      'live-user',
      'live-assistant',
    ]);
  });

  test(
    'multi-block assistant readback covers the live turn without duplicating',
    () {
      // One assistant reply with tool calls is recorded as several content
      // blocks: two assistant text messages around a tool card.
      final persisted = [
        _message('native-user', 'user', 'build it'),
        _message('native-assistant-1', 'assistant', 'I will build it.'),
        _message('native-tool', 'tool_call', ''),
        _message('native-assistant-2', 'assistant', 'Build complete.'),
      ];
      final live = [
        _message('live-user', 'user', 'build it'),
        _message('live-assistant', 'assistant', 'Build complete.'),
      ];

      final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

      expect(merged.map((message) => message.id), [
        'native-user',
        'native-assistant-1',
        'native-tool',
        'native-assistant-2',
      ]);
    },
  );

  test(
    'readback that does not cover the live tail still appends it',
    () {
      final persisted = [
        _message('native-user', 'user', 'old'),
        _message('native-assistant', 'assistant', 'answer'),
      ];
      final live = [
        _message('live-user', 'user', 'build it'),
        _message('live-assistant', 'assistant', 'Build complete.'),
      ];

      final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

      expect(merged.map((message) => message.id), [
        'native-user',
        'native-assistant',
        'live-user',
        'live-assistant',
      ]);
    },
  );
}

AgentConversationMessage _message(String id, String role, String text) =>
    AgentConversationMessage(
      id: id,
      role: role,
      text: text,
      createdAt: '2026-07-23T00:00:00Z',
    );
