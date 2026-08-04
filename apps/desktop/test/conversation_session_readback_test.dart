import 'agents_workspace/support/agents_workspace_test_harness.dart';

void main() {
  test(
    'native readback only clears a live turn when the ordered history tail matches',
    () {
      final controller = ClientController();
      addTearDown(controller.dispose);
      const liveTurn = [
        AgentConversationMessage(
          id: 'live-user',
          role: 'user',
          text: 'Repeat this request',
          createdAt: '2026-06-15T00:00:00Z',
        ),
        AgentConversationMessage(
          id: 'live-assistant',
          role: 'assistant',
          text: 'Repeated response',
          createdAt: '2026-06-15T00:00:01Z',
        ),
      ];
      controller.liveConversationMessagesByAgent = {'codex': liveTurn};

      AgentConversationSession sessionWith(
        List<AgentConversationMessage> messages,
      ) => AgentConversationSession(
        id: 'session-1',
        agentId: 'codex',
        title: 'Repeated conversation',
        createdAt: '2026-06-15T00:00:00Z',
        updatedAt: '2026-06-15T00:00:03Z',
        nativeSessionId: 'native-session-1',
        messages: messages,
      );

      controller.conversationClearLiveProjectionWhenReadBack(
        'codex',
        providerReadback: sessionWith([
          ...liveTurn,
          const AgentConversationMessage(
            id: 'newer-user',
            role: 'user',
            text: 'A different request',
            createdAt: '2026-06-15T00:00:02Z',
          ),
        ]),
      );
      expect(controller.liveConversationMessagesByAgent['codex'], liveTurn);

      controller.conversationClearLiveProjectionWhenReadBack(
        'codex',
        providerReadback: sessionWith([
          const AgentConversationMessage(
            id: 'older-user',
            role: 'user',
            text: 'A different request',
            createdAt: '2026-06-15T00:00:02Z',
          ),
          ...liveTurn,
        ]),
      );
      expect(
        controller.liveConversationMessagesByAgent.containsKey('codex'),
        isFalse,
      );
    },
  );
}
