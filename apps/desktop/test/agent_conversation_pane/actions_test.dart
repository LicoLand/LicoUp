import 'pane_test_harness.dart';

void main() {
  testWidgets('pane actions preserve explicit enabled and busy boundaries', (
    tester,
  ) async {
    var newConversationCount = 0;
    var addTargetCount = 0;
    await tester.pumpWidget(
      paneTestApp(
        Column(
          children: [
            NewAgentConversationButton(
              enabled: true,
              tooltip: 'New conversation',
              onPressed: () => newConversationCount += 1,
            ),
            ArchiveAgentConversationsButton(
              busy: true,
              tooltip: 'Archive conversations',
              onPressed: () {},
            ),
            Expanded(
              child: AgentConversationEmptySelection(
                allowManualTargetActions: true,
                onAddTarget: () => addTargetCount += 1,
              ),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.byTooltip('New conversation'));
    await tester.tap(find.text('Add target'));
    await tester.pump();

    expect(newConversationCount, 1);
    expect(addTargetCount, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
