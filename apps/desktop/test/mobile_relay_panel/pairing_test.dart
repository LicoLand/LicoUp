import 'panel_test_harness.dart';

void main() {
  testWidgets('pairing workspace owns gateway and one-time code details', (
    tester,
  ) async {
    final controller = mobileRelayPanelTestController();
    final urlController = TextEditingController(
      text: 'https://relay.example.test',
    );
    addTearDown(controller.dispose);
    addTearDown(urlController.dispose);
    controller.mobileRelayConfig = controller.mobileRelayConfig.copyWith(
      useCustomGateway: true,
      customGatewayUrl: 'https://relay.example.test',
      pairingId: 'pair-1',
      lastPairingExpiresAt: '2030-01-01T00:00:00Z',
    );

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        child: MobileRelayPairingWorkspaceCard(
          controller: controller,
          customUrlController: urlController,
          presentation: const MobilePairingPresentation(
            pairingCode: 'CODE-1',
            inviteText: 'opaque-pairing-invite',
          ),
          onGenerate: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('mobile-relay-explicit-gateway-field')),
      findsOneWidget,
    );
    expect(find.text('https://relay.example.test'), findsOneWidget);
    expect(find.text('pair-1'), findsOneWidget);
    expect(find.text('CODE-1'), findsOneWidget);
    expect(find.byTooltip('Copy Pairing Code'), findsOneWidget);
  });
}
