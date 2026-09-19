import 'dart:async';

import 'package:licoup/src/frontend/features/agents/ui/conversation_execution_binding_viewer.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/shared/ui/reading_position_scroll_controller.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/header.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/projection.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/reveal.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/roster.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/strategy.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/support.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/assistant_configuration_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Canonical Conversation renderer. Durable Events and Parts stay distinct
/// from native catalog sessions; the live Membership turns only contribute
/// their transient messages to the shared visual timeline.
class CanonicalGroupConversationPane extends StatefulWidget {
  const CanonicalGroupConversationPane({
    super.key,
    required this.conversation,
    required this.agents,
    required this.canonical,
    required this.turns,
    required this.composer,
    required this.attachments,
    this.onOpenAgentConversations,
    this.onOpenAdaptiveFlywheel,
    this.onPickComposerImages,
    this.onClearComposerImages,
    this.framed = true,
  });

  final ConversationBinding conversation;
  final AgentsBinding agents;
  final CanonicalConversationProjection canonical;
  final PersistentTurnProjection turns;
  final ComposerProjection composer;
  final ConversationAttachmentsProjection attachments;
  final ValueChanged<String>? onOpenAgentConversations;
  final Future<void> Function(String? revision)? onOpenAdaptiveFlywheel;
  final VoidCallback? onPickComposerImages;
  final VoidCallback? onClearComposerImages;
  final bool framed;

  @override
  State<CanonicalGroupConversationPane> createState() =>
      _CanonicalGroupConversationPaneState();
}

class _CanonicalGroupConversationPaneState
    extends State<CanonicalGroupConversationPane> {
  bool _rosterVisible = false;
  double _composerExtent =
      MessagingDesktopMetrics.conversationComposerOverlayExtent;
  final _messageScrollController = ReadingPositionScrollController();
  final Map<String, bool> _assistantActiveByConversation = <String, bool>{};
  AgentConversationSession? _cachedSession;
  ClientConversation? _cachedSessionConversation;
  List<ClientConversationEvent>? _cachedSessionEvents;
  String _cachedSessionLocale = '';
  List<AgentConversationMessage>? _cachedLiveMessages;
  List<List<AgentConversationMessage>>? _cachedLiveParts;

  @override
  void initState() {
    super.initState();
    _scheduleSurfaceRefresh(attach: true);
  }

  void _scheduleSurfaceRefresh({bool attach = false}) {
    final conversation = widget.conversation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(conversation, widget.conversation)) return;
      if (attach) {
        conversation.intents.send(
          const SetCanonicalConversationSurfaceAttached(true),
        );
      }
      // Refresh publishes projections, so it must follow the mounting frame.
      conversation.intents.send(const RefreshCanonicalAssistantProfile());
    });
  }

  @override
  void didUpdateWidget(covariant CanonicalGroupConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.conversation, widget.conversation)) {
      oldWidget.conversation.intents.send(
        const SetCanonicalConversationSurfaceAttached(false),
      );
      _scheduleSurfaceRefresh(attach: true);
    } else if (oldWidget.canonical.conversation?.assistantMembershipId !=
        widget.canonical.conversation?.assistantMembershipId) {
      _scheduleSurfaceRefresh();
    }
  }

  @override
  void dispose() {
    widget.conversation.intents.send(
      const SetCanonicalConversationSurfaceAttached(false),
    );
    _messageScrollController.dispose();
    super.dispose();
  }

  bool _assistantActive(ClientConversation conversation) =>
      _assistantActiveByConversation[conversation.id] ??
      conversation.assistantMembership != null;

  void _toggleAssistant(ClientConversation conversation) {
    final nextActive = !_assistantActive(conversation);
    setState(() {
      _assistantActiveByConversation[conversation.id] = nextActive;
    });
  }

  String _mentionLabel(
    ClientConversationMembership membership,
    TargetCandidate target,
  ) {
    final displayName = membership.principal.displayName.trim();
    if (displayName.isNotEmpty) return displayName;
    final known =
        agentProductDisplayName(target.target) ??
        agentProductDisplayName(target.id);
    if (known != null) return known;
    return agentConversationTargetDisplayName(target);
  }

  TargetCandidate? _assistantTarget(
    ClientConversation conversation,
    List<TargetCandidate> targets,
  ) {
    final agentId =
        conversation.assistantMembership?.principal.agentId.trim() ?? '';
    if (agentId.isEmpty) return null;
    for (final target in targets) {
      if (target.target == agentId) return target;
    }
    return null;
  }

  Map<String, AgentParticipantRuntimeProfile> get _runtimeProfiles => {
    for (final profile in widget.canonical.participantRuntimeProfiles)
      profile.agentId: AgentParticipantRuntimeProfile(
        model: profile.model,
        reasoningEffort: profile.reasoningEffort,
      ),
  };

  GroupAssistantStatusLight _assistantStatus(ClientConversation conversation) {
    if (conversation.assistantMembership == null) {
      return GroupAssistantStatusLight.unconfigured;
    }
    if (!_assistantActive(conversation)) {
      return GroupAssistantStatusLight.paused;
    }
    if ((widget.canonical.notice?.reasonCode ?? '').isNotEmpty) {
      return GroupAssistantStatusLight.failure;
    }
    if (widget.turns.memberships.any(
      (turn) => turn.phase == PersistentTurnPhase.waiting,
    )) {
      return GroupAssistantStatusLight.waiting;
    }
    if (widget.canonical.dispatchPending ||
        widget.turns.memberships.any(
          (turn) =>
              (turn.participantRole.trim() != 'assistant' &&
                  turn.participantAgentId.trim().isNotEmpty) ||
              turn.phase == PersistentTurnPhase.running,
        )) {
      return GroupAssistantStatusLight.working;
    }
    return GroupAssistantStatusLight.ready;
  }

  List<AgentConversationMessage> get _timelineMessages {
    final parts = <List<AgentConversationMessage>>[
      for (final membership in widget.turns.memberships)
        canonicalGroupLiveTurnMessages(membership.messages),
    ];
    final cachedParts = _cachedLiveParts;
    final cachedMessages = _cachedLiveMessages;
    var unchanged =
        cachedParts != null &&
        cachedMessages != null &&
        cachedParts.length == parts.length;
    if (unchanged) {
      for (var index = 0; index < parts.length; index += 1) {
        if (identical(cachedParts[index], parts[index])) continue;
        unchanged = false;
        break;
      }
    }
    final live = unchanged
        ? cachedMessages!
        : List<AgentConversationMessage>.unmodifiable([
            for (final part in parts) ...part,
          ]);
    if (!unchanged) {
      _cachedLiveParts = List<List<AgentConversationMessage>>.unmodifiable(
        parts,
      );
      _cachedLiveMessages = live;
    }
    if (widget.attachments.attachments.isEmpty) return live;
    final identity = 'draft:${widget.canonical.conversationId}:attachments';
    return List<AgentConversationMessage>.unmodifiable([
      ...live,
      AgentConversationMessage(
        id: identity,
        role: 'user',
        text: widget.composer.draft,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        stableIdentity: identity,
        images: [
          for (final attachment in widget.attachments.attachments)
            AgentConversationImageAttachment(
              mediaType: attachment.mediaKind,
              dataBase64: attachment.dataBase64,
              name: attachment.displayName,
            ),
        ],
      ),
    ]);
  }

  bool get _turnActive =>
      widget.canonical.dispatchPending ||
      widget.turns.memberships.any(
        (turn) =>
            turn.phase == PersistentTurnPhase.running ||
            turn.phase == PersistentTurnPhase.waiting,
      );

  Future<void> _openAdaptiveFlywheel(String? revision) async {
    final override = widget.onOpenAdaptiveFlywheel;
    if (override != null) {
      await override(revision);
    } else {
      await showAdaptiveFlywheelDialog(
        context,
        conversation: widget.conversation,
        agents: widget.agents,
        initialRevision: revision ?? '',
      );
    }
    if (!mounted) return;
    widget.conversation.intents.send(const RefreshCanonicalAssistantProfile());
  }

  Future<void> _openAssistantConfiguration() async {
    await showAssistantConfigurationDialog(
      context,
      conversation: widget.conversation,
      agents: widget.agents,
    );
    if (!mounted) return;
    widget.conversation.intents.send(const RefreshCanonicalAssistantProfile());
  }

  void _refreshAssistantThread() {
    if (_turnActive || widget.canonical.sending) {
      widget.conversation.intents.send(
        SurfaceConversationFailure(
          stage: 'assistant-refresh',
          reasonCode: 'assistant_turn_active',
          conversationId: widget.canonical.conversationId,
        ),
      );
      return;
    }
    widget.conversation.intents.send(const RefreshCanonicalAssistantThread());
  }

  void _clearHistory() {
    if (_turnActive || widget.canonical.sending) {
      widget.conversation.intents.send(
        SurfaceConversationFailure(
          stage: 'canonical-clear',
          reasonCode: 'conversation_clear_blocked',
          conversationId: widget.canonical.conversationId,
        ),
      );
      return;
    }
    unawaited(_confirmAndClearHistory());
  }

  Future<void> _confirmAndClearHistory() async {
    final conversation = widget.canonical.conversation;
    if (conversation == null) return;
    final strings = LicoStrings.of(context);
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final dialogStrings = LicoStrings.of(dialogContext);
        return AlertDialog(
          title: Text(dialogStrings.confirmClearCanonicalConversationTitle),
          content: Text(
            dialogStrings.confirmClearCanonicalConversationMessage(title),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dialogStrings.cancel),
            ),
            FilledButton(
              key: const Key('canonical-group-clear-history-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                dialogStrings.confirmClearCanonicalConversationAction,
              ),
            ),
          ],
        );
      },
    );
    if (confirmed == true && mounted) {
      widget.conversation.intents.send(
        const ClearCanonicalConversationHistory(),
      );
    }
  }

  Future<bool> _sendComposerMessage(
    ClientConversation conversation,
    String text,
  ) async {
    if (widget.attachments.attachments.isNotEmpty &&
        !widget.attachments.acceptsImages) {
      widget.conversation.intents.send(
        SurfaceConversationFailure(
          stage: 'send',
          reasonCode: 'attachment_transport_unsupported',
          conversationId: widget.canonical.conversationId,
        ),
      );
      return false;
    }
    widget.conversation.intents.send(
      PostConversationMessage(
        conversationId: widget.composer.conversationId,
        content: text,
        addressedMembershipIds: [
          for (final membership in conversation.activeAgentMemberships)
            membership.id,
        ],
        dispatchCanonical: true,
        suppressAssistant: !_assistantActive(conversation),
      ),
    );
    return true;
  }

  Future<void> _cancelVisibleTurn() async {
    final cancellable = widget.turns.memberships
        .where((membership) => membership.cancelEnabled)
        .toList(growable: false);
    if (cancellable.length != 1) return;
    widget.conversation.intents.send(
      InterruptConversationTurn(
        widget.canonical.conversationId,
        cancellable.single.membershipId,
      ),
    );
  }

  void _mentionAgent(ClientConversation conversation, TargetCandidate target) {
    var membership = canonicalGroupAgentMembership(conversation, target);
    if (membership == null) {
      widget.conversation.intents.send(
        EnsureCanonicalAgentMembership(
          agentId: target.target,
          displayName: agentConversationTargetDisplayName(target),
        ),
      );
    }
    final label = membership == null
        ? agentConversationTargetDisplayName(target)
        : _mentionLabel(membership, target);
    final separator =
        widget.composer.draft.isEmpty ||
            RegExp(r'\\s$').hasMatch(widget.composer.draft)
        ? ''
        : ' ';
    widget.conversation.intents.send(
      UpdateConversationDraft(
        widget.composer.conversationId,
        '${widget.composer.draft}$separator@$label ',
      ),
    );
  }

  void _continueConversationScroll(double overscroll) {
    if (!_messageScrollController.hasClients || overscroll == 0) return;
    final position = _messageScrollController.position;
    _messageScrollController.jumpTo(
      (position.pixels - overscroll).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  Future<void> _copyText(String text) async {
    widget.conversation.intents.send(CopyConversationText(text));
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final canonical = widget.canonical;
    final conversation = canonical.conversation;
    if (conversation == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          CanonicalGroupLoadingOrEmpty(
            loading: canonical.phase == PresentationPhase.loading,
          ),
          if ((canonical.notice?.reasonCode ?? '').isNotEmpty)
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
                child: _failureCapsule(),
              ),
            ),
        ],
      );
    }

    final allTargets = widget.agents.projection.current.targetDetails;
    final participantTargets = resolveCanonicalGroupParticipantTargets(
      conversation,
      allTargets,
    );
    final ordered = resolveCanonicalGroupOrderedParticipantTargets(
      conversation,
      [...participantTargets, ...allTargets],
      canonical.recentParticipantAgentIds,
    );
    final rosterTargets = ordered.isEmpty ? participantTargets : ordered;
    final session = _canonicalSession(
      conversation,
      canonical.canonicalEvents,
      strings,
    );
    final assistantStatus = _assistantStatus(conversation);
    final assistantTarget = _assistantTarget(conversation, allTargets);
    final paneTarget = participantTargets.isNotEmpty
        ? participantTargets.first
        : assistantTarget ??
              TargetCandidate(
                target: conversation.id,
                label: conversation.title.trim().isEmpty
                    ? strings.groupConversation
                    : conversation.title.trim(),
                kind: 'group',
                status: TargetCandidateStatus.unavailable,
                configured: false,
                confidence: 0,
                adapterStatus: 'runtime-unavailable',
              );
    final mentionLabels = <String, String>{};
    for (final membership in conversation.activeAgentMemberships) {
      final target = canonicalGroupParticipantTarget(
        participantTargets,
        membership.principal.agentId,
      );
      if (target == null) continue;
      mentionLabels[target.target] = _mentionLabel(membership, target);
    }
    final state = AgentConversationPaneState(
      target: paneTarget,
      session: session,
      liveMessages: _timelineMessages,
      recentSessions: const [],
      loading: canonical.phase == PresentationPhase.loading,
      turnActive: _turnActive,
      hasEarlierMessages: canonical.hasEarlier,
      messagePageLoading: canonical.earlierLoading,
      messagePageError: canonical.earlierError,
      composerBusy: canonical.sending || _turnActive,
      inputEnabled: widget.turns.memberships.every(
        (membership) => membership.inputEnabled,
      ),
      cancelEnabled:
          widget.turns.memberships
              .where((membership) => membership.cancelEnabled)
              .length ==
          1,
      preparingNewConversation: false,
      composerEnabled: conversation.localOwnerMembership != null,
      sendGateReasonCode: '',
      composerDraft: widget.composer.draft,
      hasAttachments: widget.attachments.attachments.isNotEmpty,
      conversationLabel: historySessionDisplayTitle(
        conversation.title,
        fallback: strings.groupConversation,
      ),
      modelOptions: const [],
      selectedModel: '',
      defaultModel: '',
      reasoningEffortOptions: const [],
      selectedReasoningEffort: '',
      participantTargets: participantTargets,
      composerMentionLabels: mentionLabels,
      participantConversationIds: {
        for (final membership in conversation.activeAgentMemberships)
          membership.principal.agentId: conversation.id,
      },
      participantRuntimeProfiles: _runtimeProfiles,
      assistantActive: _assistantActive(conversation),
      composerFlywheel: GroupStrategyPickerCapsule(
        selectedRevision: conversation.strategyRevision.trim().isEmpty
            ? null
            : conversation.strategyRevision.trim(),
        onOpen: (revision) => unawaited(_openAdaptiveFlywheel(revision)),
      ),
      composerFieldLeading: AssistantToggleButton(
        active: _assistantActive(conversation),
        configured: conversation.assistantMembership != null,
        label: conversation.assistantMembership == null
            ? strings.assistantNeedsConfigurationStatus
            : _mentionLabel(
                conversation.assistantMembership!,
                _assistantTarget(conversation, participantTargets) ??
                    participantTargets.firstWhere(
                      (t) =>
                          t.target ==
                          conversation.assistantMembership!.principal.agentId,
                      orElse: () => participantTargets.first,
                    ),
              ),
        status: assistantStatus,
        onTap: () => _toggleAssistant(conversation),
        onEdit: () => unawaited(_openAssistantConfiguration()),
      ),
      composerLeading: CanonicalGroupAssistantActions(
        onPickAttachments:
            widget.onPickComposerImages ??
            () => widget.conversation.intents.send(
              AddConversationAttachment(widget.composer.conversationId),
            ),
        onNewConversation: conversation.assistantMembership == null
            ? null
            : _refreshAssistantThread,
        onClearHistory: _clearHistory,
        onDiscardImages:
            widget.onClearComposerImages ??
            () => widget.conversation.intents.send(
              ClearConversationAttachments(widget.composer.conversationId),
            ),
        showDiscardImages: widget.attachments.attachments.isNotEmpty,
      ),
    );
    final actions = AgentConversationPaneActions(
      onOpenExecution: (context, message, speakingTarget, returnFocusNode) =>
          unawaited(
            showBoundConversationExecution(
              context: context,
              message: message,
              target: speakingTarget,
              conversationTitle: state.conversationLabel,
              projection: widget.conversation.execution,
              intents: widget.conversation.intents,
              onCopyText: _copyText,
              returnFocusNode: returnFocusNode,
            ),
          ),
      onModelChanged: (_) {},
      onReasoningEffortChanged: (_) {},
      onDraftChanged: (draft) => widget.conversation.intents.send(
        UpdateConversationDraft(widget.composer.conversationId, draft),
      ),
      onSend: (text) => _sendComposerMessage(conversation, text),
      onCancel: _cancelVisibleTurn,
      onSelectSession: (_) {},
      onLoadEarlierMessages: () async => widget.conversation.intents.send(
        LoadEarlierConversationEvents(conversation.id),
      ),
      onCopyText: _copyText,
      onRetryMessage: (messageId) async => widget.conversation.intents.send(
        RetryCanonicalConversationMessage(
          resolveCanonicalGroupSourceEventId(
            messageId,
            canonical.canonicalEvents,
          ),
        ),
      ),
      onDeleteMessage: (messageId) async => widget.conversation.intents.send(
        DeleteCanonicalConversationMessage(
          resolveCanonicalGroupSourceEventId(
            messageId,
            canonical.canonicalEvents,
          ),
        ),
      ),
      onNewConversation: _refreshAssistantThread,
    );
    final pane = AgentConversationActivePane(
      key: const Key('canonical-group-conversation-pane'),
      state: state,
      actions: actions,
      header: CanonicalGroupConversationHeader(
        conversation: conversation,
        rosterVisible: _rosterVisible,
        onToggleRoster: () => setState(() => _rosterVisible = !_rosterVisible),
      ),
      framed: false,
      messageScrollController: _messageScrollController,
      onComposerExtentChanged: (extent) {
        if (mounted && _composerExtent != extent) {
          setState(() => _composerExtent = extent);
        }
      },
    );

    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    final rosterFloats =
        !isMobileClientPlatform(context) &&
        strategy.messageStyle == AgentsMessageStyle.participantFlow;
    final conversationBody = rosterFloats
        ? LayoutBuilder(
            builder: (context, constraints) {
              final topInset =
                  MessagingDesktopMetrics.conversationHeaderOverlayExtent +
                  MessagingDesktopMetrics.groupRosterHeaderGap;
              final bottomInset =
                  _composerExtent +
                  MessagingDesktopMetrics.groupRosterComposerGap;
              final visibleExtent =
                  constraints.maxHeight - topInset - bottomInset;
              if (visibleExtent <
                      MessagingDesktopMetrics.groupRosterMinimumVisibleExtent ||
                  rosterTargets.isEmpty) {
                return pane;
              }
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  pane,
                  Positioned(
                    right:
                        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
                    top: topInset,
                    bottom: bottomInset,
                    width: MessagingDesktopMetrics.groupRosterExtent,
                    child: CanonicalGroupRosterReveal(
                      visible: _rosterVisible,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.min(
                            visibleExtent,
                            MessagingDesktopMetrics.groupRosterMaxVisibleExtent,
                          ),
                        ),
                        child: CanonicalGroupRosterSurface(
                          child: CanonicalGroupRoster(
                            conversation: conversation,
                            targets: rosterTargets,
                            quotaSnapshots: canonical.quotaSnapshots,
                            onMentionAgent: (target) =>
                                _mentionAgent(conversation, target),
                            onOpenAgentConversations:
                                widget.onOpenAgentConversations == null
                                ? null
                                : (target) => widget.onOpenAgentConversations!(
                                    target.target,
                                  ),
                            onBoundaryOverscroll: _continueConversationScroll,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: pane),
              if (_rosterVisible && rosterTargets.isNotEmpty)
                CanonicalGroupRoster(
                  conversation: conversation,
                  targets: rosterTargets,
                  quotaSnapshots: canonical.quotaSnapshots,
                  onMentionAgent: (target) =>
                      _mentionAgent(conversation, target),
                  onOpenAgentConversations:
                      widget.onOpenAgentConversations == null
                      ? null
                      : (target) =>
                            widget.onOpenAgentConversations!(target.target),
                  onBoundaryOverscroll: _continueConversationScroll,
                ),
            ],
          );

    final scopedBody = ContinuousAssistantHostScope(
      conversationId: conversation.id,
      progressByGoalId: continuousAssistantProgressByGoalId(
        widget.canonical.taskViews,
      ),
      onCommand: (intent) => widget.conversation.intents.send(
        ExecuteContinuousAssistantCommand(
          conversationId: conversation.id,
          command: intent.command.wireName,
          goalId: intent.goalId,
        ),
      ),
      onOpenChild: (childId) => widget.conversation.intents.send(
        SelectCanonicalConversation(childId),
      ),
      child: conversationBody,
    );
    final body = Stack(
      fit: StackFit.expand,
      children: [
        scopedBody,
        if ((canonical.notice?.reasonCode ?? '').isNotEmpty)
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(
                top:
                    MessagingDesktopMetrics.conversationHeaderOverlayExtent +
                    MessagingDesktopMetrics.conversationFailureAlertGap,
                left: MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
                right: MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
              ),
              child: _failureCapsule(),
            ),
          ),
      ],
    );
    return widget.framed ? PanelFrame(child: body) : body;
  }

  AgentConversationSession _canonicalSession(
    ClientConversation conversation,
    List<ClientConversationEvent> events,
    LicoStrings strings,
  ) {
    final cached = _cachedSession;
    if (cached != null &&
        identical(_cachedSessionConversation, conversation) &&
        _sameEventObjects(_cachedSessionEvents, events) &&
        _cachedSessionLocale == strings.locale.languageCode) {
      return cached;
    }
    final session = canonicalGroupConversationSession(
      conversation,
      events,
      strings,
    );
    _cachedSession = session;
    _cachedSessionConversation = conversation;
    _cachedSessionEvents = events;
    _cachedSessionLocale = strings.locale.languageCode;
    return session;
  }

  bool _sameEventObjects(
    List<ClientConversationEvent>? previous,
    List<ClientConversationEvent> next,
  ) {
    if (previous == null || previous.length != next.length) return false;
    for (var index = 0; index < next.length; index += 1) {
      if (!identical(previous[index], next[index])) return false;
    }
    return true;
  }

  Widget _failureCapsule() => CanonicalGroupFailureCapsule(
    code: widget.canonical.notice?.reasonCode ?? '',
    failureRef: widget.canonical.failureRef,
    recovery: widget.canonical.failureRecovery,
    copyBlob: widget.canonical.failureCopyBlob,
    onCopy: _copyText,
  );
}
