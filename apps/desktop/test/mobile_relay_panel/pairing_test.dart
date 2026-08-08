import 'panel_test_harness.dart';

var _synthSeq = 0;
String _synth(String label) => '$label-${_synthSeq++}';

void main() {
  testWidgets('pairing workspace owns station and one-time code details', (
    tester,
  ) async {
  final sv_code_1 = _synth('CODE-1');
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
          presentation:  MobilePairingPresentation(
            pairingCode: sv_code_1,
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
    expect(find.text(sv_code_1), findsOneWidget);
    expect(find.byTooltip('Copy Pairing Code'), findsOneWidget);
  });
}
