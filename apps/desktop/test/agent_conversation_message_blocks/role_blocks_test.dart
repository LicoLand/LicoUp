import 'message_blocks_test_harness.dart';

void main() {
  testWidgets('role blocks preserve user and assistant layouts', (
    tester,
  ) async {
    final adapter = AgentRenderAdapter.fallback();

    await tester.pumpWidget(
      messageBlocksTestApp(
        Column(
          children: [
            AgentConversationUserMessageBlock(
              message: messageBlockTestMessage(
                role: 'user',
                text: 'User role body',
              ),
              adapter: adapter,
            ),
            AgentConversationAssistantDocumentBlock(
              message: messageBlockTestMessage(
                role: 'assistant',
                text: 'Assistant role body',
              ),
              adapter: adapter,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('User role body', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Assistant role body', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(AgentConversationMessageContent), findsNWidgets(2));
  });
}
