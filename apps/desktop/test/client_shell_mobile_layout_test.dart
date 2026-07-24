import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/shell_pair_device_dialog.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  testWidgets('mobile runtime keeps the phone shell under a desktop theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ClientController(
      portableData: _testPortableData(),
      presentationPreferencesRepository:
          _TestPresentationPreferencesRepository(),
      agentService: _NoopAgentService(scanTargetsResponse: _targets),
      conversationService: const _NoopConversationService(),
      mobileRelayService: _SecureAgentRelayService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;
    controller.scannedTargets = _targets;
    controller.scannedTargets = _targets;
    await controller.layoutManager.initialize().timeout(
      const Duration(seconds: 5),
    );

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 390,
          height: 844,
          child: ClientShell(controller: controller),
        ),
      ),
    );

    await tester.pump();
    expect(
      find.byKey(const Key('workbench-mobile-compact-navigation-trigger')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('mobile-agent-list-item-codex')),
      findsOneWidget,
    );
  });

  testWidgets('mobile empty agent list opens the add agent sheet', (
    tester,
  ) async {
    final controller = ClientController(
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: Material(child: MobileAgentsHome(controller: controller)),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('No available agents found'), findsOneWidget);
    expect(
      find.byKey(const Key('mobile-empty-add-agent-button')),
      findsOneWidget,
    );
    expect(find.text('Refresh Agents'), findsNothing);

    await tester.tap(find.byKey(const Key('mobile-empty-add-agent-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('mobile-agent-scan-qr-option')),
      findsOneWidget,
    );
  });

  testWidgets(
    'mobile Arc Desktop agent conversation sends through paired computer',
    (tester) async {
      final relayService = _SecureAgentRelayService();
      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(),
        agentService: _NoopAgentService(scanTargetsResponse: _targets),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.agents;
      controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
        useCustomGateway: true,
        customGatewayUrl: 'https://relay.example.test',
        pcClientName: 'ARC Desktop',
        pairingId: 'pairing_desktop',
        mobileTokenPresent: true,
        paired: true,
      );
      controller.scannedTargets = _targets;
      controller.selectedConversationAgentId = 'codex';
      await controller.layoutManager.initialize();

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: SizedBox(
            width: 390,
            height: 844,
            child: ClientShell(controller: controller),
          ),
        ),
      );
      await tester.pump();

      final pairedDeviceKey = Key(
        'mobile-paired-device-${controller.mobileRelayConfig.deviceTabs.single.id}',
      );

      await tester.tap(find.byKey(pairedDeviceKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('mobile-desktop-agent-codex')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('mobile-desktop-agent-codex')));
      await tester.pumpAndSettle();

      expect(controller.mobileClientRuntimePlatform, isTrue);
      expect(controller.selectedConversationAgentId, 'codex');
      expect(controller.lastError, isEmpty);
      final composer = find.widgetWithText(TextField, 'Message Codex');
      expect(composer, findsOneWidget);

      await tester.enterText(composer, 'hello');
      await tester.pump();
      final sendButton = find.byKey(
        const Key('agent-conversation-composer-send'),
      );
      expect(sendButton, findsOneWidget);
      expect(tester.widget<InkWell>(sendButton).onTap, isNotNull);
      await tester.tap(sendButton);
      await tester.pumpAndSettle();

      expect(
        relayService.agentMessageCalls,
        1,
        reason: 'send status=${controller.lastError}',
      );
      expect(relayService.lastAgentId, 'codex');
      expect(relayService.lastAgentText, 'hello');
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('Codex relay reply'), findsOneWidget);
    },
  );

  testWidgets(
    'mobile home keeps profile navigation without manual target entry',
    (tester) async {
      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.agents;
      await controller.layoutManager.initialize();

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: SizedBox(
            width: 390,
            height: 844,
            child: ClientShell(controller: controller),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workbench-mobile-medium-contextual-navigation')),
        findsOneWidget,
      );
      expect(find.byTooltip('Pair Device'), findsNothing);
      expect(find.text('No available agents found'), findsOneWidget);
      expect(find.text('Add target'), findsNothing);
    },
  );

  testWidgets('pair device dialog fits above the soft keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            viewInsets: EdgeInsets.only(bottom: 360),
          ),
          child: SizedBox(
            width: 390,
            height: 844,
            child: PairDeviceDialog(
              scannerPreviewOverride: const ColoredBox(color: Colors.black),
              onClaim: (_) async {},
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('配对设备'), findsOneWidget);
    expect(find.text('扫描二维码'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('pair device dialog automatically claims detected QR capture', (
    tester,
  ) async {
    const invite = 'licoup://pair?invite=test-token';
    final claims = <String>[];
    final claimGate = Completer<void>();
    late Future<void> Function(BarcodeCapture capture) submitCapture;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: PairDeviceDialog(
            scannerPreviewBuilder: (context, onDetect) {
              submitCapture = onDetect;
              return const ColoredBox(color: Colors.black);
            },
            onClaim: (value) async {
              claims.add(value);
              await claimGate.future;
            },
          ),
        ),
      ),
    );

    await tester.pump();
    final detectFuture = submitCapture(
      const BarcodeCapture(
        barcodes: [Barcode(format: BarcodeFormat.qrCode, rawValue: invite)],
      ),
    );
    await tester.pump();

    expect(claims, [invite]);
    expect(find.text('已识别二维码，正在配对...'), findsOneWidget);

    claimGate.complete();
    await tester.pump(const Duration(milliseconds: 360));
    await detectFuture;
    await tester.pump();

    expect(find.text('扫描成功，设备已配对。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reselecting the agents destination returns to the home list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = ClientController(
      portableData: _testPortableData(),
      presentationPreferencesRepository:
          _TestPresentationPreferencesRepository(),
      agentService: _NoopAgentService(scanTargetsResponse: _targets),
      conversationService: const _NoopConversationService(),
      mobileRelayService: _SecureAgentRelayService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;
    controller.scannedTargets = _targets;
    controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
      useCustomGateway: true,
      customGatewayUrl: 'https://relay.example.test',
      pcClientName: 'LicoUp',
      pairingId: 'pairing_test',
      mobileTokenPresent: true,
      paired: true,
    );
    final pairedDeviceKey = Key(
      'mobile-paired-device-${controller.mobileRelayConfig.deviceTabs.single.id}',
    );
    await controller.layoutManager.initialize();

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: ClientShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(pairedDeviceKey), findsOneWidget);
    expect(find.byKey(const Key('mobile-desktop-agent-codex')), findsNothing);

    await tester.tap(find.byKey(pairedDeviceKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mobile-desktop-agent-codex')), findsOneWidget);

    expect(
      find.byKey(const Key('workbench-mobile-compact-navigation-trigger')),
      findsOneWidget,
    );
  });
}

PortableDataRoot _testPortableData() {
  final directory = Directory.systemTemp.createTempSync(
    'licoup-shell-layout-',
  );
  addTearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  return PortableDataRoot(dataDirectoryOverride: directory);
}

final class _TestPresentationPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences _preferences = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('workbench'),
    appearancePresetId: 'default-system',
    localePreference: 'system',
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: _preferences);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      _preferences = _preferences.copyWith(appearancePresetId: id);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      _preferences = _preferences.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => _preferences = _preferences.copyWith(localePreference: preference);
}

final List<TargetCandidate> _targets = [
  TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: false,
    confidence: 0.72,
    adapterStatus: 'implemented',
    adapterCapabilities: const {'conversationReadiness': 'ready'},
    supportedActions: ['runtime.message.send'],
  ),
];

class _NoopAgentService extends AgentService {
  _NoopAgentService({this.scanTargetsResponse = const []})
    : super(runCliExecutable: null);

  final List<TargetCandidate> scanTargetsResponse;
  int agentUsageScanCalls = 0;

  @override
  Future<List<TargetCandidate>> scanTargets() async {
    return scanTargetsResponse;
  }

  @override
  Future<TargetCandidate?> scanOneTarget(String targetId) async {
    final id = targetId.trim();
    for (final target in scanTargetsResponse) {
      if (target.target == id) {
        return target;
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> stopOpencodeServe() async {
    return const {'ok': true, 'status': 'stopped'};
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'scan') {
      agentUsageScanCalls++;
      final agentArgIndex = args.indexOf('--agent');
      final agentId = agentArgIndex >= 0 && agentArgIndex + 1 < args.length
          ? args[agentArgIndex + 1]
          : 'codex';
      final provider = agentId == 'claude-code'
          ? 'Claude'
          : agentId == 'kilo-code'
          ? 'Kilo'
          : 'ChatGPT';
      return {
        'schemaVersion': AgentUsageReport.currentSchemaVersion,
        'ok': true,
        'mode': AgentUsageReport.currentMode,
        'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
        'generatedAt': '2026-07-02T00:00:00Z',
        'summary': {'agentCount': 1, 'totalTokens': 84, 'confidence': 'medium'},
        'agents': [
          {
            'agentId': agentId,
            'label': provider,
            'status': 'detected',
            'history': {
              'sessionCount': 2,
              'messageCount': 8,
              'totalTokens': 84,
            },
            'confidence': 'medium',
          },
        ],
      };
    }
    return {'ok': true};
  }
}

class _NoopConversationService extends AgentConversationService {
  const _NoopConversationService();

  @override
  Stream<AgentConversationSession> streamSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) {
    return const Stream.empty();
  }

  @override
  Future<List<AgentConversationSession>> loadSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) async {
    return const [];
  }

  @override
  Future<AgentDispatchTurnResult> send({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    return const AgentDispatchTurnResult(
      ok: true,
      sessionId: 'noop-session',
      raw: <String, dynamic>{'ok': true},
    );
  }
}

class _SecureAgentRelayService extends MobileRelayService {
  int agentMessageCalls = 0;
  String lastAgentId = '';
  String lastAgentText = '';

  @override
  Future<Map<String, dynamic>> listSecureAgentSessions({
    required AgentService agentService,
    required String agentId,
    int limit = 20,
    int offset = 0,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    return {
      'ok': true,
      'agentId': agentId,
      'sessions': const <Map<String, dynamic>>[],
      'hasMore': false,
    };
  }

  @override
  Future<Map<String, dynamic>> describeSecureAgentSession({
    required AgentService agentService,
    required String agentId,
    required String sessionId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    return {
      'ok': true,
      'agentId': agentId,
      'sessions': const <Map<String, dynamic>>[],
      'hasMore': false,
    };
  }

  @override
  Future<Map<String, dynamic>> sendSecureAgentMessage({
    required AgentService agentService,
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    agentMessageCalls++;
    lastAgentId = agentId;
    lastAgentText = text;
    final nativeSessionId = sessionId.trim().isNotEmpty
        ? sessionId.trim()
        : 'native-$agentId-relay';
    return {
      'ok': true,
      'result': {
        'openedResult': {
          'execution': {
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {
                'ok': true,
                'adapterId': agentId,
                'nativeSessionId': nativeSessionId,
                'threadId': nativeSessionId,
                'sessionId': nativeSessionId,
                'effective': {
                  'model': model.isEmpty ? null : model,
                  'reasoningEffort': reasoningEffort.isEmpty
                      ? null
                      : reasoningEffort,
                },
                'content': 'Codex relay reply',
                'output': 'Codex relay reply',
              },
            },
          },
        },
      },
    };
  }
}
