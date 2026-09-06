import 'panel_test_harness.dart';

void main() {
  testWidgets('trust card renders exact verification evidence', (tester) async {
    final presentation = RelayTrustProjection(
      schemaVersion: 'secure-mesh.trust-presentation.v1',
      protocolVersion: 'secure-mesh.device-trust.v2',
      localFingerprint: 'local-fingerprint',
      peerFingerprint: 'peer-fingerprint',
      safetyNumberGroups: [
        '00001',
        '00002',
        '00003',
        '00004',
        '00005',
        '00006',
        '00007',
        '00008',
        '00009',
        '00010',
        '00011',
        '00012',
      ],
      qrPayload: 'opaque-trust-qr',
      trustState: 'verified',
      verificationMethod: 'pairing_claim_proof',
      verified: true,
    );

    await tester.pumpWidget(
      mobileRelayPanelTestApp(
        child: Builder(
          builder: (context) => SingleChildScrollView(
            child: MobileRelayTrustVerificationCard(
              presentation: presentation,
              colors: context.licoColors,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('secure-mesh-trust-verification-card')),
      findsOneWidget,
    );
    expect(find.text('Verified — protected send enabled'), findsOneWidget);
    expect(
      find.byKey(const Key('secure-mesh-60-digit-safety-number')),
      findsOneWidget,
    );
    expect(find.text('local-fingerprint'), findsOneWidget);
    expect(find.text('peer-fingerprint'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
  });
}
