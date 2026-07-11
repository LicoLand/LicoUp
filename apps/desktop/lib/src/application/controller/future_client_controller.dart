import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/contracts/locale_preferences.dart';
import 'package:flutter_client/src/application/features/skill_hub/services/skill_hub_skill_catalog.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/application/models/future_client_models.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/application/features/routing/engine/route_bridge.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/platform/agent_orchestration/agent_orchestration_policy_store.dart';
import 'package:flutter_client/src/platform/agents/agent_tab_order_store.dart';
import 'package:flutter_client/src/platform/appearance/appearance_preferences_service.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_usage_service.dart';
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
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_agent_account_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_provider_conversation_service.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_agent_account_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_home_layout_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_provider_conversation_store.dart';
import 'package:flutter_client/src/platform/runtime_platform_bridge.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_client/src/contracts/appearance/appearance_preset_config.dart';

part '../features/mcp_plugins/controller/mcp_plugin_actions.dart';
part '../features/skill_hub/controller/skill_hub_actions.dart';
part '../features/targets/controller/target_actions.dart';
part '../features/targets/controller/target_ordering_actions.dart';
part '../features/agents/controller/agent_conversation_actions.dart';
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
part 'controller_lifecycle_actions.dart';
part '../features/mobile_relay/controller/mobile_agent_oauth_prompt.dart';
part 'controller_shell_state.dart';
part '../features/feed/controller/agent_feed_actions.dart';
part 'controller_navigation_actions.dart';

class FutureClientController extends ChangeNotifier {
  FutureClientController({
    PortableDataRoot? portableData,
    AgentService? agentService,
    AgentConversationService? conversationService,
    AgentUsageService? agentUsageService,
    MobileRelayService? mobileRelayService,
    MobileAgentAccountService? mobileAgentAccountService,
    MobileHomeLayoutService? mobileHomeLayoutService,
    MobileProviderConversationService? mobileProviderConversationService,
    AgentOrchestrationPolicyStore? agentOrchestrationPolicyStore,
    AgentTabOrderStore? agentTabOrderStore,
    AppearancePreferencesService? appearancePreferencesService,
    LocalRuntimePreferencesStore? localRuntimePreferencesStore,
    ClientLogExportService? clientLogExportService,
    ClientClipboardService? clientClipboardService,
    RuntimePlatformBridge? runtimePlatformBridge,
    AgentFeedService? agentFeedService,
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
       mobileRelayService = mobileRelayService ?? const MobileRelayService(),
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
       agentOrchestrationPolicyStore =
           agentOrchestrationPolicyStore ??
           const PlatformAgentOrchestrationPolicyStore(),
       agentTabOrderStore =
           agentTabOrderStore ?? const PlatformAgentTabOrderStore(),
       appearancePreferencesService =
           appearancePreferencesService ?? const AppearancePreferencesService(),
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
    bootstrapController.addListener(_notifyStateChanged);
    archiveKeywordsController.addListener(_notifyStateChanged);
    archiveDestinationController.addListener(_notifyStateChanged);
  }

  final PortableDataRoot portableData;
  final AgentService agentService;
  final AgentConversationService conversationService;
  final AgentUsageService agentUsageService;
  final MobileRelayService mobileRelayService;
  final MobileAgentAccountService mobileAgentAccountService;
  final MobileHomeLayoutService mobileHomeLayoutService;
  final MobileProviderConversationService mobileProviderConversationService;
  final AgentOrchestrationPolicyStore agentOrchestrationPolicyStore;
  final AgentTabOrderStore agentTabOrderStore;
  final AppearancePreferencesService appearancePreferencesService;
  final LocalRuntimePreferencesStore localRuntimePreferencesStore;
  final ClientLogExportService clientLogExportService;
  final ClientClipboardService clientClipboardService;
  final RuntimePlatformBridge runtimePlatformBridge;
  final AgentFeedService agentFeedService;
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

  FutureClientSection currentSection = FutureClientSection.controlPanel;
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
  Map<String, dynamic>? skillHubActionResult;
  Map<String, dynamic>? skillInstallPlan;
  Map<String, dynamic>? skillInstallResult;
  MobileRelayConfig mobileRelayConfig = MobileRelayConfig.defaults();
  Map<String, dynamic>? mobileRelayActionResult;
  Map<String, dynamic>? secureMeshStatus;
  Map<String, dynamic>? secureMeshDeviceTrustPolicy;
  Map<String, dynamic>? secureMeshFileRoute;
  Map<String, dynamic>? secureMeshFileReceiveDestination;
  List<MobileAgentAccount> mobileAgentAccounts = const [];
  MobileHomeLayout mobileHomeLayout = MobileHomeLayout.defaults();
  List<Map<String, dynamic>> lastSecureMeshCommandExecutions = const [];
  LocalRuntimePreferences localRuntimePreferences =
      LocalRuntimePreferences.defaults();
  Map<String, dynamic>? localRuntimeState;
  List<String> localRuntimeLogLines = const [];
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
  String selectedConversationSessionId = '';
  Map<String, String> _pendingConversationNativeSessionIds = const {};
  Map<String, String> conversationModelsByAgent = const {};
  Map<String, String> conversationReasoningEffortsByAgent = const {};
  AgentOrchestrationPolicy agentOrchestrationPolicy =
      const AgentOrchestrationPolicy();
  Set<String> agentOrchestrationCircuitBrokenAgentIds = const {};
  String selectedArchiveProfileId = '';
  String selectedConversationArchiveJobId = '';
  bool initialized = false;
  bool isScanningTargets = false;
  bool isAddingTarget = false;
  bool isSkillHubBusy = false;
  bool isMobileRelayBusy = false;
  bool isMobileRelayPolling = false;
  bool _mobileRelayAuthorizationRequired = false;
  bool isLocalRuntimeBusy = false;
  bool isProxyBridgeBusy = false;
  bool isExportingClientLogs = false;
  bool isLoadingConversations = false;
  bool isSendingConversationMessage = false;
  bool isSendingMobileProviderMessage = false;
  bool _isSyncingMobileProviderCredentials = false;
  bool _syncMobileProviderCredentialsAgain = false;
  bool isScanningAgentUsage = false;
  bool isCollectingConversationArchive = false;
  bool isSavingSnapshotRoot = false;
  bool isSavingSnapshotCurator = false;
  bool _preparingNewConversation = false;
  Map<String, String> _newConversationWorkingDirectories = const {};
  bool _disposed = false;
  Timer? _mobileRelayTimer;
  Timer? _conversationSessionTimer;
  Timer? _mobileAgentOAuthStatusTimer;
  Timer? _mcpPluginTargetScanTimer;
  Timer? _agentUsagePollingTimer;
  bool _agentUsagePollingActive = false;
  bool _isRefreshingTargets = false;
  bool _isPollingMobileAgentOAuthStatus = false;
  int _mobileAgentOAuthAttempt = 0;
  final Map<String, Future<Map<String, dynamic>>>
  _mobileAgentOAuthValidationFutures = {};
  String _conversationSessionPollingAgentId = '';
  bool _isRefreshingConversationSessions = false;
  final Set<String> _conversationSessionLoadMoreTargets = <String>{};
  final Set<String> _mcpPluginBusyTargets = <String>{};
  final Set<String> _agentAllowanceRefreshes = <String>{};
  Future<void>? _agentUsageRefreshFuture;
  Future<void>? _agentUsageScanFuture;
  String portableDataPath = '';
  String statusMessage = '等待扫描目标适配器。';
  String statusCaption = 'Future client';
  String _localizedStatusMessageSource = '等待扫描目标适配器。';
  String _localizedStatusMessageChinese = '等待扫描目标适配器。';
  String _localizedStatusMessageEnglish = 'Waiting to scan target adapters.';
  String lastError = '';

  void _notifyStateChanged() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _mobileRelayTimer?.cancel();
    _conversationSessionTimer?.cancel();
    _mobileAgentOAuthStatusTimer?.cancel();
    _mcpPluginTargetScanTimer?.cancel();
    _agentUsagePollingActive = false;
    _agentUsagePollingTimer?.cancel();
    if (_ownsAgentService) {
      unawaited(agentService.dispose());
    }
    bootstrapController.dispose();
    snapshotRootController.dispose();
    archiveKeywordsController.dispose();
    archiveDestinationController.dispose();
    snapshotCuratorController.dispose();
    super.dispose();
  }
}
