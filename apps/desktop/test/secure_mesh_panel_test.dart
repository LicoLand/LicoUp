import 'package:flutter/material.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mobile_relay_binding_fixture.dart';
import 'fixtures/secure_mesh_capability_projection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('approval buttons use retained secrets without exposing them', (
    tester,
  ) async {
    const approval = RelayApprovalProjection(
      id: 'operation-actionable',
      requesterLabel: 'claude-code',
      capabilityLabel: 'local_effect',
      summary: 'Approve a bounded tool call',
      expiresLabel: '2099-01-01T00:00:00Z',
      resolvable: true,
    );
    final fixture = MobileRelayBindingFixture(
      projection: mobileRelayProjectionFixture(
        approvals: const [approval],
        paired: true,
      ),
    );
    addTearDown(fixture.dispose);
    expect(approval.toString(), isNot(contains('private-nonce')));
    expect(approval.toString(), isNot(contains('private-token')));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SecureMeshApprovalCard(
            projection: fixture.projection.current,
            intents: fixture.intents,
          ),
        ),
      ),
    );

    final allow = tester.widget<FilledButton>(
      find.byKey(const Key('secure-mesh-approval-allow-operation-actionable')),
    );
    final deny = tester.widget<OutlinedButton>(
      find.byKey(const Key('secure-mesh-approval-deny-operation-actionable')),
    );
    expect(allow.onPressed, isNotNull);
    expect(deny.onPressed, isNotNull);
    await tester.tap(
      find.byKey(const Key('secure-mesh-approval-allow-operation-actionable')),
    );
    await tester.tap(
      find.byKey(const Key('secure-mesh-approval-deny-operation-actionable')),
    );
    expect(fixture.intents.values, [
      isA<ResolveRelayApproval>()
          .having((intent) => intent.approvalId, 'approvalId', approval.id)
          .having((intent) => intent.approved, 'approved', true),
      isA<ResolveRelayApproval>()
          .having((intent) => intent.approvalId, 'approvalId', approval.id)
          .having((intent) => intent.approved, 'approved', false),
    ]);
  });

  testWidgets(
    'MobileRelayPanel hides diagnostics and exposes pairing controls',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = MobileRelayBindingFixture(
        projection: mobileRelayProjectionFixture(
          stationLabel: 'https://station.example.test',
          stationConfigured: true,
          paired: true,
          pairingId: 'pair-1',
          pairingExpiresLabel: '2026-06-12T12:00:00Z',
        ),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(body: MobileRelayPanel(binding: fixture.binding)),
        ),
      );
      await tester.pump();

      expect(find.byType(PanelFrame), findsNothing);
      expect(find.text('Station'), findsOneWidget);
      expect(find.text('Address'), findsNothing);
      expect(find.text('licomesh.app'), findsNothing);
      expect(find.text('https://station.example.test'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      final stationEditable = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText &&
            widget.controller.text == 'https://station.example.test',
      );
      expect(stationEditable, findsOneWidget);
      expect(tester.widget<EditableText>(stationEditable).readOnly, isFalse);
      expect(find.text('Default'), findsNothing);
      expect(find.text('Active'), findsNothing);
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
      expect(find.text('Communication'), findsOneWidget);
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

  testWidgets('MobileRelayPanel keeps the station base URL directly editable', (
    tester,
  ) async {
    final fixture = MobileRelayBindingFixture(
      projection: mobileRelayProjectionFixture(
        stationLabel: 'https://station.example',
        stationConfigured: true,
      ),
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(body: MobileRelayPanel(binding: fixture.binding)),
      ),
    );
    await tester.pump();

    expect(find.byType(PanelFrame), findsNothing);
    expect(find.text('Station'), findsOneWidget);
    expect(find.text('https://station.example'), findsOneWidget);
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
  });

  testWidgets(
    'MobileRelayPanel renders exact local peer and negotiated capability sets',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = MobileRelayBindingFixture(
        projection: mobileRelayProjectionFixture(
          secureMeshCapabilities: SecureMeshCapabilityProjection.fromJson(
            activeSecureMeshCapabilityProjectionFixture(),
          ),
        ),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(body: MobileRelayPanel(binding: fixture.binding)),
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
      // Neutral charcoal, deliberately not the brand-tinted surface: this card
      // is ordinary content, not a brand-owned one.
      expect(decoration.color, themeColors.surfaceLow);
      expect(decoration.color, isNot(themeColors.brandSurface));
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
      final fixture = MobileRelayBindingFixture(
        projection: mobileRelayProjectionFixture(
          pairingId: 'pair-1',
          paired: true,
          trust: RelayTrustProjection(
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
        ),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(body: MobileRelayPanel(binding: fixture.binding)),
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
    final copiedCodes = <String>[];
    final fixture = MobileRelayBindingFixture(
      projection: mobileRelayProjectionFixture(
        stationLabel: 'https://station.example.test',
        stationConfigured: true,
      ),
      onIntent: (intent, fixture) {
        switch (intent) {
          case CreateRelayPairing():
            fixture.publish(
              mobileRelayProjectionFixture(
                stationLabel: 'https://station.example.test',
                stationConfigured: true,
                pairingCode: 'CODE-1',
                pairingInvite: 'opaque-invite-1',
                pairingId: 'pair-1',
              ),
            );
          case CopyRelayPairingCode(:final pairingCode):
            copiedCodes.add(pairingCode);
            fixture.effects.add(const RelayPairingCodeCopied());
          default:
            fail('unexpected intent: ${intent.runtimeType}');
        }
      },
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(body: MobileRelayPanel(binding: fixture.binding)),
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

    expect(copiedCodes, ['CODE-1']);
    expect(find.text('Pairing Code Copied'), findsOneWidget);
  });

  testWidgets(
    'MobileRelayPanel QR controls create a new desktop pairing code',
    (tester) async {
      var createPairingCalls = 0;
      var refreshPairingStatusCalls = 0;
      final fixture = MobileRelayBindingFixture(
        projection: mobileRelayProjectionFixture(
          stationLabel: 'https://station.example.test',
          stationConfigured: true,
        ),
        onIntent: (intent, fixture) {
          switch (intent) {
            case CreateRelayPairing():
              createPairingCalls += 1;
              fixture.publish(
                mobileRelayProjectionFixture(
                  stationLabel: 'https://station.example.test',
                  stationConfigured: true,
                  pairingCode: 'CODE-$createPairingCalls',
                  pairingInvite: 'opaque-invite-$createPairingCalls',
                  pairingId: 'pair-$createPairingCalls',
                ),
              );
            case RefreshMobileRelay():
              refreshPairingStatusCalls += 1;
            default:
              fail('unexpected intent: ${intent.runtimeType}');
          }
        },
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(body: MobileRelayPanel(binding: fixture.binding)),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('pairing-qr-frame')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(createPairingCalls, 1);
      expect(refreshPairingStatusCalls, 0);
      expect(find.text('CODE-1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pairing-qr-frame')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(createPairingCalls, 2);
      expect(find.text('CODE-2'), findsOneWidget);
      expect(find.byKey(const Key('pairing-qr-regenerate')), findsNothing);
    },
  );
}
