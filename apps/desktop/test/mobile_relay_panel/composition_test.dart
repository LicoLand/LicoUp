import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';

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

    // The panel inherits the standard feature-page structure: pane title bar
    // (移动配对 + refresh) above, content below.
    expect(find.byType(LicoPaneScaffold), findsOneWidget);
    expect(find.text('Mobile Pairing'), findsOneWidget);
    expect(find.byKey(const Key('mobile-relay-refresh')), findsOneWidget);
    expect(find.text('Communication'), findsNothing);
    expect(find.byKey(const Key('pairing-qr-workspace-card')), findsOneWidget);
    expect(find.byKey(const Key('pairing-qr-frame')), findsOneWidget);
    expect(find.byType(MobileRelayScanPairingPrompt), findsNothing);
  });
}
