import 'message_blocks_test_harness.dart';

void main() {
  testWidgets('message content keeps details and plugins collapsed', (
    tester,
  ) async {
    final adapter = AgentRenderAdapter.fallback();
    const data = '''Visible answer.

<recommended_plugins>
- Plugin One
- Plugin Two
</recommended_plugins>

<ADDITIONAL_METADATA>
Hidden detail value
</ADDITIONAL_METADATA>''';

    await tester.pumpWidget(
      messageBlocksTestApp(
        Builder(
          builder: (context) {
            final colors = context.licoColors;
            return AgentConversationMessageContent(
              data: data,
              foreground: colors.text,
              accent: colors.primary,
              codeBackground: colors.surfaceRaised,
              blockBackground: colors.surface,
              borderColor: colors.line,
              renderStyle: adapter.markdownStyle,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recommended Plugins · 2'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(
      find.textContaining('Hidden detail value', findRichText: true),
      findsNothing,
    );

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Hidden detail value', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(find.text('Recommended Plugins · 2'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Plugin One', findRichText: true),
      findsOneWidget,
    );
  });
}
