import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const scope = 'claude-code|sess-1|native-1';
  const turn = 'live-claude-code-1720000000000000';

  test('live turn events form one pinned card that grows in place', () {
    final frame1 = [
      _message('$turn-user', 'user', 'build it', stableIdentity: '$turn-user'),
      _structured('$turn-lifecycle', turn, 'lifecycle', 'processing'),
      _structured('$turn-process-0', turn, 'reasoning', 'reasoning'),
      _message(
        '$turn-assistant',
        'assistant',
        'I will build it.',
        stableIdentity: '$turn-assistant',
      ),
    ];
    // Next frame: another tool step arrived after the reply started.
    final frame2 = [
      _message('$turn-user', 'user', 'build it', stableIdentity: '$turn-user'),
      _structured('$turn-lifecycle', turn, 'lifecycle', 'processing'),
      _structured('$turn-process-0', turn, 'reasoning', 'reasoning'),
      _structured('$turn-process-1', turn, 'tool-call', 'Bash'),
      _message(
        '$turn-assistant',
        'assistant',
        'I will build it.',
        stableIdentity: '$turn-assistant',
      ),
    ];

    final items1 = buildConversationTimelineItems(frame1, scope);
    final items2 = buildConversationTimelineItems(frame2, scope);

    final card1 = items1.whereType<ConversationProcessTimelineItem>().toList();
    final card2 = items2.whereType<ConversationProcessTimelineItem>().toList();
    expect(card1, hasLength(1));
    expect(card2, hasLength(1));
    expect(card1.single.storageKey, card2.single.storageKey);
    expect(card1.single.events, hasLength(2));
    expect(card2.single.events, hasLength(3));
    expect(card2.single.events.last.text, 'Bash');
  });

  test('the turn card stays between the user message and the reply', () {
    final items = buildConversationTimelineItems([
      _message('$turn-user', 'user', 'build it', stableIdentity: '$turn-user'),
      _structured('$turn-lifecycle', turn, 'lifecycle', 'processing'),
      _structured('$turn-process-0', turn, 'tool-call', 'Bash'),
      _message(
        '$turn-assistant',
        'assistant',
        'done',
        stableIdentity: '$turn-assistant',
      ),
    ], scope);

    expect(items, hasLength(3));
    expect(items[0], isA<ConversationMessageTimelineItem>());
    expect(items[1], isA<ConversationProcessTimelineItem>());
    expect(items[2], isA<ConversationMessageTimelineItem>());
  });

  test('a second live turn opens a distinct card', () {
    const turn2 = 'live-claude-code-1720000000000001';
    final items = buildConversationTimelineItems([
      _message('$turn-user', 'user', 'one', stableIdentity: '$turn-user'),
      _structured('$turn-lifecycle', turn, 'lifecycle', 'completed'),
      _message(
        '$turn-assistant',
        'assistant',
        'one done',
        stableIdentity: '$turn-assistant',
      ),
      _message('$turn2-user', 'user', 'two', stableIdentity: '$turn2-user'),
      _structured('$turn2-lifecycle', turn2, 'lifecycle', 'accepted'),
    ], scope);

    final cards = items.whereType<ConversationProcessTimelineItem>().toList();
    expect(cards, hasLength(2));
    expect(cards[0].storageKey, isNot(cards[1].storageKey));
  });

  test('non-live structured events keep the legacy anchor batching', () {
    final items = buildConversationTimelineItems([
      _message('native-user', 'user', 'build it'),
      _structured('native-reason', '', 'reasoning', 'reasoning'),
      _structured('native-tool', '', 'tool-call', 'Bash'),
      _message('native-assistant', 'assistant', 'done'),
    ], scope);

    final cards = items.whereType<ConversationProcessTimelineItem>().toList();
    expect(cards, hasLength(1));
    expect(cards.single.events, hasLength(2));
  });

  test('liveTurnKeyOf recovers the turn from lifecycle and evidence ids', () {
    expect(
      liveTurnKeyOf(
        _structured(
          'live-claude-code-1-lifecycle',
          'live-claude-code-1',
          'lifecycle',
          'processing',
        ),
      ),
      'live-claude-code-1',
    );
    expect(
      liveTurnKeyOf(
        _structured(
          'live-claude-code-1-process-12',
          'live-claude-code-1',
          'tool-call',
          'Bash',
        ),
      ),
      'live-claude-code-1',
    );
    expect(
      liveTurnKeyOf(_structured('native-reason', '', 'reasoning', 'reasoning')),
      isNull,
    );
  });
}

AgentConversationMessage _message(
  String id,
  String role,
  String text, {
  String stableIdentity = '',
}) => AgentConversationMessage(
  id: id,
  role: role,
  text: text,
  createdAt: '2026-08-07T00:00:00Z',
  stableIdentity: stableIdentity,
);

AgentConversationMessage _structured(
  String id,
  String turn,
  String cardType,
  String text,
) => AgentConversationMessage(
  id: id,
  role: 'event',
  text: text,
  createdAt: '2026-08-07T00:00:00Z',
  cardType: cardType,
  stableIdentity: id,
);
