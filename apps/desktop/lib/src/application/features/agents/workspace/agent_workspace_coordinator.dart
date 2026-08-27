import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_tool_allowlist_repository.dart';
import 'package:licoup/src/contracts/conversation_image_byte_reader.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

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
  Object get agentWorkspacePortableData;
  AgentToolAllowlistRepository get agentToolAllowlistRepository;
  Future<Map<String, Object?>> agentWorkspaceReadSettingsState();
  Future<void> agentWorkspaceWriteSettingsState(Map<String, Object?> content);
  Future<void> agentWorkspaceEnsureActivePlanDocument();
  Future<void> loadConversationToolAllowlists();
  void agentWorkspaceSelectDefaultConversationAgent({
    bool preferDirectAgent = false,
  });
  Future<bool> agentWorkspaceEnsureConversationRuntimeBinding(String agentId);
  void agentWorkspaceEnsureSelectedAgentModelCatalog(
    String agentId, {
    bool forceEntry = false,
  });
  void agentWorkspaceSetLocalizedStatusMessage(
    String chinese,
    String english, {
    String? displayChinese,
  });
  MessagingNotificationCenter get messagingNotificationCenter;

  /// Platform-root byte reader for path-backed conversation images. Only the
  /// application root binds the platform implementation; the frontend never
  /// imports filesystem code.
  ConversationImageByteReader get conversationImageByteReader;

  /// Releases only client-owned temporary attachment files. Platform
  /// implementations ignore user-selected files.
  ConversationAttachmentRelease get conversationAttachmentRelease;
  void agentWorkspacePublishNotification({
    required String id,
    required String messageChinese,
    required String messageEnglish,
    MessagingNotificationTone tone = MessagingNotificationTone.info,
    String code = '',
  });
  ConversationPresentationSignals get conversationPresentationSignals;
  void agentWorkspaceNotifyStateChanged();
  void agentWorkspaceNotifyConversationStructureChanged({
    bool activeChanged = true,
  });
  void agentWorkspaceNotifyActiveConversationChanged();
  void agentWorkspaceNotifyLiveConversationChanged();
  void agentWorkspaceRecordCurrentAgentView();
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
  Future<bool> reattachActiveConversationTurn(
    String agentId,
    String sessionId,
  ) async => false;

  bool get agentWorkspaceDisposed => lifecycleProjection.disposed;
  bool conversationMobileLoading = false;
  Map<String, String> _newConversationDraftTokensByAgent = const {};
  int _newConversationDraftSequence = 0;
  Map<String, String> newConversationWorkingDirectories = const {};
  Timer? conversationActiveRefreshTimer;
  Timer? conversationBackgroundRefreshTimer;
  Timer? conversationCodexRuntimeRefreshTimer;
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
  final Set<String> conversationMessagePageLoadingKeys = <String>{};
  Map<String, String> conversationMessagePageErrors = const {};
  Map<String, int> conversationMessagePageContinuationCounts = const {};
  Map<String, int> conversationSessionLoadMoreCountsByAgent = const {};
  Map<String, String> _selectedConversationSessionIdsByAgent = const {};

  Map<String, List<AgentConversationSession>> conversationSessionsByAgent =
      const {};
  Map<String, List<AgentConversationSession>>
  committedConversationTurnsByAgent = const {};
  Map<String, bool> conversationSessionsHasMoreByAgent = const {};
  String selectedConversationAgentId = '';

  /// Session identity from the global current-view snapshot. Native history
  /// confirms it after the restored agent catalog becomes available.
  String currentViewRestoreSessionId = '';
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
  String pendingConversationLiveReplyScopeKey = '';
  String pendingConversationLiveReplyTurnId = '';
  String pendingConversationLiveReplyText = '';
  String pendingConversationLiveReplyParticipantAgentId = '';
  String pendingConversationLiveReplyParticipantLabel = '';
  String pendingConversationLiveReplyParticipantRole = '';

  /// Last permission-denied turn: agent, denied tool, and the user text that
  /// can be resent with the tool allowed (`--allowedTools`).
  String pendingPermissionRetryAgentId = '';
  String pendingPermissionRetryTool = '';
  String pendingPermissionRetryText = '';
  List<ConversationAttachment> pendingPermissionRetryAttachments = const [];

  /// Per-agent tool allowlists ("allow and remember"): every send merges the
  /// remembered tools into `--allowedTools` so they are auto-approved.
  Map<String, List<String>> conversationToolAllowlistsByAgent =
      const <String, List<String>>{};

  List<String> conversationToolAllowlistFor(String agentId) =>
      conversationToolAllowlistsByAgent[agentId.trim()] ?? const <String>[];

  void rememberConversationToolAllowlist(String agentId, String tool) {
    final normalizedAgent = agentId.trim();
    final normalizedTool = tool.trim();
    if (normalizedAgent.isEmpty || normalizedTool.isEmpty) return;
    final current =
        conversationToolAllowlistsByAgent[normalizedAgent] ?? const <String>[];
    if (current.contains(normalizedTool)) return;
    conversationToolAllowlistsByAgent = {
      ...conversationToolAllowlistsByAgent,
      normalizedAgent: List<String>.unmodifiable([...current, normalizedTool]),
    };
    agentWorkspaceNotifyStateChanged();
  }

  void replaceConversationToolAllowlists(Map<String, List<String>> value) {
    conversationToolAllowlistsByAgent = Map.unmodifiable(
      Map<String, List<String>>.from(value),
    );
  }

  final ConversationTurnQueue conversationTurnQueue = ConversationTurnQueue();
  int conversationTurnSubmissionSequence = 0;
  bool conversationTurnDrainScheduled = false;
  bool conversationTurnCancellationRequested = false;

  /// Cursor IDE composer ids that already received a one-time IDE→CLI handoff
  /// in this process (metadata + last assistant return).
  final Set<String> cursorIdeCliHandoffComposerIds = <String>{};

  /// Live turn messages and blackboard, keyed per conversation scope so the
  /// progress card is part of one conversation's message stream and never
  /// leaks into another conversation's timeline.
  Map<String, List<AgentConversationMessage>> liveConversationMessagesByScope =
      const {};
  Map<String, ConversationTurnProcessState>
  conversationTurnProcessStateByScope = const {};
  Map<String, AgentConversationTabActivity> conversationTabActivityByAgent =
      const {};
  Map<String, String> conversationSendErrorsByAgent = const {};

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

  /// Stable identity of the composer's conversation scope: one slot per
  /// selected session and one slot per active new-conversation draft. The
  /// draft token distinguishes repeated new-conversation drafts for the same
  /// agent, so clicking "new conversation" again starts with a fresh box.
  String get conversationComposerScopeKey {
    final agentId = selectedConversationAgentId.trim();
    if (agentId.isEmpty) return '';
    final draftToken = selectedNewConversationDraftToken.trim();
    if (draftToken.isNotEmpty) return 'draft:$agentId:$draftToken';
    final sessionId = selectedConversationSessionId.trim();
    if (sessionId.isEmpty) return 'new:$agentId';
    return 'session:$agentId:$sessionId';
  }

  String get conversationComposerDraft => conversationPresentationSignals
      .composerDraftFor(conversationComposerScopeKey);

  /// Pending image attachments for the current conversation scope, beside the
  /// text draft. Bounded and immutable; cleared only after terminal success.
  List<ConversationAttachment> get conversationComposerAttachments =>
      conversationPresentationSignals.composerAttachmentsFor(
        conversationComposerScopeKey,
      );

  /// Stable redacted picker outcome code for the current scope (empty when
  /// the last picker interaction succeeded or none happened).
  String get conversationAttachmentStatus => conversationPresentationSignals
      .composerAttachmentStatusFor(conversationComposerScopeKey);

  /// Whether the selected target transports images end to end: the packaged
  /// `multimodal` capability truth intersected with desktop, direct-local,
  /// non-VM transport. Every other adapter, Mobile Relay target, and VM target
  /// stays attachment-unsupported.
  bool get selectedConversationSupportsImageAttachments {
    final target = selectedConversationAgent;
    if (target == null || agentWorkspaceMobileRuntime) return false;
    final matrix = target.conversationCapabilityMatrix;
    if (matrix['multimodal'] != true) return false;
    return target.location == 'local' &&
        !target.hasValidVirtualMachineConnection;
  }

  /// Timeline projection for the selected conversation: the live turn
  /// projection plus, while attachments are pending, a synthetic local draft
  /// message carrying the ordered pending images and the current draft text.
  /// The draft message reuses the existing message structure, so no tray,
  /// chip family, or style token is added.
  List<AgentConversationMessage> get selectedConversationTimelineMessages {
    final live = selectedLiveConversationMessages;
    final attachments = conversationComposerAttachments;
    if (attachments.isEmpty) return live;
    final scopeKey = conversationComposerScopeKey;
    final identity = 'draft:$scopeKey:attachments';
    return [
      ...live,
      AgentConversationMessage(
        id: identity,
        role: 'user',
        text: conversationComposerDraft,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        stableIdentity: identity,
        images: [
          for (final attachment in attachments)
            AgentConversationImageAttachment(
              mediaType: attachment.mediaType,
              filePath: attachment.path,
              name: attachment.name,
            ),
        ],
      ),
    ];
  }

  void updateConversationComposerDraft(String value) {
    conversationPresentationSignals.replaceComposerDraft(
      conversationComposerScopeKey,
      value,
    );
  }

  void clearConversationComposerDraft() {
    conversationPresentationSignals.replaceComposerDraft(
      conversationComposerScopeKey,
      '',
    );
  }

  void replaceConversationComposerAttachments(
    List<ConversationAttachment> attachments, {
    String statusCode = '',
  }) {
    conversationPresentationSignals.replaceComposerAttachments(
      conversationComposerScopeKey,
      attachments,
    );
    conversationPresentationSignals.replaceComposerAttachmentStatus(
      conversationComposerScopeKey,
      statusCode,
    );
    agentWorkspaceNotifyStateChanged();
  }

  void clearConversationComposerAttachments() {
    replaceConversationComposerAttachments(const <ConversationAttachment>[]);
  }

  void clearConversationComposerAttachmentsForScope(String scopeKey) {
    final attachments = conversationPresentationSignals.composerAttachmentsFor(
      scopeKey,
    );
    conversationPresentationSignals.replaceComposerAttachments(
      scopeKey,
      const <ConversationAttachment>[],
    );
    conversationPresentationSignals.replaceComposerAttachmentStatus(
      scopeKey,
      '',
    );
    unawaited(conversationAttachmentRelease.releaseAttachments(attachments));
    agentWorkspaceNotifyStateChanged();
  }

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

  /// Live messages of the in-flight turn, as part of the selected
  /// conversation's own message stream. The turn blackboard is stored per
  /// conversation scope, so another conversation's timeline simply has no
  /// live entries of its own; nothing is hidden or restored on switch.
  List<AgentConversationMessage> get selectedLiveConversationMessages =>
      liveConversationMessagesByScope[conversationComposerScopeKey] ?? const [];

  /// Every live-projection scope key owned by [agentId], for agent-wide
  /// resets (new-conversation start) without touching other agents.
  List<String> conversationLiveScopeKeysForAgent(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) return const [];
    final draftPrefix = 'draft:$normalized:';
    final sessionPrefix = 'session:$normalized:';
    final newPrefix = 'new:$normalized';
    return [
      for (final key in {
        ...liveConversationMessagesByScope.keys,
        ...conversationTurnProcessStateByScope.keys,
      })
        if (key.startsWith(draftPrefix) ||
            key.startsWith(sessionPrefix) ||
            key == newPrefix ||
            key.startsWith('$newPrefix:'))
          key,
    ];
  }

  bool get isLoadingConversations => agentWorkspaceMobileRuntime
      ? conversationMobileLoading
      : conversationSessionLoadingTargets.contains(selectedConversationAgentId);

  String get selectedConversationMessagePageKey {
    final session = selectedConversationSession;
    if (session == null) return '';
    final nativeId = session.nativeSessionId.trim();
    if (nativeId.isEmpty) return '';
    return '${session.agentId.trim()}\u0000$nativeId';
  }

  bool get isLoadingEarlierSelectedConversationMessages =>
      conversationMessagePageLoadingKeys.contains(
        selectedConversationMessagePageKey,
      );

  String get selectedConversationMessagePageError =>
      conversationMessagePageErrors[selectedConversationMessagePageKey] ?? '';

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
