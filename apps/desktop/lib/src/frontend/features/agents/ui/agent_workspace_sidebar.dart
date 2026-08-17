import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// Second-layer conversation list: a flat, newest-first list of every
/// conversation across agents, grouped into muted time sections (today,
/// yesterday, this week's weekdays, earlier) — the Atlas-style sidebar.
/// Merged products (for example Codex CLI and Codex Desktop) share one brand
/// icon resolved through the session-map key, never through native-history
/// metadata. The Earlier section starts collapsed so the list stays focused
/// on the current week.
class AgentsWorkspaceSidebar extends StatefulWidget {
  const AgentsWorkspaceSidebar({
    super.key,
    required this.targets,
    required this.sessionsByAgent,
    required this.selectedSessionId,
    required this.activityFor,
    required this.onSelectSession,
    required this.onNewConversation,
    this.runningFor,
    this.onPrefetchSessions,
    this.onArchive,
    this.onAddTarget,
    this.onRefresh,
    this.allowManualTargetActions = true,
    this.scanning = false,
    this.adding = false,
    this.refreshing = false,
  });

  final List<TargetCandidate> targets;
  final Map<String, List<AgentConversationSession>> sessionsByAgent;
  final String selectedSessionId;
  final AgentConversationTabActivity Function(String agentId) activityFor;
  final void Function(String agentId, String sessionId) onSelectSession;
  final VoidCallback onNewConversation;
  final bool Function(AgentConversationSession session)? runningFor;

  /// Kicks a first-page session load for one agent. Invoked once on first
  /// build for every conversation agent without loaded sessions, mirroring
  /// the messaging contact list's prefetch.
  final ValueChanged<String>? onPrefetchSessions;
  final VoidCallback? onArchive;
  final VoidCallback? onAddTarget;

  /// Reloads the conversation list. Wired to the header refresh button that
  /// sits immediately left of the manual-target actions button.
  final VoidCallback? onRefresh;
  final bool allowManualTargetActions;
  final bool scanning;
  final bool adding;
  final bool refreshing;

  @override
  State<AgentsWorkspaceSidebar> createState() => _AgentsWorkspaceSidebarState();
}

class _AgentsWorkspaceSidebarState extends State<AgentsWorkspaceSidebar> {
  bool _prefetched = false;
  bool _earlierExpanded = false;

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
      final loaded =
          widget.sessionsByAgent[target.id] ??
          widget.sessionsByAgent[target.target];
      if (loaded == null || loaded.isEmpty) {
        prefetch(target.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final entries = flattenSidebarConversations(
      targets: widget.targets,
      sessionsByAgent: widget.sessionsByAgent,
      activityFor: widget.activityFor,
    );
    return ColoredBox(
      key: const Key('agents-workspace-sidebar'),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title bar matches the conversation pane header in height (64) and
          // center line, and its divider aligns with the pane's exactly.
          SizedBox(
            height: conversationHeaderHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.agentsSidebarConversations,
                          key: const Key(
                            'agents-sidebar-conversations-heading',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          strings.conversationCount(entries.length),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 1.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onRefresh != null) ...[
                    _SidebarActionButton(
                      key: const Key('agents-sidebar-refresh'),
                      tooltip: strings.refresh,
                      onPressed: widget.refreshing ? null : widget.onRefresh,
                      icon: Icons.refresh_rounded,
                    ),
                    if (widget.allowManualTargetActions &&
                        widget.onAddTarget != null)
                      const SizedBox(width: 8),
                  ],
                  if (widget.allowManualTargetActions &&
                      widget.onAddTarget != null)
                    _SidebarActionButton(
                      key: const Key('agents-sidebar-add-target'),
                      tooltip: strings.addTarget,
                      onPressed: widget.adding ? null : widget.onAddTarget,
                      icon: Icons.more_horiz_rounded,
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
            child: _NewConversationGuideButton(
              onPressed: widget.onNewConversation,
              label: strings.newConversation,
            ),
          ),
          if (widget.onArchive != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: _NewConversationGuideButton(
                onPressed: widget.onArchive!,
                label: strings.backupConversations,
                icon: Icons.archive_outlined,
                buttonKey: const Key('agents-sidebar-backup-conversations'),
              ),
            ),
          Expanded(
            child: widget.targets.isEmpty
                ? _SidebarEmptyAgents(
                    scanning: widget.scanning,
                    adding: widget.adding,
                    allowManualTargetActions: widget.allowManualTargetActions,
                    onAddTarget: widget.onAddTarget,
                  )
                : SidebarConversationListView(
                    entries: entries,
                    selectedSessionId: widget.selectedSessionId,
                    earlierExpanded: _earlierExpanded,
                    showAgentIcons: true,
                    runningFor: widget.runningFor,
                    onToggleEarlier: () =>
                        setState(() => _earlierExpanded = !_earlierExpanded),
                    onSelectSession: widget.onSelectSession,
                  ),
          ),
        ],
      ),
    );
  }
}

/// One flattened conversation row: the session, the target that owns it
/// through the session-map key, the product-group representative that
/// supplies the brand icon, and the owning group's activity signal.
class SidebarConversationEntry {
  const SidebarConversationEntry({
    required this.session,
    required this.owner,
    required this.brandTarget,
    required this.brandDetected,
    required this.activity,
  });

  final AgentConversationSession session;
  final TargetCandidate owner;
  final TargetCandidate brandTarget;
  final bool brandDetected;
  final AgentConversationTabActivity activity;
}

/// Targets that share a canonical product name collapse into one group; the
/// first target in the incoming order represents the group's brand.
List<List<TargetCandidate>> mergeSidebarTargetGroups(
  List<TargetCandidate> targets,
) {
  final groups = <List<TargetCandidate>>[];
  final indexByName = <String, int>{};
  for (final target in targets) {
    if (!target.isConversationAgent) {
      continue;
    }
    final name = agentConversationTargetDisplayName(target).toLowerCase();
    final index = indexByName[name];
    if (index == null) {
      indexByName[name] = groups.length;
      groups.add([target]);
    } else {
      groups[index].add(target);
    }
  }
  return groups;
}

/// Flattens every agent group's sessions into one newest-first list. Rows
/// are deduplicated by session id and by native session id, so merged
/// products never surface the same conversation twice; the first occurrence
/// wins the ownership resolution.
List<SidebarConversationEntry> flattenSidebarConversations({
  required List<TargetCandidate> targets,
  required Map<String, List<AgentConversationSession>> sessionsByAgent,
  required AgentConversationTabActivity Function(String agentId) activityFor,
}) {
  final entries = <SidebarConversationEntry>[];
  final seenSessionIds = <String>{};
  final seenNativeSessionIds = <String>{};
  for (final members in mergeSidebarTargetGroups(targets)) {
    final activity = members
        .map((member) => activityFor(member.id))
        .firstWhere(
          (value) => value != AgentConversationTabActivity.none,
          orElse: () => AgentConversationTabActivity.none,
        );
    final detected = members.any(
      (member) => member.status == 'detected' || member.configured,
    );
    for (final member in members) {
      final memberSessions =
          sessionsByAgent[member.id] ??
          sessionsByAgent[member.target] ??
          const <AgentConversationSession>[];
      for (final session in memberSessions) {
        if (!seenSessionIds.add(session.id)) {
          continue;
        }
        final nativeSessionId = session.nativeSessionId.trim();
        if (nativeSessionId.isNotEmpty &&
            !seenNativeSessionIds.add(nativeSessionId)) {
          continue;
        }
        entries.add(
          SidebarConversationEntry(
            session: session,
            owner: member,
            brandTarget: members.first,
            brandDetected: detected,
            activity: activity,
          ),
        );
      }
    }
  }
  entries.sort(
    (left, right) => conversationSessionSortTime(
      right.session,
    ).compareTo(conversationSessionSortTime(left.session)),
  );
  return List<SidebarConversationEntry>.unmodifiable(entries);
}

/// The time bucket a conversation update falls into. [weekday] covers the
/// current calendar week (Monday-based) outside today and yesterday.
enum SidebarTimeGroup { today, yesterday, weekday, earlier }

SidebarTimeGroup sidebarTimeGroupFor(DateTime updatedLocal, DateTime nowLocal) {
  final today = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
  final date = DateTime(
    updatedLocal.year,
    updatedLocal.month,
    updatedLocal.day,
  );
  if (date == today) {
    return SidebarTimeGroup.today;
  }
  if (date == today.subtract(const Duration(days: 1))) {
    return SidebarTimeGroup.yesterday;
  }
  final weekStart = today.subtract(Duration(days: today.weekday - 1));
  if (!date.isBefore(weekStart)) {
    return SidebarTimeGroup.weekday;
  }
  return SidebarTimeGroup.earlier;
}

class SidebarConversationListView extends StatelessWidget {
  const SidebarConversationListView({
    super.key,
    required this.entries,
    required this.selectedSessionId,
    required this.earlierExpanded,
    required this.onToggleEarlier,
    required this.onSelectSession,
    this.runningFor,
    this.showAgentIcons = true,
  });

  final List<SidebarConversationEntry> entries;
  final String selectedSessionId;
  final bool earlierExpanded;
  final VoidCallback onToggleEarlier;
  final void Function(String agentId, String sessionId) onSelectSession;
  final bool Function(AgentConversationSession session)? runningFor;
  final bool showAgentIcons;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final now = DateTime.now();
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Text(
          strings.noConversationsYet,
          style: TextStyle(color: colors.textMuted, fontSize: 12),
        ),
      );
    }
    final items = <Widget>[];
    final runningSessionIds = <String>{};
    final runningEntries = entries
        .where((entry) {
          final running = runningFor?.call(entry.session) ?? false;
          if (running) runningSessionIds.add(entry.session.id);
          return running;
        })
        .toList(growable: false);
    if (runningEntries.isNotEmpty) {
      items.add(
        LicoGroupHeader(
          label: strings.priority,
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
        ),
      );
      for (final entry in runningEntries) {
        items.add(
          _SidebarConversationRow(
            key: Key('agents-sidebar-conversation-${entry.session.id}'),
            entry: entry,
            selected: entry.session.id == selectedSessionId,
            running: true,
            showAgentIcon: showAgentIcons,
            onTap: () => onSelectSession(entry.owner.id, entry.session.id),
          ),
        );
      }
    }
    var currentHeader = '';
    var earlierCount = 0;
    var earlierHeaderIndex = -1;
    // A selected conversation stays visible: when it lives in Earlier, the
    // group renders expanded even before the user opens it.
    var earlierContainsSelected = false;
    for (final entry in entries) {
      if (runningSessionIds.contains(entry.session.id)) {
        continue;
      }
      final updated =
          DateTime.tryParse(entry.session.updatedAt.trim())?.toLocal() ?? now;
      final group = sidebarTimeGroupFor(updated, now);
      final header = switch (group) {
        SidebarTimeGroup.today => strings.today,
        SidebarTimeGroup.yesterday => strings.yesterday,
        SidebarTimeGroup.weekday => strings.conversationWeekdayLabel(
          updated.weekday,
        ),
        SidebarTimeGroup.earlier => strings.earlier,
      };
      if (group == SidebarTimeGroup.earlier) {
        // The Earlier section starts collapsed: its rows only appear after
        // the user expands the header, keeping the list focused on the week.
        earlierCount += 1;
        if (entry.session.id == selectedSessionId) {
          earlierContainsSelected = true;
        }
        if (currentHeader != header) {
          currentHeader = header;
          earlierHeaderIndex = items.length;
          items.add(const SizedBox.shrink());
        }
        if (earlierExpanded || earlierContainsSelected) {
          items.add(
            _SidebarConversationRow(
              key: Key('agents-sidebar-conversation-${entry.session.id}'),
              entry: entry,
              selected: entry.session.id == selectedSessionId,
              running: runningFor?.call(entry.session) ?? false,
              showAgentIcon: showAgentIcons,
              onTap: () => onSelectSession(entry.owner.id, entry.session.id),
            ),
          );
        }
        continue;
      }
      if (header != currentHeader) {
        currentHeader = header;
        items.add(
          LicoGroupHeader(
            label: header,
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
          ),
        );
      }
      items.add(
        _SidebarConversationRow(
          key: Key('agents-sidebar-conversation-${entry.session.id}'),
          entry: entry,
          selected: entry.session.id == selectedSessionId,
          running: runningFor?.call(entry.session) ?? false,
          showAgentIcon: showAgentIcons,
          onTap: () => onSelectSession(entry.owner.id, entry.session.id),
        ),
      );
    }
    if (earlierHeaderIndex >= 0) {
      items[earlierHeaderIndex] = LicoGroupHeader(
        label: strings.earlier,
        count: earlierCount,
        expanded: earlierExpanded || earlierContainsSelected,
        onToggle: onToggleEarlier,
        toggleKey: const Key('agents-sidebar-earlier-toggle'),
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      children: items,
    );
  }
}

class _SidebarConversationRow extends StatelessWidget {
  const _SidebarConversationRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.running,
    required this.showAgentIcon,
    required this.onTap,
  });

  final SidebarConversationEntry entry;
  final bool selected;
  final bool running;
  final bool showAgentIcon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final session = entry.session;
    final title = session.title.trim().isEmpty ? session.id : session.title;
    final project = historySessionProjectLabel(
      session.workingDirectory,
      fallback: strings.ungroupedConversationProject,
    );
    final activityColor = switch (entry.activity) {
      AgentConversationTabActivity.needsApproval => colors.warning,
      AgentConversationTabActivity.workFinished => colors.accent,
      AgentConversationTabActivity.none => null,
    };
    final activityTooltip = switch (entry.activity) {
      AgentConversationTabActivity.needsApproval =>
        strings.agentTabNeedsApproval,
      AgentConversationTabActivity.workFinished => strings.agentTabWorkFinished,
      AgentConversationTabActivity.none => '',
    };
    final activityDot = activityColor == null
        ? null
        : Container(
            key: Key('agents-sidebar-activity-${session.id}'),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: activityColor,
            ),
          );
    final titleColor = colors.text;
    final subtitleColor = colors.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
          hoverColor: colors.isDark
              ? Colors.white.withAlpha(8)
              : Colors.black.withAlpha(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              // Neutral gray-white selection tint for this list — solid brand
              // yellow reads too loud against the dashboard's dark panes.
              color: selected
                  ? (colors.isDark
                        ? Colors.white.withAlpha(26)
                        : Colors.black.withAlpha(16))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(LicoRadius.floating),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                          height: 1.25,
                        ),
                      ),
                    ),
                    if (running)
                      Tooltip(
                        message: strings.working,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: SizedBox.square(
                            key: Key('agents-sidebar-running-${session.id}'),
                            dimension: 13,
                            child: LicoSpinningRefreshIcon(
                              size: 13,
                              color: selected ? colors.text : colors.textMuted,
                            ),
                          ),
                        ),
                      )
                    else if (activityDot != null)
                      Tooltip(
                        message: activityTooltip,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child:
                              entry.activity ==
                                  AgentConversationTabActivity.workFinished
                              ? _SidebarPulsingActivityDot(child: activityDot)
                              : activityDot,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (showAgentIcon) ...[
                      AgentBrandIcon(
                        target: entry.brandTarget,
                        size: 14,
                        iconSize: 10,
                        selected: selected,
                        detected: entry.brandDetected,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        project,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: subtitleColor,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w400,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarPulsingActivityDot extends StatefulWidget {
  const _SidebarPulsingActivityDot({required this.child});

  final Widget child;

  @override
  State<_SidebarPulsingActivityDot> createState() =>
      _SidebarPulsingActivityDotState();
}

class _SidebarPulsingActivityDotState extends State<_SidebarPulsingActivityDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: LicoMotion.loopLong,
    );
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _opacity = Tween<double>(begin: 0.48, end: 1).animate(curve);
    _scale = Tween<double>(begin: 0.82, end: 1.18).animate(curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

class _NewConversationGuideButton extends StatelessWidget {
  const _NewConversationGuideButton({
    required this.onPressed,
    required this.label,
    this.icon = Icons.edit_square,
    this.buttonKey = const Key('agents-sidebar-new-conversation'),
  });

  final VoidCallback onPressed;
  final String label;
  final IconData icon;
  final Key buttonKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final interactionColor = colors.isDark
        ? Colors.white.withAlpha(12)
        : Colors.black.withAlpha(12);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: buttonKey,
        onTap: onPressed,
        borderRadius: BorderRadius.circular(LicoRadius.floating),
        hoverColor: interactionColor,
        focusColor: interactionColor,
        splashColor: colors.primary.withAlpha(20),
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              children: [
                Icon(icon, size: 18, color: colors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
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
      ),
    );
  }
}

class _SidebarActionButton extends StatelessWidget {
  const _SidebarActionButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return LicoIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      size: LicoIconButtonSize.large,
      tone: LicoIconButtonTone.outlined,
      icon: Icon(icon),
    );
  }
}

class _SidebarEmptyAgents extends StatelessWidget {
  const _SidebarEmptyAgents({
    required this.scanning,
    required this.adding,
    required this.allowManualTargetActions,
    required this.onAddTarget,
  });

  final bool scanning;
  final bool adding;
  final bool allowManualTargetActions;
  final VoidCallback? onAddTarget;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            scanning ? strings.scanningLocalAgents : strings.noLocalAgentsFound,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          if (allowManualTargetActions && onAddTarget != null) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: adding ? null : onAddTarget,
              icon: const Icon(Icons.add, size: 16),
              label: Text(strings.addTarget),
            ),
          ],
        ],
      ),
    );
  }
}
