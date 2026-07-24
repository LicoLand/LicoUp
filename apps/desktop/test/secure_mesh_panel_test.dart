import 'dart:io';

import 'package:flutter/material.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/client_clipboard_service.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';
import 'package:licoup/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/secure_mesh_capability_projection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'MobileRelayPanel hides diagnostics and exposes pairing controls',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final dataDirectory = Directory.systemTemp.createTempSync(
        'lico-secure-mesh-panel-',
      );
      addTearDown(() {
        if (dataDirectory.existsSync()) {
          dataDirectory.deleteSync(recursive: true);
        }
      });

      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
        agentService: AgentService(
          runCliExecutable: (_, _, _) async {
            throw StateError('panel evidence test does not execute CLI calls');
          },
        ),
      );
      addTearDown(controller.dispose);

      controller.mobileRelayConfig = controller.mobileRelayConfig.copyWith(
        useCustomGateway: true,
        customGatewayUrl: 'https://relay.example.test',
        pairingId: 'pair-1',
        pcToken: 'pc-token',
        lastPairingCode: '1234-5678',
        lastPairingExpiresAt: '2026-06-12T12:00:00Z',
        paired: true,
        relayEnabled: true,
      );
      controller.secureMeshStatus = {
        'protocolVersion': 'licomesh.secure-mesh.v1',
        'pairwiseCryptoStatus': 'pairwise-runtime-available',
        'mlsCryptoStatus': 'mls-runtime-available',
        'fileCryptoStatus': 'file-runtime-available',
        'commandSecurityStatus': 'command-policy-ready',
        'deviceTrustStatus': 'device-trust-ready',
        'cryptoCoreStatus': 'blocked_for_production',
        'mobileRelayE2eeStatus': {
          'productionReady': false,
          'secretStore': {
            'persistentBackend':
                'portable_config_pending_platform_secret_store',
            'productionBlocker':
                'endpoint_private_key_is_persisted_in_portable_config',
          },
        },
        'mobileRelayE2eeSecretStore': {
          'persistentBackend': 'portable_config_pending_platform_secret_store',
          'productionBlocker':
              'endpoint_private_key_is_persisted_in_portable_config',
        },
      };
      controller.secureMeshDeviceTrustPolicy = {
        'ok': true,
        'protocolVersion': 'licomesh.secure-mesh.device-trust.v2',
        'trustState': 'verified',
        'decision': {
          'code': 'trusted',
          'allowedForPrekey': true,
          'allowedForHighRiskCommand': true,
          'allowedForReadOnlyCommand': true,
        },
      };
      controller.mobileRelayActionResult = {
        'config': {
          'mobileRelayPairingInvite': {
            'protocolVersion': 'licomesh.mobile-relay.e2ee.v2',
            'gatewayUrl': 'https://relay.example.test',
            'pairingId': 'pair-1',
            'pairingCode': '1234-5678',
            'pcSecureMesh': {'endpointId': 'pc'},
            'e2eePairingSecret': 'secret',
          },
        },
      };
      controller.secureMeshFileRoute = {
        'ok': true,
        'route': {
          'uploadOperation': 'secure_mesh.file_chunk.upload',
          'fetchOperation': 'secure_mesh.file_chunk.fetch',
        },
      };
      controller.secureMeshFileReceiveDestination = {
        'ok': true,
        'receivePolicy': {
          'destinationApproved': true,
          'destinationPathRedacted': true,
          'conflictPolicy': 'fail_if_exists',
          'writeOperation': 'secure_mesh.file_receive.write',
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(body: MobileRelayPanel(controller: controller)),
        ),
      );
      await tester.pump();

      expect(find.byType(PanelFrame), findsNothing);
      expect(find.text('Gateway'), findsOneWidget);
      expect(find.text('LicoUp Gateway'), findsNothing);
      expect(find.text('Custom Gateway'), findsNothing);
      expect(find.text('Address'), findsNothing);
      expect(find.text('licomesh.app'), findsNothing);
      expect(find.text('https://relay.example.test'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      final gatewayEditable = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText &&
            widget.controller.text == 'https://relay.example.test',
      );
      expect(gatewayEditable, findsOneWidget);
      expect(tester.widget<EditableText>(gatewayEditable).readOnly, isFalse);
      expect(find.text('Default'), findsNothing);
      expect(find.text('Active'), findsNothing);
      expect(find.text('Private Cloud Gateway URL'), findsNothing);
      expect(find.text('Relay Status'), findsNothing);
      expect(find.text('Paired Computer'), findsNothing);
      expect(find.text('Available Agents'), findsNothing);
      expect(find.text('Recent Commands'), findsNothing);
      expect(find.text('Execution Records'), findsNothing);
      expect(find.text('Secure Mesh'), findsNothing);
      expect(find.text('Device Trust'), findsNothing);
      expect(find.text('Trust Policy'), findsNothing);
      expect(find.text('Trusted'), findsNothing);
      expect(find.text('E2EE Readiness'), findsNothing);
      expect(find.text('Secret Store'), findsNothing);
      expect(find.text('File Route'), findsNothing);
      expect(find.text('File Receive Destination'), findsNothing);
      expect(find.text('MobileRelayCompatibilityTransport'), findsNothing);
      expect(find.text('licomesh.secure-mesh.v1'), findsNothing);
      expect(find.text('pairwise-runtime-available'), findsNothing);
      expect(find.text('mls-runtime-available'), findsNothing);
      expect(find.text('file-runtime-available'), findsNothing);
      expect(find.text('command-policy-ready'), findsNothing);
      expect(find.text('device-trust-ready'), findsNothing);
      expect(find.text('blocked_for_production'), findsNothing);
      expect(
        find.text('endpoint_private_key_is_persisted_in_portable_config'),
        findsNothing,
      );
      expect(
        find.text(
          'secure_mesh.file_chunk.upload / secure_mesh.file_chunk.fetch',
        ),
        findsNothing,
      );
      expect(
        find.text('secure_mesh.file_receive.write / fail_if_exists'),
        findsNothing,
      );

      expect(find.text('File Sync'), findsOneWidget);
      expect(
        find.byKey(const Key('secure-mesh-file-sync-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('secure-mesh-file-sync-pick-source')),
        findsOneWidget,
      );
      expect(find.text('Pairing'), findsOneWidget);
      expect(
        find.byKey(const Key('pairing-qr-workspace-card')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pairing-qr-frame')), findsOneWidget);
      expect(find.byType(MinimalScanIcon), findsWidgets);
      expect(find.byTooltip('Copy Pairing Code'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Create Code'), findsNothing);
      expect(
        find.byKey(const Key('secure-mesh-approval-refresh')),
        findsOneWidget,
      );
      expect(find.text('Poll'), findsNothing);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Stop'), findsNothing);
      expect(find.text('PC pairing invite JSON'), findsNothing);
    },
  );

  testWidgets('MobileRelayPanel keeps private gateway field unlabeled', (
    tester,
  ) async {
    final controller = ClientController(
      agentService: AgentService(
        runCliExecutable: (_, _, _) async {
          throw StateError('private gateway field test does not execute CLI');
        },
      ),
    );
    addTearDown(controller.dispose);

    controller.mobileRelayConfig = controller.mobileRelayConfig.copyWith(
      useCustomGateway: true,
      customGatewayUrl: 'https://private.example',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(body: MobileRelayPanel(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.byType(PanelFrame), findsNothing);
    expect(find.text('LicoUp Gateway'), findsNothing);
    expect(find.text('Custom Gateway'), findsNothing);
    expect(find.text('Private Cloud Gateway URL'), findsNothing);
    expect(find.text('https://private.example'), findsOneWidget);
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
  });

  testWidgets(
    'MobileRelayPanel renders exact local peer and negotiated capability sets',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ClientController(
        agentService: AgentService(
          runCliExecutable: (_, _, _) async {
            throw StateError('capability projection test does not execute CLI');
          },
        ),
      );
      addTearDown(controller.dispose);
      controller.secureMeshCapabilityProjection =
          SecureMeshCapabilityProjection.fromJson(
            activeSecureMeshCapabilityProjectionFixture(),
          );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(body: MobileRelayPanel(controller: controller)),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('secure-mesh-capability-card')),
        findsOneWidget,
      );
      final card = tester.widget<AnimatedContainer>(
        find.byKey(const Key('secure-mesh-capability-card')),
      );
      final decoration = card.decoration! as BoxDecoration;
      final themeColors = buildLicoTheme().extension<LicoThemeColors>()!;
      expect(decoration.color, themeColors.surfaceLow);
      expect(decoration.color, isNot(themeColors.surfaceHigh));
      expect(
        find.byKey(const Key('secure-mesh-capability-details')),
        findsNothing,
      );
      expect(find.byKey(const Key('secure-mesh-local-enabled')), findsNothing);

      await tester.tap(find.byKey(const Key('secure-mesh-capability-toggle')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('secure-mesh-capability-details')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secure-mesh-local-enabled')),
          matching: find.textContaining('custody.memory_only_ephemeral'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secure-mesh-local-selected-custody')),
          matching: find.text('memory_only_ephemeral'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secure-mesh-local-restart-semantics')),
          matching: find.text('re_pair_rekey_after_restart'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secure-mesh-peer-selected-custody')),
          matching: find.text('os_secure_store'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secure-mesh-peer-restart-semantics')),
          matching: find.text('persistent_state_available'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secure-mesh-local-dependencies')),
          matching: find.textContaining(
            'custody.strongbox ← custody.android_keystore, custody.hardware_backed',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secure-mesh-local-reasons')),
          matching: find.textContaining('os_secure_store_not_available'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secure-mesh-peer-enabled')),
          matching: find.textContaining('custody.os_secure_store'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const Key('secure-mesh-negotiated-protocol-capabilities'),
          ),
          matching: find.textContaining('protocol.complete_aad_binding'),
        ),
        findsOneWidget,
      );
      expect(find.text('Tier'), findsNothing);
      expect(find.text('Level'), findsNothing);
      expect(find.text('Ready'), findsNothing);
    },
  );

  testWidgets(
    'MobileRelayPanel renders the exact verified 60-digit trust presentation',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ClientController(
        agentService: AgentService(
          runCliExecutable: (_, _, _) async {
            throw StateError('trust presentation test does not execute CLI');
          },
        ),
      );
      addTearDown(controller.dispose);
      controller.mobileRelayConfig = controller.mobileRelayConfig.copyWith(
        pairingId: 'pair-1',
        pcTokenPresent: true,
        paired: true,
        trustPresentation: const MobileRelayTrustPresentation(
          schemaVersion: 'licomesh.secure-mesh.device-trust-presentation.v1',
          protocolVersion: 'licomesh.secure-mesh.device-trust.v2',
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
          qrPayload: 'licomesh-trust-qr',
          trustState: 'verified',
          verificationMethod: 'pairing_claim_proof',
          verified: true,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(body: MobileRelayPanel(controller: controller)),
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('secure-mesh-trust-verification-card')),
        300,
        scrollable: find.byType(Scrollable).first,
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
      expect(find.textContaining('00001 00002 00003'), findsOneWidget);
      expect(find.text('local-fingerprint'), findsOneWidget);
      expect(find.text('peer-fingerprint'), findsOneWidget);
    },
  );

  testWidgets('MobileRelayPanel copies the visible pairing code', (
    tester,
  ) async {
    final clipboard = _FakeClipboardService();
    final relayService = _PanelMobileRelayService();
    final controller = ClientController(
      agentService: AgentService(
        runCliExecutable: (_, _, _) async {
          throw StateError('copy pairing code test does not execute CLI');
        },
      ),
      mobileRelayService: relayService,
      clientClipboardService: clipboard,
    );
    addTearDown(controller.dispose);
    controller.mobileRelayConfig = relayService.config;
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'implemented',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => MobileRelayPanel(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('pairing-qr-frame')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('CODE-1'), findsOneWidget);
    expect(find.byTooltip('Copy Pairing Code'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy Pairing Code'));
    await tester.pump();

    expect(clipboard.writtenText, 'CODE-1');
    expect(find.text('Pairing Code Copied'), findsOneWidget);

    expect(controller.mobileRelayActionResult, isNotNull);
    expect(controller.mobileRelayConfig.lastPairingCode, isEmpty);
    controller.stopMobileRelayPolling();
    await tester.pump();
  });

  testWidgets(
    'MobileRelayPanel QR controls create a new desktop pairing code',
    (tester) async {
      final relayService = _PanelMobileRelayService();
      final controller = ClientController(
        agentService: AgentService(
          runCliExecutable: (_, _, _) async {
            throw StateError('refresh pairing code test does not execute CLI');
          },
        ),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);
      controller.mobileRelayConfig = relayService.config;
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'implemented',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => MobileRelayPanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('pairing-qr-frame')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(relayService.createPairingCalls, 1);
      expect(relayService.refreshPairingStatusCalls, 0);
      expect(find.text('CODE-1'), findsOneWidget);
      expect(controller.mobileRelayConfig.lastPairingCode, isEmpty);

      await tester.tap(find.byKey(const Key('pairing-qr-frame')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(relayService.createPairingCalls, 2);
      expect(find.text('CODE-2'), findsOneWidget);
      expect(find.byKey(const Key('pairing-qr-regenerate')), findsNothing);

      controller.stopMobileRelayPolling();
      await tester.pump();
    },
  );
}

class _PanelMobileRelayService extends MobileRelayService {
  int createPairingCalls = 0;
  int refreshPairingStatusCalls = 0;
  MobileRelayConfig config = MobileRelayConfig.defaults().copyWith(
    useCustomGateway: true,
    customGatewayUrl: 'https://relay.example.test',
    pairingId: 'pair-old',
    pcToken: 'pc-token-old',
    lastPairingCode: '',
    lastPairingExpiresAt: '',
    relayEnabled: true,
  );

  @override
  Future<MobileRelayConfig> loadConfig({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorizeSecrets = false,
  }) async {
    return config;
  }

  @override
  Future<void> saveConfig({
    required AgentService agentService,
    required MobileRelayConfig config,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    this.config = config;
  }

  @override
  Future<Map<String, dynamic>> createPairing({
    required AgentService agentService,
  }) async {
    createPairingCalls++;
    final pairingCode = 'CODE-$createPairingCalls';
    final expiresAt = '2026-06-12T12:0$createPairingCalls:00.000Z';
    config = config.copyWith(
      pairingId: 'pair-$createPairingCalls',
      pcToken: 'pc-token-$createPairingCalls',
      lastPairingCode: '',
      lastPairingExpiresAt: '',
      paired: false,
      relayEnabled: true,
    );
    return {
      'ok': true,
      'pairingId': config.pairingId,
      'pcToken': config.pcToken,
      'pairingCode': pairingCode,
      'expiresAt': expiresAt,
      'mobileRelayPairingInvite': {
        'protocolVersion': 'licomesh.mobile-relay.e2ee.v2',
        'oneTime': true,
        'gatewayUrl': 'https://relay.example.test',
        'pairingId': config.pairingId,
        'pairingCode': pairingCode,
        'pcSecureMesh': {'endpointId': 'pc'},
        'e2eePairingSecret': 'secret-$createPairingCalls',
      },
      'pairing': {'status': 'pending'},
    };
  }

  @override
  Future<Map<String, dynamic>> refreshPairingStatus({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    refreshPairingStatusCalls++;
    return {
      'ok': true,
      'pairingId': config.pairingId,
      'pairing': {'status': 'pending'},
    };
  }
}

class _FakeClipboardService extends ClientClipboardService {
  String writtenText = '';

  @override
  Future<void> writeText(String text) async {
    writtenText = text;
  }
}
