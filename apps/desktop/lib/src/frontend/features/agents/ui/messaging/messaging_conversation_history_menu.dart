import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_session_ordering.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_list_typography.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Width of the floating conversation-history card.
const double messagingConversationHistoryMenuWidth = 300;

/// Shows the floating conversation history list at [globalPosition].
///
/// [sessions] may mix parent and child conversations; only top-level parent
/// sessions (`parentSessionId` empty) are listed — sub-agent threads merge
/// into their parent and never appear as separate history rows. Sessions are
/// grouped by the working directory's project name (never the full path) and,
/// inside each project, by the sidebar's existing time buckets.
///
/// `onNewConversation` renders a leading "New conversation" row when non-null;
/// pass null for a group member's in-group history where starting a detached
/// conversation would leave the group.
Future<void> showMessagingConversationHistoryMenu({
  required BuildContext context,
  required Offset globalPosition,
  required List<AgentConversationSession> sessions,
  required String selectedSessionId,
  required ValueChanged<String> onSelect,
  VoidCallback? onNewConversation,
  bool Function(AgentConversationSession session)? runningFor,
  Key? menuKey,
}) {
  final navigator = Navigator.of(context, rootNavigator: false);
  // The menu rides a route on the app navigator, outside the calling
  // shell's subtree — carry its selection treatment over.
  final treatment = LicoSelectionTreatmentScope.of(context);
  final typography = LicoListTypographyScope.of(context);
  return navigator.push<void>(
    _MessagingConversationHistoryRoute(
      globalPosition: globalPosition,
      sessions: sessions,
      selectedSessionId: selectedSessionId,
      onSelect: onSelect,
      onNewConversation: onNewConversation,
      runningFor: runningFor,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      menuKey: menuKey,
      treatment: treatment,
      typography: typography,
    ),
  );
}

/// One rendered row in the history list: a project header, a time-bucket
/// header inside a project, or a session row.
sealed class MessagingConversationHistoryEntry {
  const MessagingConversationHistoryEntry();
}

/// A project header: the working directory's final path segment only.
final class MessagingConversationHistoryProjectHeader
    extends MessagingConversationHistoryEntry {
  const MessagingConversationHistoryProjectHeader(this.label);

  final String label;
}

/// A time-bucket header inside one project group (today / yesterday /
/// weekday / earlier).
final class MessagingConversationHistoryTimeHeader
    extends MessagingConversationHistoryEntry {
  const MessagingConversationHistoryTimeHeader(this.label);

  final String label;
}

/// One selectable session row.
final class MessagingConversationHistorySessionEntry
    extends MessagingConversationHistoryEntry {
  const MessagingConversationHistorySessionEntry(this.session);

  final AgentConversationSession session;
}

/// Builds the ordered entry model: projects in first-seen (most recent)
/// order, each holding the sidebar's time buckets newest-first.
List<MessagingConversationHistoryEntry> messagingConversationHistoryEntries({
  required List<AgentConversationSession> sessions,
  required LicoStrings strings,
  DateTime? now,
}) {
  final parents = sortConversationSessionsByUpdatedAt(
    sessions.where((session) => session.parentSessionId.trim().isEmpty),
  );
  final nowLocal = now ?? DateTime.now();
  final groups = <String, List<AgentConversationSession>>{};
  final labels = <String, String>{};
  for (final session in parents) {
    final key = session.workingDirectory.trim();
    (groups[key] ??= <AgentConversationSession>[]).add(session);
    labels.putIfAbsent(
      key,
      () => historySessionProjectLabel(
        session.workingDirectory,
        fallback: strings.ungroupedConversationProject,
      ),
    );
  }
  final entries = <MessagingConversationHistoryEntry>[];
  for (final group in groups.entries) {
    entries.add(
      MessagingConversationHistoryProjectHeader(labels[group.key] ?? ''),
    );
    var bucket = '';
    for (final session in group.value) {
      final updated =
          DateTime.tryParse(session.updatedAt.trim())?.toLocal() ?? nowLocal;
      final label = switch (sidebarTimeGroupFor(updated, nowLocal)) {
        SidebarTimeGroup.today => strings.today,
        SidebarTimeGroup.yesterday => strings.yesterday,
        SidebarTimeGroup.weekday => strings.conversationWeekdayLabel(
          updated.weekday,
        ),
        SidebarTimeGroup.earlier => strings.earlier,
      };
      if (label != bucket) {
        bucket = label;
        entries.add(MessagingConversationHistoryTimeHeader(label));
      }
      entries.add(MessagingConversationHistorySessionEntry(session));
    }
  }
  return List<MessagingConversationHistoryEntry>.unmodifiable(entries);
}

final class _MessagingConversationHistoryRoute extends PopupRoute<void> {
  _MessagingConversationHistoryRoute({
    required this.globalPosition,
    required this.sessions,
    required this.selectedSessionId,
    required this.onSelect,
    required this.onNewConversation,
    required this.runningFor,
    required this.barrierLabel,
    required this.treatment,
    required this.typography,
    this.menuKey,
  });

  final Offset globalPosition;
  final List<AgentConversationSession> sessions;
  final String selectedSessionId;
  final ValueChanged<String> onSelect;
  final VoidCallback? onNewConversation;
  final bool Function(AgentConversationSession session)? runningFor;
  final Key? menuKey;
  final LicoSelectionTreatment treatment;

  /// The list typeface scale carried over from the calling shell.
  final LicoListTypography typography;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final padding = media.padding;
    final maxWidth = media.size.width - padding.horizontal - 16;
    return CustomSingleChildLayout(
      delegate: _HistoryMenuLayout(
        position: globalPosition,
        screenSize: media.size,
        padding: padding,
      ),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: Material(
          type: MaterialType.transparency,
          child: MessagingGlassOptionCard(
            key: menuKey ?? const Key('messaging-conversation-history-menu'),
            width: messagingConversationHistoryMenuWidth.clamp(160.0, maxWidth),
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: MessagingDesktopMetrics.composerOptionPopoverMaxHeight,
            ),
            padding: EdgeInsets.zero,
            child: LicoListTypographyScope(
              typography: typography,
              child: LicoSelectionTreatmentScope(
                treatment: treatment,
                child: _HistoryMenuBody(
                  sessions: sessions,
                  selectedSessionId: selectedSessionId,
                  onSelect: (sessionId) {
                    Navigator.of(context).pop();
                    onSelect(sessionId);
                  },
                  onNewConversation: onNewConversation == null
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          onNewConversation!();
                        },
                  runningFor: runningFor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _HistoryMenuLayout extends SingleChildLayoutDelegate {
  const _HistoryMenuLayout({
    required this.position,
    required this.screenSize,
    required this.padding,
  });

  final Offset position;
  final Size screenSize;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: screenSize.width - padding.horizontal - 16,
      maxHeight: (screenSize.height - padding.vertical - 16).clamp(
        48.0,
        screenSize.height,
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var dx = position.dx;
    var dy = position.dy;
    if (dx + childSize.width > screenSize.width - padding.right - 8) {
      dx = screenSize.width - padding.right - 8 - childSize.width;
    }
    if (dy + childSize.height > screenSize.height - padding.bottom - 8) {
      dy = screenSize.height - padding.bottom - 8 - childSize.height;
    }
    dx = dx.clamp(padding.left + 8, screenSize.width);
    dy = dy.clamp(padding.top + 8, screenSize.height);
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(covariant _HistoryMenuLayout oldDelegate) =>
      position != oldDelegate.position ||
      screenSize != oldDelegate.screenSize ||
      padding != oldDelegate.padding;
}

final class _HistoryMenuBody extends StatelessWidget {
  const _HistoryMenuBody({
    required this.sessions,
    required this.selectedSessionId,
    required this.onSelect,
    required this.onNewConversation,
    required this.runningFor,
  });

  final List<AgentConversationSession> sessions;
  final String selectedSessionId;
  final ValueChanged<String> onSelect;
  final VoidCallback? onNewConversation;
  final bool Function(AgentConversationSession session)? runningFor;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final entries = messagingConversationHistoryEntries(
      sessions: sessions,
      strings: strings,
      now: conversationNow(),
    );
    return SingleChildScrollView(
      key: const Key('messaging-conversation-history-scroll'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onNewConversation != null)
            _HistoryNewConversationRow(onPressed: onNewConversation!),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Text(
                strings.noConversationsYet,
                style: TextStyle(color: colors.textMuted, fontSize: 12.5),
              ),
            )
          else
            for (final entry in entries)
              switch (entry) {
                MessagingConversationHistoryProjectHeader(:final label) =>
                  _HistoryGroupLabel(label: label, project: true),
                MessagingConversationHistoryTimeHeader(:final label) =>
                  _HistoryGroupLabel(label: label, project: false),
                MessagingConversationHistorySessionEntry(:final session) =>
                  _HistorySessionRow(
                    key: ValueKey<String>(
                      'messaging-history-session-${session.id}',
                    ),
                    session: session,
                    selected: session.id == selectedSessionId,
                    running: runningFor?.call(session) ?? false,
                    onTap: () => onSelect(session.id),
                  ),
              },
        ],
      ),
    );
  }
}

final class _HistoryNewConversationRow extends StatelessWidget {
  const _HistoryNewConversationRow({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('messaging-history-new-conversation'),
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

final class _HistoryGroupLabel extends StatelessWidget {
  const _HistoryGroupLabel({required this.label, required this.project});

  final String label;

  /// Project headers are primary group labels; time buckets render one level
  /// quieter inside their project.
  final bool project;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(project ? 12 : 20, 8, 12, 2),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: project ? 11.5 : 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

final class _HistorySessionRow extends StatelessWidget {
  const _HistorySessionRow({
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
    final strings = LicoStrings.of(context);
    final preview = conversationMessagePreviewText(
      session.preview,
      chinese: strings.isChinese,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          hoverColor: LicoSelectionLight.hoverFill(context),
          child: LicoSelectionLight(
            selected: selected,
            radius: LicoRadius.chip,
            child: AnimatedContainer(
              duration: context.motion(LicoMotion.micro),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(LicoRadius.chip),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          historySessionDisplayTitle(
                            session.title.trim().isEmpty
                                ? session.id
                                : session.title,
                            fallback: strings.untitledConversation,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                selected &&
                                    !LicoSelectionLight.isStarlight(context)
                                ? colors.selectionInk
                                : colors.text,
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                        if (preview.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  selected &&
                                      !LicoSelectionLight.isStarlight(context)
                                  ? colors.selectionInk.withAlpha(180)
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
                      key: const Key('messaging-history-running-dot'),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? colors.selectionInk : colors.accent,
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Text(
                    conversationSessionRelativeUpdatedAtLabel(session),
                    maxLines: 1,
                    style: TextStyle(
                      color: selected
                          ? colors.selectionInk.withAlpha(180)
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
      ),
    );
  }
}
