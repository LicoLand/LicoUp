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

  test('failed is terminal', () {
    final s = state();
    s.advanceStage('accepted');
    s.advanceStage('failed');
    expect(s.stage, ConversationTurnProcessStage.failed);
    s.advanceStage('processing');
    s.advanceStage('completed');
    expect(s.stage, ConversationTurnProcessStage.failed);
    expect(s.observedStages, ['submitted', 'accepted', 'failed']);
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
    expect(group.first.cardSubtitle, 'submitted,accepted');
    expect(group.last.role, 'assistant');
    expect(group.last.text, 'hi');
    final oneToOne = s.projectedMessages();
    expect(oneToOne.first.role, 'user');
    expect(oneToOne.first.text, 'build it');
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
