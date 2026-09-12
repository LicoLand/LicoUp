import 'message_blocks_test_harness.dart';

void main() {
  test('native subagent_prompt role resolves to the subagent card', () {
    final message = messageBlockTestMessage(
      role: 'subagent_prompt',
      text: 'Discovery worker',
    );
    expect(
      agentConversationMessageKindFor(role: message.role),
      AgentConversationMessageKind.subagent,
    );
    expect(message.isSubagentCard, isTrue);
    expect(message.isDisplayable, isTrue);
  });

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

  testWidgets('expanded card body is height-capped and scrolls like a page', (
    tester,
  ) async {
    final adapter = AgentRenderAdapter.fallback();
    final message = messageBlockTestMessage(
      role: 'subagent',
      cardType: 'subagent',
      cardTitle: 'Deep exploration',
      text: 'Worker preview line',
      childMessages: [
        for (var index = 0; index < 12; index++)
          messageBlockTestMessage(
            id: 'step-$index',
            role: 'assistant',
            text: 'Step $index outcome ${'with some words ' * 8}',
          ),
      ],
    );

    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentConversationSubagentCardBlock(message: message, adapter: adapter),
      ),
    );
    await tester.tap(find.text('Deep exploration'));
    await tester.pumpAndSettle();

    final scrollable = find.byType(ListView);
    expect(scrollable, findsOneWidget);
    final bodyHeight = tester.renderObject<RenderBox>(scrollable).size.height;
    expect(bodyHeight, lessThanOrEqualTo(320));

    // The bounded frame starts at the newest child message and reveals older
    // task content when the reader scrolls upward.
    expect(
      find.textContaining('Step 0 outcome', findRichText: true).hitTestable(),
      findsNothing,
    );
    await tester.drag(scrollable, const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Step 0 outcome', findRichText: true).hitTestable(),
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

  testWidgets('tool-only child retains complete details when expanded', (
    tester,
  ) async {
    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentConversationSubagentCardBlock(
          message: messageBlockTestMessage(
            role: 'subagent',
            text: '',
            cardTitle: 'Tool worker',
            childMessages: [
              messageBlockTestMessage(
                role: 'tool_call',
                text:
                    'Start\n\nDetails one\n\nDetails two\n\nComplete tool result',
                cardType: 'tool_call',
              ),
            ],
          ),
          adapter: AgentRenderAdapter.fallback(),
        ),
      ),
    );
    await tester.tap(find.text('Tool worker'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Complete tool result', findRichText: true),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('subagent-step-run-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Complete tool result', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('native lineage remains expandable beyond four levels', (
    tester,
  ) async {
    AgentConversationMessage nestedTask(int depth) => messageBlockTestMessage(
      id: 'task-$depth',
      role: 'subagent',
      cardType: 'subagent',
      cardTitle: 'Native task $depth',
      text: '',
      childMessages: depth == 5
          ? [
              messageBlockTestMessage(
                role: 'assistant',
                text: 'Deep native result',
              ),
            ]
          : [nestedTask(depth + 1)],
    );
    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentConversationSubagentCardBlock(
          message: nestedTask(0),
          adapter: AgentRenderAdapter.fallback(),
        ),
      ),
    );
    for (var depth = 0; depth <= 5; depth += 1) {
      final title = find.text('Native task $depth');
      await tester.ensureVisible(title);
      await tester.tap(title);
      await tester.pumpAndSettle();
    }
    expect(
      find.textContaining('Deep native result', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
