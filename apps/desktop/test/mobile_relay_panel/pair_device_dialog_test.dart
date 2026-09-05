import 'panel_test_harness.dart';

void main() {
  testWidgets('pairing remains user-triggered and completes from its effect', (
    tester,
  ) async {
    final fixture = MobileRelayBindingFixture();
    addTearDown(fixture.dispose);
    late Future<void> Function(String value) submitCapture;

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        platform: TargetPlatform.android,
        child: PairDeviceDialog(
          binding: fixture.binding,
          scannerPreviewBuilder: (context, onDetect) {
            submitCapture = onDetect;
            return const ColoredBox(color: Colors.black);
          },
        ),
      ),
    );
    await tester.pump();

    expect(fixture.intents.values, isEmpty);
    final capture = submitCapture('licoup://pair?invite=synthetic');
    await tester.pump();

    expect(fixture.intents.values, hasLength(1));
    expect(fixture.intents.values.single, isA<ClaimRelayPairing>());
    expect(
      (fixture.intents.values.single as ClaimRelayPairing).invite,
      'licoup://pair?invite=synthetic',
    );
    expect(find.text('QR detected, pairing...'), findsOneWidget);

    fixture.effects.add(const RelayPairingClaimed());
    await tester.pump(const Duration(milliseconds: 360));
    await capture;
    await tester.pump();

    expect(find.text('Scan successful. Device paired.'), findsOneWidget);
  });
}
