import 'panel_test_harness.dart';

void main() {
  testWidgets('panel composes the desktop pairing workspace', (tester) async {
    final fixture = MobileRelayBindingFixture(
      projection: mobileRelayProjectionFixture(
        stationLabel: 'https://station.example.test',
        stationConfigured: true,
      ),
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        child: MobileRelayPanel(binding: fixture.binding),
      ),
    );
    await tester.pump();

    expect(find.text('Communication'), findsOneWidget);
    expect(find.byKey(const Key('pairing-qr-workspace-card')), findsOneWidget);
    expect(find.byKey(const Key('pairing-qr-frame')), findsOneWidget);
    expect(find.byType(MobileRelayScanPairingPrompt), findsNothing);
  });
}
