import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_client/src/controllers/future_client_controller.dart';
import 'package:flutter_client/src/services/agent_service.dart';
import 'package:flutter_client/src/services/portable_data_root.dart';
import 'package:flutter_client/src/ui/mobile_relay_panel.dart';
import 'package:flutter_client/src/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MobileRelayPanel exposes device trust and pairing controls', (
    tester,
  ) async {
    final dataDirectory = Directory.systemTemp.createTempSync(
      'lico-secure-mesh-panel-',
    );
    addTearDown(() {
      if (dataDirectory.existsSync()) {
        dataDirectory.deleteSync(recursive: true);
      }
    });

    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
      agentService: AgentService(
        runCliExecutable: (_, _, _) async {
          throw StateError('panel evidence test does not execute CLI calls');
        },
      ),
    );
    addTearDown(controller.dispose);

    controller.mobileRelayConfig = controller.mobileRelayConfig.copyWith(
      pairingId: 'pair-1',
      pcToken: 'pc-token',
      lastPairingCode: '1234-5678',
      lastPairingExpiresAt: '2026-06-12T12:00:00Z',
      paired: true,
      relayEnabled: true,
    );
    controller.secureMeshStatus = {
      'protocolVersion': 'licolite.secure-mesh.v1',
      'pairwiseCryptoStatus': 'pairwise-runtime-available',
      'mlsCryptoStatus': 'mls-runtime-available',
      'fileCryptoStatus': 'file-runtime-available',
      'commandSecurityStatus': 'command-policy-ready',
      'deviceTrustStatus': 'device-trust-ready',
      'cryptoCoreStatus': 'blocked_for_production',
    };
    controller.secureMeshDeviceTrustPolicy = {
      'ok': true,
      'protocolVersion': 'licolite.secure-mesh.device-trust.v1',
      'trustState': 'verified',
      'decision': {
        'code': 'trusted',
        'allowedForPrekey': true,
        'allowedForHighRiskCommand': true,
        'allowedForReadOnlyCommand': true,
      },
    };
    controller.secureMeshFileRoute = {
      'ok': true,
      'route': {
        'uploadOperation': 'secure_mesh.file_chunk.upload',
        'fetchOperation': 'secure_mesh.file_chunk.fetch',
      },
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(),
        home: Scaffold(body: MobileRelayPanel(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.text('Secure Mesh'), findsOneWidget);
    expect(find.text('Device Trust'), findsOneWidget);
    expect(find.text('Trust Policy'), findsOneWidget);
    expect(find.text('trusted'), findsOneWidget);
    expect(
      find.text('secure_mesh.file_chunk.upload / secure_mesh.file_chunk.fetch'),
      findsOneWidget,
    );

    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pump();

    expect(find.text('Pairing'), findsOneWidget);
    expect(find.text('Create Code'), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_2_outlined), findsOneWidget);
  });
}
