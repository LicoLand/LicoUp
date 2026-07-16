import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/application/composition/built_in_layout_composition.dart';
import 'package:flutter_client/src/application/controller/client_agent_usage_facade.dart';
import 'package:flutter_client/src/application/controller/client_component_assembly.dart';
import 'package:flutter_client/src/application/controller/client_conversation_archive_bindings.dart';
import 'package:flutter_client/src/application/controller/client_conversation_facade.dart';
import 'package:flutter_client/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:flutter_client/src/application/controller/client_lifecycle_facade.dart';
import 'package:flutter_client/src/application/controller/client_maintenance_facade.dart';
import 'package:flutter_client/src/application/controller/client_mobile_relay_facade.dart';
import 'package:flutter_client/src/application/controller/client_navigation_facade.dart';
import 'package:flutter_client/src/application/controller/client_presentation_facade.dart';
import 'package:flutter_client/src/application/controller/client_routing_facade.dart';
import 'package:flutter_client/src/application/controller/client_shell_controller.dart';
import 'package:flutter_client/src/application/controller/client_skill_hub_facade.dart';
import 'package:flutter_client/src/application/controller/client_target_facade.dart';
import 'package:flutter_client/src/application/features/agents/archive/conversation_archive_controller.dart';
import 'package:flutter_client/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:flutter_client/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:flutter_client/src/application/features/agents/controller/agent_usage_controller.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_refresh_controller.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_selection_store.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_controller.dart';
import 'package:flutter_client/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:flutter_client/src/application/features/layout/layout_manager.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:flutter_client/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:flutter_client/src/application/features/routing/controller/routing_module_lifecycle_controller.dart';
import 'package:flutter_client/src/application/features/settings/controller/client_log_export_controller.dart';
import 'package:flutter_client/src/application/features/settings/controller/client_update_controller.dart';
import 'package:flutter_client/src/application/features/settings/controller/directory_path_controller.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_update_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/services/skill_auto_update_scheduler.dart';
import 'package:flutter_client/src/application/features/targets/controller/target_controller.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_usage_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:flutter_client/src/backend/features/settings/services/client_update_service.dart';
import 'package:flutter_client/src/backend/features/skill_hub/services/skill_hub_preferences_service.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout_repository.dart';
import 'package:flutter_client/src/contracts/catalog_convergence/catalog_convergence_gateway.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_gateway.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_client/src/contracts/skill_delete.dart';
import 'package:flutter_client/src/contracts/skill_hub.dart';
import 'package:flutter_client/src/contracts/skill_update.dart';
import 'package:flutter_client/src/contracts/skill_usage.dart';
import 'package:flutter_client/src/platform/agents/agent_tab_order_store.dart';
import 'package:flutter_client/src/platform/agents/scanned_targets_cache_store.dart';
import 'package:flutter_client/src/platform/appearance/appearance_preset_catalog_service.dart';
import 'package:flutter_client/src/platform/client_clipboard_service.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_home_layout_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/runtime_platform_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_capability_service.dart';
import 'package:flutter_client/src/platform/skill_hub/skill_hub_preferences_store.dart';
import 'package:flutter_client/src/platform/storage/client_log_export_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';

/// Stable application facade. Feature behavior and component construction live
/// in focused facade and assembly leaves.
class ClientController extends AgentOrchestrationController
    with
        ConversationRefreshController,
        ConversationSelectionStore,
        ConversationArchiveJobController,
        ConversationSnapshotCollectionController,
        ConversationArchiveProfileController,
        ConversationArchiveSettingsController,
        ConversationArchiveController,
        ClientConversationArchiveBindings,
        ClientConversationFacade,
        ClientPresentationFacade,
        ClientAgentUsageFacade,
        ClientMobileRelayFacade,
        ClientSkillHubFacade,
        ClientTargetFacade,
        ClientMaintenanceFacade,
        ClientRoutingFacade,
        ClientNavigationFacade,
        ClientLifecycleFacade {
  ClientController({
    PortableDataRoot? portableData,
    AgentService? agentService,
    AgentConversationService? conversationService,
    AgentUsageService? agentUsageService,
    ClientUpdateService? clientUpdateService,
    OptionalCollaborationGateway? optionalCollaborationGateway,
    MobileRelayService? mobileRelayService,
    SecureMeshCapabilityService? secureMeshCapabilityService,
    MobileHomeLayoutService? mobileHomeLayoutService,
    MobileHomeLayoutRepository? mobileHomeLayoutRepository,
    SkillHubGateway? skillHubGateway,
    SkillUpdateGateway? skillUpdateGateway,
    SkillDeleteGateway? skillDeleteGateway,
    SkillUsageGateway? skillUsageGateway,
    SkillHubLocalCatalogSource? skillHubLocalCatalogSource,
    SkillHubPreferencesService? skillHubPreferencesService,
    AgentTabOrderStore? agentTabOrderStore,
    ScannedTargetsCacheStore? scannedTargetsCacheStore,
    AppearancePresetCatalogService? appearancePresetCatalogService,
    BuiltInLayoutComposition? layoutComposition,
    LayoutManager? layoutManager,
    PresentationPreferencesRepository? presentationPreferencesRepository,
    ClientLogExportService? clientLogExportService,
    ClientClipboardService? clientClipboardService,
    RuntimePlatformBridge? runtimePlatformBridge,
    this.conversationRefreshPolicy = const ConversationRefreshPolicy(),
    bool? mobileClientRuntimePlatformOverride,
    CatalogConvergenceGateway? catalogConvergenceGateway,
  }) : portableData = portableData ?? PortableDataRoot(),
       agentService =
           agentService ??
           AgentService(
             dataDirectory: () async => (portableData ?? PortableDataRoot())
                 .dataDirectory()
                 .then((directory) => directory.path),
           ),
       conversationService =
           conversationService ?? const AgentConversationService(),
       agentUsageService = agentUsageService ?? const AgentUsageService(),
       clientUpdateService = clientUpdateService ?? const ClientUpdateService(),
       mobileRelayService = mobileRelayService ?? const MobileRelayService(),
       secureMeshCapabilityService =
           secureMeshCapabilityService ?? const SecureMeshCapabilityService(),
       mobileHomeLayoutService =
           mobileHomeLayoutService ??
           const MobileHomeLayoutService(
             store: PlatformMobileHomeLayoutStore(),
           ),
       skillHubPreferencesService =
           skillHubPreferencesService ??
           const SkillHubPreferencesService(
             store: PlatformSkillHubPreferencesStore(),
           ),
       agentTabOrderStore =
           agentTabOrderStore ?? const PlatformAgentTabOrderStore(),
       scannedTargetsCacheStore =
           scannedTargetsCacheStore ?? const PlatformScannedTargetsCacheStore(),
       appearancePresetCatalogService =
           appearancePresetCatalogService ??
           const AppearancePresetCatalogService(),
       clientLogExportService =
           clientLogExportService ?? const ClientLogExportService(),
       clientClipboardService =
           clientClipboardService ?? const ClientClipboardService(),
       runtimePlatformBridge =
           runtimePlatformBridge ?? const RuntimePlatformBridge(),
       _mobileClientRuntimePlatformOverride =
           mobileClientRuntimePlatformOverride,
       _ownsAgentService = agentService == null {
    _components = ClientComponentAssembly(
      portableData: this.portableData,
      agentService: this.agentService,
      conversationService: this.conversationService,
      agentUsageService: this.agentUsageService,
      clientUpdateService: this.clientUpdateService,
      mobileRelayService: this.mobileRelayService,
      secureMeshCapabilityService: this.secureMeshCapabilityService,
      mobileHomeLayoutService: this.mobileHomeLayoutService,
      skillHubPreferencesService: this.skillHubPreferencesService,
      agentTabOrderStore: this.agentTabOrderStore,
      scannedTargetsCacheStore: this.scannedTargetsCacheStore,
      clientLogExportService: this.clientLogExportService,
      clientClipboardService: this.clientClipboardService,
      runtimePlatformBridge: this.runtimePlatformBridge,
      isMobileRuntime: () => mobileClientRuntimePlatform,
      selectedAgentId: () => selectedConversationAgentId,
      scannedTargets: () => scannedTargets,
      replaceScannedTargets: (value) => scannedTargets = value,
      ensureTargets: scanTargets,
      ensureTargetsSilently: () =>
          scanTargets(showProgress: false, surfaceErrors: true),
      loadSelectedConversation: loadConversationSessions,
      shouldLoadSelectedConversation: () =>
          selectedConversationAgentId.isNotEmpty &&
          !selectedConversationIsOrchestration &&
          !mobileClientRuntimePlatform,
      isOrchestrationTarget: isAgentOrchestrationTargetId,
      discoverMobileTargets: discoverMobileRelayTargets,
      onTargetsSettled: () {
        syncAgentOrchestrationPolicy();
        selectDefaultConversationAgent();
      },
      selectDefaultConversationAgent: selectDefaultConversationAgent,
      onRoutingPolicy: clientApplyRoutingPolicy,
      onInitializedChanged: (value) => initialized = value,
      onEnterAgents: clientEnterAgentsSection,
      onEnterMonitoring: clientEnterMonitoringSection,
      onExitMonitoring: clientExitMonitoringSection,
      onEnterMobileRelay: clientEnterMobileRelaySection,
      notifyStateChanged: notifyClientStateChanged,
      mobileHomeLayoutRepository: mobileHomeLayoutRepository,
      skillHubGateway: skillHubGateway,
      skillUpdateGateway: skillUpdateGateway,
      skillDeleteGateway: skillDeleteGateway,
      skillUsageGateway: skillUsageGateway,
      skillHubLocalCatalogSource: skillHubLocalCatalogSource,
      optionalCollaborationGateway: optionalCollaborationGateway,
      layoutComposition: layoutComposition,
      layoutManager: layoutManager,
      presentationPreferencesRepository: presentationPreferencesRepository,
      catalogConvergenceGateway: catalogConvergenceGateway,
    );
    bootstrapController.addListener(notifyClientStateChanged);
    archiveQueryController.addListener(notifyClientStateChanged);
    archiveDestinationController.addListener(notifyClientStateChanged);
  }

  @override
  final PortableDataRoot portableData;
  @override
  final AgentService agentService;
  final AgentConversationService conversationService;
  final AgentUsageService agentUsageService;
  final ClientUpdateService clientUpdateService;
  final MobileRelayService mobileRelayService;
  final SecureMeshCapabilityService secureMeshCapabilityService;
  final MobileHomeLayoutService mobileHomeLayoutService;
  final SkillHubPreferencesService skillHubPreferencesService;
  final AgentTabOrderStore agentTabOrderStore;
  final ScannedTargetsCacheStore scannedTargetsCacheStore;
  @override
  final AppearancePresetCatalogService appearancePresetCatalogService;
  final ClientLogExportService clientLogExportService;
  final ClientClipboardService clientClipboardService;
  final RuntimePlatformBridge runtimePlatformBridge;
  @override
  final ConversationRefreshPolicy conversationRefreshPolicy;
  final bool? _mobileClientRuntimePlatformOverride;
  final bool _ownsAgentService;
  late final ClientComponentAssembly _components;
  bool _disposed = false;

  final TextEditingController bootstrapController = TextEditingController();
  @override
  final TextEditingController snapshotRootController = TextEditingController();
  @override
  final TextEditingController archiveQueryController = TextEditingController();
  @override
  final TextEditingController archiveDestinationController =
      TextEditingController();

  @override
  ClientComponentAssembly get componentAssembly => _components;
  @override
  AgentConversationGateway get conversationGateway =>
      _components.conversationGateway;
  @override
  MobileAgentConversationGateway get mobileConversationGateway =>
      _components.mobileConversationGateway;
  @override
  ConversationPresentationSignals get conversationPresentationSignals =>
      _components.conversationPresentationSignals;
  @override
  TargetController get targetController => _components.targetController;
  @override
  SkillHubController get skillHubController => _components.skillHubController;
  @override
  SkillUpdateController get skillUpdateController =>
      _components.skillUpdateController;
  @override
  SkillDeleteController get skillDeleteController =>
      _components.skillDeleteController;
  @override
  SkillUsageController get skillUsageController =>
      _components.skillUsageController;
  @override
  SkillAutoUpdateScheduler get skillAutoUpdateScheduler =>
      _components.skillAutoUpdateScheduler;
  @override
  AgentUsageController get agentUsageController =>
      _components.agentUsageController;
  @override
  ClientLogExportController get clientLogExportController =>
      _components.clientLogExportController;
  @override
  ClientUpdateController get clientUpdateController =>
      _components.clientUpdateController;
  OptionalCollaborationController get optionalCollaborationController =>
      _components.optionalCollaborationController;
  @override
  DirectoryPathController get directoryPathController =>
      _components.directoryPathController;
  @override
  MobileHomeLayoutController get mobileHomeLayoutController =>
      _components.mobileHomeLayoutController;
  @override
  MobileRelayController get mobileRelayController =>
      _components.mobileRelayController;
  @override
  SecureMeshController get secureMeshController =>
      _components.secureMeshController;
  @override
  ClientLifecycleCoordinator get lifecycleController =>
      _components.lifecycleController;
  @override
  CatalogConvergenceController get catalogConvergenceController =>
      _components.catalogConvergenceController;
  @override
  ClientShellController get shellController => _components.shellController;
  @override
  RoutingModuleLifecycleController get routingLifecycleController =>
      _components.routingLifecycleController;
  @override
  ClientNavigationController get navigationController =>
      _components.navigationController;
  BuiltInLayoutComposition get layoutComposition =>
      _components.layoutComposition;
  @override
  LayoutManager get layoutManager => _components.layoutManager;

  @override
  bool get clientControllerDisposed => _disposed;
  @override
  bool get mobileClientRuntimePlatform =>
      _mobileClientRuntimePlatformOverride ??
      runtimePlatformBridge.isMobileClientRuntime;

  @override
  Future<void> agentWorkspaceOpenDirectory(
    String path, {
    String caption = '',
  }) => openDirectoryPath(path, caption: caption);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    disposeAgentWorkspace();
    if (!mobileClientRuntimePlatform) {
      unawaited(stopClientRuntimeServices());
    }
    if (_ownsAgentService) unawaited(agentService.dispose());
    _components.dispose();
    bootstrapController.dispose();
    snapshotRootController.dispose();
    archiveQueryController.dispose();
    archiveDestinationController.dispose();
    super.dispose();
  }
}
