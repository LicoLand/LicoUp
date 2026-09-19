import 'panel_test_harness.dart';

var _synthSeq = 0;
String _synth(String label) => '$label-${_synthSeq++}';

void main() {
  testWidgets('pairing workspace owns station and one-time code details', (
    tester,
  ) async {
  final sv_code_1 = _synth('CODE-1');
    final stationBaseUrlController = TextEditingController(
      text: 'https://station.example.test',
    );
    addTearDown(stationBaseUrlController.dispose);
    final intents = RecordingMobileRelayIntents();
    final projection = MobileRelayProjection(
      peers: const [],
      approvals: const [],
      transfers: const [],
      pairingCode: sv_code_1,
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
          inputs: MobileRelayPairingInputs.fromProjection(projection),
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
    expect(find.text(sv_code_1), findsOneWidget);
    expect(find.byTooltip('Copy Pairing Code'), findsOneWidget);
    expect(intents.values, isEmpty);
  });
}
