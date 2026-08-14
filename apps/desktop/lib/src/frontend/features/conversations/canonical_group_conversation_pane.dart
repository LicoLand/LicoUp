import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

Future<void> showCreateCanonicalGroupConversationDialog({
  required BuildContext context,
  required ClientConversationController controller,
  required List<TargetCandidate> targets,
}) async {
  final candidates = targets
      .where((target) => target.isConversationAgent && target.canRelayRuntime)
      .toList(growable: false);
  await showDialog<void>(
    context: context,
    builder: (context) => _CreateCanonicalGroupConversationDialog(
      controller: controller,
      candidates: candidates,
    ),
  );
}

class _CreateCanonicalGroupConversationDialog extends StatefulWidget {
  const _CreateCanonicalGroupConversationDialog({
    required this.controller,
    required this.candidates,
  });

  final ClientConversationController controller;
  final List<TargetCandidate> candidates;

  @override
  State<_CreateCanonicalGroupConversationDialog> createState() =>
      _CreateCanonicalGroupConversationDialogState();
}

class _CreateCanonicalGroupConversationDialogState
    extends State<_CreateCanonicalGroupConversationDialog> {
  final _title = TextEditingController();
  final _selected = <String>{};
  var _creating = false;
  var _failureCode = '';

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final canCreate =
        !_creating && _title.text.trim().isNotEmpty && _selected.isNotEmpty;
    return AlertDialog(
      key: const Key('canonical-group-create-dialog'),
      title: Text(strings.newGroupConversation),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('canonical-group-title-field'),
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                labelText: strings.groupConversationName,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 18),
            Text(
              strings.selectGroupConversationAgents,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (widget.candidates.isEmpty)
              Text(
                strings.groupConversationNeedsAgent,
                style: TextStyle(color: context.licoColors.error),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.candidates.length,
                  itemBuilder: (context, index) {
                    final candidate = widget.candidates[index];
                    final checked = _selected.contains(candidate.target);
                    return CheckboxListTile(
                      key: ValueKey<String>(
                        'canonical-group-member-${candidate.target}',
                      ),
                      value: checked,
                      title: Text(
                        agentConversationTargetDisplayName(candidate),
                      ),
                      secondary: MessagingAgentAvatar(
                        target: candidate,
                        size: 32,
                        iconSize: 18,
                      ),
                      controlAffinity: ListTileControlAffinity.trailing,
                      onChanged: (value) => setState(() {
                        value == true
                            ? _selected.add(candidate.target)
                            : _selected.remove(candidate.target);
                      }),
                    );
                  },
                ),
              ),
            if (_failureCode.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                key: const Key('canonical-group-create-failure'),
                strings.groupConversationFailure('create', _failureCode),
                style: TextStyle(color: context.licoColors.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const Key('canonical-group-create-confirm'),
          onPressed: canCreate ? _create : null,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return colors.surfaceLow.withValues(alpha: 0.5);
              }
              if (states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.hovered)) {
                return colors.primaryStrong;
              }
              return colors.primary;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.disabled)
                  ? colors.textDisabled
                  : colors.textOnPrimary;
            }),
          ),
          child: _creating
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(strings.createGroupConversation),
        ),
      ],
    );
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _failureCode = '';
    });
    final members = [
      for (final candidate in widget.candidates)
        if (_selected.contains(candidate.target))
          ClientConversationGroupMemberDraft(
            agentId: candidate.target,
            displayName: agentConversationTargetDisplayName(candidate),
          ),
    ];
    final created = await widget.controller.createGroup(
      title: _title.text,
      members: members,
    );
    if (!mounted) return;
    if (created) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _creating = false;
        _failureCode = widget.controller.failureCode.isEmpty
            ? 'conversation_operation_failed'
            : widget.controller.failureCode;
      });
    }
  }
}

class CanonicalGroupConversationPane extends StatefulWidget {
  const CanonicalGroupConversationPane({
    super.key,
    required this.controller,
    required this.targets,
    required this.onCopyText,
    this.onOpenAgentConversations,
    this.framed = true,
  });

  final ClientConversationController controller;
  final List<TargetCandidate> targets;
  final Future<void> Function(String) onCopyText;
  final ValueChanged<String>? onOpenAgentConversations;
  final bool framed;

  @override
  State<CanonicalGroupConversationPane> createState() =>
      _CanonicalGroupConversationPaneState();
}

class _CanonicalGroupConversationPaneState
    extends State<CanonicalGroupConversationPane> {
  bool _rosterVisible = true;
  final ScrollController _messageScrollController = ScrollController();

  @override
  void dispose() {
    _messageScrollController.dispose();
    super.dispose();
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

  Future<void> _mentionAgent(
    ClientConversation conversation,
    TargetCandidate target,
  ) async {
    var membership = _agentMembership(conversation, target);
    if (membership == null) {
      final joined = await widget.controller.ensureSelectedAgentMembership(
        agentId: target.target,
        displayName: agentConversationTargetDisplayName(target),
      );
      if (!mounted || !joined) return;
      final refreshed = widget.controller.selectedConversation;
      if (refreshed == null) return;
      membership = _agentMembership(refreshed, target);
      if (membership == null) return;
    }
    final label = membership.principal.displayName.trim().isEmpty
        ? agentConversationTargetDisplayName(target)
        : membership.principal.displayName.trim();
    final draft = widget.controller.draft;
    final separator = draft.isEmpty || RegExp(r'\s$').hasMatch(draft)
        ? ''
        : ' ';
    widget.controller.updateDraft('$draft$separator@$label ');
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final controller = widget.controller;
    final conversation = controller.selectedConversation;
    if (conversation == null) {
      return _CanonicalGroupLoadingOrEmpty(loading: controller.loading);
    }
    final participantTargets = resolveCanonicalGroupParticipantTargets(
      conversation,
      widget.targets,
    );
    if (participantTargets.isEmpty) {
      return _CanonicalGroupLoadingOrEmpty(loading: controller.loading);
    }
    final rosterTargets = resolveCanonicalGroupOrderedParticipantTargets(
      conversation,
      [...participantTargets, ...widget.targets],
      controller.recentParticipantAgentIds,
    );
    final session = canonicalGroupConversationSession(
      conversation,
      controller.events,
      strings,
    );
    final primaryTarget = participantTargets.first;
    final state = AgentConversationPaneState(
      target: primaryTarget,
      session: session,
      liveMessages: const [],
      recentSessions: const [],
      loading: controller.loading,
      turnActive: controller.sending,
      preparingNewConversation: false,
      composerEnabled: conversation.localOwnerMembership != null,
      sendGateReasonCode: '',
      composerDraft: controller.draft,
      conversationLabel: conversation.title.trim().isEmpty
          ? strings.groupConversation
          : conversation.title.trim(),
      modelOptions: const [],
      selectedModel: '',
      defaultModel: '',
      reasoningEffortOptions: const [],
      selectedReasoningEffort: '',
      participantTargets: participantTargets,
      composerMentionLabels: {
        for (final membership in conversation.activeAgentMemberships)
          membership.principal.agentId:
              membership.principal.displayName.trim().isEmpty
              ? agentConversationTargetDisplayName(
                  participantTargets.firstWhere(
                    (target) => target.target == membership.principal.agentId,
                  ),
                )
              : membership.principal.displayName.trim(),
      },
      participantConversationIds: {
        for (final membership in conversation.activeAgentMemberships)
          membership.principal.agentId: conversation.id,
      },
    );
    final actions = AgentConversationPaneActions(
      onModelChanged: (_) {},
      onReasoningEffortChanged: (_) {},
      onDraftChanged: controller.updateDraft,
      onSend: controller.postMessage,
      onSelectSession: (_) {},
      onCopyText: widget.onCopyText,
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
                  MessagingDesktopMetrics.conversationComposerOverlayExtent +
                  MessagingDesktopMetrics.groupRosterComposerGap;
              final visibleExtent =
                  constraints.maxHeight - topInset - bottomInset;
              if (visibleExtent <
                  MessagingDesktopMetrics.groupRosterMinimumVisibleExtent) {
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
                    child: _CanonicalGroupRosterReveal(
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
                            onMentionAgent: (target) =>
                                unawaited(_mentionAgent(conversation, target)),
                            onOpenAgentConversations:
                                widget.onOpenAgentConversations == null
                                ? null
                                : (target) => widget.onOpenAgentConversations!(
                                    target.id,
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
              if (_rosterVisible)
                CanonicalGroupRoster(
                  conversation: conversation,
                  targets: rosterTargets,
                  onMentionAgent: (target) =>
                      unawaited(_mentionAgent(conversation, target)),
                  onOpenAgentConversations:
                      widget.onOpenAgentConversations == null
                      ? null
                      : (target) => widget.onOpenAgentConversations!(target.id),
                  onBoundaryOverscroll: _continueConversationScroll,
                ),
            ],
          );
    final body = Column(
      children: [
        if (controller.failureCode.isNotEmpty)
          _CanonicalGroupFailureBanner(
            stage: controller.failureStage,
            code: controller.failureCode,
          ),
        Expanded(child: conversationBody),
      ],
    );
    return widget.framed ? PanelFrame(child: body) : body;
  }
}

class CanonicalGroupConversationSidebar extends StatelessWidget {
  const CanonicalGroupConversationSidebar({
    super.key,
    required this.conversations,
    required this.selectedConversationId,
    required this.onSelect,
    required this.onCreate,
  });

  final List<ClientConversationSummary> conversations;
  final String selectedConversationId;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 42,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.push_pin_rounded,
                    size: 13,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      strings.groupConversation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('canonical-group-sidebar-create'),
                    tooltip: strings.newGroupConversation,
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded, size: 17),
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          for (final conversation in conversations.take(3))
            _CanonicalGroupSidebarRow(
              conversation: conversation,
              selected: conversation.id == selectedConversationId,
              onTap: () => onSelect(conversation.id),
            ),
          if (conversations.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.noGroupConversationsYet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 10.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CanonicalGroupSidebarRow extends StatelessWidget {
  const _CanonicalGroupSidebarRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final ClientConversationSummary conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? colors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(LicoRadius.floating),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.groups_2_rounded,
                  size: 20,
                  color: selected
                      ? colors.textOnPrimary
                      : ConversationVisualTokens.groupIdentityMark(colors),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? colors.textOnPrimary : colors.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        strings.groupConversationMemberCount(
                          conversation.membershipCount,
                        ),
                        style: TextStyle(
                          color: selected
                              ? colors.textOnPrimary.withAlpha(180)
                              : colors.textMuted,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CanonicalGroupConversationHeader extends StatelessWidget {
  const CanonicalGroupConversationHeader({
    super.key,
    required this.conversation,
    required this.rosterVisible,
    required this.onToggleRoster,
  });

  final ClientConversation conversation;
  final bool rosterVisible;
  final VoidCallback onToggleRoster;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    final identity = Row(
      children: [
        Container(
          key: const Key('canonical-group-header-avatar'),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: ConversationVisualTokens.circularIdentityWellFill(colors),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.groups_2_rounded,
            color: ConversationVisualTokens.groupIdentityMark(colors),
            size: 21,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (conversation.pinned) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.push_pin_rounded,
                      size: 13,
                      color: colors.textMuted,
                    ),
                  ],
                ],
              ),
              Text(
                strings.groupConversationMemberCount(
                  conversation.activeMemberships.length,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textMuted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ],
    );
    final rosterToggle = _CanonicalGroupRosterToggleButton(
      rosterVisible: rosterVisible,
      onPressed: onToggleRoster,
    );
    if (isMobileClientPlatform(context)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(child: identity),
            rosterToggle,
          ],
        ),
      );
    }
    final identityRadius = BorderRadius.circular(
      MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius,
    );
    final controlRadius = BorderRadius.circular(999);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetV,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetV,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: MessagingConversationOverlayGlass(
                borderRadius: identityRadius,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal:
                        MessagingDesktopMetrics.conversationHeaderCapsulePadH,
                    vertical:
                        MessagingDesktopMetrics.conversationHeaderCapsulePadV,
                  ),
                  child: identity,
                ),
              ),
            ),
            const SizedBox(
              width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
            ),
            AspectRatio(
              aspectRatio: 1,
              child: MessagingConversationOverlayGlass(
                key: const Key('canonical-group-roster-toggle-capsule'),
                borderRadius: controlRadius,
                child: Center(child: rosterToggle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _CanonicalGroupRosterToggleButton extends StatelessWidget {
  const _CanonicalGroupRosterToggleButton({
    required this.rosterVisible,
    required this.onPressed,
  });

  final bool rosterVisible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return LicoIconButton(
      key: const Key('canonical-group-roster-toggle'),
      tooltip: rosterVisible
          ? strings.collapseAgentsSidebar
          : strings.expandAgentsSidebar,
      onPressed: onPressed,
      size: LicoIconButtonSize.large,
      shape: LicoIconButtonShape.circle,
      tone: LicoIconButtonTone.ghost,
      icon: AnimatedSwitcher(
        duration: context.motion(LicoMotion.short),
        switchInCurve: LicoMotion.standard,
        switchOutCurve: LicoMotion.standard,
        child: Icon(
          rosterVisible
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          key: ValueKey<bool>(rosterVisible),
        ),
      ),
    );
  }
}

final class _CanonicalGroupRosterReveal extends StatefulWidget {
  const _CanonicalGroupRosterReveal({
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  State<_CanonicalGroupRosterReveal> createState() =>
      _CanonicalGroupRosterRevealState();
}

final class _CanonicalGroupRosterRevealState
    extends State<_CanonicalGroupRosterReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _reveal;
  late bool _renderChild;

  @override
  void initState() {
    super.initState();
    _renderChild = widget.visible;
    _controller = AnimationController(
      vsync: this,
      duration: LicoMotion.medium,
      value: widget.visible ? 1 : 0,
    );
    _reveal = CurvedAnimation(
      parent: _controller,
      curve: LicoMotion.decelerate,
      reverseCurve: LicoMotion.accelerate,
    );
  }

  @override
  void didUpdateWidget(covariant _CanonicalGroupRosterReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    _syncVisibility();
  }

  void _syncVisibility() {
    final duration = context.motion(LicoMotion.medium);
    _controller.duration = duration;
    _controller.reverseDuration = duration;
    if (widget.visible) {
      if (!_renderChild) {
        setState(() => _renderChild = true);
      }
      if (duration == Duration.zero) {
        _controller.value = 1;
      } else {
        _controller.forward();
      }
      return;
    }
    if (duration == Duration.zero) {
      _controller.value = 0;
      if (_renderChild) {
        setState(() => _renderChild = false);
      }
      return;
    }
    _controller.reverse().whenCompleteOrCancel(() {
      if (!mounted || widget.visible || !_controller.isDismissed) return;
      setState(() => _renderChild = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_renderChild) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _reveal,
      child: widget.child,
      builder: (context, child) {
        final reveal = _reveal.value;
        return IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeSemantics(
            excluding: !widget.visible,
            child: Align(
              key: const Key('canonical-group-roster-alignment'),
              alignment: Alignment.lerp(
                Alignment.topCenter,
                Alignment.center,
                reveal,
              )!,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: reveal,
                  child: Opacity(opacity: reveal, child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class CanonicalGroupRoster extends StatelessWidget {
  const CanonicalGroupRoster({
    super.key,
    required this.conversation,
    required this.targets,
    required this.onMentionAgent,
    this.onOpenAgentConversations,
    this.onBoundaryOverscroll,
  });

  final ClientConversation conversation;
  final List<TargetCandidate> targets;
  final ValueChanged<TargetCandidate> onMentionAgent;
  final ValueChanged<TargetCandidate>? onOpenAgentConversations;
  final ValueChanged<double>? onBoundaryOverscroll;

  Future<void> _showAgentMenu({
    required BuildContext context,
    required TargetCandidate target,
    required String label,
    required Offset globalPosition,
  }) async {
    final strings = LicoStrings.of(context);
    final action = await showMessagingGlassMenu<_CanonicalGroupRosterAction>(
      context: context,
      globalPosition: globalPosition,
      menuKey: Key('canonical-group-roster-menu-${target.target}'),
      actions: [
        MessagingGlassMenuAction(
          value: _CanonicalGroupRosterAction.mention,
          label: strings.mentionAgent(label),
          leading: const Icon(Icons.alternate_email_rounded, size: 17),
        ),
        if (onOpenAgentConversations != null)
          MessagingGlassMenuAction(
            value: _CanonicalGroupRosterAction.openConversations,
            label: strings.openAgentConversations(label),
            leading: const Icon(Icons.forum_outlined, size: 17),
          ),
      ],
    );
    switch (action) {
      case _CanonicalGroupRosterAction.mention:
        onMentionAgent(target);
        break;
      case _CanonicalGroupRosterAction.openConversations:
        onOpenAgentConversations?.call(target);
        break;
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final membershipsByAgentId = {
      for (final membership in conversation.activeAgentMemberships)
        membership.principal.agentId: membership,
    };
    return SizedBox(
      key: const Key('canonical-group-roster'),
      width: MessagingDesktopMetrics.groupRosterExtent,
      child: ScrollConfiguration(
        behavior: const _CanonicalGroupRosterScrollBehavior(),
        child: NotificationListener<OverscrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0) {
              onBoundaryOverscroll?.call(notification.overscroll);
            }
            return false;
          },
          child: ListView.separated(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(
              horizontal: MessagingDesktopMetrics.groupRosterContentInset,
              vertical: MessagingDesktopMetrics.groupRosterVerticalInset,
            ),
            itemCount: targets.length,
            separatorBuilder: (_, _) => const SizedBox(
              height: MessagingDesktopMetrics.groupRosterMemberGap,
            ),
            itemBuilder: (context, index) {
              final target = targets[index];
              final membership =
                  membershipsByAgentId[target.target] ??
                  membershipsByAgentId[target.id];
              final membershipLabel =
                  membership?.principal.displayName.trim() ?? '';
              final fullLabel = membershipLabel.isEmpty
                  ? agentConversationTargetDisplayName(target)
                  : membershipLabel;
              final compactLabel = agentConversationTargetCompactDisplayName(
                target,
              );
              return Tooltip(
                message: fullLabel,
                waitDuration: LicoMotion.tooltipWait,
                child: Column(
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        key: Key(
                          'canonical-group-roster-agent-${target.target}',
                        ),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onMentionAgent(target),
                        onDoubleTap: onOpenAgentConversations == null
                            ? null
                            : () => onOpenAgentConversations!(target),
                        onSecondaryTapDown: (details) => _showAgentMenu(
                          context: context,
                          target: target,
                          label: compactLabel,
                          globalPosition: details.globalPosition,
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            MessagingAgentAvatar(
                              target: target,
                              size: 42,
                              iconSize: 24,
                            ),
                            Positioned(
                              right: -1,
                              bottom: -1,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: target.canRelayRuntime
                                      ? colors.success
                                      : colors.textDisabled,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: colors.surface,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      compactLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 9,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _CanonicalGroupRosterAction { mention, openConversations }

final class _CanonicalGroupRosterScrollBehavior extends MaterialScrollBehavior {
  const _CanonicalGroupRosterScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => Scrollbar(
    key: const Key('canonical-group-roster-scrollbar'),
    controller: details.controller,
    thickness: MessagingDesktopMetrics.groupRosterScrollbarThickness,
    radius: const Radius.circular(1),
    interactive: true,
    child: child,
  );
}

/// Detached group-member capsule, centered in the right transcript band and
/// styled with the same glass and width as the header visibility control.
class CanonicalGroupRosterSurface extends StatelessWidget {
  const CanonicalGroupRosterSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(
      MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius,
    );
    return SizedBox(
      key: const Key('canonical-group-roster-surface'),
      width: MessagingDesktopMetrics.groupRosterExtent,
      child: MessagingConversationOverlayGlass(
        key: const Key('canonical-group-roster-glass'),
        borderRadius: radius,
        child: child,
      ),
    );
  }
}

List<TargetCandidate> resolveCanonicalGroupParticipantTargets(
  ClientConversation conversation,
  List<TargetCandidate> targets,
) {
  final resolved = <TargetCandidate>[];
  for (final membership in conversation.activeAgentMemberships) {
    final agentId = membership.principal.agentId.trim();
    TargetCandidate? target;
    for (final candidate in targets) {
      if (candidate.target == agentId || candidate.id == agentId) {
        target = candidate;
        break;
      }
    }
    resolved.add(
      target ??
          TargetCandidate(
            target: agentId,
            label: membership.principal.displayName.trim().isEmpty
                ? agentId
                : membership.principal.displayName.trim(),
            kind: 'conversation-member',
            status: 'detected',
            configured: false,
            confidence: 1,
            adapterStatus: 'runtime-unavailable',
            scanSource: 'canonical-conversation',
          ),
    );
  }
  return List<TargetCandidate>.unmodifiable(resolved);
}

List<TargetCandidate> resolveCanonicalGroupOrderedParticipantTargets(
  ClientConversation conversation,
  List<TargetCandidate> targets,
  List<String> orderedAgentIds,
) {
  if (orderedAgentIds.isEmpty) return const [];
  final targetByAgentId = {
    for (final target in targets) target.target: target,
    for (final target in targets) target.id: target,
  };
  final membershipByAgentId = {
    for (final membership in conversation.activeAgentMemberships)
      membership.principal.agentId: membership,
  };
  final resolved = <TargetCandidate>[];
  for (final agentId in orderedAgentIds) {
    final target = targetByAgentId[agentId];
    if (target != null) {
      resolved.add(target);
    } else {
      final membership = membershipByAgentId[agentId];
      if (membership != null) {
        resolved.add(
          TargetCandidate(
            target: agentId,
            label: membership.principal.displayName.trim().isEmpty
                ? agentId
                : membership.principal.displayName.trim(),
            kind: 'conversation-member',
            status: 'detected',
            configured: false,
            confidence: 1,
            adapterStatus: 'runtime-unavailable',
            scanSource: 'canonical-conversation',
          ),
        );
      }
    }
  }
  return List<TargetCandidate>.unmodifiable(resolved);
}

ClientConversationMembership? _agentMembership(
  ClientConversation conversation,
  TargetCandidate target,
) {
  for (final membership in conversation.activeAgentMemberships) {
    final agentId = membership.principal.agentId;
    if (agentId == target.target || agentId == target.id) return membership;
  }
  return null;
}

AgentConversationSession canonicalGroupConversationSession(
  ClientConversation conversation,
  List<ClientConversationEvent> events,
  LicoStrings strings,
) {
  final memberships = {
    for (final membership in conversation.memberships)
      membership.id: membership,
  };
  final membershipsByPrincipal = {
    for (final membership in conversation.memberships)
      membership.principal.id: membership,
  };
  final messages = <AgentConversationMessage>[];
  for (final event in events) {
    final author = memberships[event.authorMembershipId];
    if (event.kind != ConversationEventKind.message) {
      final presentation = _canonicalGroupEventPresentation(
        event,
        memberships: memberships,
        membershipsByPrincipal: membershipsByPrincipal,
        strings: strings,
      );
      messages.add(
        AgentConversationMessage(
          id: event.id,
          role: 'event',
          text: presentation.detail,
          createdAt: _iso(event.createdAtUnixMs),
          layer: AgentConversationSemanticLayer.execution,
          cardType: event.kind.wireName,
          cardTitle: presentation.title,
          stableIdentity: event.id,
        ),
      );
      continue;
    }
    for (final eventPart in event.parts) {
      final user = author?.principal.kind == ConversationPrincipalKind.human;
      final cardType = switch (eventPart.kind) {
        ConversationEventPartKind.text => '',
        ConversationEventPartKind.reasoning => 'reasoning',
        ConversationEventPartKind.toolCall => 'tool-call',
        ConversationEventPartKind.toolResult => 'tool-result',
        ConversationEventPartKind.artifact => 'artifact',
        ConversationEventPartKind.diagnostic => 'diagnostic',
        ConversationEventPartKind.metadata => 'metadata',
        ConversationEventPartKind.unknown => 'event',
      };
      messages.add(
        AgentConversationMessage(
          id: eventPart.id.isEmpty
              ? '${event.id}:${eventPart.ordinal}'
              : eventPart.id,
          role: user
              ? 'user'
              : cardType.isEmpty
              ? 'assistant'
              : cardType,
          text: eventPart.content,
          createdAt: _iso(
            eventPart.createdAtUnixMs == 0
                ? event.createdAtUnixMs
                : eventPart.createdAtUnixMs,
          ),
          layer: cardType.isEmpty
              ? AgentConversationSemanticLayer.thread
              : AgentConversationSemanticLayer.execution,
          cardType: cardType,
          stableIdentity: event.id,
          participantAgentId: user
              ? ''
              : author?.principal.agentId.trim() ?? '',
          participantLabel: user
              ? ''
              : author?.principal.displayName.trim() ?? '',
          participantRole: user ? '' : 'member',
        ),
      );
    }
  }
  return AgentConversationSession(
    id: conversation.id,
    agentId: conversation.activeAgentMemberships.isEmpty
        ? ''
        : conversation.activeAgentMemberships.first.principal.agentId,
    title: conversation.title,
    createdAt: _iso(conversation.createdAtUnixMs),
    updatedAt: _iso(conversation.updatedAtUnixMs),
    messages: List<AgentConversationMessage>.unmodifiable(messages),
    nativeSessionId: conversation.id,
    adapterId: 'canonical-conversation',
    sourceKind: 'canonical-conversation',
    sourceClient: 'licoup',
    sourceClientLabel: 'LicoUp',
    native: false,
    readOnly: false,
    messageCount: conversation.eventCount,
    sourceMessageCount: conversation.eventCount,
    historyTruncated: conversation.eventCount > events.length,
  );
}

({String title, String detail}) _canonicalGroupEventPresentation(
  ClientConversationEvent event, {
  required Map<String, ClientConversationMembership> memberships,
  required Map<String, ClientConversationMembership> membershipsByPrincipal,
  required LicoStrings strings,
}) {
  final membershipEvent = event.kind == ConversationEventKind.membershipChanged;
  final title = membershipEvent
      ? strings.groupConversationMembershipChangeTitle
      : strings.groupConversationAvailabilityChangeTitle;
  final metadata = _canonicalGroupEventMetadata(event);
  if (metadata == null) {
    return (
      title: title,
      detail: strings.groupConversationEventDetailsUnavailable,
    );
  }
  final membershipId = (metadata['membershipId'] ?? '').toString().trim();
  final principalId = (metadata['principalId'] ?? '').toString().trim();
  final membership =
      memberships[membershipId] ?? membershipsByPrincipal[principalId];
  final memberLabel = _canonicalGroupEventMemberLabel(
    metadata,
    membership: membership,
    strings: strings,
  );

  if (membershipEvent) {
    final change = (metadata['change'] ?? '').toString().trim();
    final detail = switch (change) {
      'joined' => strings.groupConversationMemberJoined(memberLabel),
      'left' => strings.groupConversationMemberLeft(memberLabel),
      'access-set' => strings.groupConversationMemberAccessSet(
        memberLabel,
        strings.groupConversationAccessLabel(
          (metadata['access'] ?? '').toString(),
        ),
      ),
      _ => strings.groupConversationMemberChangeUnknown(memberLabel),
    };
    return (title: title, detail: detail);
  }

  final availability = strings.groupConversationAvailabilityLabel(
    (metadata['availability'] ?? '').toString(),
  );
  return (
    title: title,
    detail: strings.groupConversationMemberAvailabilitySet(
      memberLabel,
      availability,
    ),
  );
}

Map<String, dynamic>? _canonicalGroupEventMetadata(
  ClientConversationEvent event,
) {
  for (final part in event.parts) {
    if (part.kind != ConversationEventPartKind.metadata ||
        part.content.trim().isEmpty) {
      continue;
    }
    try {
      final decoded = jsonDecode(part.content);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      continue;
    }
  }
  return null;
}

String _canonicalGroupEventMemberLabel(
  Map<String, dynamic> metadata, {
  required ClientConversationMembership? membership,
  required LicoStrings strings,
}) {
  final embedded = (metadata['displayName'] ?? '').toString().trim();
  if (embedded.isNotEmpty) return embedded;
  final principal = membership?.principal;
  final displayName = principal?.displayName.trim() ?? '';
  if (displayName.isNotEmpty) return displayName;
  final agentId = principal?.agentId.trim() ?? '';
  if (agentId.isNotEmpty) return agentId;
  final principalId = (metadata['principalId'] ?? '').toString().trim();
  if (principalId.isNotEmpty) return principalId;
  final membershipId = (metadata['membershipId'] ?? '').toString().trim();
  if (membershipId.isNotEmpty) return membershipId;
  return strings.groupConversationUnknownMember;
}

class _CanonicalGroupFailureBanner extends StatelessWidget {
  const _CanonicalGroupFailureBanner({required this.stage, required this.code});

  final String stage;
  final String code;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Container(
      key: const Key('canonical-group-failure'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: colors.error.withAlpha(colors.isDark ? 42 : 24),
      child: Text(
        strings.groupConversationFailure(stage, code),
        style: TextStyle(color: colors.error, fontSize: 12),
      ),
    );
  }
}

class _CanonicalGroupLoadingOrEmpty extends StatelessWidget {
  const _CanonicalGroupLoadingOrEmpty({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const CircularProgressIndicator()
          else
            Icon(Icons.groups_2_outlined, size: 30, color: colors.textMuted),
          const SizedBox(height: 12),
          Text(
            loading
                ? strings.loadingNativeHistories
                : strings.groupConversation,
            style: TextStyle(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

String _iso(int unixMs) => unixMs <= 0
    ? ''
    : DateTime.fromMillisecondsSinceEpoch(
        unixMs,
        isUtc: true,
      ).toIso8601String();
