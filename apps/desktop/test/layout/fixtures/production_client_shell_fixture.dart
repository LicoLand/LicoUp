import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/contracts/generated/client_state.g.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/contracts/llm_gateway_diagnostics.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/appearance_resource_state.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_management.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/presentation/layout/built_in_layout_catalog.dart';

import 'package:licoup/src/frontend/shared/mascot/self_mascot_identity.dart';

import '../../presentation/composed_client_shell_test_helper.dart';
import '../../support/fake_conversation_transport.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Deterministic, process-free production shell harness used only to freeze
/// the current catalog renderers before ownership moves.
final class ProductionClientShellFixture {
  ProductionClientShellFixture._({
    required this.controller,
    required this.surface,
    required this.size,
    required this.brightness,
    required this.appearancePresetId,
    required Directory temporaryDataRoot,
  }) : _temporaryDataRoot = temporaryDataRoot;

  final ClientController controller;
  final LayoutRuntimeSurface surface;
  final Size size;
  final Brightness brightness;
  final String appearancePresetId;
  final Directory _temporaryDataRoot;
  LayoutStatePort? _layoutStateStore;
  Future<void> Function()? _closeComposition;

  /// Let the caller drain platform/stream cleanup using WidgetTester.runAsync.
  Future<void> closeComposition() async => _closeComposition?.call();

  LayoutStatePort get layoutStateStore =>
      _layoutStateStore ??
      (throw StateError('production_shell_fixture_not_composed'));

  static Future<ProductionClientShellFixture> create({
    required LayoutProfileId profileId,
    required LayoutRuntimeSurface surface,
    required ClientSection destination,
    required Size size,
    required Brightness brightness,
    ClientConversationNativePort? conversationNativePort,
    LayoutStyleId? layoutStyleId,
  }) async {
    final layoutCatalog = createBuiltInLayoutCatalog();
    // Golden baselines keep the deterministic self face; the composed
    // application would otherwise pick a random first-run mascot.
    selfMascotIdentity.value = 'lico';
    // The production baseline renders the out-of-box preference: the
    // system-following preset, which resolves per platform brightness.
    const appearancePresetId = 'default-system';
    final preferences = InMemoryPresentationPreferencesRepository(
      PresentationPreferences(
        layoutProfileId: profileId,
        appearancePresetId: appearancePresetId,
        localePreference: LocalePreference.english,
        layoutStyleIds: {profileId: ?layoutStyleId},
      ),
    );
    final targets = _fixtureTargets();
    final primaryTarget = targets.firstWhere(
      (candidate) => candidate.visibleInClient,
    );
    final agentService = _FixtureAgentService(
      targets: targets,
      primaryTargetId: primaryTarget.target,
    );
    final temporaryDataRoot = Directory.systemTemp.createTempSync(
      'licoup-production-layout-',
    );
    final portableData = _FixturePortableDataRoot(
      temporaryDataRoot,
      mobileRuntimeOverride: surface == LayoutRuntimeSurface.mobile,
    );
    final controller = ClientController(
      portableData: portableData,
      memoryDiagnosticSink: const NoopClientMemoryDiagnosticSink(),
      conversationNativePort: conversationNativePort,
      agentService: agentService,
      conversationService: _FixtureConversationService(
        native: agentService.conversationNativePort,
      ),
      layoutCatalog: layoutCatalog,
      presentationPreferencesRepository: preferences,
      mobileClientRuntimePlatformOverride:
          surface == LayoutRuntimeSurface.mobile,
      llmGatewayMonitorInterval: Duration.zero,
      llmGatewayRecoveryRetryDelay: Duration.zero,
      llmGatewayDiagnosticSink: const NoopLlmGatewayDiagnosticSink(),
    );

    controller
      ..currentSection = destination
      ..appearancePresetId = appearancePresetId
      ..localePreference = LocalePreference.english
      ..statusCaption = 'Ready'
      ..statusMessage = 'Deterministic layout baseline ready.'
      ..portableDataPath = ''
      ..scannedTargets = targets
      ..agentTabOrder = [primaryTarget.target];

    if (destination == ClientSection.agentHub) {
      // Populate the catalog the way the section entry hook does on a real
      // launch, so the baseline renders the populated grid instead of the
      // first-frame empty scan.
      await controller.agentHubCatalogController.refresh();
    }
    if (destination == ClientSection.agents) {
      final session = _fixtureConversation(primaryTarget);
      controller
        ..selectedConversationAgentId = primaryTarget.target
        ..conversationSessionsByAgent = {
          primaryTarget.target: [session],
        }
        ..selectedConversationSessionId = session.id
        ..agentUsageReport = AgentUsageReport.fromAgents(
          generatedAt: _fixtureTimestamp,
          agents: [
            AgentUsageAgentSummary(
              agentId: primaryTarget.target,
              label: primaryTarget.label,
              status: 'detected',
              history: const {
                'sessionCount': 1,
                'messageCount': 2,
                'totalTokens': 1200,
              },
              confidence: 'high',
            ),
          ],
        );
    }

    await controller.layoutManager.initialize();
    if (conversationNativePort != null) {
      await controller.clientConversationController.initialize();
    }
    return ProductionClientShellFixture._(
      controller: controller,
      surface: surface,
      size: size,
      brightness: brightness,
      appearancePresetId: appearancePresetId,
      temporaryDataRoot: temporaryDataRoot,
    );
  }

  void dispose() {
    controller.dispose();
    if (_temporaryDataRoot.existsSync()) {
      _temporaryDataRoot.deleteSync(recursive: true);
    }
  }

  Widget buildApp({
    required Key semanticsKey,
    required Key repaintBoundaryKey,
    bool disableAnimations = true,
  }) {
    final theme =
        buildLicoTheme(
          presetId: appearancePresetId,
          platformBrightness: brightness,
        ).copyWith(
          platform: surface == LayoutRuntimeSurface.mobile
              ? TargetPlatform.android
              : TargetPlatform.macOS,
        );
    final safePadding = surface == LayoutRuntimeSurface.mobile
        ? const EdgeInsets.only(top: 24, bottom: 16)
        : EdgeInsets.zero;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      restorationScopeId: 'production-layout-baseline',
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          devicePixelRatio: 1,
          textScaler: TextScaler.noScaling,
          platformBrightness: brightness,
          padding: safePadding,
          viewPadding: safePadding,
          disableAnimations: disableAnimations,
        ),
        child: Semantics(
          key: semanticsKey,
          container: true,
          explicitChildNodes: true,
          child: RepaintBoundary(
            key: repaintBoundaryKey,
            child: composedClientShell(
              controller,
              onComposed: (composition) {
                _layoutStateStore = composition.renderer.layoutStateStore;
                _closeComposition = composition.dispose;
              },
            ),
          ),
        ),
      ),
    );
  }
}

final class _FixturePortableDataRoot extends PortableDataRoot {
  _FixturePortableDataRoot(this.root, {required bool mobileRuntimeOverride})
    : super(
        dataDirectoryOverride: root,
        mobileRuntimeOverride: mobileRuntimeOverride,
      );

  final Directory root;

  @override
  Future<Directory> dataDirectory() => Future.value(root);
}

final class InMemoryPresentationPreferencesRepository
    implements PresentationPreferencesRepository {
  InMemoryPresentationPreferencesRepository(this._preferences);

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

final class _FixtureAgentService extends AgentService {
  _FixtureAgentService({required this.targets, required this.primaryTargetId})
    : super(
        conversationNativePort: FakeConversationTransport(
          command: (_, _) async => {'ok': true, 'turns': [], 'result': []},
        ).native,
        runCliExecutable: (executable, arguments, environment) async =>
            ProcessResult(0, 0, '{}', ''),
      );

  final List<TargetCandidate> targets;
  final String primaryTargetId;

  @override
  Future<List<TargetCandidate>> scanTargets() async => targets;

  @override
  Future<TargetScanBatch> scanTargetsBatch(
    List<String> targetIds, {
    bool enableAgentCliModelLookup = false,
  }) async => TargetScanBatch([
    for (final targetId in targetIds)
      TargetScanSlot(
        targetId: targetId,
        candidate: targets
            .where((target) => target.target == targetId)
            .firstOrNull,
      ),
  ]);

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args.first == 'agent-hub' && args[1] == 'catalog') {
      return {
        'ok': true,
        'scanGeneration': 1,
        'cards': _fixtureAgentHubCards(),
      };
    }
    if (args.length >= 2 && args.first == 'devices' && args[1] == 'status') {
      return const {
        'ok': true,
        'enrolled': false,
        'legacyPairingsDetected': false,
        'station': null,
        'mailboxId': null,
        'peers': <Map<String, Object?>>[],
        'pairings': <Map<String, Object?>>[],
      };
    }
    if (args.length >= 2 && args.first == 'agent-usage' && args[1] == 'scan') {
      return {
        'schemaVersion': AgentUsageReport.currentSchemaVersion,
        'mode': AgentUsageReport.currentMode,
        'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
        'generatedAt': _fixtureTimestamp,
        'summary': {'agentCount': 1, 'totalTokens': 1200, 'confidence': 'high'},
        'agents': [
          {
            'agentId': primaryTargetId,
            'label': 'Fixture Agent',
            'status': 'detected',
            'history': {
              'sessionCount': 1,
              'messageCount': 2,
              'totalTokens': 1200,
            },
            'confidence': 'high',
          },
        ],
        'warnings': const <Object>[],
      };
    }
    return const {'ok': true};
  }

  @override
  Future<ClientStateGetResult> getClientState(
    ClientStateGetRequest request,
  ) async => ClientStateGetResult(
    collection: request.collection,
    document: ClientStateDocument(
      schemaVersion: clientStateSchemaVersion,
      collection: request.collection,
    ),
  );
}

final class _FixtureConversationService extends AgentConversationService {
  const _FixtureConversationService({required super.native});

  @override
  Future<List<AgentConversationSession>> loadSessions({
    required Object agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async => const [];

  @override
  Stream<AgentConversationSession> streamSessions({
    required Object agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => const Stream.empty();
}

const String _fixtureTimestamp = '2020-01-02T03:04:00Z';

/// Deterministic Agent Hub catalog mirroring the approved design lab roster:
/// the resident assistant, the extensible entry point, the tool agents and one
/// not-installed tile so the grid renders both status styles.
List<Map<String, dynamic>> _fixtureAgentHubCards() => [
  _fixtureAgentHubCard(
    id: 'lico-assistant',
    label: 'Lico Assistant',
    summary: 'The resident assistant that keeps track of ongoing work.',
    present: true,
    ownership: 'owned',
    lifecycle: 'ready',
    primaryAction: 'open',
  ),
  _fixtureAgentHubCard(
    id: 'lico-agent',
    label: 'Lico Agent',
    summary: 'The extensible agent entry point with custom capabilities.',
    present: true,
    ownership: 'owned',
    lifecycle: 'ready',
    primaryAction: 'open',
    installedVersion: '1.0',
  ),
  _fixtureAgentHubCard(
    id: 'claude-code',
    label: 'Claude Code',
    summary: 'Terminal coding agent that reads, writes and runs code.',
    present: true,
    lifecycle: 'detected',
    primaryAction: 'open',
    installedVersion: '2.1',
    installable: true,
  ),
  _fixtureAgentHubCard(
    id: 'codex',
    label: 'Codex',
    summary: 'Coding agent focused on review and autonomous edits.',
    present: true,
    lifecycle: 'detected',
    primaryAction: 'open',
    installedVersion: '0.9',
    installable: true,
  ),
  _fixtureAgentHubCard(
    id: 'cursor',
    label: 'Cursor',
    summary: 'Coding agent strong at code completion and quick edits.',
    present: true,
    lifecycle: 'detected',
    primaryAction: 'open',
    installedVersion: '1.7',
    installable: true,
  ),
  _fixtureAgentHubCard(
    id: 'kimi-code',
    label: 'Kimi Code',
    summary: 'Long-context coding agent that reads the whole repository.',
    present: true,
    lifecycle: 'detected',
    primaryAction: 'open',
    installedVersion: '1.2',
    installable: true,
  ),
  _fixtureAgentHubCard(
    id: 'deepseek-harness',
    label: 'DeepSeek Harness',
    summary: 'Automated test agent that runs suites and reports results.',
    present: true,
    lifecycle: 'detected',
    primaryAction: 'open',
    installedVersion: '0.6',
    installable: true,
  ),
  _fixtureAgentHubCard(
    id: 'github-copilot',
    label: 'GitHub Copilot',
    summary: 'Pair-programming agent for completion and answers.',
    present: false,
    lifecycle: 'absent',
    primaryAction: 'install',
    installable: true,
  ),
];

Map<String, dynamic> _fixtureAgentHubCard({
  required String id,
  required String label,
  required String summary,
  required bool present,
  required String lifecycle,
  required String primaryAction,
  String ownership = 'none',
  String installedVersion = '',
  bool installable = false,
}) => <String, dynamic>{
  'id': id,
  'label': label,
  'summary': summary,
  'present': present,
  'ownership': ownership,
  'lifecycle': lifecycle,
  'primaryAction': primaryAction,
  'installable': installable,
  'installedVersion': installedVersion,
  'adaptation': 'deep',
};

List<TargetCandidate> _fixtureTargets() {
  final ids = AgentService.packagedScanTargetIds;
  if (ids.isEmpty) {
    throw StateError('production_layout_baseline_target_catalog_empty');
  }
  final primaryId = ids.first;
  return [
    for (final id in ids)
      TargetCandidate(
        id: id,
        target: id,
        label: id == primaryId ? 'Fixture Agent' : 'Unavailable fixture',
        kind: 'cli',
        status: id == primaryId ? 'detected' : 'not-detected',
        configured: id == primaryId,
        confidence: id == primaryId ? 1 : 0,
        binaryPath: id == primaryId ? '/test-bin/$id' : '',
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationProtocol': 'deterministic-fixture',
          'conversationReadiness': 'ready',
        },
        supportedActions: const ['runtime.message.send'],
      ),
  ];
}

AgentConversationSession _fixtureConversation(TargetCandidate target) =>
    AgentConversationSession(
      id: 'fixture-session',
      agentId: target.target,
      title: 'Layout baseline conversation',
      createdAt: _fixtureTimestamp,
      updatedAt: _fixtureTimestamp,
      messageCount: 2,
      sourceMessageCount: 2,
      messages: const [
        AgentConversationMessage(
          id: 'fixture-message-user',
          role: 'user',
          text: 'Show the current client layout.',
          createdAt: _fixtureTimestamp,
        ),
        AgentConversationMessage(
          id: 'fixture-message-assistant',
          role: 'assistant',
          text: 'The deterministic production baseline is ready.',
          createdAt: _fixtureTimestamp,
        ),
      ],
    );
