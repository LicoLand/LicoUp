import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_projection_repository.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/agents/group_conversation_store.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

/// Shared feature state plus narrow composition callbacks. Concrete feature
/// controllers never import the root [ClientController].
abstract class AgentWorkspaceCoordinator extends ChangeNotifier {
  AgentService get agentService;
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
  Object get agentWorkspacePortableData;
  Future<Map<String, Object?>> agentWorkspaceReadSettingsState();
  Future<void> agentWorkspaceWriteSettingsState(Map<String, Object?> content);
  Future<Map<String, Object?>> agentWorkspaceReadAdaptiveFlywheelState();
  Future<void> agentWorkspaceWriteAdaptiveFlywheelState(
    Map<String, Object?> content,
  );
  Future<void> loadAgentOrchestrationPolicy();
  AgentConversationProjectionRepository
  get agentConversationProjectionRepository;
  Future<void> hydrateConversationProjectionCache();
  void agentWorkspaceSelectDefaultConversationAgent({
    bool preferDirectAgent = false,
  });
  Future<bool> agentWorkspaceEnsureConversationRuntimeBinding(String agentId);
  void agentWorkspaceSetLocalizedStatusMessage(
    String chinese,
    String english, {
    String? displayChinese,
  });
  MessagingNotificationCenter get messagingNotificationCenter;
  void agentWorkspacePublishNotification({
    required String id,
    required String messageChinese,
    required String messageEnglish,
    MessagingNotificationTone tone = MessagingNotificationTone.info,
    String code = '',
  });
  void agentWorkspaceNotifyStateChanged();
  void agentWorkspaceNotifyConversationStructureChanged({
    bool activeChanged = true,
  });
  void agentWorkspaceNotifyActiveConversationChanged();
  void agentWorkspaceNotifyLiveConversationChanged();
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
  String get selectedConversationLicoProfile;
  bool get selectedConversationIsOrchestration;
  void recordConversationTabSendOutcome({
    required String agentId,
    required bool ok,
    Map<String, dynamic> result,
    String failureCode,
  });
  String conversationSendErrorFor(String agentId);
  void clearConversationSendError(String agentId);
  Future<Map<String, dynamic>> agentWorkspaceAuthorizeRuntime(
    String agentId, {
    String binaryPath = '',
  });
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
  Map<String, List<AgentConversationSession>>
  durableConversationProjectionsByAgent = const {};
  Map<String, bool> conversationSessionsHasMoreByAgent = const {};
  String selectedConversationAgentId = '';
  Map<String, String> pendingConversationNativeSessionIds = const {};
  Map<String, String> conversationModelsByAgent = const {};
  Map<String, String> conversationReasoningEffortsByAgent = const {};
  Map<String, String> conversationLicoProfilesByAgent = const {};
  bool isSendingConversationMessage = false;
  bool isAuthorizingConversationRuntime = false;
  String sendingConversationAgentId = '';
  String sendingConversationSessionId = '';
  String sendingConversationNativeSessionId = '';
  String sendingConversationTurnId = '';
  Timer? conversationLiveReplyPublishTimer;
  String pendingConversationLiveReplyAgentId = '';
  String pendingConversationLiveReplyTurnId = '';
  String pendingConversationLiveReplyText = '';
  String pendingConversationLiveReplyParticipantAgentId = '';
  String pendingConversationLiveReplyParticipantLabel = '';
  String pendingConversationLiveReplyParticipantRole = '';
  final ConversationTurnQueue conversationTurnQueue = ConversationTurnQueue();
  int conversationTurnSubmissionSequence = 0;
  bool conversationTurnDrainScheduled = false;
  bool conversationTurnCancellationRequested = false;

  /// Cursor IDE composer ids that already received a one-time IDE→CLI handoff
  /// in this process (metadata + last assistant return).
  final Set<String> cursorIdeCliHandoffComposerIds = <String>{};
  Map<String, List<AgentConversationMessage>> liveConversationMessagesByAgent =
      const {};
  Map<String, AgentConversationTabActivity> conversationTabActivityByAgent =
      const {};
  Map<String, String> conversationSendErrorsByAgent = const {};

  GroupRoster groupConversationRoster = GroupRoster.empty;
  Map<String, GroupAgentSessionBinding> groupConversationAgentSessions =
      const {};
  String groupConversationLastLocalSessionId = '';

  Map<String, Object?> orchestrationPolicyDraft = const {};
  String activeOrchestrationPolicyRevision = '';

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
    conversationLiveReplyPublishTimer?.cancel();
    conversationLiveReplyPublishTimer = null;
    pendingConversationLiveReplyAgentId = '';
    pendingConversationLiveReplyTurnId = '';
    pendingConversationLiveReplyText = '';
    pendingConversationLiveReplyParticipantAgentId = '';
    pendingConversationLiveReplyParticipantLabel = '';
    pendingConversationLiveReplyParticipantRole = '';
    conversationActiveRefreshTimer?.cancel();
    conversationBackgroundRefreshTimer?.cancel();
  }
}
