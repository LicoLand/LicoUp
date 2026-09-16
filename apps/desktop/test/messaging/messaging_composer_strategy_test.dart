import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_scroll_to_latest_button.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';

import '../agent_conversation_pane/pane_test_harness.dart';

void main() {
  testWidgets(
    'growing composer leaves the final message and jump action unobscured',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final messages = List.generate(
        30,
        (index) => AgentConversationMessage(
          id: 'message-$index',
          role: 'user',
          text: 'Synthetic message $index',
          createdAt: '2026-09-16T00:00:00Z',
        ),
      );
      await tester.pumpWidget(
        paneTestApp(
          LayoutAgentsStrategyScope(
            strategy: const AgentsPresentationStrategy.messaging(),
            child: AgentConversationActivePane(
              state: paneTestState(liveMessages: messages, turnActive: false),
              actions: paneTestActions(),
              header: paneTestHeader(),
              messageScrollController: scroll,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('agent-conversation-composer-field'));
      final originalHeight = tester.getSize(field).height;
      await tester.enterText(
        find.byType(TextField),
        'first line\nsecond line\nthird line\nfourth line',
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(field).height, greaterThan(originalHeight));
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      final last = find.text('Synthetic message 29');
      expect(last, findsOneWidget);
      expect(tester.getRect(last).bottom, lessThan(tester.getRect(field).top));
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final jump = find.byType(MessagingScrollToLatestButton);
      expect(jump, findsOneWidget);
      expect(tester.getRect(jump).bottom, lessThan(tester.getRect(field).top));
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(tester.getRect(last).bottom, lessThan(tester.getRect(field).top));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('console strategy keeps the composer runtime settings bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.console(),
          child: _strategyPane(),
        ),
      ),
    );

    expect(find.byType(ConversationRuntimeSettingsBar), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('messaging strategy hides the composer runtime settings bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.messaging(),
          child: _strategyPane(),
        ),
      ),
    );

    expect(find.byType(ConversationRuntimeSettingsBar), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });
}

Widget _strategyPane() {
  return AgentConversationActivePane(
    state: AgentConversationPaneState(
      target: paneTestTarget(),
      session: null,
      liveMessages: const [],
      recentSessions: const [],
      loading: false,
      turnActive: false,
      preparingNewConversation: false,
      composerEnabled: true,
      sendGateReasonCode: '',
      composerDraft: '',
      modelOptions: const ['fixture-model'],
      selectedModel: 'fixture-model',
      defaultModel: 'fixture-model',
      reasoningEffortOptions: const [],
      selectedReasoningEffort: '',
      showWorkingDirectory: false,
      workingDirectory: '',
      workingDirectorySelectable: false,
    ),
    actions: paneTestActions(),
    header: paneTestHeader(),
  );
}
