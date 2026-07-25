import 'panel_test_harness.dart';

void main() {
  testWidgets('QR frame gates generation and renders an invite', (
    tester,
  ) async {
    var generationCalls = 0;

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        child: MobileRelayPairingQrFrame(
          inviteText: '',
          busy: false,
          gatewayConfigured: false,
          onGenerate: () async {
            generationCalls += 1;
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('pairing-qr-frame')));
    await tester.pump();
    expect(generationCalls, 0);

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        child: MobileRelayPairingQrFrame(
          inviteText: '',
          busy: false,
          gatewayConfigured: true,
          onGenerate: () async {
            generationCalls += 1;
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('pairing-qr-frame')));
    await tester.pump();
    expect(generationCalls, 1);

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        child: MobileRelayPairingQrFrame(
          inviteText: 'opaque-pairing-invite',
          busy: false,
          gatewayConfigured: true,
          onGenerate: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Scan This QR Code To Pair Your Phone'), findsOneWidget);
  });
}
