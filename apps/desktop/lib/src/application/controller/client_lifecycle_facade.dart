import 'dart:async';

import 'package:licoup/src/application/controller/client_agent_usage_facade.dart';
import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/controller/client_maintenance_facade.dart';
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
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/shared/appearance/appearance_preset_config.dart'
    as appearance_ui;
import 'package:licoup/src/contracts/llm_vault_authorization.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';

mixin ClientLifecycleFacade
    on
        AgentWorkspaceCoordinator,
        ConversationArchiveController,
        ClientPresentationFacade,
        ClientRoutingFacade,
        ClientMaintenanceFacade,
        ClientAgentUsageFacade,
        ClientMobileRelayFacade,
        ClientSkillHubFacade,
        ClientTargetFacade,
        ClientNavigationFacade {
  ClientLifecycleCoordinator get lifecycleController;
  @override
  TargetController get targetController;
  @override
  MobileRelayController get mobileRelayController;
  @override
  MobileHomeLayoutController get mobileHomeLayoutController;
  @override
  SkillHubController get skillHubController;
  CatalogConvergenceController get catalogConvergenceController;
  LlmGatewayLifecycleController get llmGatewayLifecycleController;
  LlmVaultAuthorization get llmVaultAuthorization;
  Future<void> loadConversationSessions(String agentId);

  String portableDataPath = '';
  Future<void> initialize() => initializeWithOptions();

  Future<void> initializeWithOptions({bool runBackgroundSteps = true}) =>
      lifecycleController.initialize(
        sequentialSteps: [
          ClientBootstrapStep(
            id: 'client_storage',
            action: _initializeClientStorage,
          ),
          ClientBootstrapStep(
            id: 'client_preferences',
            action: _initializeClientPreferences,
          ),
          ClientBootstrapStep(
            id: 'client_mobile_relay',
            action: _initializeClientCore,
          ),
          ClientBootstrapStep(
            id: 'client_mobile_home',
            action: _initializeClientMobileHome,
          ),
          ClientBootstrapStep(
            id: 'client_skill_preferences',
            action: _initializeClientSkillPreferences,
          ),
          ClientBootstrapStep(
            id: 'client_catalog',
            action: _initializeClientCatalog,
          ),
          ClientBootstrapStep(
            id: 'client_preload',
            action: _initializeClientPreload,
          ),
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
                  action: ensureOpencodeServeSilently,
                ),
              ],
        runBackgroundSteps: runBackgroundSteps,
        finalStep: ClientBootstrapStep(
          id: 'client_finalize',
          action: _finalizeClientInitialization,
        ),
      );

  /// Starts the desktop Gateway sidecar after the application owns a visible
  /// window. Credential authorization stays on the Models Gateway card so cold
  /// start never opens the protected store or prompts for system approval.
  Future<void> initializeLlmGateway() async {
    if (!mobileClientRuntimePlatform) {
      await llmGatewayLifecycleController.initialize();
    }
  }

  Future<void> _initializeClientStorage() async {
    final dataDir = await portableData.dataDirectory();
    portableDataPath = dataDir.path;
    await hydrateConversationProjectionCache();
    await loadConversationToolAllowlists();
    final catalog = await appearancePresetCatalogService.loadCatalog(
      portableData,
    );
    applyAppearancePresetCatalog(catalog);
    await layoutManager.initialize();
  }

  Future<void> _initializeClientPreferences() async {
    final presentation = layoutManager.preferences;
    final requestedAppearancePresetId =
        presentation?.appearancePresetId ?? AppearancePresetIds.licoSoda;
    // System-following and light themes are not ready yet, so a configured
    // brightness that lands on them falls back to the dark theme at startup.
    final resolvedAppearancePresetId = switch (appearance_ui
        .appearanceBrightnessSelectionFor(
          requestedAppearancePresetId,
          appearancePresetConfigs,
        )) {
      appearance_ui.AppearanceBrightnessSelection.system ||
      appearance_ui.AppearanceBrightnessSelection.light =>
        AppearancePresetIds.licoSoda,
      _ => requestedAppearancePresetId,
    };
    if (!hasAppearancePresetConfig(
      resolvedAppearancePresetId,
      appearancePresetConfigs,
    )) {
      appearancePresetId = AppearancePresetIds.licoSoda;
      await layoutManager.setAppearancePreset(appearancePresetId);
    } else {
      appearancePresetId = resolvedAppearancePresetId;
    }
    localePreference = LocalePreference.normalize(
      presentation?.localePreference ?? LocalePreference.system,
    );
    await targetController.loadTabOrder();
    await targetController.hydrateCache();
    await loadAgentOrchestrationPolicy();
  }

  Future<void> _initializeClientCore() async {
    await mobileRelayController.loadConfig(authorizeSecrets: false);
  }

  Future<void> _initializeClientMobileHome() =>
      mobileHomeLayoutController.load();

  Future<void> _initializeClientSkillPreferences() =>
      skillHubController.loadPreferences();

  Future<void> _initializeClientCatalog() =>
      catalogConvergenceController.bootstrap();

  Future<void> _initializeClientPreload() async {
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
            : 'LicoUp client 已就绪，部分外观预设配置无效。',
        appearancePresetLoadErrors.isEmpty
            ? 'LicoUp client is ready.'
            : 'LicoUp client is ready, but some appearance preset configurations are invalid.',
        displayChinese: appearancePresetLoadErrors.isEmpty
            ? '客户端已就绪。'
            : '客户端已就绪，但部分外观预设配置无效。',
      );
      statusCaption = 'Ready';
    }
    notifyAppPresentationChanged();
    notifyClientStateChanged();
  }
}
