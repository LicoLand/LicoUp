import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exact message pages merge chronologically without overlap', () {
    AgentConversationSession page(int start, int end, int total) =>
        AgentConversationSession.fromJson({
          'id': 'projection',
          'agentId': 'codex',
          'nativeSessionId': 'native-page-session',
          'sourceMessageCount': total,
          'messages': [
            for (var index = start; index < end; index += 1)
              {
                'id': 'message-$index',
                'role': 'assistant',
                'text': 'message $index',
              },
          ],
          'messagePage': {
            'start': start,
            'endExclusive': end,
            'returned': end - start,
            'total': total,
            'hasEarlier': start > 0,
            if (start > 0) 'nextBefore': 'message-$start',
          },
        });

    var accumulated = page(203, 253, 253);
    accumulated = accumulated.mergeExactMessagePage(page(153, 203, 253));
    accumulated = accumulated.mergeExactMessagePage(page(53, 153, 253));
    accumulated = accumulated.mergeExactMessagePage(page(0, 53, 253));

    expect(accumulated.messages, hasLength(253));
    expect(accumulated.messages.first.id, 'message-0');
    expect(accumulated.messages.last.id, 'message-252');
    expect(accumulated.messagePage.hasEarlier, isFalse);
    expect(accumulated.messagePage.start, 0);
  });

  test('exact message page rejects conflicting stable identity overlap', () {
    AgentConversationSession page(String text) =>
        AgentConversationSession.fromJson({
          'id': 'projection',
          'agentId': 'codex',
          'nativeSessionId': 'native-page-session',
          'sourceMessageCount': 1,
          'messages': [
            {'id': 'message-0', 'role': 'assistant', 'text': text},
          ],
          'messagePage': {
            'start': 0,
            'endExclusive': 1,
            'returned': 1,
            'total': 1,
            'hasEarlier': false,
          },
        });

    expect(
      () => page('first').mergeExactMessagePage(page('different')),
      throwsA(isA<FormatException>()),
    );
  });

  test('empty browse placeholder adopts the first exact page', () {
    // Remote browse rows legitimately carry zeroed page facts and no preview
    // messages; opening the session must adopt the exact page instead of
    // measuring a gap against the placeholder.
    final placeholder = AgentConversationSession.fromJson({
      'id': 'projection',
      'agentId': 'openclaw',
      'nativeSessionId': 'remote-native-session',
      'sourceMessageCount': 0,
      'messages': <Map<String, dynamic>>[],
      'messagePage': {
        'start': 0,
        'endExclusive': 0,
        'returned': 0,
        'total': 0,
        'hasEarlier': false,
      },
    });
    AgentConversationSession exactPage() => AgentConversationSession.fromJson({
      'id': 'projection',
      'agentId': 'openclaw',
      'nativeSessionId': 'remote-native-session',
      'sourceMessageCount': 120,
      'messages': [
        for (var index = 70; index < 120; index += 1)
          {
            'id': 'message-$index',
            'role': 'assistant',
            'text': 'message $index',
          },
      ],
      'messagePage': {
        'start': 70,
        'endExclusive': 120,
        'returned': 50,
        'total': 120,
        'hasEarlier': true,
        'nextBefore': 'message-70',
      },
    });

    for (final allowRevisions in [true, false]) {
      final merged = placeholder.mergeExactMessagePage(
        exactPage(),
        allowMessageRevisions: allowRevisions,
      );
      expect(merged.messages, hasLength(50));
      expect(merged.messages.first.id, 'message-70');
      expect(merged.messagePage.start, 70);
      expect(merged.messagePage.total, 120);
      expect(merged.messagePage.hasEarlier, isTrue);
      expect(merged.messagePage.nextBefore, 'message-70');
    }
  });

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

  test('readback that does not cover the live tail still appends it', () {
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
  });

  test(
    'readback covering the live turn retains the blackboard events after the '
    'user message',
    () {
      final persisted = [
        _message('native-user', 'user', 'build it'),
        _message('native-assistant-1', 'assistant', 'I will build it.'),
      ];
      final live = [
        _message('live-user', 'user', 'build it'),
        _structured('live-lifecycle', 'lifecycle', 'processing'),
        _structured('live-process-0', 'reasoning', 'reasoning'),
        _structured('live-process-1', 'tool-call', 'Bash'),
        _message('live-assistant', 'assistant', 'I will build it.'),
      ];

      final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

      expect(merged.map((message) => message.id), [
        'native-user',
        'live-lifecycle',
        'live-process-0',
        'live-process-1',
        'native-assistant-1',
      ]);
    },
  );

  test('retained live events are not duplicated when readback already carries '
      'the same evidence', () {
    final persisted = [
      _message('native-user', 'user', 'build it'),
      _structured('native-tool', 'tool-call', 'Bash'),
      _message('native-assistant-1', 'assistant', 'Build complete.'),
    ];
    final live = [
      _message('live-user', 'user', 'build it'),
      _structured('live-lifecycle', 'lifecycle', 'processing'),
      _structured('live-process-1', 'tool-call', 'Bash'),
      _message('live-assistant', 'assistant', 'Build complete.'),
    ];

    final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

    expect(merged.map((message) => message.id), [
      'native-user',
      'live-lifecycle',
      'native-tool',
      'native-assistant-1',
    ]);
  });

  test(
    'readback operations of the covered turn bridge into the turn identity',
    () {
      final persisted = [
        _message('native-user', 'user', 'build it'),
        _structured('native-thinking', 'reasoning', 'thinking...'),
        _structured('native-tool', 'tool-call', 'Bash'),
        _message('native-assistant-1', 'assistant', 'Build complete.'),
      ];
      final live = [
        _message('live-user', 'user', 'build it'),
        _structured('live-lifecycle', 'lifecycle', 'completed'),
        _structured('live-process-0', 'reasoning', 'thinking...'),
        _structured('live-process-1', 'tool-call', 'Bash'),
        _message('live-assistant', 'assistant', 'Build complete.'),
      ];

      final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

      // The lifecycle survives from live; the readback operations keep their
      // transcript ids but now carry the turn key in their stable identity,
      // so the timeline groups them into the same blackboard card.
      expect(merged.map((message) => message.id), [
        'native-user',
        'live-lifecycle',
        'native-thinking',
        'native-tool',
        'native-assistant-1',
      ]);
      expect(merged[2].stableIdentity, 'live-process-0');
      expect(merged[3].stableIdentity, 'live-process-1');
    },
  );

  test('multi-block readback converges into one turn card in the timeline', () {
    // One assistant reply is recorded as several content blocks with tool
    // operations between them; all of them belong to the same turn card.
    final persisted = [
      _message('native-user', 'user', 'build it'),
      _structured('native-thinking', 'reasoning', 'thinking...'),
      _structured('native-tool-1', 'tool-call', 'Bash'),
      _message('native-assistant-1', 'assistant', 'checking...'),
      _structured('native-tool-2', 'tool-call', 'Grep'),
      _message('native-assistant-2', 'assistant', 'done'),
    ];
    final live = [
      _message('live-user', 'user', 'build it'),
      _structured('live-lifecycle', 'lifecycle', 'completed'),
      _message('live-assistant', 'assistant', 'done'),
    ];

    final merged = mergeConversationReadbackAndLiveMessages(persisted, live);

    final items = buildConversationTimelineItems(merged, 'claude-code|s-1');
    final cards = items.whereType<ConversationProcessTimelineItem>().toList();
    expect(cards, hasLength(1));
    expect(cards.single.events.map((message) => message.text), [
      'completed',
      'thinking...',
      'Bash',
      'Grep',
    ]);
  });

  test('the turn card keeps its key across the readback handover', () {
    const scope = 'claude-code|sess-1|native-1';
    final liveFrame = buildConversationTimelineItems([
      _message('live-user', 'user', 'build it'),
      _structured('live-lifecycle', 'lifecycle', 'processing'),
      _structured('live-process-0', 'reasoning', 'thinking...'),
      _structured('live-process-1', 'tool-call', 'Bash'),
      _message('live-assistant', 'assistant', 'done'),
    ], scope);

    final merged = mergeConversationReadbackAndLiveMessages(
      [
        _message('native-user', 'user', 'build it'),
        _structured('native-thinking', 'reasoning', 'thinking...'),
        _structured('native-tool', 'tool-call', 'Bash'),
        _message('native-assistant', 'assistant', 'done'),
      ],
      [
        _message('live-user', 'user', 'build it'),
        _structured('live-lifecycle', 'lifecycle', 'processing'),
        _structured('live-process-0', 'reasoning', 'thinking...'),
        _structured('live-process-1', 'tool-call', 'Bash'),
        _message('live-assistant', 'assistant', 'done'),
      ],
    );
    final converged = buildConversationTimelineItems(merged, scope);

    final liveCard = liveFrame
        .whereType<ConversationProcessTimelineItem>()
        .single;
    final convergedCards = converged
        .whereType<ConversationProcessTimelineItem>()
        .toList();
    expect(convergedCards, hasLength(1));
    expect(convergedCards.single.storageKey, liveCard.storageKey);
    expect(convergedCards.single.events.map((message) => message.text), [
      'processing',
      'thinking...',
      'Bash',
    ]);
  });
}

AgentConversationMessage _structured(String id, String cardType, String text) =>
    AgentConversationMessage(
      id: id,
      role: 'event',
      text: text,
      createdAt: '2026-07-23T00:00:00Z',
      cardType: cardType,
      stableIdentity: id,
    );

AgentConversationMessage _message(String id, String role, String text) =>
    AgentConversationMessage(
      id: id,
      role: role,
      text: text,
      createdAt: '2026-07-23T00:00:00Z',
    );
