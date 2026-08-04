import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Messaging contact list: one row per local conversation agent, like the
/// contact list of a messaging app. Merged products (for example Codex CLI
/// and Codex Desktop) stay one contact with the group representative's brand
/// icon. Rows carry the latest conversation's preview and relative activity
/// time, sort by most recent activity, and tapping a contact lands on that
/// agent's new-conversation home (old conversations stay reachable through
/// the recent list and the switcher).
class MessagingContactList extends StatefulWidget {
  const MessagingContactList({
    super.key,
    required this.targets,
    required this.sessionsByAgent,
    required this.selectedAgentId,
    required this.activityFor,
    required this.onSelectAgent,
    required this.onNewConversation,
    this.onPrefetchSessions,
    this.scanning = false,
    this.loading = false,
  });

  final List<TargetCandidate> targets;
  final Map<String, List<AgentConversationSession>> sessionsByAgent;
  final String selectedAgentId;
  final AgentConversationTabActivity Function(String agentId) activityFor;

  /// Activates an agent, landing on its new-conversation home. Old
  /// conversations stay reachable through the recent list and the switcher.
  final ValueChanged<String> onSelectAgent;
  final VoidCallback onNewConversation;

  /// Kicks a first-page session load for one agent. Invoked once on first
  /// build for every conversation agent without loaded sessions, mirroring
  /// the search palette prefetch.
  final ValueChanged<String>? onPrefetchSessions;
  final bool scanning;
  final bool loading;

  @override
  State<MessagingContactList> createState() => _MessagingContactListState();
}

class _MessagingContactListState extends State<MessagingContactList> {
  bool _prefetched = false;

  @override
  void initState() {
    super.initState();
    _prefetchUnloadedSessions();
  }

  void _prefetchUnloadedSessions() {
    if (_prefetched) {
      return;
    }
    _prefetched = true;
    final prefetch = widget.onPrefetchSessions;
    if (prefetch == null) {
      return;
    }
    for (final target in widget.targets) {
      if (!target.isConversationAgent) {
        continue;
      }
      final loaded = widget.sessionsByAgent[target.id];
      if (loaded == null || loaded.isEmpty) {
        prefetch(target.id);
      }
    }
  }

  /// Targets that share a canonical product name collapse into one contact,
  /// mirroring the tree sidebar's agent grouping; the first target in the
  /// incoming order represents the contact and supplies its brand icon.
  List<_MessagingContactGroup> _groups() {
    final groups = <_MessagingContactGroup>[];
    final indexByName = <String, int>{};
    for (final target in widget.targets) {
      final name = agentConversationTargetDisplayName(target);
      final key = name.toLowerCase();
      final index = indexByName[key];
      if (index == null) {
        indexByName[key] = groups.length;
        groups.add(_MessagingContactGroup(name, [target]));
      } else {
        groups[index].members.add(target);
      }
    }
    return groups;
  }

  /// One contact per agent group with its most recent conversation resolved
  /// through the session-map key — the same ownership resolution the tree
  /// sidebar uses. `session.agentId` is native-history metadata and is
  /// deliberately not used for ownership.
  List<_MessagingContactEntry> _entries() {
    final entries = <_MessagingContactEntry>[];
    for (final group in _groups()) {
      final sessions = <AgentConversationSession>[];
      final seenSessionIds = <String>{};
      for (final member in group.members) {
        final memberSessions =
            widget.sessionsByAgent[member.id] ??
            widget.sessionsByAgent[member.target] ??
            const <AgentConversationSession>[];
        for (final session in memberSessions) {
          if (seenSessionIds.add(session.id)) {
            sessions.add(session);
          }
        }
      }
      AgentConversationSession? latest;
      if (sessions.isNotEmpty) {
        latest = sortConversationSessionsByUpdatedAt(sessions).first;
      }
      entries.add(
        _MessagingContactEntry(
          group: group,
          latestSession: latest,
          activity: group.members
              .map((member) => widget.activityFor(member.id))
              .firstWhere(
                (value) => value != AgentConversationTabActivity.none,
                orElse: () => AgentConversationTabActivity.none,
              ),
        ),
      );
    }
    entries.sort((left, right) {
      final leftTime = left.latestSession == null
          ? -1
          : conversationSessionSortTime(left.latestSession!);
      final rightTime = right.latestSession == null
          ? -1
          : conversationSessionSortTime(right.latestSession!);
      return rightTime.compareTo(leftTime);
    });
    return List<_MessagingContactEntry>.unmodifiable(entries);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final entries = _entries();
    return ColoredBox(
      key: const Key('messaging-contact-list'),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
            child: SizedBox(
              height: 36,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      strings.contacts,
                      key: const Key('messaging-contact-list-heading'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _MessagingContactActionButton(
                    key: const Key('messaging-new-conversation'),
                    tooltip: strings.newConversation,
                    onPressed: widget.onNewConversation,
                    icon: Icons.edit_square,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? _MessagingContactListEmpty(
                    scanning: widget.scanning,
                    loading: widget.loading,
                  )
                : ScrollConfiguration(
                    behavior: const _MessagingSlimScrollbarBehavior(),
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return _MessagingContactRow(
                          key: ValueKey<String>(
                            'messaging-contact-${entry.group.members.first.id}',
                          ),
                          entry: entry,
                          selected: entry.group.members.any(
                            (member) =>
                                member.id == widget.selectedAgentId ||
                                member.target == widget.selectedAgentId,
                          ),
                          onTap: () => widget.onSelectAgent(
                            entry.group.members.first.id,
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One contact row: the agent group plus its most recent conversation.
final class _MessagingContactEntry {
  const _MessagingContactEntry({
    required this.group,
    required this.latestSession,
    required this.activity,
  });

  final _MessagingContactGroup group;
  final AgentConversationSession? latestSession;
  final AgentConversationTabActivity activity;
}

/// Targets merged under one canonical product name, mirroring the tree
/// sidebar's agent grouping.
final class _MessagingContactGroup {
  _MessagingContactGroup(this.displayName, this.members);

  final String displayName;
  final List<TargetCandidate> members;
}

class _MessagingContactActionButton extends StatelessWidget {
  const _MessagingContactActionButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        hoverColor: colors.isDark
            ? Colors.white.withAlpha(10)
            : Colors.black.withAlpha(12),
        child: SizedBox.square(
          dimension: 30,
          child: Icon(icon, size: 17, color: colors.textMuted),
        ),
      ),
    );
  }
}

class _MessagingContactListEmpty extends StatelessWidget {
  const _MessagingContactListEmpty({
    required this.scanning,
    required this.loading,
  });

  final bool scanning;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      key: const Key('messaging-contact-list-empty'),
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.people_outline_rounded, size: 22, color: colors.textMuted),
          const SizedBox(height: 10),
          Text(
            scanning || loading
                ? strings.scanningLocalAgents
                : strings.noLocalAgentsFound,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            strings.messagingEmptyConversationGuide,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _MessagingContactRow extends StatelessWidget {
  const _MessagingContactRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _MessagingContactEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final latest = entry.latestSession;
    String subtitle;
    if (latest == null) {
      subtitle = strings.noConversationsYet;
    } else {
      final preview = conversationMessagePreviewText(latest.preview);
      final project = historySessionProjectLabel(
        latest.workingDirectory,
        fallback: '',
      );
      subtitle = preview.isEmpty
          ? project
          : project.isEmpty
          ? preview
          : '$preview · $project';
      if (subtitle.isEmpty) {
        subtitle = latest.title.trim().isEmpty ? latest.id : latest.title;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          hoverColor: colors.isDark
              ? Colors.white.withAlpha(8)
              : Colors.black.withAlpha(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              // Solid brand-yellow selection with dark foreground — the
              // user-chosen 黄底黑字 rule, not a muted alpha tint.
              color: selected ? colors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                MessagingAgentAvatar(
                  target: entry.group.members.first,
                  activity: entry.activity,
                  size: 40,
                  iconSize: 22,
                  onSolidAccent: selected,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.group.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: selected
                                    ? colors.textOnPrimary
                                    : colors.text,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (latest != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              conversationSessionRelativeUpdatedAtLabel(latest),
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
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? colors.textOnPrimary.withAlpha(180)
                              : colors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
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

/// Slim, low-key scrollbar for the contact list: thin 3px thumb that fades
/// out after scrolling instead of a permanently thick desktop scrollbar.
final class _MessagingSlimScrollbarBehavior extends MaterialScrollBehavior {
  const _MessagingSlimScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final colors = context.licoColors;
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(colors.textMuted.withAlpha(70)),
      ),
      child: Scrollbar(
        controller: details.controller,
        thickness: 3,
        radius: const Radius.circular(1.5),
        interactive: true,
        child: child,
      ),
    );
  }
}
