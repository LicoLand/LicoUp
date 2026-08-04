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

  testWidgets('full-width card spans the detail column', (tester) async {
    const paneWidth = 800.0;
    const detailWidth = 600.0;
    final adapter = AgentRenderAdapter.fallback();
    final message = messageBlockTestMessage(
      role: 'subagent',
      cardType: 'subagent',
      cardTitle: 'Retry client after chevron fix',
      text: 'Worker preview line',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: paneWidth,
            height: 400,
            child: Center(
              child: SizedBox(
                width: detailWidth,
                child: AgentConversationSubagentCardBlock(
                  message: message,
                  adapter: adapter,
                  fullWidth: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.renderObject<RenderBox>(
      find.byType(DecoratedBox).first,
    );
    final cardCenter = card.localToGlobal(Offset(card.size.width / 2, 0)).dx;
    expect(cardCenter, closeTo(paneWidth / 2, 1));
    expect(card.size.width, closeTo(detailWidth, 1));
  });
}
