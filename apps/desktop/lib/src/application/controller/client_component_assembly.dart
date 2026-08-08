import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;

import 'package:licoup/src/application/composition/built_in_layout_composition.dart';
import 'package:licoup/src/application/controller/assembly/client_catalog_convergence_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_conversation_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_lifecycle_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_mobile_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_navigation_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_presentation_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_plugin_management_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_settings_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_skill_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_target_component_assembly.dart';
import 'package:licoup/src/application/controller/assembly/client_usage_component_assembly.dart';
import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:licoup/src/application/features/agents/controller/agent_usage_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/features/plugin_management/controller/adapter_plugin_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_log_export_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_update_controller.dart';
import 'package:licoup/src/application/features/settings/controller/directory_path_controller.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_update_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_auto_update_scheduler.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/backend/features/agents/services/agent_usage_service.dart';
import 'package:licoup/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:licoup/src/backend/features/settings/services/client_update_service.dart';
import 'package:licoup/src/backend/features/skill_hub/services/skill_hub_preferences_service.dart';
import 'package:licoup/src/contracts/mobile_home_layout_repository.dart';
import 'package:licoup/src/contracts/agent_conversation_projection_repository.dart';
import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_gateway.dart';
import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
import 'package:licoup/src/contracts/skill_hub.dart';
import 'package:licoup/src/contracts/skill_update.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:licoup/src/platform/agents/agent_tab_order_store.dart';
import 'package:licoup/src/platform/agents/agent_conversation_projection_store.dart';
import 'package:licoup/src/platform/agents/scanned_targets_cache_store.dart';
import 'package:licoup/src/platform/client_clipboard_service.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/runtime_platform_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_capability_service.dart';
import 'package:licoup/src/platform/storage/client_log_export_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Owns independent component assemblies while preserving the stable client
/// facade projection.
final class ClientComponentAssembly {
  ClientComponentAssembly({
    required PortableDataRoot portableData,
    required AgentService agentService,
    required AgentConversationService conversationService,
    required AgentUsageService agentUsageService,
    required ClientUpdateService clientUpdateService,
    required MobileRelayService mobileRelayService,
    required SecureMeshCapabilityService secureMeshCapabilityService,
    required MobileHomeLayoutService mobileHomeLayoutService,
    required SkillHubPreferencesService skillHubPreferencesService,
    required AgentTabOrderStore agentTabOrderStore,
    required ScannedTargetsCacheStore scannedTargetsCacheStore,
    required ClientLogExportService clientLogExportService,
    required ClientClipboardService clientClipboardService,
    required RuntimePlatformBridge runtimePlatformBridge,
    AgentConversationProjectionRepository?
    agentConversationProjectionRepository,
    required bool Function() isMobileRuntime,
    required String Function() selectedAgentId,
    required List<TargetCandidate> Function() scannedTargets,
    required void Function(List<TargetCandidate>) replaceScannedTargets,
    required Future<void> Function() ensureTargets,
    required Future<void> Function() ensureTargetsSilently,
    required Future<void> Function(String) loadSelectedConversation,
    required bool Function() shouldLoadSelectedConversation,
    required bool Function(String) isOrchestrationTarget,
    required Future<List<TargetCandidate>> Function({
      Map<String, dynamic>? pairingStatus,
    })
    discoverMobileTargets,
    required VoidCallback onTargetsSettled,
    required VoidCallback selectDefaultConversationAgent,
    required VoidCallback onEnterAgents,
    required VoidCallback onEnterMonitoring,
    required VoidCallback onExitMonitoring,
    required VoidCallback onEnterMobileRelay,
    required VoidCallback notifyStateChanged,
    required ClientSectionPreloadTaskMap sectionPreloadTasks,
    MobileHomeLayoutRepository? mobileHomeLayoutRepository,
    SkillHubGateway? skillHubGateway,
    SkillUpdateGateway? skillUpdateGateway,
    SkillDeleteGateway? skillDeleteGateway,
    SkillUsageGateway? skillUsageGateway,
    SkillHubLocalCatalogSource? skillHubLocalCatalogSource,
    OptionalCollaborationGateway? optionalCollaborationGateway,
    BuiltInLayoutComposition? layoutComposition,
    LayoutManager? layoutManager,
    PresentationPreferencesRepository? presentationPreferencesRepository,
    CatalogConvergenceGateway? catalogConvergenceGateway,
  }) : _notifyStateChanged = notifyStateChanged,
       agentConversationProjectionRepository =
           agentConversationProjectionRepository ??
           const PlatformAgentConversationProjectionStore() {
    presentation = ClientPresentationComponentAssembly(
      portableData: portableData,
      layoutComposition: layoutComposition,
      layoutManager: layoutManager,
      presentationPreferencesRepository: presentationPreferencesRepository,
    );
    lifecycle = ClientLifecycleComponentAssembly(reportStatus: _reportStatus);
    catalogConvergence = ClientCatalogConvergenceComponentAssembly(
      agentService: agentService,
      gateway: catalogConvergenceGateway,
    );
    conversation = ClientConversationComponentAssembly(
      conversationService: conversationService,
      mobileRelayService: mobileRelayService,
      agentService: agentService,
    );
    target = ClientTargetComponentAssembly(
      portableData: portableData,
      agentService: agentService,
      agentTabOrderStore: agentTabOrderStore,
      scannedTargetsCacheStore: scannedTargetsCacheStore,
      isMobileRuntime: isMobileRuntime,
      discoverMobileTargets: discoverMobileTargets,
      onTargetsSettled: onTargetsSettled,
      loadSelectedConversation: loadSelectedConversation,
      selectedAgentId: selectedAgentId,
      shouldLoadSelectedConversation: shouldLoadSelectedConversation,
      isOrchestrationTarget: isOrchestrationTarget,
      reportStatus: _reportStatus,
    );
    skill = ClientSkillComponentAssembly(
      portableData: portableData,
      agentService: agentService,
      preferencesService: skillHubPreferencesService,
      targets: scannedTargets,
      ensureTargets: ensureTargets,
      reportStatus: _reportStatus,
      skillHubGateway: skillHubGateway,
      skillUpdateGateway: skillUpdateGateway,
      skillDeleteGateway: skillDeleteGateway,
      skillUsageGateway: skillUsageGateway,
      localCatalogSource: skillHubLocalCatalogSource,
    );
    settings = ClientSettingsComponentAssembly(
      portableData: portableData,
      agentService: agentService,
      clientUpdateService: clientUpdateService,
      clientLogExportService: clientLogExportService,
      runtimePlatformBridge: runtimePlatformBridge,
      directoryCaption: () => shellController.strings.directory,
      reportStatus: _reportStatus,
      notifyStateChanged: notifyStateChanged,
      optionalCollaborationGateway: optionalCollaborationGateway,
      onCatalogPurge: catalogConvergenceController.disable,
    );
    pluginManagement = ClientPluginManagementComponentAssembly(
      runner: agentService,
      reportStatus: _reportStatus,
    );
    mobile = ClientMobileComponentAssembly(
      portableData: portableData,
      agentService: agentService,
      mobileRelayService: mobileRelayService,
      secureMeshCapabilityService: secureMeshCapabilityService,
      mobileHomeLayoutService: mobileHomeLayoutService,
      clientClipboardService: clientClipboardService,
      runtimePlatformBridge: runtimePlatformBridge,
      skillHubGateway: skill.resolvedGateway,
      replaceSkillInstallResult: skillHubController.replaceInstallResult,
      isMobileRuntime: isMobileRuntime,
      scannedTargets: scannedTargets,
      replaceScannedTargets: replaceScannedTargets,
      ensureTargetsSilently: ensureTargetsSilently,
      discoverMobileTargets: discoverMobileTargets,
      selectDefaultConversationAgent: selectDefaultConversationAgent,
      reportStatus: _reportStatus,
      mobileHomeLayoutRepository: mobileHomeLayoutRepository,
    );
    usage = ClientUsageComponentAssembly(
      agentUsageService: agentUsageService,
      agentService: agentService,
      selectedAgentId: selectedAgentId,
      reportStatus: _reportStatus,
    );
    navigation = ClientNavigationComponentAssembly(
      isMobileRuntime: isMobileRuntime,
      onEnterAgents: onEnterAgents,
      onEnterMonitoring: onEnterMonitoring,
      onExitMonitoring: onExitMonitoring,
      onEnterMobileRelay: onEnterMobileRelay,
      sectionPreloadTasks: sectionPreloadTasks,
      onPreloadReport: (report) =>
          shellController.replaceLastError(report.code),
    );
    for (final component in _listenedComponents) {
      component.addListener(_notifyStateChanged);
    }
  }

  final VoidCallback _notifyStateChanged;
  final AgentConversationProjectionRepository
  agentConversationProjectionRepository;
  late final ClientPresentationComponentAssembly presentation;
  late final ClientLifecycleComponentAssembly lifecycle;
  late final ClientCatalogConvergenceComponentAssembly catalogConvergence;
  late final ClientConversationComponentAssembly conversation;
  late final ClientTargetComponentAssembly target;
  late final ClientSkillComponentAssembly skill;
  late final ClientSettingsComponentAssembly settings;
  late final ClientPluginManagementComponentAssembly pluginManagement;
  late final ClientMobileComponentAssembly mobile;
  late final ClientUsageComponentAssembly usage;
  late final ClientNavigationComponentAssembly navigation;

  ClientShellController get shellController => presentation.shellController;
  ClientLifecycleCoordinator get lifecycleController => lifecycle.controller;
  CatalogConvergenceController get catalogConvergenceController =>
      catalogConvergence.controller;
  ConversationPresentationSignals get conversationPresentationSignals =>
      conversation.presentationSignals;
  AgentConversationGateway get conversationGateway =>
      conversation.conversationGateway;
  MobileAgentConversationGateway get mobileConversationGateway =>
      conversation.mobileConversationGateway;
  TargetController get targetController => target.controller;
  SkillHubController get skillHubController => skill.controller;
  SkillUpdateController get skillUpdateController => skill.updateController;
  SkillAutoUpdateScheduler get skillAutoUpdateScheduler =>
      skill.autoUpdateScheduler;
  SkillDeleteController get skillDeleteController => skill.deleteController;
  SkillUsageController get skillUsageController => skill.usageController;
  ClientLogExportController get clientLogExportController =>
      settings.logExportController;
  ClientUpdateController get clientUpdateController =>
      settings.updateController;
  OptionalCollaborationController get optionalCollaborationController =>
      settings.optionalCollaborationController;
  AdapterPluginController get adapterPluginController =>
      pluginManagement.adapterPluginController;
  DirectoryPathController get directoryPathController =>
      settings.directoryPathController;
  MobileHomeLayoutController get mobileHomeLayoutController =>
      mobile.homeLayoutController;
  MobileRelayController get mobileRelayController => mobile.relayController;
  SecureMeshController get secureMeshController => mobile.secureMeshController;
  BuiltInLayoutComposition get layoutComposition =>
      presentation.layoutComposition;
  LayoutManager get layoutManager => presentation.layoutManager;
  AgentUsageController get agentUsageController => usage.controller;
  ClientNavigationController get navigationController => navigation.controller;
  ClientSectionPreloadController get sectionPreloadController =>
      navigation.preloadController;

  List<ChangeNotifier> get _listenedComponents => [
    ...presentation.listenables,
    ...lifecycle.listenables,
    ...catalogConvergence.listenables,
    ...target.listenables,
    ...skill.listenables,
    ...settings.listenables,
    ...pluginManagement.listenables,
    ...mobile.listenables,
    ...usage.listenables,
    ...navigation.listenables,
  ];

  void _reportStatus({
    required String chinese,
    required String english,
    required String caption,
    String errorCode = '',
  }) {
    shellController.replaceLastError(errorCode);
    if (chinese.isNotEmpty || english.isNotEmpty) {
      shellController.setLocalizedStatus(
        chinese,
        english,
        caption: shellController.statusCaption,
      );
    }
    shellController.replaceStatusCaption(caption);
  }

  void dispose() {
    for (final component in _listenedComponents.reversed) {
      component.removeListener(_notifyStateChanged);
    }
    navigation.dispose();
    usage.dispose();
    mobile.dispose();
    pluginManagement.dispose();
    settings.dispose();
    skill.dispose();
    target.dispose();
    conversation.dispose();
    catalogConvergence.dispose();
    lifecycle.dispose();
    presentation.dispose();
  }
}
