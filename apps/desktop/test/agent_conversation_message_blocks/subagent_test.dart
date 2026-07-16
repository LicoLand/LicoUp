import 'message_blocks_test_harness.dart';

void main() {
  testWidgets('subagent card reveals child messages on demand', (tester) async {
    final adapter = AgentRenderAdapter.fallback();
    final message = messageBlockTestMessage(
      role: 'subagent',
      cardType: 'subagent',
      cardTitle: 'Discovery worker',
      text: 'Worker preview line',
      childMessages: [
        messageBlockTestMessage(
          role: 'assistant',
          text: 'Detailed worker result',
        ),
      ],
    );

    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentConversationSubagentCardBlock(message: message, adapter: adapter),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Discovery worker'), findsOneWidget);
    expect(find.text('Worker preview line'), findsOneWidget);
    expect(
      find.textContaining('Detailed worker result', findRichText: true),
      findsNothing,
    );

    await tester.tap(find.text('Discovery worker'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Detailed worker result', findRichText: true),
      findsOneWidget,
    );
  });
}
