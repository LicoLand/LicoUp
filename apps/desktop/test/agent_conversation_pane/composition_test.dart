import 'pane_test_harness.dart';

void main() {
  testWidgets('pane composition connects header, messages, and composer', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          controller: controller,
          target: paneTestTarget(),
          historyCollapsed: false,
          onToggleHistory: () {},
          collapseHistoryTooltip: 'Collapse history',
          expandHistoryTooltip: 'Expand history',
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ConversationPaneHeader), findsOneWidget);
    expect(find.byType(RuntimeMessageComposer), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
