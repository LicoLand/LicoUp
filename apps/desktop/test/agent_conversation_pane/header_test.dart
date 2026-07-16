import 'pane_test_harness.dart';

void main() {
  testWidgets('header owns session identity and sidebar toggle interaction', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    var toggleCount = 0;
    const session = AgentConversationSession(
      id: 'session-1',
      agentId: 'codex',
      title: 'Focused session',
      createdAt: '2026-07-16T00:00:00Z',
      updatedAt: '2026-07-16T00:00:00Z',
      messages: [],
    );
    await tester.pumpWidget(
      paneTestApp(
        ConversationPaneHeader(
          controller: controller,
          target: paneTestTarget(),
          session: session,
          historyCollapsed: false,
          onToggleHistory: () => toggleCount += 1,
          collapseHistoryTooltip: 'Collapse history',
          expandHistoryTooltip: 'Expand history',
        ),
      ),
    );

    expect(find.text('Focused session'), findsOneWidget);
    await tester.tap(find.byTooltip('Collapse history'));
    await tester.pump();
    expect(toggleCount, 1);
  });
}
