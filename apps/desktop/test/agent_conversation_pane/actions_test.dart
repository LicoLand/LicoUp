import 'pane_test_harness.dart';

void main() {
  testWidgets('pane actions preserve explicit enabled and busy boundaries', (
    tester,
  ) async {
    var newConversationCount = 0;
    var archiveCount = 0;
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
              onPressed: () => archiveCount += 1,
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.byTooltip('New conversation'));
    await tester.tap(find.byTooltip('Archive conversations'));
    await tester.pump();

    expect(newConversationCount, 1);
    expect(archiveCount, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
