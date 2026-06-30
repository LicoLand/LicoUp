import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/future_client_models.dart';
import '../services/appearance_preferences_service.dart';
import '../services/agent_conversation_service.dart';
import '../services/agent_service.dart';
import '../services/agent_usage_service.dart';
import '../services/local_runtime_preferences_service.dart';
import '../services/mobile_relay_service.dart';
import '../services/portable_data_root.dart';
import '../ui/appearance_preset_config.dart';

part 'mcp_plugin_actions.dart';
part 'model_forwarding_actions.dart';
part 'skill_hub_actions.dart';
part 'target_actions.dart';
part 'agent_conversation_actions.dart';
part 'agent_usage_actions.dart';
part 'agent_conversation_archive_actions.dart';
part 'secure_mesh_actions.dart';
part 'mobile_relay_actions.dart';
part 'local_runtime_actions.dart';
part 'controller_lifecycle_actions.dart';

class FutureClientController extends ChangeNotifier {
  FutureClientController({
    PortableDataRoot? portableData,
    AgentService? agentService,
    AgentConversationService? conversationService,
    AgentUsageService? agentUsageService,
    MobileRelayService? mobileRelayService,
    AppearancePreferencesService? appearancePreferencesService,
    LocalRuntimePreferencesService? localRuntimePreferencesService,
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
       appearancePreferencesService =
           appearancePreferencesService ?? const AppearancePreferencesService(),
       localRuntimePreferencesService =
           localRuntimePreferencesService ??
           const LocalRuntimePreferencesService() {
    bootstrapController.addListener(_notifyStateChanged);
    archiveKeywordsController.addListener(_notifyStateChanged);
    archiveDestinationController.addListener(_notifyStateChanged);
  }

  final PortableDataRoot portableData;
  final AgentService agentService;
  final AgentConversationService conversationService;
  final AgentUsageService agentUsageService;
  final MobileRelayService mobileRelayService;
  final AppearancePreferencesService appearancePreferencesService;
  final LocalRuntimePreferencesService localRuntimePreferencesService;
  final TextEditingController bootstrapController = TextEditingController();
  final TextEditingController snapshotRootController = TextEditingController();
  final TextEditingController archiveKeywordsController =
      TextEditingController();
  final TextEditingController archiveDestinationController =
      TextEditingController();
  final TextEditingController snapshotCuratorController =
      TextEditingController();

  FutureClientSection currentSection = FutureClientSection.agents;
  String appearancePresetId = AppearancePresetIds.defaultSystem;
  List<AppearancePresetConfig> appearancePresetConfigs =
      builtInAppearancePresetConfigs;
  String appearancePresetDirectoryPath = '';
  List<String> appearancePresetLoadErrors = const [];
  List<TargetCandidate> scannedTargets = const [];
  Map<String, dynamic>? targetInspection;
  Map<String, dynamic>? targetConfigPlan;
  Map<String, Map<String, dynamic>> mcpPluginStatuses = const {};
  Map<String, dynamic>? mcpPluginActionResult;
  List<Map<String, dynamic>> modelProfiles = const [];
  Map<String, dynamic>? modelForwardingResult;
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
  List<Map<String, dynamic>> lastSecureMeshCommandExecutions = const [];
  LocalRuntimePreferences localRuntimePreferences =
      LocalRuntimePreferences.defaults();
  Map<String, dynamic>? localRuntimeState;
  List<String> localRuntimeLogLines = const [];
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
  List<AgentUsageReport> agentUsageReports = const [];
  Map<String, List<AgentConversationSession>> conversationSessionsByAgent =
      const {};
  String selectedConversationAgentId = '';
  String selectedConversationSessionId = '';
  String selectedArchiveProfileId = '';
  String selectedConversationArchiveJobId = '';
  bool initialized = false;
  bool isScanningTargets = false;
  bool isAddingTarget = false;
  bool isModelForwardingBusy = false;
  bool isSkillHubBusy = false;
  bool isMobileRelayBusy = false;
  bool isMobileRelayPolling = false;
  bool isLocalRuntimeBusy = false;
  bool isLoadingConversations = false;
  bool isSendingConversationMessage = false;
  bool isScanningAgentUsage = false;
  bool isObservingAgentNetwork = false;
  bool isCollectingConversationArchive = false;
  bool isSavingSnapshotRoot = false;
  bool isSavingSnapshotCurator = false;
  bool _disposed = false;
  Timer? _mobileRelayTimer;
  final Set<String> _mcpPluginBusyTargets = <String>{};
  String portableDataPath = '';
  String statusMessage = '等待扫描目标适配器。';
  String statusCaption = 'Future client';
  String lastError = '';

  String get appearancePresetLabel {
    return findAppearancePresetConfig(
      appearancePresetId,
      appearancePresetConfigs,
    ).labelFor();
  }

  bool isMcpPluginBusy(String target) {
    return _mcpPluginBusyTargets.contains(target);
  }

  void _notifyStateChanged() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  void selectSection(FutureClientSection section) {
    if (currentSection == section) {
      return;
    }
    currentSection = section;
    _notifyStateChanged();
    if (section == FutureClientSection.agents && scannedTargets.isEmpty) {
      unawaited(scanTargets());
    }
    if (section == FutureClientSection.localRuntime) {
      unawaited(refreshLocalRuntimeStatus());
    }
    if (section == FutureClientSection.mobileRelay) {
      unawaited(refreshSecureMeshStatus());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _mobileRelayTimer?.cancel();
    bootstrapController.dispose();
    snapshotRootController.dispose();
    archiveKeywordsController.dispose();
    archiveDestinationController.dispose();
    snapshotCuratorController.dispose();
    super.dispose();
  }
}
