import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

void main() {
  test('bounded FIFO preserves submission order and rejects duplicate ids', () {
    final queue = ConversationTurnQueue(capacity: 2);

    expect(
      queue.add(_turn(1, 'first')),
      ConversationTurnEnqueueResult.accepted,
    );
    expect(
      queue.add(_turn(1, 'duplicate')),
      ConversationTurnEnqueueResult.duplicate,
    );
    expect(
      queue.add(_turn(2, 'second')),
      ConversationTurnEnqueueResult.accepted,
    );
    expect(queue.add(_turn(3, 'full')), ConversationTurnEnqueueResult.full);

    expect(queue.removeFirst()?.text, 'first');
    expect(queue.removeFirst()?.text, 'second');
    expect(queue.removeFirst(), isNull);
  });

  test('new-conversation follow-ups bind to the returned native session', () {
    final queue = ConversationTurnQueue();
    queue.add(_turn(1, 'follow-up', awaitActiveSession: true));

    queue.bindAwaitingSession(
      agentId: 'codex',
      nativeSessionId: 'native-session-1',
    );

    final rebound = queue.removeFirst()!;
    expect(rebound.nativeSessionId, 'native-session-1');
    expect(rebound.awaitActiveSession, isFalse);
  });

  test('clear releases pending identities for lifecycle disposal', () {
    final queue = ConversationTurnQueue();
    expect(
      queue.add(_turn(1, 'pending')),
      ConversationTurnEnqueueResult.accepted,
    );

    queue.clear();

    expect(queue.isEmpty, isTrue);
    expect(
      queue.add(_turn(1, 'new lifecycle')),
      ConversationTurnEnqueueResult.accepted,
    );
  });
}

ConversationQueuedTurn _turn(
  int id,
  String text, {
  bool awaitActiveSession = false,
}) {
  return ConversationQueuedTurn(
    submissionId: id,
    agent: TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      adapterStatus: 'implemented',
    ),
    text: text,
    session: null,
    nativeSessionId: '',
    workingDirectory: '',
    model: '',
    reasoningEffort: '',
    throughMobileRelay: false,
    awaitActiveSession: awaitActiveSession,
  );
}
