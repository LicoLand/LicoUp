import 'panel_test_harness.dart';

var _synthSeq = 0;
String _synth(String label) => '$label-${_synthSeq++}';

void main() {
  testWidgets('pairing workspace owns gateway and one-time code details', (
    tester,
  ) async {
  final sv_code_1 = _synth('CODE-1');
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
      find.byKey(const Key('mobile-relay-explicit-gateway-field')),
      findsOneWidget,
    );
    expect(find.text('https://relay.example.test'), findsOneWidget);
    expect(find.text('pair-1'), findsOneWidget);
    expect(find.text(sv_code_1), findsOneWidget);
    expect(find.byTooltip('Copy Pairing Code'), findsOneWidget);
  });
}
