import 'dart:async';

import 'package:licoup/src/application/controller/client_agent_usage_facade.dart';
import 'package:licoup/src/application/controller/client_appearance_commands.dart';
import 'package:licoup/src/application/controller/client_functional_status_commands.dart';
import 'package:licoup/src/application/controller/client_locale_commands.dart';
import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/controller/client_maintenance_facade.dart';
import 'package:licoup/src/application/controller/client_mobile_relay_facade.dart';
import 'package:licoup/src/application/controller/client_navigation_facade.dart';
import 'package:licoup/src/application/controller/client_routing_facade.dart';
import 'package:licoup/src/application/controller/client_skill_hub_facade.dart';
import 'package:licoup/src/application/controller/client_target_facade.dart';
import 'package:licoup/src/application/features/agents/archive/conversation_archive_controller.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/application/features/plugin_management/controller/package_center_controller.dart';
import 'package:licoup/src/application/features/plugin_management/controller/package_recommendation_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';

mixin ClientLifecycleFacade
    on
        AgentWorkspaceCoordinator,
        ConversationArchiveController,
        ClientAppearanceCommands,
        ClientLocaleCommands,
        ClientFunctionalStatusCommands,
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
  PackageCenterController get packageCenterController;
  PackageRecommendationController get packageRecommendationController;
  @override
  LlmGatewayLifecycleController get llmGatewayLifecycleController;
  LlmVaultAuthorization get llmVaultAuthorization;
  @override
  Future<void> loadConversationSessions(String agentId);

  final Set<String> _unavailableFeatureDomains = {};

  String portableDataPath = '';
  String portableDataSource = '';
  String portableDataPreviousRootPath = '';
  bool portableDataPreviousRootAvailable = false;
  Future<void> initialize() => initializeWithOptions();

  Future<void> initializeWithOptions({bool runBackgroundSteps = true}) =>
      lifecycleController.initialize(
        sequentialSteps: _clientSequentialSteps,
        backgroundSteps: _clientBackgroundSteps,
        runBackgroundSteps: runBackgroundSteps,
        finalStep: ClientBootstrapStep(
          id: 'client_finalize',
          action: _finalizeClientInitialization,
        ),
      );

  List<ClientBootstrapStep> get _clientSequentialSteps => [
    ClientBootstrapStep(
      id: 'client_storage_root',
      action: _resolveClientStorageRoot,
    ),
    ClientBootstrapStep(
      id: 'client_state_migration',
      action: _admitClientStateMigration,
    ),
    // Local is the highest-priority startup data target. Native state
    // admission is its only prerequisite; target-cache hydration can itself
    // start Agent history/model reads, so it must follow Local's first page.
    ClientBootstrapStep(
      id: 'client_local_conversation',
      action: _initializeLocalConversation,
    ),
    ClientBootstrapStep(id: 'client_storage', action: _initializeClientStorage),
    ClientBootstrapStep(
      id: 'client_preferences',
      action: _initializeClientPreferences,
    ),
    ClientBootstrapStep(
      id: 'client_target_order',
      requiredForStartup: false,
      action: () => _loadOptionalFeature(
        'agent-tab-order',
        targetController.loadTabOrder,
      ),
    ),
    ClientBootstrapStep(
      id: 'client_target_cache',
      action: targetController.hydrateCache,
    ),
    ClientBootstrapStep(
      id: 'client_mobile_relay',
      requiredForStartup: false,
      action: () => _loadOptionalFeature('mobile-relay', _initializeClientCore),
    ),
    ClientBootstrapStep(
      id: 'client_mobile_home',
      requiredForStartup: false,
      action: () => _loadOptionalFeature(
        'mobile-home-layout',
        _initializeClientMobileHome,
      ),
    ),
    ClientBootstrapStep(
      id: 'client_skill_preferences',
      requiredForStartup: false,
      action: () => _loadOptionalFeature(
        'skill-hub-preferences',
        _initializeClientSkillPreferences,
      ),
    ),
    ClientBootstrapStep(id: 'client_catalog', action: _initializeClientCatalog),
    // First launch settles the package center after the catalogue, never before
    // it. The step is optional twice over: it never throws, and the coordinator
    // treats any failure as an unavailable optional step rather than a failed
    // startup.
    ClientBootstrapStep(
      id: 'client_package_recommendation',
      requiredForStartup: false,
      action: _initializePackageRecommendation,
    ),
  ];

  List<ClientBootstrapStep> get _clientBackgroundSteps =>
      mobileClientRuntimePlatform
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
          ClientBootstrapStep(
            id: 'client_update_check',
            action: checkClientUpdateSilently,
          ),
        ];

  /// Starts the desktop Gateway sidecar after the application owns a visible
  /// window. Credential authorization stays on the Models Gateway card so cold
  /// start never opens the protected store or prompts for system approval.
  Future<void> initializeLlmGateway() async {
    if (!mobileClientRuntimePlatform) {
      await llmGatewayLifecycleController.initialize();
    }
  }

  Future<void> _resolveClientStorageRoot() async {
    final selection = await portableData.dataHomeSelection();
    final dataDir = await portableData.dataDirectory();
    portableDataPath = dataDir.path;
    portableDataSource = selection.source.name;
    try {
      final status = await agentService.dataHomeStatus();
      portableDataPreviousRootPath = status['previousRootPath'] is String
          ? status['previousRootPath'] as String
          : '';
      portableDataPreviousRootAvailable =
          status['previousRootAvailable'] == true &&
          portableDataPreviousRootPath.isNotEmpty;
    } on Object {
      portableDataPreviousRootPath = '';
      portableDataPreviousRootAvailable = false;
    }
  }

  Future<void> _admitClientStateMigration() async {
    try {
      final admission = await agentService.admitClientStateMigration(
        portableDataPath,
      );
      _unavailableFeatureDomains
        ..clear()
        ..addAll(
          (admission['unavailableFeatureDomainIds'] as List? ?? const [])
              .whereType<String>(),
        );
    } on Object {
      throw StateError('client_state_migration');
    }
  }

  Future<void> _initializeClientStorage() async {
    await portableData.loadWorkspaceManifest();
    replaceConversationToolAllowlists(const {});
    if (!_unavailableFeatureDomains.contains('agent-tool-allowlist')) {
      await loadConversationToolAllowlists();
    }
    if (!_unavailableFeatureDomains.contains('current-view')) {
      await loadCurrentViewRestore();
    }
    final catalog = await appearancePresetCatalogService.loadCatalog(
      portableData,
    );
    applyAppearancePresetCatalog(catalog);
    // Installed language resources render the interface strings. A first launch
    // has none, and the compiled baseline renders instead.
    await loadInstalledLocaleResources();
    await layoutManager.initialize(
      loadStoredState: !_unavailableFeatureDomains.contains(
        'appearance-presentation',
      ),
    );
  }

  Future<void> _loadOptionalFeature(
    String domain,
    Future<void> Function() load,
  ) async {
    if (_unavailableFeatureDomains.contains(domain)) {
      throw StateError('client_optional_state_unavailable');
    }
    await load();
  }

  Future<void> _initializeLocalConversation() async {
    if (mobileClientRuntimePlatform || lifecycleProjection.disposed) return;
    await clientConversationController.initialize();
  }

  Future<void> _initializeClientPreferences() async {
    final presentation = layoutManager.preferences;
    final requestedAppearancePresetId =
        presentation?.appearancePresetId ?? AppearancePresetIds.licoSoda;
    final resolvedAppearancePresetId = requestedAppearancePresetId;
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
    appearancePreferenceOwner.replaceReduceMotion(
      presentation?.reduceMotion ?? false,
    );
    appearancePreferenceOwner.replaceLoadingEffect(
      presentation?.loadingEffectId ?? 'spinner',
    );
  }

  Future<void> _initializeClientCore() async {
    if (lifecycleProjection.disposed) return;
    await mobileRelayController.loadConfig(authorizeSecrets: false);
  }

  Future<void> _initializeClientMobileHome() =>
      mobileHomeLayoutController.load();

  Future<void> _initializeClientSkillPreferences() =>
      skillHubController.loadPreferences();

  Future<void> _initializeClientCatalog() =>
      catalogConvergenceController.bootstrap();

  /// First launch: read the native package catalogue, scan for detected Agents
  /// off the frame, and offer the recommended packages as one confirmation.
  ///
  /// The durable first-launch marker is written by the recommendation
  /// controller before the offer is shown, so a quit, a crash or a refusal never
  /// repeats the offer. Nothing here throws: a failed scan or a failed install
  /// leaves the client fully usable and only the optional step unavailable.
  Future<void> _initializePackageRecommendation() async {
    if (mobileClientRuntimePlatform) return;
    final dataRoot = portableDataPath.trim();
    if (dataRoot.isEmpty) return;
    packageCenterController.useDataRoot(dataRoot);
    await packageRecommendationController.load();
    await packageCenterController.refresh();
    await adapterPluginController.refresh();
    final firstLaunch = await packageRecommendationController.runFirstLaunch(
      adapters: adapterPluginController.adapters,
    );
    if (firstLaunch.offered || firstLaunch.markerRecorded) {
      // This launch either made the first offer or is the launch that recorded
      // the marker: both settle the first launch, so nothing is offered a second
      // time here.
      return;
    }
    // First use: a capability the native catalogue names as available but not
    // installed, and that this data home has not declined, is offered once.
    packageRecommendationController.offerOnFirstUse(
      availability: PackageRecommendationController.availableCapabilities(
        adapterPluginController.adapters,
      ),
      catalog: packageCenterController.catalog,
    );
  }

  /// Startup auto-check: silently checks the GitHub release source once.
  /// Failures are non-blocking and never disturb the user; when an update is
  /// found the Settings card naturally shows the update-available state.
  Future<void> checkClientUpdateSilently() async {
    try {
      await hydrateClientUpdateIdentity();
      await checkClientUpdateFromGithub();
    } catch (_) {}
  }

  Future<void> _finalizeClientInitialization() async {
    if (lifecycleProjection.disposed) return;
    if (!mobileClientRuntimePlatform) {
      // The restored destination keeps the historical readiness contract: its
      // entry Hook lane is warm before initialization settles, while grouped
      // siblings finish quietly in the background.
      interfaceEntryHookController.requestEntry(currentSection);
      await interfaceEntryHookController.awaitEntry(currentSection);
      if (lifecycleProjection.disposed) return;
      final agentId = selectedConversationAgentId.trim();
      if (agentId.isNotEmpty) {
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
    notifyClientStateChanged();
  }
}
