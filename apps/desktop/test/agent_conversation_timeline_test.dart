import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reasoning, tools and runtime records do not occupy transcript rows',
    () {
      final items = buildConversationTimelineItems([
        _message('user', 'user', 'Build the example'),
        _message('reasoning', 'reasoning', 'Synthetic reasoning'),
        _message('tool', 'tool-call', 'Synthetic invocation'),
        _message('result', 'tool-result', 'Synthetic result'),
        _message('log', 'event', 'Synthetic log'),
        _message('reply', 'assistant', 'Done'),
      ], 'synthetic');
      expect(
        items.whereType<ConversationMessageTimelineItem>().map(
          (item) => item.message.id,
        ),
        ['user', 'reply'],
      );
      expect(items, hasLength(2));
    },
  );

  test('actual failures and child conversations stay in the main timeline', () {
    final items = buildConversationTimelineItems([
      _message('user', 'user', 'Build the example'),
      _message('child', 'subagent', 'Child conversation'),
      _message('failure', 'error', 'Transport failed during response'),
    ], 'synthetic');
    expect(items, hasLength(3));
    expect(
      (items[1] as ConversationMessageTimelineItem).message.isSubagentCard,
      isTrue,
    );
    expect(
      (items[2] as ConversationFailureTimelineItem).message.text,
      'Transport failed during response',
    );
  });

  test(
    'first reply keeps its key when text arrives amid execution records',
    () {
      final before = buildConversationTimelineItems([
        _message('user', 'user', 'Build'),
        _message('reply', 'assistant', ''),
      ], 'synthetic');
      final after = buildConversationTimelineItems([
        _message('user', 'user', 'Build'),
        _message('tool', 'tool-call', 'Synthetic invocation'),
        _message('reply', 'assistant', 'Available immediately'),
      ], 'synthetic');
      expect(before.last.storageKey, after.last.storageKey);
      expect(after, hasLength(2));
    },
  );

  test(
    'legacy failed lifecycle stays hidden while conversation facts remain',
    () {
      final items = buildConversationTimelineItems(const [
        AgentConversationMessage(
          id: 'life',
          role: 'error',
          text: 'failed',
          createdAt: '',
          cardType: 'lifecycle',
        ),
        AgentConversationMessage(
          id: 'membership',
          role: 'event',
          text: 'Added member',
          createdAt: '',
          cardType: 'membership-changed',
        ),
        AgentConversationMessage(
          id: 'availability',
          role: 'event',
          text: 'Agent unavailable',
          createdAt: '',
          cardType: 'availability',
        ),
      ], 'synthetic');
      expect(items, hasLength(2));
      expect(
        items.every((item) => item is ConversationNoticeTimelineItem),
        isTrue,
      );
    },
  );
}

AgentConversationMessage _message(String id, String role, String text) =>
    AgentConversationMessage(
      id: id,
      role: role,
      text: text,
      createdAt: '2026-09-13T00:00:00Z',
      stableIdentity: id,
    );
