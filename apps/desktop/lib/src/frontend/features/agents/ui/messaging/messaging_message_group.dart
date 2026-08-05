import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_surface.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// One author group in the messaging participant flow: a header row with the
/// author avatar, display name, and AGENT badge for agent authors, followed
/// by every message in the group. Messages render with the shared markdown
/// content renderer inside a readable message bubble. Hovering a row applies
/// a subtle [LicoSurface] highlight and reveals that message's timestamp
/// outside the bubble at its bottom-right corner.
class MessagingMessageGroup extends StatelessWidget {
  const MessagingMessageGroup({
    super.key,
    required this.authorIsUser,
    required this.participantLabel,
    required this.participantRole,
    required this.participantTarget,
    required this.messages,
    required this.target,
    required this.adapter,
  });

  final bool authorIsUser;
  final String participantLabel;
  final String participantRole;
  final TargetCandidate? participantTarget;
  final List<AgentConversationMessage> messages;
  final TargetCandidate target;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final authorName = authorIsUser
        ? strings.you
        : participantLabel.trim().isNotEmpty
        ? participantLabel.trim()
        : participantTarget != null
        ? agentConversationTargetDisplayName(participantTarget!)
        : agentConversationTargetDisplayName(target);
    return Column(
      key: Key(
        authorIsUser
            ? 'messaging-user-message-group'
            : 'messaging-agent-message-group',
      ),
      crossAxisAlignment: authorIsUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 36,
          child: Row(
            mainAxisAlignment: authorIsUser
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: authorIsUser
                ? [
                    Flexible(
                      child: Text(
                        authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _MessagingUserAvatar(accessibilityLabel: authorName),
                  ]
                : [
                    MessagingAgentAvatar(
                      target: participantTarget ?? target,
                      size: 36,
                      iconSize: 20,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _MessagingAgentBadge(participantRole: participantRole),
                  ],
          ),
        ),
        const SizedBox(height: LicoContentSpacing.compact),
        for (var index = 0; index < messages.length; index++) ...[
          _MessagingGroupMessageRow(
            key: ValueKey<String>(
              'messaging-group-message-${messages[index].id}-${messages[index].createdAt}',
            ),
            message: messages[index],
            adapter: adapter,
            authorIsUser: authorIsUser,
          ),
          if (index != messages.length - 1)
            const SizedBox(height: LicoContentSpacing.compact),
        ],
      ],
    );
  }
}

class _MessagingGroupMessageRow extends StatefulWidget {
  const _MessagingGroupMessageRow({
    super.key,
    required this.message,
    required this.adapter,
    required this.authorIsUser,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  /// Drives the asymmetric treatment. Giving both authors an identical bordered
  /// bubble is why the surface did not read like a chat client: there was no
  /// visual cue for who is speaking beyond the avatar.
  final bool authorIsUser;

  @override
  State<_MessagingGroupMessageRow> createState() =>
      _MessagingGroupMessageRowState();
}

class _MessagingGroupMessageRowState extends State<_MessagingGroupMessageRow> {
  bool _hovered = false;

  DateTime? get _messageTime =>
      parseAgentConversationTimestamp(widget.message.createdAt);

  Widget _buildMessageColumn(BuildContext context, Widget bubble) {
    final colors = context.licoColors;
    final messageTime = _messageTime;
    final timestampLabel = messageTime == null
        ? null
        : MaterialLocalizations.of(
            context,
          ).formatTimeOfDay(TimeOfDay.fromDateTime(messageTime));
    final timestampStyle = TextStyle(
      color: colors.textMuted.withAlpha(colors.isDark ? 180 : 200),
      fontSize: 10.5,
      fontWeight: FontWeight.w400,
      height: 1.2,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        bubble,
        if (timestampLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AnimatedOpacity(
              opacity: _hovered ? 1 : 0,
              duration: context.motion(LicoMotion.micro),
              curve: LicoMotion.standard,
              child: Text(
                timestampLabel,
                key: const Key('messaging-message-hover-timestamp'),
                style: timestampStyle,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final content = AgentConversationMessageContent(
      data: widget.message.text,
      foreground: agentConversationMessageForeground(
        colors,
        widget.message.role,
      ),
      accent: colors.accent,
      codeBackground: agentConversationToneColor(
        colors,
        widget.adapter.codeTone,
      ),
      blockBackground: agentConversationToneColor(
        colors,
        widget.adapter.quoteTone,
      ),
      borderColor: colors.line,
      renderStyle: widget.adapter.markdownStyle,
      images: widget.message.images,
    );
    final bubbleRadius = BorderRadius.circular(LicoRadius.composerField);
    final bubblePadding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 11,
    );
    final bubble = widget.authorIsUser
        ? MessagingUserBubbleGlass(
            key: const Key('messaging-message-bubble'),
            borderRadius: bubbleRadius,
            padding: bubblePadding,
            hovered: _hovered,
            child: content,
          )
        : LicoSurface(
            key: const Key('messaging-message-bubble'),
            tone: LicoSurfaceTone.neutral,
            elevation: LicoElevation.flat,
            radius: LicoRadius.composerField,
            bordered: false,
            hovered: _hovered,
            padding: bubblePadding,
            child: content,
          );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: widget.authorIsUser
            ? Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: widget.adapter.userBubble.maxWidth,
                  ),
                  child: _buildMessageColumn(context, bubble),
                ),
              )
            : Align(
                alignment: Alignment.centerLeft,
                child: _buildMessageColumn(context, bubble),
              ),
      ),
    );
  }
}

class _MessagingUserAvatar extends StatelessWidget {
  const _MessagingUserAvatar({required this.accessibilityLabel});

  final String accessibilityLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Semantics(
      label: accessibilityLabel,
      child: Container(
        key: const Key('messaging-user-avatar'),
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.surfaceLow,
          border: Border.all(color: colors.line.withAlpha(90), width: 1),
        ),
        child: Icon(
          Icons.person_outline_rounded,
          size: 20,
          color: colors.textMuted,
        ),
      ),
    );
  }
}

/// The small caps pill marking an agent participant, mirroring the BOT badge
/// in chat clients.
class _MessagingAgentBadge extends StatelessWidget {
  const _MessagingAgentBadge({required this.participantRole});

  final String participantRole;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final role = switch (participantRole.trim().toLowerCase()) {
      'main-agent' => 'MAIN AGENT',
      'peer-agent' => 'AGENT',
      'designer' => 'DESIGNER',
      'backend-worker' => 'BACKEND WORKER',
      'frontend-worker' => 'FRONTEND WORKER',
      'backend-reviewer' => 'BACKEND REVIEWER',
      'frontend-reviewer' => 'FRONTEND REVIEWER',
      _ => strings.agentBadge,
    };
    return Container(
      key: const Key('messaging-agent-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        // Neutral chip — brand/primary wash reads as olive 泛黄 on dark glass.
        color: colors.surfaceLow.withAlpha(colors.isDark ? 180 : 220),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: colors.line.withAlpha(colors.isDark ? 90 : 110),
          width: MessagingDesktopMetrics.hairline,
        ),
      ),
      child: Text(
        role,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
          height: 1.1,
        ),
      ),
    );
  }
}
