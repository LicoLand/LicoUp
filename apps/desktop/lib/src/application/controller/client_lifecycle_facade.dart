import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:licoup/src/application/controller/client_agent_usage_facade.dart';
import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/controller/client_mobile_relay_facade.dart';
import 'package:licoup/src/application/controller/client_navigation_facade.dart';
import 'package:licoup/src/application/controller/client_presentation_facade.dart';
import 'package:licoup/src/application/controller/client_routing_facade.dart';
import 'package:licoup/src/application/controller/client_skill_hub_facade.dart';
import 'package:licoup/src/application/controller/client_target_facade.dart';
import 'package:licoup/src/application/features/agents/archive/conversation_archive_controller.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

mixin ClientLifecycleFacade
    on
        AgentWorkspaceCoordinator,
        ConversationArchiveController,
        ClientPresentationFacade,
        ClientRoutingFacade,
        ClientAgentUsageFacade,
        ClientMobileRelayFacade,
        ClientSkillHubFacade,
        ClientTargetFacade,
        ClientNavigationFacade {
  ClientLifecycleCoordinator get lifecycleController;
  @override
  AgentService get agentService;
  @override
  TargetController get targetController;
  @override
  MobileRelayController get mobileRelayController;
  @override
  MobileHomeLayoutController get mobileHomeLayoutController;
  @override
  SkillHubController get skillHubController;
  CatalogConvergenceController get catalogConvergenceController;
  Future<void> loadConversationSessions(String agentId);

  String portableDataPath = '';
  Map<String, dynamic>? opencodeServeState;
  Future<void> initialize() => lifecycleController.initialize(
    sequentialSteps: [
      ClientBootstrapStep(id: 'client_core', action: _initializeClientCore),
    ],
    backgroundSteps: mobileClientRuntimePlatform
        ? const []
        : [
            ClientBootstrapStep(
              id: 'conversation_snapshot_root',
              action: refreshConversationSnapshotRoot,
            ),
            ClientBootstrapStep(
              id: 'opencode_serve',
              action: _ensureOpencodeServeSilently,
            ),
          ],
    finalStep: ClientBootstrapStep(
      id: 'client_finalize',
      action: _finalizeClientInitialization,
    ),
  );

  Future<void> _initializeClientCore() async {
    final dataDir = await portableData.dataDirectory();
    portableDataPath = dataDir.path;
    final catalog = await appearancePresetCatalogService.loadCatalog(
      portableData,
    );
    applyAppearancePresetCatalog(catalog);
    await layoutManager.initialize();
    final presentation = layoutManager.preferences;
    final requestedAppearancePresetId =
        presentation?.appearancePresetId ?? AppearancePresetIds.defaultSystem;
    if (!hasAppearancePresetConfig(
      requestedAppearancePresetId,
      appearancePresetConfigs,
    )) {
      appearancePresetId = AppearancePresetIds.defaultSystem;
      await layoutManager.setAppearancePreset(appearancePresetId);
    } else {
      appearancePresetId = requestedAppearancePresetId;
    }
    localePreference = LocalePreference.normalize(
      presentation?.localePreference ?? LocalePreference.system,
    );
    await targetController.loadTabOrder();
    await targetController.hydrateCache();
    await mobileRelayController.loadConfig(authorizeSecrets: false);
    await mobileHomeLayoutController.load();
    await skillHubController.loadPreferences();
    await catalogConvergenceController.bootstrap();

    if (lifecycleProjection.disposed) return;
    if (!mobileClientRuntimePlatform) {
      sectionPreloadController.start();
    }
  }

  Future<void> _finalizeClientInitialization() async {
    if (lifecycleProjection.disposed) return;
    if (!mobileClientRuntimePlatform) {
      // The landing section keeps the historical readiness contract: its data
      // is warm before initialization settles. Remaining sections keep
      // preloading in the background.
      await sectionPreloadController.awaitSection(currentSection);
      if (lifecycleProjection.disposed) return;
      startAgentUsagePolling();
      skillAutoUpdateScheduler.start();
      final agentId = selectedConversationAgentId.trim();
      if (agentId.isNotEmpty && !selectedConversationIsOrchestration) {
        unawaited(loadConversationSessions(agentId));
      }
    }
    if (lastError.isEmpty) {
      setLocalizedStatusMessage(
        appearancePresetLoadErrors.isEmpty
            ? 'LicoUp client 已就绪。'
            : 'LicoUp client 已就绪，部分外观方案配置无效。',
        appearancePresetLoadErrors.isEmpty
            ? 'LicoUp client is ready.'
            : 'LicoUp client is ready, but some appearance preset configurations are invalid.',
        displayChinese: appearancePresetLoadErrors.isEmpty
            ? '客户端已就绪。'
            : '客户端已就绪，但部分外观方案配置无效。',
      );
      statusCaption = 'Ready';
    }
    notifyAppPresentationChanged();
    notifyClientStateChanged();
  }

  Future<void> _ensureOpencodeServeSilently() async {
    try {
      opencodeServeState = await agentService.ensureOpencodeServe();
      if (opencodeServeState?['ok'] != true) {
        debugPrint('OpenCode serve bootstrap unavailable.');
      }
    } catch (_) {
      opencodeServeState = <String, dynamic>{
        'ok': false,
        'status': 'unavailable',
        'errorCode': 'opencode_serve_unavailable',
      };
      debugPrint('OpenCode serve bootstrap failed.');
    }
  }

  Future<void> stopClientRuntimeServices() async {
    try {
      opencodeServeState = await agentService.stopOpencodeServe();
    } catch (_) {
      debugPrint('OpenCode serve shutdown failed.');
    }
  }
}
