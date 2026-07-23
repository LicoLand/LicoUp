import 'pane_test_harness.dart';

void main() {
  testWidgets('pane composition connects header, messages, and composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ConversationPaneHeader), findsOneWidget);
    expect(find.byType(RuntimeMessageComposer), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new conversation reveals live messages as soon as send starts', (
    tester,
  ) async {
    const recentSession = AgentConversationSession(
      id: 'recent-session',
      agentId: 'codex',
      title: 'Recent session',
      createdAt: '2026-07-23T00:00:00Z',
      updatedAt: '2026-07-23T00:00:00Z',
      messages: [],
    );

    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            recentSessions: const [recentSession],
            preparingNewConversation: true,
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    expect(find.text('Recent conversations'), findsOneWidget);

    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            recentSessions: const [recentSession],
            preparingNewConversation: true,
            liveMessages: const [
              AgentConversationMessage(
                id: 'synthetic-turn',
                role: 'user',
                text: 'Synthetic live prompt',
                createdAt: '2026-07-23T00:00:01Z',
              ),
            ],
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );

    expect(find.text('Recent conversations'), findsNothing);
    expect(find.text('Synthetic live prompt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed failed send remains visible beside the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            turnActive: false,
            sendGateReasonCode: 'native_agent_transport_failed',
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('conversation-send-failed')), findsOneWidget);
    expect(
      find.byKey(const Key('conversation-send-failed-reason')),
      findsOneWidget,
    );
    expect(
      find.textContaining('native_agent_transport_failed'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
