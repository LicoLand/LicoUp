import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/contracts/locale_preferences.dart';
import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/application/composition/built_in_layout_composition.dart';
import 'package:flutter_client/src/frontend/shell/client_shell.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';

/// Deterministic, process-free production shell harness used only to freeze
/// the current catalog renderers before ownership moves.
final class ProductionClientShellFixture {
  ProductionClientShellFixture._({
    required this.controller,
    required this.surface,
    required this.size,
    required this.brightness,
    required this.appearancePresetId,
  });

  final ClientController controller;
  final LayoutRuntimeSurface surface;
  final Size size;
  final Brightness brightness;
  final String appearancePresetId;

  static Future<ProductionClientShellFixture> create({
    required LayoutProfileId profileId,
    required LayoutRuntimeSurface surface,
    required ClientSection destination,
    required Size size,
    required Brightness brightness,
  }) async {
    final composition = BuiltInLayoutComposition();
    final appearancePresetId = brightness == Brightness.dark
        ? 'lico-crystal'
        : 'geek-light-blue';
    final preferences = InMemoryPresentationPreferencesRepository(
      PresentationPreferences(
        layoutProfileId: profileId,
        appearancePresetId: appearancePresetId,
        localePreference: LocalePreference.english,
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
    final controller = ClientController(
      agentService: agentService,
      conversationService: const _FixtureConversationService(),
      layoutComposition: composition,
      presentationPreferencesRepository: preferences,
      mobileClientRuntimePlatformOverride:
          surface == LayoutRuntimeSurface.mobile,
    );

    controller
      ..currentSection = destination
      ..appearancePresetId = appearancePresetId
      ..localePreference = LocalePreference.english
      ..statusCaption = 'Ready'
      ..statusMessage = 'Deterministic layout baseline ready.'
      ..portableDataPath = ''
      ..scannedTargets = targets
      ..agentTabOrder = [primaryTarget.target]
      ..mobileRelayConfig = _fixtureMobileRelayConfig();

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
    return ProductionClientShellFixture._(
      controller: controller,
      surface: surface,
      size: size,
      brightness: brightness,
      appearancePresetId: appearancePresetId,
    );
  }

  Widget buildApp({
    required Key semanticsKey,
    required Key repaintBoundaryKey,
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
          disableAnimations: true,
        ),
        child: Semantics(
          key: semanticsKey,
          container: true,
          explicitChildNodes: true,
          child: RepaintBoundary(
            key: repaintBoundaryKey,
            child: ClientShell(controller: controller),
          ),
        ),
      ),
    );
  }
}

final class InMemoryPresentationPreferencesRepository
    implements PresentationPreferencesRepository {
  InMemoryPresentationPreferencesRepository(this._preferences);

  PresentationPreferences _preferences;

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

final class _FixtureAgentService extends AgentService {
  _FixtureAgentService({required this.targets, required this.primaryTargetId})
    : super(
        runCliExecutable: (executable, arguments, environment) async =>
            ProcessResult(0, 0, '{}', ''),
      );

  final List<TargetCandidate> targets;
  final String primaryTargetId;

  @override
  Future<List<TargetCandidate>> scanTargets() async => targets;

  @override
  Future<TargetCandidate?> scanOneTarget(String targetId) async {
    for (final target in targets) {
      if (target.target == targetId) {
        return target;
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
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
}

final class _FixtureConversationService extends AgentConversationService {
  const _FixtureConversationService();

  @override
  Future<List<AgentConversationSession>> loadSessions({
    required Object agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) async => const [];

  @override
  Stream<AgentConversationSession> streamSessions({
    required Object agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) => const Stream.empty();
}

const String _fixtureTimestamp = '2020-01-02T03:04:00Z';

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

MobileRelayConfig _fixtureMobileRelayConfig() => const MobileRelayConfig(
  schemaVersion: MobileRelayConfig.currentSchemaVersion,
  defaultGatewayUrl: '',
  useCustomGateway: false,
  customGatewayUrl: '',
  pcClientId: '',
  pcClientName: 'Fixture Desktop',
  pairingId: '',
  pcToken: '',
  mobileToken: '',
  lastPairingCode: '',
  lastPairingExpiresAt: '',
  paired: false,
  relayEnabled: false,
  pollIntervalSeconds: 5,
  pcTokenPresent: false,
  mobileTokenPresent: false,
);
