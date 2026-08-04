import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';

import '../agent_conversation_pane/pane_test_harness.dart';

void main() {
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
      orchestrationSelected: false,
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
