import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/application/features/agents/conversation/persistent_turn_process_observer.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';

void main() {
  ConversationTurnProcessState state() => ConversationTurnProcessState(
    turnId: 'live-dispatch:entry',
    userText: 'hi',
    createdAt: '2026-08-19T00:00:00Z',
  );

  test(
    'empty-text failure still advances the process card and is terminal',
    () {
      final s = state();
      s.advanceStage('accepted');
      final terminal = applyPersistentTurnProcessEvent(
        state: s,
        event: const AgentDispatchEvent(
          kind: 'dispatch.turn.failed',
          payload: {
            'turnStatus': 'failed/Unauthorized',
            'code': 'codex_turn_not_completed',
          },
        ),
        agentId: 'codex',
        participantLabel: 'Codex',
      );
      expect(terminal, isTrue);
      expect(s.stage, ConversationTurnProcessStage.failed);
      expect(s.observedStages, ['submitted', 'accepted']);
      expect(s.replyText, isEmpty);
      final live = s.projectedMessages(includeUser: false);
      expect(live.first.cardType, 'lifecycle');
      expect(live.first.cardTitle, 'lifecycle.failed');
      expect(
        live.any(
          (message) =>
              message.cardType == 'diagnostic' &&
              message.text.contains('codex_turn_not_completed') &&
              message.text.contains('failed/Unauthorized'),
        ),
        isTrue,
      );
    },
  );

  test(
    'a stream that dies before completed does not wait for a next actor',
    () {
      final s = state();
      s.advanceStage('accepted');
      failPersistentTurnIfOpen(s);
      expect(s.stage, ConversationTurnProcessStage.failed);
      expect(persistentTurnAllowsNextActor(s), isFalse);
      expect(
        persistentTurnDiagnosticFailureCode(
          '{"code":"codex_turn_not_completed","stage":"turn/completed"}',
        ),
        'codex_turn_not_completed',
      );
    },
  );

  test('processing events appear before any assistant text', () {
    final s = state();
    expect(
      applyPersistentTurnProcessEvent(
        state: s,
        event: const AgentDispatchEvent(kind: 'agent.turn.accepted'),
        agentId: 'codex',
        participantLabel: 'Codex',
      ),
      isFalse,
    );
    expect(
      applyPersistentTurnProcessEvent(
        state: s,
        event: const AgentDispatchEvent(
          kind: 'agent.turn.processing',
          payload: {'evidenceKind': 'reasoning'},
        ),
        agentId: 'codex',
        participantLabel: 'Codex',
      ),
      isFalse,
    );
    expect(s.stage, ConversationTurnProcessStage.processing);
    expect(s.observedStages, ['submitted', 'accepted', 'processing']);
    expect(s.projectedMessages(includeUser: false), isNotEmpty);
  });
}
