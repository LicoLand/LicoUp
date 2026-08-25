import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';

ConversationDeltaEvent _delta(
  String event,
  Map<String, dynamic> payload, {
  String turnId = 'turn-1',
}) {
  return ConversationDeltaEvent(<String, dynamic>{
    'event': event,
    'turnId': turnId,
    'payload': payload,
  });
}

const List<String> _respondingPrefix = [
  'submitted',
  'accepted',
  'processing',
  'responding',
];

void main() {
  testWidgets('holder coalesces chunk bursts into one publish per interval', (
    tester,
  ) async {
    final holder = ConversationStateHolder();
    addTearDown(holder.dispose);
    var publishes = 0;
    holder.addListener(() => publishes += 1);

    holder.applyDelta(
      _delta('agent.turn.accepted', const {
        'lifecyclePrefix': ['submitted', 'accepted'],
      }),
      scopeKey: 'scope-1',
      participantAgentId: 'codex',
      participantLabel: 'Codex',
    );
    for (var index = 0; index < 24; index += 1) {
      holder.applyDelta(
        _delta('agent.message.chunk', {
          'text': 'tok$index',
          'lifecyclePrefix': _respondingPrefix,
        }),
        scopeKey: 'scope-1',
        participantAgentId: 'codex',
        participantLabel: 'Codex',
      );
    }
    // The accepted event and all 24 chunks share one 32 ms window: a per-chunk
    // publish storm would fire ~25 times here.
    await tester.pump(const Duration(milliseconds: 40));
    expect(publishes, 1);
    final messages = holder.messagesFor('scope-1');
    expect(messages.last.text, endsWith('tok23'));
  });

  testWidgets('terminal transitions publish immediately', (tester) async {
    final holder = ConversationStateHolder();
    addTearDown(holder.dispose);
    var publishes = 0;
    holder.addListener(() => publishes += 1);

    holder.applyDelta(
      _delta('agent.message.chunk', {
        'text': 'partial',
        'lifecyclePrefix': _respondingPrefix,
      }),
      scopeKey: 'scope-1',
      participantAgentId: 'codex',
      participantLabel: 'Codex',
    );
    expect(publishes, 0);

    holder.applyDelta(
      _delta('agent.message.completed', const {
        'text': 'partial done',
        'terminalTransition': {'kind': 'lifecycle', 'stage': 'completed'},
      }),
      scopeKey: 'scope-1',
      participantAgentId: 'codex',
      participantLabel: 'Codex',
    );
    expect(publishes, 1);
    expect(holder.messagesFor('scope-1').last.text, 'partial done');
  });

  testWidgets('events without an active phase publish immediately', (
    tester,
  ) async {
    final holder = ConversationStateHolder();
    addTearDown(holder.dispose);
    var publishes = 0;
    holder.addListener(() => publishes += 1);
    holder.applyDelta(
      _delta('agent.message.chunk', const {'text': 'first'}),
      scopeKey: 'scope-1',
      participantAgentId: 'codex',
      participantLabel: 'Codex',
    );
    // No lifecycle prefix keeps the phase unknown (not active), so the publish
    // stays immediate rather than waiting out the coalescing window.
    expect(publishes, 1);
  });

  testWidgets('removeScope clears the projection and publishes immediately', (
    tester,
  ) async {
    final holder = ConversationStateHolder();
    addTearDown(holder.dispose);
    var publishes = 0;
    holder.addListener(() => publishes += 1);
    holder.applyDelta(
      _delta('agent.message.chunk', {
        'text': 'draft',
        'lifecyclePrefix': _respondingPrefix,
      }),
      scopeKey: 'scope-1',
      participantAgentId: 'codex',
      participantLabel: 'Codex',
    );
    await tester.pump(const Duration(milliseconds: 40));
    expect(holder.messagesFor('scope-1').last.text, 'draft');
    final before = publishes;

    holder.removeScope('scope-1');
    expect(publishes, before + 1);
    expect(holder.messagesFor('scope-1'), isEmpty);
  });
}
