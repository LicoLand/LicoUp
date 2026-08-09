import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';

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
      controller.liveConversationMessagesByScope = {'session:codex:session-1': liveTurn};

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
      expect(controller.liveConversationMessagesByScope['session:codex:session-1'], liveTurn);

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
        controller.liveConversationMessagesByScope.containsKey('session:codex:session-1'),
        isFalse,
      );
    },
  );

  test(
    'multi-block assistant readback still clears the live turn',
    () {
      final controller = ClientController();
      addTearDown(controller.dispose);
      const liveTurn = [
        AgentConversationMessage(
          id: 'live-user',
          role: 'user',
          text: 'Build and install it',
          createdAt: '2026-06-15T00:00:00Z',
        ),
        AgentConversationMessage(
          id: 'live-assistant',
          role: 'assistant',
          text: 'Installed successfully',
          createdAt: '2026-06-15T00:00:05Z',
        ),
      ];
      controller.liveConversationMessagesByScope = {'session:codex:session-1': liveTurn};

      // The native transcript records one assistant reply with tool calls as
      // several content blocks: two assistant text messages around a tool card.
      const multiBlockReadback = [
        AgentConversationMessage(
          id: 'native-user',
          role: 'user',
          text: 'Build and install it',
          createdAt: '2026-06-15T00:00:00Z',
        ),
        AgentConversationMessage(
          id: 'native-assistant-1',
          role: 'assistant',
          text: 'I will build it.',
          createdAt: '2026-06-15T00:00:01Z',
        ),
        AgentConversationMessage(
          id: 'native-tool',
          role: 'tool_call',
          text: '',
          createdAt: '2026-06-15T00:00:02Z',
        ),
        AgentConversationMessage(
          id: 'native-assistant-2',
          role: 'assistant',
          text: 'Installed successfully',
          createdAt: '2026-06-15T00:00:05Z',
        ),
      ];
      controller.conversationClearLiveProjectionWhenReadBack(
        'codex',
        providerReadback: AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Multi-block conversation',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:06Z',
          nativeSessionId: 'native-session-1',
          messages: multiBlockReadback,
        ),
      );
      expect(
        controller.liveConversationMessagesByScope.containsKey('session:codex:session-1'),
        isFalse,
      );
    },
  );

  test(
    'readback must not clear a live projection while its turn is still streaming',
    () {
      final controller = ClientController();
      addTearDown(controller.dispose);
      const scopeKey = 'session:codex:session-1';
      const liveTurn = [
        AgentConversationMessage(
          id: 'live-user',
          role: 'user',
          text: 'Repeat this request',
          createdAt: '2026-06-15T00:00:00Z',
        ),
      ];
      controller.liveConversationMessagesByScope = {scopeKey: liveTurn};
      controller.conversationTurnProcessStateByScope = {
        scopeKey: ConversationTurnProcessState(
          turnId: 'live-turn-1',
          userText: 'Repeat this request',
          createdAt: '2026-06-15T00:00:00Z',
          scopeKey: scopeKey,
        ),
      };

      // The pending user message trivially matches the native readback, but
      // the turn blackboard has not reached a terminal stage: the projection
      // must survive so the streamed reply and evidence keep landing.
      controller.conversationClearLiveProjectionWhenReadBack(
        'codex',
        providerReadback: AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Repeated conversation',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:01Z',
          nativeSessionId: 'native-session-1',
          messages: liveTurn,
        ),
      );
      expect(
        controller.liveConversationMessagesByScope.containsKey(scopeKey),
        isTrue,
      );
      expect(
        controller.conversationTurnProcessStateByScope.containsKey(scopeKey),
        isTrue,
      );
    },
  );

  test(
    'a refresh catalog commit keeps the turn projection while the turn streams',
    () {
      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'session-1';
      const scopeKey = 'session:codex:session-1';
      final turnProjection = AgentConversationSession(
        id: 'session-1',
        agentId: 'codex',
        title: 'Repeated conversation',
        createdAt: '2026-06-15T00:00:00Z',
        updatedAt: '2026-06-15T00:00:03Z',
        nativeSessionId: 'native-session-1',
        messages: [
          const AgentConversationMessage(
            id: 'turn-user',
            role: 'user',
            text: 'Repeat this request',
            createdAt: '2026-06-15T00:00:00Z',
          ),
          const AgentConversationMessage(
            id: 'turn-assistant',
            role: 'assistant',
            text: 'Repeated response',
            createdAt: '2026-06-15T00:00:01Z',
          ),
        ],
      );
      controller.conversationSessionsByAgent = {
        'codex': [turnProjection],
      };
      controller.liveConversationMessagesByScope = {
        scopeKey: const [
          AgentConversationMessage(
            id: 'live-user',
            role: 'user',
            text: 'Repeat this request',
            createdAt: '2026-06-15T00:00:00Z',
          ),
        ],
      };
      controller.conversationTurnProcessStateByScope = {
        scopeKey: ConversationTurnProcessState(
          turnId: 'live-turn-1',
          userText: 'Repeat this request',
          createdAt: '2026-06-15T00:00:00Z',
          scopeKey: scopeKey,
        ),
      };
      // Provider history only persisted the pending user message so far.
      const readbackOnlyUser = [
        AgentConversationMessage(
          id: 'native-user',
          role: 'user',
          text: 'Repeat this request',
          createdAt: '2026-06-15T00:00:00Z',
        ),
      ];

      controller.conversationCommitCatalog(
        'codex',
        const ConversationSessionPage(
          sessions: [
            AgentConversationSession(
              id: 'session-1',
              agentId: 'codex',
              title: 'Repeated conversation',
              createdAt: '2026-06-15T00:00:00Z',
              updatedAt: '2026-06-15T00:00:02Z',
              nativeSessionId: 'native-session-1',
              messages: readbackOnlyUser,
            ),
          ],
          hasMore: false,
        ),
        replaceAll: true,
        updateStatus: false,
        notifyChanges: false,
      );

      // The readback trivially covers the pending user message, but the
      // streaming turn must neither be swapped out of the catalog nor have its
      // live projection cleared: the streamed reply still has to land.
      final cataloged = controller.conversationSessionsByAgent['codex']!;
      expect(cataloged, hasLength(1));
      expect(cataloged.single.messages.map((message) => message.text), [
        'Repeat this request',
        'Repeated response',
      ]);
      expect(
        controller.liveConversationMessagesByScope.containsKey(scopeKey),
        isTrue,
      );
      expect(
        controller.conversationTurnProcessStateByScope.containsKey(scopeKey),
        isTrue,
      );
    },
  );

  test(
    'the same readback clears the projection once the turn is completed',
    () {
      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'session-1';
      const scopeKey = 'session:codex:session-1';
      final turnProjection = AgentConversationSession(
        id: 'session-1',
        agentId: 'codex',
        title: 'Repeated conversation',
        createdAt: '2026-06-15T00:00:00Z',
        updatedAt: '2026-06-15T00:00:03Z',
        nativeSessionId: 'native-session-1',
        messages: [
          const AgentConversationMessage(
            id: 'turn-user',
            role: 'user',
            text: 'Repeat this request',
            createdAt: '2026-06-15T00:00:00Z',
          ),
          const AgentConversationMessage(
            id: 'turn-assistant',
            role: 'assistant',
            text: 'Repeated response',
            createdAt: '2026-06-15T00:00:01Z',
          ),
        ],
      );
      controller.conversationSessionsByAgent = {
        'codex': [turnProjection],
      };
      controller.liveConversationMessagesByScope = {
        scopeKey: const [
          AgentConversationMessage(
            id: 'live-user',
            role: 'user',
            text: 'Repeat this request',
            createdAt: '2026-06-15T00:00:00Z',
          ),
        ],
      };
      final completedState = ConversationTurnProcessState(
        turnId: 'live-turn-1',
        userText: 'Repeat this request',
        createdAt: '2026-06-15T00:00:00Z',
        scopeKey: scopeKey,
      )..advanceStage('completed');
      controller.conversationTurnProcessStateByScope = {
        scopeKey: completedState,
      };

      controller.conversationCommitCatalog(
        'codex',
        const ConversationSessionPage(
          sessions: [
            AgentConversationSession(
              id: 'session-1',
              agentId: 'codex',
              title: 'Repeated conversation',
              createdAt: '2026-06-15T00:00:00Z',
              updatedAt: '2026-06-15T00:00:02Z',
              nativeSessionId: 'native-session-1',
              messages: [
                AgentConversationMessage(
                  id: 'native-user',
                  role: 'user',
                  text: 'Repeat this request',
                  createdAt: '2026-06-15T00:00:00Z',
                ),
              ],
            ),
          ],
          hasMore: false,
        ),
        replaceAll: true,
        updateStatus: false,
        notifyChanges: false,
      );

      // The turn reached a terminal stage, so the completed projection can be
      // replaced by the authoritative native readback as before.
      final cataloged = controller.conversationSessionsByAgent['codex']!;
      expect(cataloged, hasLength(1));
      expect(cataloged.single.messages.map((message) => message.text), [
        'Repeat this request',
      ]);
      expect(
        controller.liveConversationMessagesByScope.containsKey(scopeKey),
        isFalse,
      );
      expect(
        controller.conversationTurnProcessStateByScope.containsKey(scopeKey),
        isFalse,
      );
    },
  );
}
