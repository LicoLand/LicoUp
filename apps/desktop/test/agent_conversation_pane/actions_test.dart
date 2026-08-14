import 'pane_test_harness.dart';

void main() {
  testWidgets('pane actions preserve explicit enabled and busy boundaries', (
    tester,
  ) async {
    var newConversationCount = 0;
    var newGroupCount = 0;
    var mobilePairingCount = 0;
    var settingsCount = 0;
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
              child: AgentConversationWelcome(
                onNewConversation: () => newConversationCount += 1,
                onNewGroupConversation: () => newGroupCount += 1,
                onOpenMobilePairing: () => mobilePairingCount += 1,
                onOpenSettings: () => settingsCount += 1,
              ),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.byTooltip('New conversation'));
    await tester.tap(find.byKey(const Key('welcome-new-conversation')));
    await tester.tap(find.byKey(const Key('welcome-new-group-conversation')));
    await tester.tap(find.byKey(const Key('welcome-mobile-pairing')));
    await tester.tap(find.byKey(const Key('welcome-settings')));
    await tester.pump();

    expect(newConversationCount, 2);
    expect(newGroupCount, 1);
    expect(mobilePairingCount, 1);
    expect(settingsCount, 1);
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('welcome actions fit a compact window at 200% text scale', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      paneTestApp(
        AgentConversationWelcome(
          onNewConversation: () {},
          onNewGroupConversation: () {},
          onOpenMobilePairing: () {},
          onOpenSettings: () {},
        ),
        width: 360,
        height: 300,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('agent-conversation-welcome-actions')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
