import 'panel_test_harness.dart';

void main() {
  testWidgets('scan prompt is independently renderable for mobile', (
    tester,
  ) async {
    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        platform: TargetPlatform.android,
        child: Builder(
          builder: (context) => MobileRelayScanPairingPrompt(
            colors: context.licoColors,
            label: 'Scan a pairing code',
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('mobile-relay-scan-pairing-prompt')),
      findsOneWidget,
    );
    expect(find.byType(MinimalScanIcon), findsOneWidget);
    expect(find.text('Scan a pairing code'), findsOneWidget);
  });
}
