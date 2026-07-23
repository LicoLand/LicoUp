import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
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
}

AgentConversationMessage _message(String id, String role, String text) =>
    AgentConversationMessage(
      id: id,
      role: role,
      text: text,
      createdAt: '2026-07-23T00:00:00Z',
    );
