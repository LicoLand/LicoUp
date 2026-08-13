import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// In-chat conversation switcher for the messaging header: a quiet icon
/// button that reveals the current agent's conversations on hover (desktop)
/// or in a modal bottom sheet on mobile. Reads like the history switcher of a
/// chat client, not a settings dialog.
class MessagingConversationSwitcher extends StatefulWidget {
  const MessagingConversationSwitcher({
    super.key,
    required this.sessions,
    required this.selectedSessionId,
    required this.onSelectConversation,
    required this.onNewConversation,
    this.runningFor,
    this.useBottomSheet = false,
  });

  final List<AgentConversationSession> sessions;
  final String selectedSessionId;
  final ValueChanged<String> onSelectConversation;
  final VoidCallback onNewConversation;

  /// Marks a conversation row as currently running (active turn).
  final bool Function(AgentConversationSession session)? runningFor;

  /// Mobile surfaces open the switcher as a bottom sheet instead of the
  /// hover card.
  final bool useBottomSheet;

  @override
  State<MessagingConversationSwitcher> createState() =>
      _MessagingConversationSwitcherState();
}

class _MessagingConversationSwitcherState
    extends State<MessagingConversationSwitcher> {
  void _openSheet() {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.6,
            ),
            child: MessagingConversationSwitcherContent(
              sessions: widget.sessions,
              selectedSessionId: widget.selectedSessionId,
              onSelectConversation: (sessionId) {
                Navigator.of(sheetContext).pop();
                widget.onSelectConversation(sessionId);
              },
              onNewConversation: () {
                Navigator.of(sheetContext).pop();
                widget.onNewConversation();
              },
              runningFor: widget.runningFor,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    if (widget.useBottomSheet) {
      return _SwitcherButton(
        key: const Key('messaging-conversation-switcher-button'),
        tooltip: strings.conversations,
        onPressed: _openSheet,
      );
    }
    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    return MessagingHoverPopover(
      popoverKey: const Key('messaging-conversation-switcher-panel'),
      width: 320,
      maxHeight: 420,
      borderRadius: menuRadius,
      cardBuilder: (context, close) {
        return MessagingConversationSwitcherContent(
          sessions: widget.sessions,
          selectedSessionId: widget.selectedSessionId,
          onSelectConversation: (sessionId) {
            close();
            widget.onSelectConversation(sessionId);
          },
          onNewConversation: () {
            close();
            widget.onNewConversation();
          },
          runningFor: widget.runningFor,
        );
      },
      triggerBuilder:
          (context, {required open, required toggle, required close}) {
            return _SwitcherButton(
              key: const Key('messaging-conversation-switcher-button'),
              tooltip: strings.conversations,
              onPressed: toggle,
            );
          },
    );
  }
}

class _SwitcherButton extends StatelessWidget {
  const _SwitcherButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
  });

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Tooltip(
      message: tooltip,
      waitDuration: LicoMotion.tooltipWait,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        hoverColor: colors.isDark
            ? Colors.white.withAlpha(10)
            : Colors.black.withAlpha(12),
        child: SizedBox.square(
          dimension: 32,
          child: Icon(Icons.forum_outlined, size: 19, color: colors.textMuted),
        ),
      ),
    );
  }
}

/// The shared switcher body: a "New conversation" row above the current
/// agent's conversations in recency order.
class MessagingConversationSwitcherContent extends StatelessWidget {
  const MessagingConversationSwitcherContent({
    super.key,
    required this.sessions,
    required this.selectedSessionId,
    required this.onSelectConversation,
    required this.onNewConversation,
    this.runningFor,
  });

  final List<AgentConversationSession> sessions;
  final String selectedSessionId;
  final ValueChanged<String> onSelectConversation;
  final VoidCallback onNewConversation;
  final bool Function(AgentConversationSession session)? runningFor;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final sorted = sortConversationSessionsByUpdatedAt(sessions);
    return SingleChildScrollView(
      key: const Key('messaging-conversation-switcher-content'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SwitcherNewConversationRow(onPressed: onNewConversation),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Text(
                strings.noConversationsYet,
                style: TextStyle(color: colors.textMuted, fontSize: 12.5),
              ),
            )
          else ...[
            Divider(height: 1, color: colors.line.withAlpha(90)),
            for (final session in sorted)
              _SwitcherConversationRow(
                key: ValueKey<String>('messaging-switcher-${session.id}'),
                session: session,
                selected: session.id == selectedSessionId,
                running: runningFor?.call(session) ?? false,
                onTap: () => onSelectConversation(session.id),
              ),
          ],
        ],
      ),
    );
  }
}

class _SwitcherNewConversationRow extends StatelessWidget {
  const _SwitcherNewConversationRow({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('messaging-switcher-new-conversation'),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.edit_square, size: 16, color: colors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.newConversation,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitcherConversationRow extends StatelessWidget {
  const _SwitcherConversationRow({
    super.key,
    required this.session,
    required this.selected,
    required this.running,
    required this.onTap,
  });

  final AgentConversationSession session;
  final bool selected;
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final preview = conversationMessagePreviewText(session.preview);
    final project = historySessionProjectLabel(
      session.workingDirectory,
      fallback: '',
    );
    final previewLine = preview.isEmpty
        ? project
        : project.isEmpty
        ? preview
        : '$preview · $project';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          hoverColor: colors.isDark
              ? Colors.white.withAlpha(8)
              : Colors.black.withAlpha(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              // Solid brand-yellow selection with dark foreground.
              color: selected ? colors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(LicoRadius.chip),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.title.trim().isEmpty
                            ? session.id
                            : session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? colors.textOnPrimary
                              : colors.textMuted,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      if (previewLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          previewLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? colors.textOnPrimary.withAlpha(180)
                                : colors.textMuted,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (running) ...[
                  const SizedBox(width: 8),
                  Container(
                    key: const Key('messaging-switcher-running-dot'),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? colors.textOnPrimary : colors.accent,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Text(
                  conversationSessionRelativeUpdatedAtLabel(session),
                  maxLines: 1,
                  style: TextStyle(
                    color: selected
                        ? colors.textOnPrimary.withAlpha(180)
                        : colors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
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
