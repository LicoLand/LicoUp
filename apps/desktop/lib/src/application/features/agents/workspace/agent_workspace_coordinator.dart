import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:flutter_client/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:flutter_client/src/application/localization/client_application_strings.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';
import 'package:flutter_client/src/contracts/secure_mesh_approval_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

/// Shared feature state plus narrow composition callbacks. Concrete feature
/// controllers never import the root [ClientController].
abstract class AgentWorkspaceCoordinator extends ChangeNotifier {
  AgentConversationGateway get conversationGateway;
  MobileAgentConversationGateway get mobileConversationGateway;
  List<TargetCandidate> get scannedTargets;
  set scannedTargets(List<TargetCandidate> value);
  bool get initialized;
  String get lastError;
  set lastError(String value);
  String get statusCaption;
  set statusCaption(String value);
  String get statusMessage;
  set statusMessage(String value);
  ConversationRefreshPolicy get conversationRefreshPolicy;
  bool get agentWorkspaceMobileRuntime;
  ClientSection get agentWorkspaceCurrentSection;
  ClientApplicationStrings get agentWorkspaceStrings;
  RoutingModuleRegistration? get agentWorkspaceRoutingModule;
  set agentWorkspaceRoutingModule(RoutingModuleRegistration? value);
  Future<RoutingModuleRegistration> agentWorkspaceEnsureRoutingModuleReady();
  Future<void> agentWorkspaceBindRoutingModulePolicyEvents(
    RoutingModuleRegistration registration,
  );
  Future<void> agentWorkspaceUnbindRoutingModulePolicyEvents();
  void agentWorkspaceSelectDefaultConversationAgent({
    bool preferDirectAgent = false,
  });
  void agentWorkspaceSetLocalizedStatusMessage(
    String chinese,
    String english, {
    String? displayChinese,
  });
  void agentWorkspaceNotifyStateChanged();
  void agentWorkspaceNotifyConversationStructureChanged({
    bool activeChanged = true,
  });
  void agentWorkspaceNotifyActiveConversationChanged();
  Future<void> agentWorkspaceOpenDirectory(String path, {String caption = ''});
  String get relaySourceClientId;
  String get relaySourceClientLabel;
  List<SecureMeshApprovalRequest> get secureMeshApprovalInbox;
  set secureMeshApprovalInbox(List<SecureMeshApprovalRequest> value);
  Future<void> refreshSecureMeshApprovalInbox({bool includeResolved = true});

  TargetCandidate? get selectedConversationAgent;
  List<AgentConversationSession> get selectedConversationSessions;
  AgentConversationSession? get selectedConversationSession;
  String get selectedConversationModel;
  String get selectedConversationReasoningEffort;
  bool get selectedConversationIsOrchestration;
  bool get routingModuleAvailable;
  String get effectiveAgentOrchestrationPrimaryAgentId;
  String get activeOrchestrationTaskId;
  Future<void> sendOrchestratedConversationMessage(String text);
  void syncAgentOrchestrationPolicy();
  void ensureOrchestrationConversationSession();
  Future<TaskRouteSwitchResult?> evaluateOrchestrationRoutingBoundary({
    required String taskId,
    required String trigger,
    RoutingPolicyDocument? policySnapshot,
  });
  void recordConversationTabSendOutcome({
    required String agentId,
    required bool ok,
    Map<String, dynamic> result,
    String errorCode,
  });
  void setConversationTabActivity(
    String agentId,
    AgentConversationTabActivity activity,
  );
  AgentConversationTabActivity conversationTabActivityFor(String agentId);
  void acknowledgeConversationTabWorkFinished(String agentId);
  String runtimeAdapterErrorCode(Map<String, dynamic> result);
  Future<void> refreshConversationCatalogInternal(
    String agentId, {
    required bool foreground,
  });
  Future<void> refreshActiveConversationSessionInternal(
    String agentId,
    String sessionId,
  );
  int beginConversationRequest();
  bool canApplyConversationRequest(String agentId, int sequence);
  void conversationAttentionContextChanged({bool immediateActive = true});
  void stopConversationRefreshScheduling();

  bool agentWorkspaceDisposed = false;
  bool conversationMobileLoading = false;
  final Set<String> _preparingNewConversationTargets = <String>{};
  Map<String, String> newConversationWorkingDirectories = const {};
  Timer? conversationActiveRefreshTimer;
  Timer? conversationBackgroundRefreshTimer;
  final Set<String> conversationSessionLoadingTargets = <String>{};
  final Set<({String agentId, String sessionId})>
  conversationActiveRefreshTargets = <({String agentId, String sessionId})>{};
  final Set<String> conversationBackgroundRefreshTargets = <String>{};
  final Map<String, int> conversationAppliedRequestSequenceByAgent =
      <String, int>{};
  int conversationRequestSequence = 0;
  ConversationLifecyclePhase conversationAppLifecycleState =
      ConversationLifecyclePhase.resumed;
  bool conversationViewFocused = true;
  final Set<String> conversationSessionLoadMoreTargets = <String>{};
  Map<String, String> _selectedConversationSessionIdsByAgent = const {};

  Map<String, List<AgentConversationSession>> conversationSessionsByAgent =
      const {};
  Map<String, bool> conversationSessionsHasMoreByAgent = const {};
  String selectedConversationAgentId = '';
  Map<String, String> pendingConversationNativeSessionIds = const {};
  Map<String, String> conversationModelsByAgent = const {};
  Map<String, String> conversationReasoningEffortsByAgent = const {};
  bool isSendingConversationMessage = false;
  String sendingConversationAgentId = '';
  String sendingConversationSessionId = '';
  String sendingConversationNativeSessionId = '';
  final ConversationTurnQueue conversationTurnQueue = ConversationTurnQueue();
  int conversationTurnSubmissionSequence = 0;
  bool conversationTurnDrainScheduled = false;
  bool conversationTurnCancellationRequested = false;
  Map<String, List<AgentConversationMessage>> liveConversationMessagesByAgent =
      const {};
  Map<String, AgentConversationTabActivity> conversationTabActivityByAgent =
      const {};

  AgentOrchestrationPolicy agentOrchestrationPolicy =
      const AgentOrchestrationPolicy();
  Future<void> orchestrationRoutingBoundaryTail = Future<void>.value();
  Map<String, RoutingCircuitBreakerState> agentOrchestrationCircuitStates =
      const {};

  Map<String, dynamic>? conversationArchiveResult;
  Map<String, dynamic>? conversationArchivePlan;
  Map<String, dynamic>? snapshotRootState;
  List<Map<String, dynamic>> conversationSnapshotCollections = const [];
  List<Map<String, dynamic>> conversationArchiveProfiles = const [];
  List<Map<String, dynamic>> conversationArchiveWorkflowEvents = const [];
  Map<String, dynamic>? conversationArchiveReport;
  String selectedArchiveProfileId = '';
  String selectedConversationArchiveJobId = '';
  bool isCollectingConversationArchive = false;
  bool isSavingSnapshotRoot = false;
  String get snapshotRootDraft;
  set snapshotRootDraft(String value);
  String get archiveQueryDraft;
  set archiveQueryDraft(String value);
  String get archiveDestinationDraft;
  set archiveDestinationDraft(String value);

  bool get preparingNewConversation =>
      _preparingNewConversationTargets.contains(selectedConversationAgentId);
  set preparingNewConversation(bool value) {
    final agentId = selectedConversationAgentId;
    if (agentId.isEmpty) return;
    value
        ? _preparingNewConversationTargets.add(agentId)
        : _preparingNewConversationTargets.remove(agentId);
  }

  String get selectedConversationSessionId =>
      _selectedConversationSessionIdsByAgent[selectedConversationAgentId] ?? '';
  set selectedConversationSessionId(String value) {
    final agentId = selectedConversationAgentId.trim();
    if (agentId.isNotEmpty) setSelectedConversationSessionId(agentId, value);
  }

  List<AgentConversationMessage> get selectedLiveConversationMessages =>
      liveConversationMessagesByAgent[selectedConversationAgentId] ?? const [];
  bool get isLoadingConversations => agentWorkspaceMobileRuntime
      ? conversationMobileLoading
      : conversationSessionLoadingTargets.contains(selectedConversationAgentId);

  int get queuedConversationTurnCount => conversationTurnQueue.length;

  void setSelectedConversationSessionId(String agentId, String value) {
    if (agentId.trim().isEmpty) return;
    final next = <String, String>{..._selectedConversationSessionIdsByAgent};
    value.isEmpty ? next.remove(agentId) : next[agentId] = value;
    _selectedConversationSessionIdsByAgent = Map.unmodifiable(next);
  }

  void disposeAgentWorkspace() {
    agentWorkspaceDisposed = true;
    conversationTurnCancellationRequested = true;
    conversationTurnQueue.clear();
    conversationTurnDrainScheduled = false;
    conversationActiveRefreshTimer?.cancel();
    conversationBackgroundRefreshTimer?.cancel();
  }
}
