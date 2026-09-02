import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/plan_document_reader.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';

/// Immutable data consumed by the conversation body. The workspace is the
/// only production adapter from mutable application controllers to this view.
final class AgentConversationPaneState {
  AgentConversationPaneState({
    required this.target,
    required this.session,
    required List<AgentConversationMessage> liveMessages,
    required List<AgentConversationSession> recentSessions,
    required this.loading,
    this.recentSessionsHasMore = false,
    this.recentSessionsLoadingMore = false,
    this.messagePageLoading = false,
    this.messagePageError = '',
    required this.turnActive,
    this.inputEnabled = true,
    this.cancelEnabled = false,
    required this.preparingNewConversation,
    required this.composerEnabled,
    required this.sendGateReasonCode,
    required this.composerDraft,
    this.hasAttachments = false,
    this.conversationLabel = '',
    required List<String> modelOptions,
    required this.selectedModel,
    required this.defaultModel,
    required List<String> reasoningEffortOptions,
    required this.selectedReasoningEffort,
    this.defaultReasoningEffort = '',
    this.showWorkingDirectory = false,
    this.workingDirectory = '',
    this.workingDirectorySelectable = false,
    this.sendAuthorizeActive = false,
    this.permissionRetryTool = '',
    List<TargetCandidate> participantTargets = const [],
    Map<String, String> composerMentionLabels = const {},
    this.showLicoProfileCapsule = false,
    this.selectedLicoProfile = 'base',
    this.planDocumentPath = '',
    this.planDocumentReader = const UnavailablePlanDocumentReader(),
    Map<String, String> participantConversationIds = const {},
    Map<String, AgentParticipantRuntimeProfile> participantRuntimeProfiles =
        const {},
    Set<String> runningRecentSessionIds = const {},
    this.recentSessionsCached = false,
    this.composerFlywheel,
    this.composerLeading,
    bool? composerBusy,
  }) : liveMessages = List.unmodifiable(liveMessages),
       recentSessions = List.unmodifiable(recentSessions),
       modelOptions = List.unmodifiable(modelOptions),
       reasoningEffortOptions = List.unmodifiable(reasoningEffortOptions),
       participantTargets = List.unmodifiable(participantTargets),
       composerMentionLabels = Map.unmodifiable(composerMentionLabels),
       participantConversationIds = Map.unmodifiable(
         participantConversationIds,
       ),
       participantRuntimeProfiles = Map.unmodifiable(
         participantRuntimeProfiles,
       ),
       runningRecentSessionIds = Set.unmodifiable(runningRecentSessionIds),
       composerBusy = composerBusy ?? turnActive;

  final TargetCandidate target;
  final AgentConversationSession? session;
  final List<AgentConversationMessage> liveMessages;
  final List<AgentConversationSession> recentSessions;
  final bool loading;
  final bool recentSessionsHasMore;
  final bool recentSessionsLoadingMore;
  final bool messagePageLoading;
  final String messagePageError;
  final bool turnActive;
  final bool inputEnabled;
  final bool cancelEnabled;
  final bool preparingNewConversation;
  final bool composerEnabled;
  final String sendGateReasonCode;
  final String composerDraft;
  final bool hasAttachments;
  final String conversationLabel;
  final List<String> modelOptions;
  final String selectedModel;
  final String defaultModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final String defaultReasoningEffort;
  final bool showWorkingDirectory;
  final String workingDirectory;
  final bool workingDirectorySelectable;
  final bool sendAuthorizeActive;
  final String permissionRetryTool;
  final List<TargetCandidate> participantTargets;
  final Map<String, String> composerMentionLabels;
  final bool showLicoProfileCapsule;
  final String selectedLicoProfile;
  final String planDocumentPath;
  final PlanDocumentReader planDocumentReader;

  /// Agent id → that agent's conversation id for bubble hover metadata.
  final Map<String, String> participantConversationIds;
  final Map<String, AgentParticipantRuntimeProfile> participantRuntimeProfiles;
  final Set<String> runningRecentSessionIds;
  final bool recentSessionsCached;
  final Widget? composerFlywheel;
  final Widget? composerLeading;
  final bool composerBusy;
}

/// Typed commands available to the conversation body.
final class AgentConversationPaneActions {
  const AgentConversationPaneActions({
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
    required this.onDraftChanged,
    required this.onSend,
    this.onCancel,
    required this.onSelectSession,
    this.onNewConversation,
    this.onLoadMoreRecentSessions,
    this.onLoadEarlierMessages,
    this.onUnblockSend,
    this.onChooseWorkingDirectory,
    this.onAttach,
    this.onPasteImage,
    this.onLicoProfileChanged,
    this.onPermissionRetry,
    this.onPermissionRetryRemember,
    this.onPermissionDeny,
    this.onCopyText,
  });

  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final ValueChanged<String> onDraftChanged;
  final Future<bool> Function(String) onSend;
  final Future<void> Function()? onCancel;
  final ValueChanged<String> onSelectSession;
  final VoidCallback? onNewConversation;
  final VoidCallback? onLoadMoreRecentSessions;
  final Future<void> Function()? onLoadEarlierMessages;
  final VoidCallback? onUnblockSend;
  final VoidCallback? onChooseWorkingDirectory;
  final VoidCallback? onAttach;
  final Future<bool> Function()? onPasteImage;
  final ValueChanged<String>? onLicoProfileChanged;
  final VoidCallback? onPermissionRetry;
  final VoidCallback? onPermissionRetryRemember;
  final VoidCallback? onPermissionDeny;
  final Future<void> Function(String)? onCopyText;
}

/// Immutable identity and status projection consumed only by the header leaf.
final class AgentConversationHeaderState {
  AgentConversationHeaderState({
    required this.target,
    required this.session,
    required this.historyCollapsed,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
    required this.opencodeServeState,
    this.showSidebarToggle = true,
  });

  final TargetCandidate target;
  final AgentConversationSession? session;
  final bool historyCollapsed;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;
  final AgentConversationServeState? opencodeServeState;
  final bool showSidebarToggle;
}

enum AgentConversationServeStatus { running, blocked, unavailable, stopped }

final class AgentConversationServeState {
  const AgentConversationServeState({
    required this.status,
    required this.port,
    required this.portConflict,
  });

  final AgentConversationServeStatus status;
  final int? port;
  final bool portConflict;
}

final class AgentConversationHeaderActions {
  const AgentConversationHeaderActions({required this.onToggleHistory});

  final VoidCallback onToggleHistory;
}
