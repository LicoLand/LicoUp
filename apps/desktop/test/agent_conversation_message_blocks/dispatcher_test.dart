import 'message_blocks_test_harness.dart';

void main() {
  testWidgets('dispatcher selects role and subagent presenters', (
    tester,
  ) async {
    final adapter = AgentRenderAdapter.fallback();

    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentConversationMessageBlock(
          message: messageBlockTestMessage(role: 'user', text: 'User body'),
          adapter: adapter,
        ),
      ),
    );
    expect(find.byType(AgentConversationUserMessageBlock), findsOneWidget);

    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentConversationMessageBlock(
          message: messageBlockTestMessage(
            role: 'subagent',
            cardType: 'subagent',
            cardTitle: 'Worker task',
            text: 'Worker preview',
          ),
          adapter: adapter,
        ),
      ),
    );
    expect(find.byType(AgentConversationSubagentCardBlock), findsOneWidget);
  });
}
