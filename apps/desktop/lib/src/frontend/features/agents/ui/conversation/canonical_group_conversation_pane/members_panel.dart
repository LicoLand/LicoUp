import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/roster.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_member_profile_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_self_avatar.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

/// Width of the members panel beside a group conversation.
const double canonicalGroupMembersPanelExtent = 216;

/// What a member is doing right now, as the members panel reports it.
enum CanonicalGroupMemberStatus { online, working, needsApproval, offline }

/// Status of one agent member from its live turn and its runtime reach.
CanonicalGroupMemberStatus canonicalGroupAgentStatus({
  required TargetCandidate target,
  required PersistentTurnPhase? phase,
}) {
  if (phase == PersistentTurnPhase.running) {
    return CanonicalGroupMemberStatus.working;
  }
  if (phase == PersistentTurnPhase.waiting) {
    return CanonicalGroupMemberStatus.needsApproval;
  }
  return target.canRelayRuntime
      ? CanonicalGroupMemberStatus.online
      : CanonicalGroupMemberStatus.offline;
}

/// Panel beside a group conversation listing every member with its role and
/// live status, the local user first. Tapping a member opens its profile
/// card anchored beside the row — the demo's `openProfile`; a secondary
/// click offers the mention menu shared with the avatar roster.
class CanonicalGroupMembersPanel extends StatelessWidget {
  const CanonicalGroupMembersPanel({
    super.key,
    required this.conversation,
    required this.targets,
    required this.turnPhases,
    required this.onMentionAgent,
    this.onOpenMemberHistory,
    this.onCollapse,
    this.onOpenSettings,
    this.selfMascotId,
    this.onSelfMascotChanged,
    this.memberSessionCounts = const {},
    this.width = canonicalGroupMembersPanelExtent,
  });

  final ClientConversation conversation;
  final List<TargetCandidate> targets;

  /// Collapses the panel. When set, the header shows a collapse affordance
  /// in its top-right corner like the demo's panel chrome.
  final VoidCallback? onCollapse;

  /// Opens the settings destination from the self profile card.
  final VoidCallback? onOpenSettings;

  /// The mascot the user picked in the self profile card this session;
  /// null keeps the default ink-disc self avatar.
  final String? selfMascotId;

  /// Reports a mascot pick from the self profile card's avatar picker.
  final ValueChanged<String>? onSelfMascotChanged;

  /// In-group session counts keyed by agent id for the card's facts grid.
  final Map<String, int> memberSessionCounts;

  /// Drag-adjustable panel width from the pane's edge handle.
  final double width;

  /// Live turn phase keyed by agent id. Members without a live turn are idle.
  final Map<String, PersistentTurnPhase> turnPhases;
  final ValueChanged<TargetCandidate> onMentionAgent;

  /// Opens the member's in-group conversation history anchored at the tap
  /// position. The profile card's 发消息 action forwards to it; a null handler
  /// keeps the tap on the mention affordance.
  final void Function(TargetCandidate target, Offset globalPosition)?
  onOpenMemberHistory;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final owner = conversation.localOwnerMembership;
    final membershipsByAgentId = {
      for (final membership in conversation.activeAgentMemberships)
        membership.principal.agentId: membership,
    };
    final count = (owner == null ? 0 : 1) + targets.length;
    return SizedBox(
      key: const Key('canonical-group-members-panel'),
      width: width,
      child: CustomPaint(
        foregroundPainter: ContinuousEdgeHairlinePainter(
          color: colors.line,
          edge: AxisDirection.left,
        ),
        child: ColoredBox(
          color: colors.background,
          child: ListView(
            key: const Key('canonical-group-members-list'),
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 0, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.groupMembersTitle(count),
                        key: const Key('canonical-group-members-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.24,
                        ),
                      ),
                    ),
                    if (onCollapse != null)
                      Tooltip(
                        message: strings.hideGroupMembers,
                        waitDuration: LicoMotion.tooltipWait,
                        child: InkWell(
                          key: const Key('canonical-group-members-collapse'),
                          borderRadius: BorderRadius.circular(LicoRadius.well),
                          onTap: onCollapse,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (owner != null)
                _CanonicalGroupMemberRow(
                  key: const Key('canonical-group-member-self'),
                  avatar: MessagingSelfAvatar(
                    size: _memberAvatarExtent,
                    mascotId: selfMascotId,
                  ),
                  name: owner.principal.displayName.trim().isEmpty
                      ? strings.memberSelf
                      : owner.principal.displayName.trim(),
                  status: CanonicalGroupMemberStatus.online,
                  onTap: (rect) => _openSelfProfile(context, rect, owner),
                ),
              for (final target in targets)
                _agentRow(
                  context,
                  strings: strings,
                  target: target,
                  membership: membershipsByAgentId[target.target],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _agentRow(
    BuildContext context, {
    required LicoStrings strings,
    required TargetCandidate target,
    required ClientConversationMembership? membership,
  }) {
    final assistant =
        membership != null &&
        membership.id == conversation.assistantMembershipId;
    return _CanonicalGroupMemberRow(
      key: Key('canonical-group-member-${target.target}'),
      avatar: MessagingAgentAvatar(
        target: target,
        size: _memberAvatarExtent,
        iconSize: 21,
      ),
      name: canonicalGroupMemberLabel(target, membership),
      tag: assistant ? strings.memberTagAssistant : strings.memberTagAgent,
      assistantTag: assistant,
      status: canonicalGroupAgentStatus(
        target: target,
        phase: turnPhases[target.target],
      ),
      onTap: (rect) => _openAgentProfile(
        context,
        anchorRect: rect,
        target: target,
        membership: membership,
        assistant: assistant,
        strings: strings,
      ),
      onSecondaryTapDown: (details) => showCanonicalGroupMemberMenu(
        context: context,
        target: target,
        label: agentConversationTargetCompactDisplayName(target),
        globalPosition: details.globalPosition,
        onMentionAgent: onMentionAgent,
      ),
    );
  }

  /// The agent member's `.profile-card`: identity, live status, install and
  /// adapter facts, capability chips; 发消息 forwards to the in-group history
  /// the workspace owns, 提及 keeps the composer affordance.
  void _openAgentProfile(
    BuildContext context, {
    required Rect anchorRect,
    required TargetCandidate target,
    required ClientConversationMembership? membership,
    required bool assistant,
    required LicoStrings strings,
  }) {
    final colors = context.licoColors;
    final status = canonicalGroupAgentStatus(
      target: target,
      phase: turnPhases[target.target],
    );
    final (statusLabel, dotColor) = switch (status) {
      CanonicalGroupMemberStatus.online => (
        strings.memberStatusOnline,
        colors.success,
      ),
      CanonicalGroupMemberStatus.working => (
        strings.memberStatusWorking,
        colors.primaryStrong,
      ),
      CanonicalGroupMemberStatus.needsApproval => (
        strings.memberStatusNeedsApproval,
        colors.warning,
      ),
      CanonicalGroupMemberStatus.offline => (
        strings.memberStatusOffline,
        colors.textDisabled,
      ),
    };
    final sessionCount =
        memberSessionCounts[target.target] ?? memberSessionCounts[target.id];
    showMessagingMemberProfile(
      context: context,
      anchorRect: anchorRect,
      card: messagingAgentProfileCard(
        context: context,
        strings: strings,
        target: target,
        name: canonicalGroupMemberLabel(target, membership),
        tag: assistant ? strings.memberTagAssistant : strings.memberTagAgent,
        assistantTag: assistant,
        statusLabel: statusLabel,
        statusDot: dotColor,
        sessionCount: sessionCount,
        actions: [
          if (onOpenMemberHistory != null)
            (
              label: strings.memberProfileMessage,
              filled: true,
              onPressed: () {
                Navigator.of(context, rootNavigator: false).pop();
                onOpenMemberHistory!(target, anchorRect.center);
              },
            ),
          (
            label: strings.memberProfileMention,
            filled: false,
            onPressed: () {
              Navigator.of(context, rootNavigator: false).pop();
              onMentionAgent(target);
            },
          ),
        ],
      ),
    );
  }

  /// The local user's card: editable avatar choice and identity facts — the
  /// demo's self `.profile-card`. 编辑资料 reveals the mascot picker; 设置
  /// navigates to the settings destination when the workspace provides one.
  void _openSelfProfile(
    BuildContext context,
    Rect anchorRect,
    ClientConversationMembership owner,
  ) {
    final strings = LicoStrings.of(context);
    final displayName = owner.principal.displayName.trim();
    showMessagingMemberProfile(
      context: context,
      anchorRect: anchorRect,
      card: MessagingSelfProfileCard(
        displayName: displayName.isEmpty ? strings.memberSelf : displayName,
        mascotId: selfMascotId,
        onMascotChanged: onSelfMascotChanged,
        onOpenSettings: onOpenSettings,
      ),
    );
  }
}

const double _memberAvatarExtent = 38;

final class _CanonicalGroupMemberRow extends StatefulWidget {
  const _CanonicalGroupMemberRow({
    super.key,
    required this.avatar,
    required this.name,
    required this.status,
    this.tag,
    this.assistantTag = false,
    this.onTap,
    this.onSecondaryTapDown,
  });

  final Widget avatar;
  final String name;
  final CanonicalGroupMemberStatus status;
  final String? tag;
  final bool assistantTag;

  /// Primary activation; receives the row's global bounds so callers can
  /// anchor a floating card beside the row.
  final ValueChanged<Rect>? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  State<_CanonicalGroupMemberRow> createState() =>
      _CanonicalGroupMemberRowState();
}

final class _CanonicalGroupMemberRowState
    extends State<_CanonicalGroupMemberRow> {
  bool _hovered = false;

  Rect _rowRect() {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final interactive = widget.onTap != null;
    final (statusLabel, statusInk, dotColor) = switch (widget.status) {
      CanonicalGroupMemberStatus.online => (
        strings.memberStatusOnline,
        colors.textMuted,
        colors.success,
      ),
      CanonicalGroupMemberStatus.working => (
        strings.memberStatusWorking,
        colors.textMuted,
        colors.primaryStrong,
      ),
      CanonicalGroupMemberStatus.needsApproval => (
        strings.memberStatusNeedsApproval,
        colors.warning,
        colors.warning,
      ),
      CanonicalGroupMemberStatus.offline => (
        strings.memberStatusOffline,
        colors.textMuted,
        colors.textDisabled,
      ),
    };
    final tag = widget.tag;
    final row = AnimatedContainer(
      duration: context.motion(LicoMotion.micro),
      curve: LicoMotion.standard,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: _hovered && interactive
            ? colors.hoverOverlay
            : Colors.transparent,
        borderRadius: BorderRadius.circular(LicoRadius.card),
      ),
      child: Row(
        children: [
          widget.avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ),
                    if (tag != null) ...[
                      const SizedBox(width: 5),
                      _CanonicalGroupMemberTag(
                        label: tag,
                        assistant: widget.assistantTag,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    _CanonicalGroupMemberStatusDot(
                      color: dotColor,
                      pulsing:
                          widget.status == CanonicalGroupMemberStatus.working,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        statusLabel,
                        key: const Key('canonical-group-member-status'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: statusInk,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!interactive) return row;
    return Semantics(
      button: true,
      label: '${widget.name}, $statusLabel',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap == null ? null : () => widget.onTap!(_rowRect()),
          onSecondaryTapDown: widget.onSecondaryTapDown,
          child: row,
        ),
      ),
    );
  }
}

final class _CanonicalGroupMemberTag extends StatelessWidget {
  const _CanonicalGroupMemberTag({
    required this.label,
    required this.assistant,
  });

  final String label;
  final bool assistant;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: assistant ? colors.accentSurface : colors.brandSurface,
        borderRadius: BorderRadius.circular(LicoRadius.well),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            color: assistant ? colors.accent : colors.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

/// The 6 px status dot. A working member's dot breathes; reduced motion
/// holds it still.
final class _CanonicalGroupMemberStatusDot extends StatefulWidget {
  const _CanonicalGroupMemberStatusDot({
    required this.color,
    required this.pulsing,
  });

  final Color color;
  final bool pulsing;

  @override
  State<_CanonicalGroupMemberStatusDot> createState() =>
      _CanonicalGroupMemberStatusDotState();
}

final class _CanonicalGroupMemberStatusDotState
    extends State<_CanonicalGroupMemberStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LicoMotion.loopShort,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _CanonicalGroupMemberStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final animate = widget.pulsing && context.allowsAmbientMotion;
    if (animate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!animate && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (!widget.pulsing) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.45).animate(_controller),
      child: dot,
    );
  }
}
