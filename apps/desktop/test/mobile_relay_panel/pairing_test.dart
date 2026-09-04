import 'panel_test_harness.dart';

void main() {
  testWidgets('pairing workspace owns station and one-time code details', (
    tester,
  ) async {
    final stationBaseUrlController = TextEditingController(
      text: 'https://station.example.test',
    );
    addTearDown(stationBaseUrlController.dispose);
    final intents = RecordingMobileRelayIntents();
    final projection = MobileRelayProjection(
      peers: const [],
      approvals: const [],
      transfers: const [],
      pairingCode: 'CODE-1',
      pairingInvite: 'opaque-pairing-invite',
      pairingId: 'pair-1',
      pairingExpiresLabel: '2030-01-01T00:00:00Z',
      stationLabel: 'https://station.example.test',
      stationConfigured: true,
      phase: PresentationPhase.ready,
    );

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        child: MobileRelayPairingWorkspaceCard(
          projection: projection,
          intents: intents,
          stationBaseUrlController: stationBaseUrlController,
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
    expect(intents.values, isEmpty);
  });
}
