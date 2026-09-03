import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ConversationTurnProcessState state() => ConversationTurnProcessState(
    turnId: 'live-claude-code-1720000000000000',
    userText: 'build it',
    createdAt: '2026-08-07T00:00:00Z',
  );

  test('stages advance monotonically and regressions are no-ops', () {
    final s = state();
    expect(s.stage, ConversationTurnProcessStage.submitted);
    s.advanceStage('submitted');
    s.advanceStage('accepted');
    s.advanceStage('processing');
    s.advanceStage('processing');
    s.advanceStage('accepted');
    expect(s.stage, ConversationTurnProcessStage.processing);
    expect(s.observedStages, ['submitted', 'accepted', 'processing']);
    s.advanceStage('responding');
    s.advanceStage('completed');
    expect(s.stage, ConversationTurnProcessStage.completed);
    expect(s.observedStages, [
      'submitted',
      'accepted',
      'processing',
      'responding',
      'completed',
    ]);
  });

  test('unknown stages are ignored', () {
    final s = state();
    s.advanceStage('bogus');
    expect(s.stage, ConversationTurnProcessStage.submitted);
  });

  test('a singleton later stage does not invent missing predecessors', () {
    final s = state();
    s.advanceStage('processing');
    expect(s.stage, ConversationTurnProcessStage.processing);
    expect(s.observedStages, ['processing']);
  });

  test('failed is terminal', () {
    final s = state();
    s.advanceStage('accepted');
    s.advanceStage('failed');
    expect(s.stage, ConversationTurnProcessStage.failed);
    s.advanceStage('processing');
    s.advanceStage('completed');
    expect(s.stage, ConversationTurnProcessStage.failed);
    expect(s.observedStages, ['accepted']);
  });

  test('an explicit reply-backed success renders all five Rust stages', () {
    final s = state();
    for (final stage in [
      'submitted',
      'accepted',
      'processing',
      'responding',
      'completed',
    ]) {
      s.advanceStage(stage);
    }
    s.setReplyText('complete reply', createdAt: '2026-08-07T00:00:01Z');

    expect(s.stage, ConversationTurnProcessStage.completed);
    expect(s.observedStages, [
      'submitted',
      'accepted',
      'processing',
      'responding',
      'completed',
    ]);
    final lifecycle = s.projectedMessages(includeUser: false).first;
    expect(
      lifecycle.cardSubtitle,
      'submitted,accepted,processing,responding,completed',
    );
    expect(s.projectedMessages(includeUser: false).last.text, 'complete reply');
  });

  test('failure locks the exact explicit Rust prefix', () {
    final s = state();
    for (final stage in ['submitted', 'accepted', 'processing']) {
      s.advanceStage(stage);
    }
    s.advanceStage('failed');
    s.advanceStage('responding');
    s.advanceStage('completed');

    expect(s.stage, ConversationTurnProcessStage.failed);
    expect(s.observedStages, ['submitted', 'accepted', 'processing']);
    final lifecycle = s.projectedMessages(includeUser: false).single;
    expect(lifecycle.cardTitle, 'lifecycle.failed');
    expect(lifecycle.cardSubtitle, 'submitted,accepted,processing');
  });

  test('evidence collapses consecutive identical steps', () {
    final s = state();
    s.appendEvidence(_evidence('process-0', 'reasoning', 'reasoning'));
    s.appendEvidence(_evidence('process-1', 'reasoning', 'reasoning'));
    s.appendEvidence(_evidence('process-2', 'tool-call', 'Bash'));
    expect(s.evidence.length, 2);
    expect(s.evidence.last.text, 'Bash');
  });

  test('evidence keeps distinct tools and kind transitions', () {
    final s = state();
    s.appendEvidence(_evidence('process-0', 'reasoning', 'reasoning'));
    s.appendEvidence(_evidence('process-1', 'tool-call', 'Bash'));
    s.appendEvidence(_evidence('process-2', 'tool-call', 'Read'));
    s.appendEvidence(_evidence('process-3', 'reasoning', 'reasoning'));
    s.appendEvidence(_evidence('process-4', 'tool-call', 'Bash'));
    expect(s.evidence.map((message) => message.text), [
      'reasoning',
      'Bash',
      'Read',
      'reasoning',
      'Bash',
    ]);
  });

  test('reply text updates in place', () {
    final s = state();
    expect(s.replyText, '');
    s.setReplyText('hello', createdAt: '2026-08-07T00:00:01Z');
    expect(s.replyText, 'hello');
    s.setReplyText('hello wor', createdAt: '2026-08-07T00:00:02Z');
    expect(s.replyText, 'hello wor');
    expect(s.replyCreatedAt, '2026-08-07T00:00:01Z');
    s.setReplyText('', createdAt: '2026-08-07T00:00:03Z');
    expect(s.replyText, '');
  });

  test('projected messages omit the user Event for group observers', () {
    final s = state();
    s.advanceStage('accepted');
    s.recordParticipant(
      participantAgentId: 'codex',
      participantLabel: 'Codex',
      participantRole: 'member',
    );
    s.setReplyText('hi', createdAt: '2026-08-07T00:00:01Z');
    final group = s.projectedMessages(includeUser: false);
    expect(group.any((message) => message.role == 'user'), isFalse);
    expect(group.first.cardType, 'lifecycle');
    expect(group.first.cardSubtitle, 'accepted');
    expect(group.last.role, 'assistant');
    expect(group.last.text, 'hi');
    final oneToOne = s.projectedMessages();
    expect(oneToOne.first.role, 'user');
    expect(oneToOne.first.text, 'build it');
  });

  test('projection variants cache independently and never serve stale data', () {
    final s = state();
    s.recordParticipant(
      participantAgentId: 'codex',
      participantLabel: 'Codex',
      participantRole: 'member',
    );
    // Populate the with-user variant at revision 0.
    final withUser = s.projectedMessages();
    expect(withUser.first.text, 'build it');
    s.setReplyText('first', createdAt: '2026-08-07T00:00:01Z');
    // Populate the without-user variant at revision 1; this must not make the
    // with-user cache claim revision 1 while still holding revision-0 content.
    final withoutUser = s.projectedMessages(includeUser: false);
    expect(withoutUser.any((message) => message.role == 'user'), isFalse);
    expect(withoutUser.last.text, 'first');

    s.setReplyText('second', createdAt: '2026-08-07T00:00:01Z');
    final withUserAgain = s.projectedMessages();
    expect(withUserAgain.last.text, 'second');
    expect(withUserAgain.first.role, 'user');

    // Unmutated reads return the identical list instance so timeline caches
    // can keep their identity-based fast path.
    expect(identical(s.projectedMessages(), withUserAgain), isTrue);
    expect(
      identical(s.projectedMessages(includeUser: false), withoutUser),
      isFalse,
    );
  });

  test('projection cache invalidates on stage and evidence mutations', () {
    final s = state();
    s.setReplyText('draft', createdAt: '2026-08-07T00:00:01Z');
    final before = s.projectedMessages();
    expect(identical(s.projectedMessages(), before), isTrue);

    s.advanceStage('accepted');
    final afterStage = s.projectedMessages();
    expect(identical(afterStage, before), isFalse);
    expect(
      afterStage.any((message) => message.cardType == 'lifecycle'),
      isTrue,
    );

    s.appendEvidence(_evidence('e1', 'reasoning', 'thinking'));
    final afterEvidence = s.projectedMessages();
    expect(identical(afterEvidence, afterStage), isFalse);
    expect(afterEvidence.any((message) => message.id == 'e1'), isTrue);

    // Duplicate evidence is not a mutation and must not invalidate the cache.
    s.appendEvidence(_evidence('e1', 'reasoning', 'thinking'));
    expect(identical(s.projectedMessages(), afterEvidence), isTrue);
  });
}

AgentConversationMessage _evidence(String id, String cardType, String text) =>
    AgentConversationMessage(
      id: id,
      role: 'event',
      text: text,
      createdAt: '2026-08-07T00:00:00Z',
      cardType: cardType,
      stableIdentity: id,
    );
