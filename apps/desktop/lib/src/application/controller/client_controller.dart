import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:licoup/src/application/composition/built_in_layout_composition.dart';
import 'package:licoup/src/application/controller/client_agent_usage_facade.dart';
import 'package:licoup/src/application/controller/client_component_assembly.dart';
import 'package:licoup/src/application/controller/client_conversation_archive_bindings.dart';
import 'package:licoup/src/application/controller/client_conversation_facade.dart';
import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/controller/client_lifecycle_facade.dart';
import 'package:licoup/src/application/controller/client_maintenance_facade.dart';
import 'package:licoup/src/application/controller/client_mobile_relay_facade.dart';
import 'package:licoup/src/application/controller/client_navigation_facade.dart';
import 'package:licoup/src/application/controller/client_presentation_facade.dart';
import 'package:licoup/src/application/controller/client_routing_facade.dart';
import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/application/controller/client_skill_hub_facade.dart';
import 'package:licoup/src/application/controller/client_target_facade.dart';
import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
import 'package:licoup/src/application/features/agents/archive/conversation_archive_controller.dart';
import 'package:licoup/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/application/features/agents/controller/agent_usage_controller.dart';
import 'package:licoup/src/application/features/agents/controller/provider_quota_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_refresh_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_selection_store.dart';
import 'package:licoup/src/application/features/agents/conversation/agent_conversation_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_interface_entry_hook_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_current_view_tracker.dart';
import 'package:licoup/src/application/features/plugin_management/controller/adapter_plugin_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_log_export_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_update_controller.dart';
import 'package:licoup/src/application/features/settings/controller/directory_path_controller.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/backend/features/agents/services/agent_usage_service.dart';
import 'package:licoup/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:licoup/src/backend/features/settings/services/client_update_service.dart';
import 'package:licoup/src/backend/features/skill_hub/services/skill_hub_preferences_service.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';
import 'package:licoup/src/contracts/llm_gateway_diagnostics.dart';
import 'package:licoup/src/contracts/agent_tool_allowlist_repository.dart';
import 'package:licoup/src/contracts/mobile_home_layout_repository.dart';
import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_gateway.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/conversation_image_byte_reader.dart';
import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/client_current_view.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
import 'package:licoup/src/contracts/skill_hub.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:licoup/src/platform/agents/agent_tab_order_store.dart';
import 'package:licoup/src/platform/agents/agent_tool_allowlist_store.dart';
import 'package:licoup/src/platform/agents/scanned_targets_cache_store.dart';
import 'package:licoup/src/platform/appearance/appearance_preset_catalog_service.dart';
import 'package:licoup/src/platform/client_clipboard_service.dart';
import 'package:licoup/src/platform/conversation/conversation_image_byte_reader.dart';
import 'package:licoup/src/platform/documents/plan_document_reader.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_home_layout_store.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/process/client_process_lifecycle.dart';
import 'package:licoup/src/platform/presentation/client_current_view_store.dart';
import 'package:licoup/src/platform/runtime_platform_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_capability_service.dart';
import 'package:licoup/src/platform/skill_hub/skill_hub_preferences_store.dart';
import 'package:licoup/src/platform/storage/client_log_export_service.dart';
import 'package:licoup/src/platform/storage/llm_gateway_diagnostic_log.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Stable application facade. Feature behavior and component construction live
/// in focused facade and assembly leaves.
@Deprecated(
  'Migrate gestures to events/EventSender and render domain streams from '
  'projections/*ProjectionConsumer. This compatibility composition root '
  'remains usable until its dependent displays migrate.',
)
class ClientController extends AgentConversationController
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
    SkillDeleteGateway? skillDeleteGateway,
    SkillUsageGateway? skillUsageGateway,
    SkillHubLocalCatalogSource? skillHubLocalCatalogSource,
    SkillHubPreferencesService? skillHubPreferencesService,
    AgentTabOrderStore? agentTabOrderStore,
    ScannedTargetsCacheStore? scannedTargetsCacheStore,
    ClientCurrentViewStore? currentViewStore,
    ClientCurrentViewTracker? currentViewTracker,
    AgentToolAllowlistRepository? agentToolAllowlistRepository,
    AppearancePresetCatalogService? appearancePresetCatalogService,
    BuiltInLayoutComposition? layoutComposition,
    LayoutManager? layoutManager,
    PresentationPreferencesRepository? presentationPreferencesRepository,
    ClientLogExportService? clientLogExportService,
    ClientClipboardService? clientClipboardService,
    ConversationImageByteReader? conversationImageByteReader,
    PlanDocumentReader? planDocumentReader,
    ClientProcessLifecycle? clientProcessLifecycle,
    RuntimePlatformBridge? runtimePlatformBridge,
    this.conversationRefreshPolicy = const ConversationRefreshPolicy(),
    bool? mobileClientRuntimePlatformOverride,
    CatalogConvergenceGateway? catalogConvergenceGateway,
    Duration llmGatewayMonitorInterval = const Duration(seconds: 5),
    Duration llmGatewayRecoveryRetryDelay = const Duration(milliseconds: 500),
    LlmGatewayDiagnosticSink? llmGatewayDiagnosticSink,
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
       currentViewStore =
           currentViewStore ?? const PlatformClientCurrentViewStore(),
       currentViewTracker =
           currentViewTracker ?? ClientCurrentViewTracker.instance,
       agentToolAllowlistRepository =
           agentToolAllowlistRepository ?? const AgentToolAllowlistStore(),
       appearancePresetCatalogService =
           appearancePresetCatalogService ??
           const AppearancePresetCatalogService(),
       clientLogExportService =
           clientLogExportService ?? const ClientLogExportService(),
       clientClipboardService =
           clientClipboardService ?? ClientClipboardService(),
       conversationImageByteReader =
           conversationImageByteReader ??
           PlatformConversationImageByteReader.instance,
       planDocumentReader =
           planDocumentReader ?? const LocalPlanDocumentReader(),
       clientProcessLifecycle =
           clientProcessLifecycle ?? const NativeClientProcessLifecycle(),
       runtimePlatformBridge =
           runtimePlatformBridge ?? const RuntimePlatformBridge(),
       _mobileClientRuntimePlatformOverride =
           mobileClientRuntimePlatformOverride,
       _ownsClientClipboardService = clientClipboardService == null,
       _ownsAgentService = agentService == null {
    llmGatewayLifecycleController = LlmGatewayLifecycleController(
      agentService: this.agentService,
      readSettings: agentWorkspaceReadSettingsState,
      monitorInterval: llmGatewayMonitorInterval,
      recoveryRetryDelay: llmGatewayRecoveryRetryDelay,
      diagnosticSink:
          llmGatewayDiagnosticSink ??
          LlmGatewayDiagnosticLog(portableData: this.portableData),
    )..addListener(notifyClientStateChanged);
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
          !mobileClientRuntimePlatform,
      discoverMobileTargets: discoverMobileRelayTargets,
      onTargetsSettled: _onTargetsSettled,
      selectDefaultConversationAgent: selectDefaultConversationAgent,
      onEnterMonitoring: clientEnterMonitoringSection,
      onExitMonitoring: clientExitMonitoringSection,
      notifyStateChanged: notifyClientStateChanged,
      entryHookTasks: resolveInterfaceEntryHookTasks(),
      mobileHomeLayoutRepository: mobileHomeLayoutRepository,
      skillHubGateway: skillHubGateway,
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
    messagingNotificationCenter = MessagingNotificationCenter()
      ..addListener(notifyClientStateChanged);
    clientConversationController = ClientConversationController(
      runner: this.agentService,
      onSelectionChanged: recordCurrentGroupConversationView,
    )..addListener(notifyClientStateChanged);
    _clientConversationControllerReady = true;
    clientConversationController.syncAvailableConversationAgents(
      scannedTargets,
    );
  }

  @override
  final PortableDataRoot portableData;
  @override
  final ClientCurrentViewStore currentViewStore;
  @override
  final ClientCurrentViewTracker currentViewTracker;
  @override
  final AgentToolAllowlistRepository agentToolAllowlistRepository;
  @override
  Object get agentWorkspacePortableData => portableData;
  @override
  final AgentService agentService;
  @override
  final LlmVaultAuthorization llmVaultAuthorization = LlmVaultAuthorization();
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
  @override
  ConversationAttachmentRelease get conversationAttachmentRelease =>
      clientClipboardService;
  @override
  final ConversationImageByteReader conversationImageByteReader;
  final PlanDocumentReader planDocumentReader;
  final ClientProcessLifecycle clientProcessLifecycle;
  final RuntimePlatformBridge runtimePlatformBridge;
  @override
  late final LlmGatewayLifecycleController llmGatewayLifecycleController;
  @override
  late final MessagingNotificationCenter messagingNotificationCenter;
  @override
  late final ClientConversationController clientConversationController;
  bool _clientConversationControllerReady = false;
  @override
  final ConversationRefreshPolicy conversationRefreshPolicy;
  final bool? _mobileClientRuntimePlatformOverride;
  final bool _ownsClientClipboardService;
  final bool _ownsAgentService;
  late final ClientComponentAssembly _components;

  final TextEditingController bootstrapController = TextEditingController();
  @override
  final TextEditingController snapshotRootController = TextEditingController();
  @override
  final TextEditingController archiveQueryController = TextEditingController();
  @override
  final TextEditingController archiveDestinationController =
      TextEditingController();

  ClientComponentAssembly get componentAssembly => _components;
  @override
  AgentConversationGateway get conversationGateway =>
      _components.conversationGateway;
  AdaptiveFlywheelGateway get adaptiveFlywheelGateway =>
      _components.adaptiveFlywheelGateway;
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
  SkillDeleteController get skillDeleteController =>
      _components.skillDeleteController;
  @override
  SkillUsageController get skillUsageController =>
      _components.skillUsageController;
  @override
  AgentUsageController get agentUsageController =>
      _components.agentUsageController;
  ProviderQuotaController get providerQuotaController =>
      _components.providerQuotaController;
  @override
  ClientLogExportController get clientLogExportController =>
      _components.clientLogExportController;
  @override
  ClientUpdateController get clientUpdateController =>
      _components.clientUpdateController;
  OptionalCollaborationController get optionalCollaborationController =>
      _components.optionalCollaborationController;
  @override
  AdapterPluginController get adapterPluginController =>
      _components.adapterPluginController;
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
  ClientLifecycleProjection get lifecycleProjection =>
      lifecycleController.projection;
  @override
  CatalogConvergenceController get catalogConvergenceController =>
      _components.catalogConvergenceController;
  @override
  ClientShellController get shellController => _components.shellController;
  @override
  ClientNavigationController get navigationController =>
      _components.navigationController;
  @override
  AgentHubCatalogController get agentHubCatalogController =>
      _components.agentHubCatalogController;
  @override
  ClientInterfaceEntryHookController get interfaceEntryHookController =>
      _components.interfaceEntryHookController;
  BuiltInLayoutComposition get layoutComposition =>
      _components.layoutComposition;
  @override
  LayoutManager get layoutManager => _components.layoutManager;

  @override
  bool get mobileClientRuntimePlatform =>
      _mobileClientRuntimePlatformOverride ??
      runtimePlatformBridge.isMobileClientRuntime;

  void _onTargetsSettled() {
    selectDefaultConversationAgent();
    if (_clientConversationControllerReady) {
      clientConversationController.syncAvailableConversationAgents(
        scannedTargets,
      );
    }
  }

  @override
  Future<void> agentWorkspaceOpenDirectory(
    String path, {
    String caption = '',
  }) => openDirectoryPath(path, caption: caption);

  Future<void> _disposeRuntimeServices() async {
    if (_ownsClientClipboardService) {
      await clientClipboardService.dispose();
    }
    if (_ownsAgentService) {
      await agentService.dispose();
    }
  }

  @override
  void dispose() {
    if (lifecycleProjection.disposed) return;
    lifecycleController.dispose();
    disposeAgentWorkspace();
    unawaited(_disposeRuntimeServices());
    llmGatewayLifecycleController
      ..removeListener(notifyClientStateChanged)
      ..dispose();
    messagingNotificationCenter
      ..removeListener(notifyClientStateChanged)
      ..dispose();
    clientConversationController
      ..removeListener(notifyClientStateChanged)
      ..dispose();
    llmVaultAuthorization.dispose();
    _components.dispose();
    bootstrapController.dispose();
    snapshotRootController.dispose();
    archiveQueryController.dispose();
    archiveDestinationController.dispose();
    super.dispose();
  }
}
