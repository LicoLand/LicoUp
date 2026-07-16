import 'panel_test_harness.dart';

void main() {
  testWidgets('panel composes the desktop pairing workspace', (tester) async {
    final controller = mobileRelayPanelTestController();
    addTearDown(controller.dispose);
    controller.mobileRelayConfig = controller.mobileRelayConfig.copyWith(
      useCustomGateway: true,
      customGatewayUrl: 'https://relay.example.test',
    );

    await tester.pumpWidget(
      mobileRelayPanelTestApp(child: MobileRelayPanel(controller: controller)),
    );
    await tester.pump();

    expect(find.text('Pairing'), findsOneWidget);
    expect(find.byKey(const Key('pairing-qr-workspace-card')), findsOneWidget);
    expect(find.byKey(const Key('pairing-qr-frame')), findsOneWidget);
    expect(find.byType(MobileRelayScanPairingPrompt), findsNothing);
  });
}
