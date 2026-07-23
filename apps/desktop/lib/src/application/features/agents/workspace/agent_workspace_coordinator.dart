import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:flutter_client/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:flutter_client/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:flutter_client/src/application/localization/client_application_strings.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/contracts/generated/secure_mesh.g.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/platform/native_client/orchestrator_ipc/client.dart';

/// Shared feature state plus narrow composition callbacks. Concrete feature
/// controllers never import the root [ClientController].
abstract class AgentWorkspaceCoordinator extends ChangeNotifier {
  AgentConversationGateway get conversationGateway;
  MobileAgentConversationGateway get mobileConversationGateway;
  List<TargetCandidate> get scannedTargets;
  set scannedTargets(List<TargetCandidate> value);
  ClientLifecycleProjection get lifecycleProjection;
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
  NativeOrchestratorClient get orchestratorClient;
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
  Future<void> sendOrchestratedConversationMessage(String text);
  void recordConversationTabSendOutcome({
    required String agentId,
    required bool ok,
    Map<String, dynamic> result,
    String failureCode,
  });
  String conversationSendErrorFor(String agentId);
  void setConversationTabActivity(
    String agentId,
    AgentConversationTabActivity activity,
  );
  AgentConversationTabActivity conversationTabActivityFor(String agentId);
  void acknowledgeConversationTabWorkFinished(String agentId);
  String runtimeAdapterFailureCode(Map<String, dynamic> result);
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

  bool get agentWorkspaceDisposed => lifecycleProjection.disposed;
  bool conversationMobileLoading = false;
  Map<String, String> _newConversationDraftTokensByAgent = const {};
  int _newConversationDraftSequence = 0;
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
  Map<String, String> conversationSendErrorsByAgent = const {};

  Map<String, Object?> orchestrationPolicyDraft = const {};
  String activeOrchestrationPolicyRevision = '';
  OrchestratorWorkflowProjection? currentOrchestrationProjection;

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
      selectedNewConversationDraftToken.isNotEmpty;

  String get selectedNewConversationDraftToken =>
      newConversationDraftTokenFor(selectedConversationAgentId);

  String newConversationDraftTokenFor(String agentId) =>
      (_newConversationDraftTokensByAgent[agentId.trim()] ?? '').trim();

  String beginNewConversationDraft(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) return '';
    final token = 'draft-${++_newConversationDraftSequence}';
    _newConversationDraftTokensByAgent = {
      ..._newConversationDraftTokensByAgent,
      normalized: token,
    };
    return token;
  }

  bool finishNewConversationDraft(String agentId, String token) {
    final normalized = agentId.trim();
    final expected = token.trim();
    if (normalized.isEmpty ||
        expected.isEmpty ||
        newConversationDraftTokenFor(normalized) != expected) {
      return false;
    }
    abandonNewConversationDraft(normalized);
    return true;
  }

  void abandonNewConversationDraft(String agentId) {
    final normalized = agentId.trim();
    if (!_newConversationDraftTokensByAgent.containsKey(normalized)) return;
    _newConversationDraftTokensByAgent = {
      for (final entry in _newConversationDraftTokensByAgent.entries)
        if (entry.key != normalized) entry.key: entry.value,
    };
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
    conversationTurnCancellationRequested = true;
    conversationTurnQueue.clear();
    conversationTurnDrainScheduled = false;
    conversationActiveRefreshTimer?.cancel();
    conversationBackgroundRefreshTimer?.cancel();
  }
}
