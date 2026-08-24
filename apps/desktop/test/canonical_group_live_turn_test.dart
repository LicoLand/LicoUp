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
      final terminal = applyPersistentTurnProcessEvent(
        state: s,
        event: const AgentDispatchEvent(
          kind: 'dispatch.turn.failed',
          payload: {
            'ok': false,
            'lifecyclePrefix': ['submitted', 'accepted'],
            'terminalTransition': {
              'kind': 'failed',
              'code': 'codex_turn_not_completed',
              'stage': 'turn/completed',
              'turnStatus': 'failed/Unauthorized',
            },
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

  test('observer loss does not synthesize a native terminal state', () {
    final s = state();
    s.advanceStage('accepted');
    expect(s.stage, ConversationTurnProcessStage.accepted);
    expect(persistentTurnAllowsNextActor(s), isFalse);
    expect(
      persistentTurnDiagnosticFailureCode(
        '{"code":"codex_turn_not_completed","stage":"turn/completed"}',
      ),
      'codex_turn_not_completed',
    );
  });

  test('processing events appear before any assistant text', () {
    final s = state();
    expect(
      applyPersistentTurnProcessEvent(
        state: s,
        event: const AgentDispatchEvent(
          kind: 'agent.turn.accepted',
          payload: {
            'lifecyclePrefix': ['submitted', 'accepted'],
          },
        ),
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
          payload: {
            'evidenceKind': 'reasoning',
            'lifecyclePrefix': ['submitted', 'accepted', 'processing'],
          },
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

  test('event kinds, ok flags, and reply presence do not own lifecycle', () {
    final s = state();
    for (final event in const [
      AgentDispatchEvent(kind: 'agent.turn.processing'),
      AgentDispatchEvent(
        kind: 'agent.message.chunk',
        payload: {'text': 'synthetic reply'},
      ),
      AgentDispatchEvent(
        kind: 'dispatch.turn.failed',
        payload: {'ok': false, 'code': 'non_canonical_failure'},
      ),
      AgentDispatchEvent(
        kind: 'dispatch.turn.completed',
        payload: {'ok': true},
      ),
    ]) {
      expect(
        applyPersistentTurnProcessEvent(
          state: s,
          event: event,
          agentId: 'codex',
          participantLabel: 'Codex',
        ),
        isFalse,
      );
    }
    expect(s.stage, ConversationTurnProcessStage.submitted);
    expect(s.replyText, 'synthetic reply');
  });

  test(
    'explicit completed terminal renders completed without kind inference',
    () {
      final s = state();
      final terminal = applyPersistentTurnProcessEvent(
        state: s,
        event: const AgentDispatchEvent(
          kind: 'vendor.opaque',
          payload: {
            'lifecyclePrefix': [
              'submitted',
              'accepted',
              'processing',
              'responding',
            ],
            'terminalTransition': {'kind': 'lifecycle', 'stage': 'completed'},
          },
        ),
        agentId: 'codex',
        participantLabel: 'Codex',
      );
      expect(terminal, isTrue);
      expect(s.stage, ConversationTurnProcessStage.completed);
      expect(s.observedStages, [
        'submitted',
        'accepted',
        'processing',
        'responding',
        'completed',
      ]);
    },
  );
}
