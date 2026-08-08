import 'panel_test_harness.dart';

void main() {
  testWidgets('pairing workspace owns station and one-time code details', (
    tester,
  ) async {
    final controller = mobileRelayPanelTestController();
    final stationBaseUrlController = TextEditingController(
      text: 'https://station.example.test',
    );
    addTearDown(controller.dispose);
    addTearDown(stationBaseUrlController.dispose);
    controller.mobileRelayConfig = controller.mobileRelayConfig.copyWith(
      stationBaseUrl: 'https://station.example.test',
      pairingId: 'pair-1',
      lastPairingExpiresAt: '2030-01-01T00:00:00Z',
    );

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        child: MobileRelayPairingWorkspaceCard(
          controller: controller,
          stationBaseUrlController: stationBaseUrlController,
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
      find.byKey(const Key('mobile-relay-station-base-url-field')),
      findsOneWidget,
    );
    expect(find.text('https://station.example.test'), findsOneWidget);
    expect(find.text('pair-1'), findsOneWidget);
    expect(find.text('CODE-1'), findsOneWidget);
    expect(find.byTooltip('Copy Pairing Code'), findsOneWidget);
  });
}
