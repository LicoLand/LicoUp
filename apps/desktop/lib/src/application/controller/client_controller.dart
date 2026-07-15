import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/contracts/locale_preferences.dart';
import 'package:flutter_client/src/application/features/skill_hub/services/skill_hub_skill_catalog.dart';
import 'package:flutter_client/src/application/features/layout/layout_manager.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/application/features/routing/controller/routing_policy_editor_adapter.dart';
import 'package:flutter_client/src/application/features/routing/engine/route_evaluator.dart';
import 'package:flutter_client/src/application/features/routing/engine/routing_dispatch_engine.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_registration_factory.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';
import 'package:flutter_client/src/platform/agents/agent_tab_order_store.dart';
import 'package:flutter_client/src/platform/agents/scanned_targets_cache_store.dart';
import 'package:flutter_client/src/platform/appearance/appearance_preset_catalog_service.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_usage_service.dart';
import 'package:flutter_client/src/backend/features/settings/services/client_update_service.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/contracts/agent_feed_timeline.dart';
import 'package:flutter_client/src/contracts/local_runtime_preferences.dart';
import 'package:flutter_client/src/platform/client_clipboard_service.dart';
import 'package:flutter_client/src/platform/feed/agent_feed_store.dart';
import 'package:flutter_client/src/platform/local_runtime/local_runtime_preferences_store.dart';
import 'package:flutter_client/src/platform/storage/client_log_export_service.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/backend/features/feed/services/agent_feed_service.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout.dart';
import 'package:flutter_client/src/contracts/mobile_provider_conversation.dart';
import 'package:flutter_client/src/contracts/skill_hub_preferences.dart';
import 'package:flutter_client/src/contracts/secure_mesh_capability_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_file_sync_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_skill_sync_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_approval_models.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_agent_account_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_provider_conversation_service.dart';
import 'package:flutter_client/src/backend/features/skill_hub/services/skill_hub_preferences_service.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_agent_account_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_home_layout_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_provider_conversation_store.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_capability_service.dart';
import 'package:flutter_client/src/platform/skill_hub/skill_hub_preferences_store.dart';
import 'package:flutter_client/src/platform/runtime_platform_bridge.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_client/src/contracts/appearance/appearance_preset_config.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_client/src/frontend/layout/built_in_layout_composition.dart';
import 'package:flutter_client/src/platform/presentation/presentation_preferences_repository.dart';

part '../features/mcp_plugins/controller/mcp_plugin_actions.dart';
part '../features/skill_hub/controller/skill_hub_actions.dart';
part '../features/skill_hub/controller/skill_hub_preferences_actions.dart';
part '../features/targets/controller/target_actions.dart';
part '../features/targets/controller/target_ordering_actions.dart';
part '../features/agents/controller/agent_conversation_actions.dart';
part '../features/agents/controller/agent_conversation_catalog_actions.dart';
part '../features/agents/controller/agent_conversation_refresh_actions.dart';
part '../features/agents/controller/agent_conversation_selection_actions.dart';
part '../features/agents/controller/agent_conversation_mobile_session_actions.dart';
part '../features/agents/controller/agent_conversation_session_actions.dart';
part '../features/agents/controller/agent_conversation_messaging_actions.dart';
part '../features/agents/controller/agent_orchestration_actions.dart';
part '../features/agents/controller/agent_conversation_session_ordering.dart';
part '../features/agents/controller/agent_usage_actions.dart';
part '../features/agents/controller/agent_usage_scan_actions.dart';
part '../features/agents/controller/agent_conversation_archive_actions.dart';
part '../features/mobile_relay/controller/secure_mesh_actions.dart';
part '../features/mobile_relay/controller/secure_mesh_approval_actions.dart';
part '../features/mobile_relay/controller/mobile_relay_actions.dart';
part '../features/mobile_relay/controller/mobile_pairing_presentation.dart';
part '../features/mobile_relay/controller/mobile_relay_invite_codec.dart';
part '../features/mobile_relay/controller/mobile_relay_polling_actions.dart';
part '../features/mobile_relay/controller/mobile_agent_account_actions.dart';
part '../features/mobile_relay/controller/mobile_home_layout_actions.dart';
part '../features/local_runtime/controller/local_runtime_actions.dart';
part '../features/settings/controller/proxy_bridge_actions.dart';
part '../features/settings/controller/client_log_export_actions.dart';
part '../features/settings/controller/directory_path_actions.dart';
part '../features/settings/controller/client_update_actions.dart';
part 'controller_lifecycle_actions.dart';
part 'controller_conversation_state.dart';
part '../features/mobile_relay/controller/mobile_agent_oauth_prompt.dart';
part 'controller_shell_state.dart';
part '../features/feed/controller/agent_feed_actions.dart';
part 'controller_navigation_actions.dart';

class ClientController extends ChangeNotifier
    with _ClientControllerConversationState {
  ClientController({
    PortableDataRoot? portableData,
    AgentService? agentService,
    AgentConversationService? conversationService,
    AgentUsageService? agentUsageService,
    ClientUpdateService? clientUpdateService,
    MobileRelayService? mobileRelayService,
    SecureMeshCapabilityService? secureMeshCapabilityService,
    MobileAgentAccountService? mobileAgentAccountService,
    MobileHomeLayoutService? mobileHomeLayoutService,
    MobileProviderConversationService? mobileProviderConversationService,
    SkillHubPreferencesService? skillHubPreferencesService,
    AgentTabOrderStore? agentTabOrderStore,
    ScannedTargetsCacheStore? scannedTargetsCacheStore,
    AppearancePresetCatalogService? appearancePresetCatalogService,
    BuiltInLayoutComposition? layoutComposition,
    LayoutManager? layoutManager,
    PresentationPreferencesRepository? presentationPreferencesRepository,
    LocalRuntimePreferencesStore? localRuntimePreferencesStore,
    ClientLogExportService? clientLogExportService,
    ClientClipboardService? clientClipboardService,
    RuntimePlatformBridge? runtimePlatformBridge,
    AgentFeedService? agentFeedService,
    this.conversationRefreshPolicy = const ConversationRefreshPolicy(),
    bool? mobileClientRuntimePlatformOverride,
  }) : portableData = portableData ?? PortableDataRoot(),
       agentService =
           agentService ??
           AgentService(
             dataDirectory: () async => (portableData ?? PortableDataRoot())
                 .dataDirectory()
                 .then((d) => d.path),
           ),
       conversationService =
           conversationService ?? const AgentConversationService(),
       agentUsageService = agentUsageService ?? const AgentUsageService(),
       clientUpdateService = clientUpdateService ?? const ClientUpdateService(),
       mobileRelayService = mobileRelayService ?? const MobileRelayService(),
       secureMeshCapabilityService =
           secureMeshCapabilityService ?? const SecureMeshCapabilityService(),
       mobileAgentAccountService =
           mobileAgentAccountService ??
           const MobileAgentAccountService(
             store: PlatformMobileAgentAccountStore(),
           ),
       mobileHomeLayoutService =
           mobileHomeLayoutService ??
           const MobileHomeLayoutService(
             store: PlatformMobileHomeLayoutStore(),
           ),
       mobileProviderConversationService =
           mobileProviderConversationService ??
           const MobileProviderConversationService(
             store: PlatformMobileProviderConversationStore(),
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
       localRuntimePreferencesStore =
           localRuntimePreferencesStore ??
           const PlatformLocalRuntimePreferencesStore(),
       clientLogExportService =
           clientLogExportService ?? const ClientLogExportService(),
       clientClipboardService =
           clientClipboardService ?? const ClientClipboardService(),
       runtimePlatformBridge =
           runtimePlatformBridge ?? const RuntimePlatformBridge(),
       agentFeedService =
           agentFeedService ??
           const AgentFeedService(store: PlatformAgentFeedStore()),
       _mobileClientRuntimePlatformOverride =
           mobileClientRuntimePlatformOverride,
       _ownsAgentService = agentService == null {
    this.layoutComposition = layoutComposition ?? BuiltInLayoutComposition();
    final preferredLayout = LayoutProfileDefaults.preferredForPlatform(
      defaultTargetPlatform,
    );
    this.layoutManager =
        layoutManager ??
        LayoutManager(
          catalog: this.layoutComposition.catalog,
          preferencesRepository:
              presentationPreferencesRepository ??
              FilePresentationPreferencesRepository(
                portableData: this.portableData,
                fallback: PresentationPreferences(
                  layoutProfileId: preferredLayout,
                  appearancePresetId: AppearancePresetIds.defaultSystem,
                  localePreference: LocalePreference.system,
                ),
              ),
          canonicalFallback: PresentationPreferences(
            layoutProfileId: preferredLayout,
            appearancePresetId: AppearancePresetIds.defaultSystem,
            localePreference: LocalePreference.system,
          ),
          preferredDefaultId: preferredLayout,
          initialEnvironment: LayoutEnvironment.fromConstraints(
            surface: LayoutRuntimeSurface.desktop,
            width: 1280,
            height: 800,
            textScale: 1,
            hasPointer: true,
            hasKeyboard: true,
          ),
        );
    bootstrapController.addListener(_notifyStateChanged);
    archiveKeywordsController.addListener(_notifyStateChanged);
    archiveDestinationController.addListener(_notifyStateChanged);
  }

  final PortableDataRoot portableData;
  final AgentService agentService;
  final AgentConversationService conversationService;
  final AgentUsageService agentUsageService;
  final ClientUpdateService clientUpdateService;
  final MobileRelayService mobileRelayService;
  final SecureMeshCapabilityService secureMeshCapabilityService;
  final MobileAgentAccountService mobileAgentAccountService;
  final MobileHomeLayoutService mobileHomeLayoutService;
  final MobileProviderConversationService mobileProviderConversationService;
  final SkillHubPreferencesService skillHubPreferencesService;
  final AgentTabOrderStore agentTabOrderStore;
  final ScannedTargetsCacheStore scannedTargetsCacheStore;
  final AppearancePresetCatalogService appearancePresetCatalogService;
  late final BuiltInLayoutComposition layoutComposition;
  late final LayoutManager layoutManager;
  final LocalRuntimePreferencesStore localRuntimePreferencesStore;
  final ClientLogExportService clientLogExportService;
  final ClientClipboardService clientClipboardService;
  final RuntimePlatformBridge runtimePlatformBridge;
  final AgentFeedService agentFeedService;
  final ConversationRefreshPolicy conversationRefreshPolicy;
  final bool? _mobileClientRuntimePlatformOverride;
  final bool _ownsAgentService;
  final TextEditingController bootstrapController = TextEditingController();
  final TextEditingController snapshotRootController = TextEditingController();
  final TextEditingController archiveKeywordsController =
      TextEditingController();
  final TextEditingController archiveDestinationController =
      TextEditingController();
  final TextEditingController snapshotCuratorController =
      TextEditingController();

  ClientSection currentSection = ClientSection.controlPanel;
  String appearancePresetId = AppearancePresetIds.defaultSystem;
  String localePreference = LocalePreference.system;
  List<AppearancePresetConfig> appearancePresetConfigs =
      builtInAppearancePresetConfigs;
  String appearancePresetDirectoryPath = '';
  List<String> appearancePresetLoadErrors = const [];
  List<TargetCandidate> scannedTargets = const [];
  List<String> agentTabOrder = const [];
  Map<String, dynamic>? targetInspection;
  Map<String, dynamic>? targetConfigPlan;
  Map<String, Map<String, dynamic>> mcpPluginStatuses = const {};
  Map<String, dynamic>? mcpPluginActionResult;
  AgentFeedTimeline feedTimeline = AgentFeedTimeline.defaults();
  List<Map<String, dynamic>> skillHubPairings = const [];
  List<Map<String, dynamic>> skillHubSkills = const [];
  SkillHubPreferences skillHubPreferences = SkillHubPreferences.defaults();
  Map<String, dynamic>? skillHubActionResult;
  Map<String, dynamic>? skillInstallPlan;
  Map<String, dynamic>? skillInstallResult;
  MobileRelayConfig mobileRelayConfig = MobileRelayConfig.defaults();
  Map<String, dynamic>? mobileRelayActionResult;
  Map<String, dynamic>? secureMeshStatus;
  SecureMeshCapabilityProjection? secureMeshCapabilityProjection;
  Map<String, dynamic>? secureMeshDeviceTrustPolicy;
  Map<String, dynamic>? secureMeshFileRoute;
  Map<String, dynamic>? secureMeshFileReceiveDestination;
  Map<String, dynamic>? secureMeshFileReceiveConfirmation;
  List<SecureMeshFileSyncTransfer> secureMeshFileSyncTransfers = const [];
  SecureMeshFileSyncTransfer? secureMeshFileSyncDraft;
  List<SecureMeshSkillSyncTransfer> secureMeshSkillSyncTransfers = const [];
  SecureMeshSkillSyncTransfer? secureMeshSkillSyncDraft;
  List<SecureMeshApprovalRequest> secureMeshApprovalInbox = const [];
  Map<String, dynamic>? secureMeshApprovalLastAction;
  Map<String, dynamic>? secureMeshApprovalAdapterCapability;
  List<MobileAgentAccount> mobileAgentAccounts = const [];
  MobileHomeLayout mobileHomeLayout = MobileHomeLayout.defaults();
  List<Map<String, dynamic>> lastSecureMeshCommandExecutions = const [];
  LocalRuntimePreferences localRuntimePreferences =
      LocalRuntimePreferences.defaults();
  Map<String, dynamic>? localRuntimeState;
  List<String> localRuntimeLogLines = const [];
  Map<String, dynamic>? opencodeServeState;
  Map<String, dynamic>? proxyBridgeStatus;
  Map<String, dynamic>? proxyBridgePlan;
  Set<String> proxyBridgeSelectedTargets = const {};
  String clientLogExportPath = '';
  List<MobileRelayCommand> lastMobileRelayCommands = const [];
  Map<String, dynamic>? snapshotRestoreResult;
  Map<String, dynamic>? conversationArchiveResult;
  Map<String, dynamic>? snapshotRootState;
  Map<String, dynamic>? preferredSnapshotCuratorState;
  List<Map<String, dynamic>> conversationSnapshotCollections = const [];
  List<Map<String, dynamic>> conversationArchiveProfiles = const [];
  List<Map<String, dynamic>> conversationArchiveWorkflowEvents = const [];
  Map<String, dynamic>? conversationArchiveReport;
  AgentUsageReport? agentUsageReport;
  Map<String, List<AgentUsageAllowance>> agentAllowanceOverrides = const {};
  List<AgentUsageReport> agentUsageReports = const [];
  ClientUpdateStatus clientUpdateStatus = const ClientUpdateStatus(
    phase: ClientUpdatePhase.idle,
    currentVersion: '',
    channel: 'stable',
  );
  String clientUpdateManifestPath = '';
  String clientUpdatePublicKeysPath = '';
  String clientUpdateStagedFileName = '';
  Map<String, List<AgentConversationSession>> conversationSessionsByAgent =
      const {};
  Map<String, bool> conversationSessionsHasMoreByAgent = const {};
  Map<String, AgentConversationSession> mobileProviderConversations = const {};
  Map<String, List<MobileProviderConversationRecord>>
  mobileProviderConversationRecordsByAccount = const {};
  Map<String, String> selectedMobileProviderConversationIds = const {};
  Map<String, MobileAgentOAuthAuthorizationPrompt>
  mobileAgentOAuthAuthorizationPrompts = const {};
  String selectedConversationAgentId = '';
  Map<String, String> _pendingConversationNativeSessionIds = const {};
  Map<String, String> conversationModelsByAgent = const {};
  Map<String, String> conversationReasoningEffortsByAgent = const {};
  AgentOrchestrationPolicy agentOrchestrationPolicy =
      const AgentOrchestrationPolicy();
  RoutingModuleRegistration? _routingModule;
  StreamSubscription<RoutingPolicyStoreEvent>? _routingPolicySubscription;
  Future<void> _orchestrationRoutingBoundaryTail = Future<void>.value();
  Map<String, RoutingCircuitBreakerState> agentOrchestrationCircuitStates =
      const {};
  String selectedArchiveProfileId = '';
  String selectedConversationArchiveJobId = '';
  bool initialized = false;
  bool isScanningTargets = false;
  bool isAddingTarget = false;
  bool isSkillHubBusy = false;
  bool isMobileRelayBusy = false;
  bool isClientUpdateBusy = false;
  bool isMobileRelayPolling = false;
  bool _mobileRelayAuthorizationRequired = false;
  bool isLocalRuntimeBusy = false;
  bool isProxyBridgeBusy = false;
  bool isExportingClientLogs = false;
  bool _isSendingConversationMessage = false;

  /// Whether any agent is currently mid-send (feed dispatch or direct UI).
  bool get isSendingConversationMessage =>
      _isSendingConversationMessage || _activeSendTargets.isNotEmpty;

  set isSendingConversationMessage(bool value) {
    _isSendingConversationMessage = value;
  }

  /// Whether the currently-selected agent is preparing a new conversation
  /// (no durable session yet). Backed by per-target state to prevent
  /// cross-agent interference during concurrent feed dispatch.
  bool get _preparingNewConversation =>
      _preparingNewConversationTargets.contains(selectedConversationAgentId);

  set _preparingNewConversation(bool value) {
    final agentId = selectedConversationAgentId;
    if (agentId.isEmpty) return;
    if (value) {
      _preparingNewConversationTargets.add(agentId);
    } else {
      _preparingNewConversationTargets.remove(agentId);
    }
  }

  /// Per-target send state: agent IDs currently mid-send (feed dispatch only).
  final Set<String> _activeSendTargets = <String>{};

  /// Local session id currently mid-send (history row + process shimmer hook).
  String sendingConversationSessionId = '';

  /// Native session id currently mid-send (matches refreshed history rows).
  String sendingConversationNativeSessionId = '';

  /// Ephemeral, in-product projection of the active native turn. Native
  /// history remains authoritative after readback, while these messages make
  /// progressive chunks and process events visible before the turn finishes.
  Map<String, List<AgentConversationMessage>> liveConversationMessagesByAgent =
      const {};

  List<AgentConversationMessage> get selectedLiveConversationMessages =>
      liveConversationMessagesByAgent[selectedConversationAgentId] ?? const [];

  /// Per-agent tab activity lights (approval / recent completion). Default: none.
  Map<String, AgentConversationTabActivity> conversationTabActivityByAgent =
      const {};
  bool isSendingMobileProviderMessage = false;
  bool _isSyncingMobileProviderCredentials = false;
  bool _syncMobileProviderCredentialsAgain = false;
  bool isScanningAgentUsage = false;
  bool isCollectingConversationArchive = false;
  bool isSavingSnapshotRoot = false;
  bool isSavingSnapshotCurator = false;
  Timer? _mobileRelayTimer;
  Timer? _mobileAgentOAuthStatusTimer;
  Timer? _mcpPluginTargetScanTimer;
  Timer? _agentUsagePollingTimer;
  bool _agentUsagePollingActive = false;
  bool _isRefreshingTargets = false;
  int _targetScanGeneration = 0;
  bool _isPollingMobileAgentOAuthStatus = false;
  int _mobileAgentOAuthAttempt = 0;
  final Map<String, Future<Map<String, dynamic>>>
  _mobileAgentOAuthValidationFutures = {};
  final Set<String> _mcpPluginBusyTargets = <String>{};
  final Set<String> _agentAllowanceRefreshes = <String>{};
  Future<void>? _agentUsageRefreshFuture;
  Future<void>? _agentUsageScanFuture;
  String portableDataPath = '';
  String statusMessage = '等待扫描目标适配器。';
  String statusCaption = 'LicoArc client';
  String _localizedStatusMessageSource = '等待扫描目标适配器。';
  String _localizedStatusMessageChinese = '等待扫描目标适配器。';
  String _localizedStatusMessageEnglish = 'Waiting to scan target adapters.';
  String lastError = '';

  bool get isLoadingConversations => _mobileClientRuntimePlatform
      ? _isLoadingMobileConversations
      : _conversationSessionLoadingTargets.contains(
          selectedConversationAgentId,
        );

  String get selectedConversationSessionId =>
      _selectedConversationSessionIdsByAgent[selectedConversationAgentId] ?? '';

  set selectedConversationSessionId(String value) {
    final agentId = selectedConversationAgentId.trim();
    if (agentId.isEmpty) {
      return;
    }
    _setSelectedConversationSessionIdForAgent(agentId, value);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_routingPolicySubscription?.cancel());
    _routingPolicySubscription = null;
    unawaited(_routingModule?.deactivate());
    _routingModule = null;
    _mobileRelayTimer?.cancel();
    _conversationActiveRefreshTimer?.cancel();
    _conversationBackgroundRefreshTimer?.cancel();
    _mobileAgentOAuthStatusTimer?.cancel();
    _mcpPluginTargetScanTimer?.cancel();
    _agentUsagePollingActive = false;
    _agentUsagePollingTimer?.cancel();
    if (!_mobileClientRuntimePlatform) {
      unawaited(_stopOpencodeServeSilently());
    }
    if (_ownsAgentService) {
      unawaited(agentService.dispose());
    }
    layoutManager.dispose();
    bootstrapController.dispose();
    snapshotRootController.dispose();
    archiveKeywordsController.dispose();
    archiveDestinationController.dispose();
    snapshotCuratorController.dispose();
    super.dispose();
  }
}
