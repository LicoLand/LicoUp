import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/contracts/target_management.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/appearance_resource_state.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';
import 'package:licoup/src/frontend/features/devices/ui/devices_panel.dart';
import 'package:licoup/src/frontend/layout/layout_host.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'presentation/composed_client_shell_test_helper.dart';

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
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: SizedBox(
          width: 390,
          height: 844,
          child: composedClientShell(controller),
        ),
      ),
    );

    await tester.pump();
    expect(
      find.byKey(const Key('dashboard-mobile-menu-button')),
      findsOneWidget,
    );
    expect(find.byType(AgentsCanvas), findsOneWidget);
  });

  testWidgets(
    'mobile desktop profile renders Devices through restored selection',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(
              layoutProfileId: LayoutProfileId.parse('desktop'),
            ),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.devices;
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: SizedBox(
            width: 390,
            height: 844,
            child: composedClientShell(controller),
          ),
        ),
      );
      await tester.pump();

      expect(controller.currentSection, ClientSection.devices);
      expect(
        tester.widget<LayoutHost>(find.byType(LayoutHost)).destination,
        ClientSection.devices,
      );
      expect(find.byType(DevicesPanel), findsOneWidget);
      expect(find.byType(AgentsCanvas), findsNothing);
    },
  );

  testWidgets(
    'mobile desktop profile navigates to Devices through destination navigation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(
              layoutProfileId: LayoutProfileId.parse('desktop'),
            ),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: SizedBox(
            width: 390,
            height: 844,
            child: composedClientShell(controller),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const Key('desktop-mobile-compact-navigation-trigger')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('desktop-mobile-compact-navigation-devices')),
      );
      await tester.pumpAndSettle();

      expect(controller.currentSection, ClientSection.devices);
      expect(
        tester.widget<LayoutHost>(find.byType(LayoutHost)).destination,
        ClientSection.devices,
      );
      expect(find.byType(DevicesPanel), findsOneWidget);
      expect(find.byType(AgentsCanvas), findsNothing);
    },
  );

  testWidgets(
    'mobile dashboard profile renders Devices through restored selection',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(
              layoutProfileId: LayoutProfileId.parse('dashboard'),
            ),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.devices;
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: SizedBox(
            width: 390,
            height: 844,
            child: composedClientShell(controller),
          ),
        ),
      );
      await tester.pump();

      expect(controller.currentSection, ClientSection.devices);
      expect(
        tester.widget<LayoutHost>(find.byType(LayoutHost)).destination,
        ClientSection.devices,
      );
      expect(find.byType(DevicesPanel), findsOneWidget);
      expect(find.byType(AgentsCanvas), findsNothing);
    },
  );

  testWidgets(
    'mobile dashboard profile navigates to Devices through destination navigation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(
              layoutProfileId: LayoutProfileId.parse('dashboard'),
            ),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: SizedBox(
            width: 390,
            height: 844,
            child: composedClientShell(controller),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('dashboard-mobile-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('dashboard-mobile-compact-navigation-devices')),
      );
      await tester.pumpAndSettle();

      expect(controller.currentSection, ClientSection.devices);
      expect(
        tester.widget<LayoutHost>(find.byType(LayoutHost)).destination,
        ClientSection.devices,
      );
      expect(find.byType(DevicesPanel), findsOneWidget);
      expect(find.byType(AgentsCanvas), findsNothing);
    },
  );
}

PortableDataRoot _testPortableData() {
  final directory = Directory.systemTemp.createTempSync('licoup-shell-layout-');
  addTearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  return PortableDataRoot(dataDirectoryOverride: directory);
}

final class _TestPresentationPreferencesRepository
    implements PresentationPreferencesRepository {
  _TestPresentationPreferencesRepository({LayoutProfileId? layoutProfileId})
    : _preferences = PresentationPreferences(
        layoutProfileId: layoutProfileId ?? LayoutProfileId.parse('dashboard'),
        appearancePresetId: 'default-system',
        localePreference: 'system',
      );

  PresentationPreferences _preferences;

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: _preferences);

  @override
  Future<PresentationPreferences> setReduceMotion(
    ReduceMotionPreference preference,
  ) async => _preferences = _preferences.copyWith(reduceMotion: preference);

  @override
  Future<PresentationPreferences> setLoadingEffect(String id) async =>
      _preferences = _preferences.copyWith(loadingEffectId: id);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      _preferences = _preferences.copyWith(appearancePresetId: id);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      _preferences = _preferences.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLayoutStyle(
    LayoutProfileId profile,
    LayoutStyleId style,
  ) async => _preferences = _preferences.copyWith(
    layoutStyleIds: {..._preferences.layoutStyleIds, profile: style},
  );

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => _preferences = _preferences.copyWith(localePreference: preference);

  @override
  Future<PresentationPreferences> setResourceSelection(
    PresentationResourceKind kind,
    PresentationResourceSelection? selection,
  ) async => _preferences = _preferences.withResourceSelection(kind, selection);
}

final List<TargetCandidate> _targets = [
  TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: false,
    confidence: 0.72,
    binaryPath: '/test-bin/codex',
    adapterStatus: 'implemented',
    adapterCapabilities: const {
      'conversationDriver': 'implemented',
      'conversationReadiness': 'ready',
    },
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
  Future<TargetScanBatch> scanTargetsBatch(
    List<String> targetIds, {
    bool enableAgentCliModelLookup = false,
  }) async => TargetScanBatch([
    for (final targetId in targetIds)
      TargetScanSlot(
        targetId: targetId,
        candidate: scanTargetsResponse
            .where((target) => target.target == targetId.trim())
            .firstOrNull,
      ),
  ]);

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
    AgentDispatchBind bind = const AgentDispatchBind(),
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
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    return const [];
  }

  @override
  Future<AgentDispatchTurnResult> send({
    required String agentId,
    required String text,
    required String sessionId,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    return const AgentDispatchTurnResult(
      ok: true,
      sessionId: 'noop-session',
      raw: <String, dynamic>{'ok': true},
    );
  }
}
