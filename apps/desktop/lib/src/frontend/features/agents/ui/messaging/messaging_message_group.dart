import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_target_catalog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_bubble.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/apple_notifications.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/assistant_sparkles_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
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
    this.runtimeProfile,
    this.conversationId = '',
    this.onCopyText,
  });

  final bool authorIsUser;
  final String participantLabel;
  final String participantRole;
  final TargetCandidate? participantTarget;
  final List<AgentConversationMessage> messages;
  final TargetCandidate target;
  final AgentRenderAdapter adapter;
  final AgentParticipantRuntimeProfile? runtimeProfile;

  /// Clipboard write routed through the platform boundary; message rows
  /// expose an explicit copy action when present.
  final Future<void> Function(String)? onCopyText;

  /// This author's native/local conversation id, revealed on message hover
  /// immediately before the timestamp (agent bubbles only).
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final isAssistant = participantRole.trim().toLowerCase() == 'assistant';
    final bubbleGlowKey = authorIsUser
        ? ''
        : messagingAgentBubbleGlowKey(participantTarget ?? target);
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
                    if (isAssistant)
                      _MessagingAssistantAvatar(accessibilityLabel: authorName)
                    else
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
                    if (!isAssistant && runtimeProfile?.hasDetails == true) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _runtimeProfileLabel(
                            strings,
                            participantTarget,
                            runtimeProfile!,
                          ),
                          key: const Key('messaging-subagent-runtime-profile'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
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
            agentKey: bubbleGlowKey,
            conversationId: conversationId,
            onCopyText: onCopyText,
          ),
          if (index != messages.length - 1)
            const SizedBox(height: LicoContentSpacing.compact),
        ],
      ],
    );
  }

  String _runtimeProfileLabel(
    LicoStrings strings,
    TargetCandidate? target,
    AgentParticipantRuntimeProfile profile,
  ) {
    final model = profile.model.trim();
    final effort = profile.reasoningEffort.trim();
    final labels = <String>[];
    if (model.isNotEmpty) {
      labels.add(
        target == null
            ? model
            : agentOrchestrationModelDisplayName(target, model),
      );
    }
    if (effort.isNotEmpty) {
      labels.add(strings.reasoningEffortOptionLabel(effort, effort));
    }
    return labels.join(' · ');
  }
}

class _MessagingGroupMessageRow extends StatefulWidget {
  const _MessagingGroupMessageRow({
    super.key,
    required this.message,
    required this.adapter,
    required this.authorIsUser,
    this.agentKey = '',
    this.conversationId = '',
    this.onCopyText,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  /// Drives the asymmetric treatment. Giving both authors an identical bordered
  /// bubble is why the surface did not read like a chat client: there was no
  /// visual cue for who is speaking beyond the avatar.
  final bool authorIsUser;

  /// Rim-light palette key for agent bubbles (the speaking agent's brand hue);
  /// empty selects the shared white light.
  final String agentKey;
  final String conversationId;

  /// Clipboard write routed through the platform boundary; the hover meta row
  /// shows an explicit copy action when present.
  final Future<void> Function(String)? onCopyText;

  @override
  State<_MessagingGroupMessageRow> createState() =>
      _MessagingGroupMessageRowState();
}

class _MessagingGroupMessageRowState extends State<_MessagingGroupMessageRow> {
  bool _hovered = false;

  DateTime? get _messageTime =>
      parseAgentConversationTimestamp(widget.message.createdAt);

  Future<void> _copyMessageText(BuildContext context) async {
    final write = widget.onCopyText;
    if (write == null) return;
    final text = widget.message.text.trim();
    if (text.isEmpty) return;
    await write(text);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      appleGlassSnackBar(
        context: context,
        message: LicoStrings.of(context).conversationMessageCopied,
      ),
    );
  }

  Widget _buildCopyAction(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Tooltip(
      message: strings.conversationCopyMessage,
      waitDuration: LicoMotion.tooltipWait,
      child: InkWell(
        key: const Key('messaging-message-copy-action'),
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        onTap: () => _copyMessageText(context),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            Icons.copy_outlined,
            size: 13,
            color: colors.textMuted.withAlpha(colors.isDark ? 180 : 200),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageColumn(BuildContext context, Widget bubble) {
    final colors = context.licoColors;
    final messageTime = _messageTime;
    final timestampLabel = messageTime == null
        ? null
        : MaterialLocalizations.of(
            context,
          ).formatTimeOfDay(TimeOfDay.fromDateTime(messageTime));
    final conversationId = widget.conversationId.trim();
    final showMeta = timestampLabel != null || conversationId.isNotEmpty;
    final metaStyle = TextStyle(
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
        if (showMeta)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AnimatedOpacity(
              opacity: _hovered ? 1 : 0,
              duration: context.motion(LicoMotion.micro),
              curve: LicoMotion.standard,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (conversationId.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Tooltip(
                        message: conversationId,
                        waitDuration: LicoMotion.tooltipWait,
                        child: Text(
                          conversationId,
                          key: const Key(
                            'messaging-message-hover-conversation-id',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      ),
                    ),
                    if (timestampLabel != null) const SizedBox(width: 8),
                  ],
                  if (timestampLabel != null)
                    Text(
                      timestampLabel,
                      key: const Key('messaging-message-hover-timestamp'),
                      style: metaStyle,
                    ),
                ],
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
        : MessagingAgentBubble(
            key: const Key('messaging-message-bubble'),
            borderRadius: bubbleRadius,
            padding: bubblePadding,
            hovered: _hovered,
            agentKey: widget.agentKey,
            child: content,
          );
    final copyOverlay = widget.onCopyText == null
        ? bubble
        : Stack(
            clipBehavior: Clip.none,
            children: [
              bubble,
              Positioned(
                top: 4,
                right: widget.authorIsUser ? 4 : null,
                left: widget.authorIsUser ? null : 4,
                child: AnimatedOpacity(
                  opacity: _hovered ? 1 : 0,
                  duration: context.motion(LicoMotion.micro),
                  curve: LicoMotion.standard,
                  child: _buildCopyAction(context),
                ),
              ),
            ],
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
                  child: _buildMessageColumn(context, copyOverlay),
                ),
              )
            : Align(
                alignment: Alignment.centerLeft,
                child: _buildMessageColumn(context, copyOverlay),
              ),
      ),
    );
  }
}

class _MessagingAssistantAvatar extends StatelessWidget {
  const _MessagingAssistantAvatar({required this.accessibilityLabel});

  final String accessibilityLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Semantics(
      label: accessibilityLabel,
      child: Container(
        key: const Key('messaging-assistant-avatar'),
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.accentSurface,
          border: Border.all(color: colors.accentBorder, width: 1),
        ),
        child: AssistantSparklesIcon(color: colors.accent, size: 19),
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
      'assistant' => strings.assistantBadge,
      'member' || 'peer-agent' => strings.subagentBadge,
      'main-agent' => 'MAIN AGENT',
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
