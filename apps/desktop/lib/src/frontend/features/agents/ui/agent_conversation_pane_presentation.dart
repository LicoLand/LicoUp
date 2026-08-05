import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/agents/group_conversation_store.dart';

/// Immutable data consumed by the conversation body. The workspace is the
/// only production adapter from mutable application controllers to this view.
final class AgentConversationPaneState {
  AgentConversationPaneState({
    required this.target,
    required this.session,
    required List<AgentConversationMessage> liveMessages,
    required List<AgentConversationSession> recentSessions,
    required this.loading,
    required this.turnActive,
    required this.preparingNewConversation,
    required this.orchestrationSelected,
    required this.composerEnabled,
    required this.sendGateReasonCode,
    required this.composerDraft,
    required List<String> modelOptions,
    required this.selectedModel,
    required this.defaultModel,
    required List<String> reasoningEffortOptions,
    required this.selectedReasoningEffort,
    this.showWorkingDirectory = false,
    this.workingDirectory = '',
    this.workingDirectorySelectable = false,
    this.sendAuthorizeActive = false,
    List<TargetCandidate> participantTargets = const [],
    this.flywheelMainAgentLabel = '',
    this.flywheelMainAgentTarget,
    List<TargetCandidate> flywheelAgentOptions = const [],
    this.flywheelSelectedAgentId = '',
    this.flywheelSelectedModel = '',
    this.showLicoProfileCapsule = false,
    this.selectedLicoProfile = 'base',
    this.planDocumentPath = '',
    List<GroupParticipant> groupRosterParticipants = const [],
  }) : liveMessages = List.unmodifiable(liveMessages),
       recentSessions = List.unmodifiable(recentSessions),
       modelOptions = List.unmodifiable(modelOptions),
       reasoningEffortOptions = List.unmodifiable(reasoningEffortOptions),
       participantTargets = List.unmodifiable(participantTargets),
       flywheelAgentOptions = List.unmodifiable(flywheelAgentOptions),
       groupRosterParticipants = List.unmodifiable(groupRosterParticipants);

  final TargetCandidate target;
  final AgentConversationSession? session;
  final List<AgentConversationMessage> liveMessages;
  final List<AgentConversationSession> recentSessions;
  final bool loading;
  final bool turnActive;
  final bool preparingNewConversation;
  final bool orchestrationSelected;
  final bool composerEnabled;
  final String sendGateReasonCode;
  final String composerDraft;
  final List<String> modelOptions;
  final String selectedModel;
  final String defaultModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final bool showWorkingDirectory;
  final String workingDirectory;
  final bool workingDirectorySelectable;
  final bool sendAuthorizeActive;
  final List<TargetCandidate> participantTargets;
  final String flywheelMainAgentLabel;
  final TargetCandidate? flywheelMainAgentTarget;
  final List<TargetCandidate> flywheelAgentOptions;
  final String flywheelSelectedAgentId;
  final String flywheelSelectedModel;
  final bool showLicoProfileCapsule;
  final String selectedLicoProfile;
  final String planDocumentPath;
  final List<GroupParticipant> groupRosterParticipants;
}

/// Typed commands available to the conversation body.
final class AgentConversationPaneActions {
  const AgentConversationPaneActions({
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
    required this.onDraftChanged,
    required this.onSend,
    required this.onSelectSession,
    this.onUnblockSend,
    this.onChooseWorkingDirectory,
    this.onAttach,
    this.onEditFlywheel,
    this.onSelectFlywheelAgent,
    this.onSelectFlywheelModel,
    this.onLicoProfileChanged,
  });

  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final ValueChanged<String> onDraftChanged;
  final Future<bool> Function(String) onSend;
  final ValueChanged<String> onSelectSession;
  final VoidCallback? onUnblockSend;
  final VoidCallback? onChooseWorkingDirectory;
  final VoidCallback? onAttach;
  final VoidCallback? onEditFlywheel;
  final ValueChanged<String>? onSelectFlywheelAgent;
  final void Function(String agentId, String model)? onSelectFlywheelModel;
  final ValueChanged<String>? onLicoProfileChanged;
}

/// Immutable identity and status projection consumed only by the header leaf.
final class AgentConversationHeaderState {
  AgentConversationHeaderState({
    required this.target,
    required this.session,
    required this.historyCollapsed,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
    required this.orchestrationSelected,
    required this.opencodeServeState,
    this.showSidebarToggle = true,
  });

  final TargetCandidate target;
  final AgentConversationSession? session;
  final bool historyCollapsed;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;
  final bool orchestrationSelected;
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
