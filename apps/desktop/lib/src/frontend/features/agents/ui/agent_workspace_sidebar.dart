import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_session_ordering.dart';
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
  final SidebarConversationFlattenMemo _flattenMemo =
      SidebarConversationFlattenMemo();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchUnloadedSessions();
    });
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
    final entries = _flattenMemo.flatten(
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
  // Precompute one sort key per entry: parsing timestamps inside the
  // comparator would cost O(N log N) date parses on every rebuild.
  final sortTimeByEntry = <SidebarConversationEntry, int>{
    for (final entry in entries)
      entry: conversationSessionSortTime(entry.session),
  };
  entries.sort(
    (left, right) => sortTimeByEntry[right]!.compareTo(sortTimeByEntry[left]!),
  );
  return List<SidebarConversationEntry>.unmodifiable(entries);
}

/// Identity-keyed memo for [flattenSidebarConversations].
///
/// Workspace rebuilds re-run on every projection publish while a turn streams,
/// but the flatten inputs — the target list elements, each per-agent session
/// list, and each agent's activity signal — keep their identity when nothing
/// changed. Reusing the sorted entries then skips the O(N log N) sort and the
/// per-session timestamp parsing on every rebuild that changes nothing the
/// sidebar shows. The activity signature covers the closure-based [activityFor]
/// input, whose identity changes on every build even when its results do not.
final class SidebarConversationFlattenMemo {
  List<TargetCandidate>? _targets;
  Map<String, List<AgentConversationSession>>? _sessionsByAgent;
  String _activitySignature = '';
  List<SidebarConversationEntry> _entries = const [];

  List<SidebarConversationEntry> flatten({
    required List<TargetCandidate> targets,
    required Map<String, List<AgentConversationSession>> sessionsByAgent,
    required AgentConversationTabActivity Function(String agentId) activityFor,
  }) {
    final activitySignature = sidebarActivitySignature(targets, activityFor);
    final cachedTargets = _targets;
    final cachedSessions = _sessionsByAgent;
    if (cachedTargets != null &&
        cachedSessions != null &&
        _activitySignature == activitySignature &&
        _targetListsEquivalent(cachedTargets, targets) &&
        _sessionMapsEquivalent(cachedSessions, sessionsByAgent)) {
      return _entries;
    }
    final entries = flattenSidebarConversations(
      targets: targets,
      sessionsByAgent: sessionsByAgent,
      activityFor: activityFor,
    );
    _targets = targets;
    _sessionsByAgent = sessionsByAgent;
    _activitySignature = activitySignature;
    _entries = entries;
    return entries;
  }
}

/// The per-agent activity values [flattenSidebarConversations] would observe,
/// serialized so a rebuild with fresh closures but unchanged signals still
/// hits the memo.
String sidebarActivitySignature(
  List<TargetCandidate> targets,
  AgentConversationTabActivity Function(String agentId) activityFor,
) {
  final signature = StringBuffer();
  for (final target in targets) {
    if (!target.isConversationAgent) {
      continue;
    }
    signature
      ..write(target.id)
      ..write('=')
      ..write(activityFor(target.id).name)
      ..write(';');
  }
  return signature.toString();
}

bool _targetListsEquivalent(
  List<TargetCandidate> cached,
  List<TargetCandidate> next,
) {
  if (identical(cached, next)) {
    return true;
  }
  if (cached.length != next.length) {
    return false;
  }
  for (var index = 0; index < cached.length; index += 1) {
    if (!identical(cached[index], next[index])) {
      return false;
    }
  }
  return true;
}

bool _sessionMapsEquivalent(
  Map<String, List<AgentConversationSession>> cached,
  Map<String, List<AgentConversationSession>> next,
) {
  if (identical(cached, next)) {
    return true;
  }
  if (cached.length != next.length) {
    return false;
  }
  for (final entry in cached.entries) {
    if (!identical(next[entry.key], entry.value)) {
      return false;
    }
  }
  return true;
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

/// One item in the sidebar's lazy conversation list: a section header or a
/// conversation row. The item model carries resolved structure only — labels
/// and callbacks attach at build time so the memoized list stays valid across
/// locale and closure identity changes.
sealed class SidebarListItem {
  const SidebarListItem();
}

/// The section headers the sidebar list renders, in encounter order.
enum SidebarSectionHeaderKind {
  priority,
  today,
  yesterday,
  weekday,
  earlier,
  otherConversations,
}

/// A section header in the sidebar list.
final class SidebarSectionHeaderItem extends SidebarListItem {
  const SidebarSectionHeaderItem(this.kind, {this.weekday = 0, this.count})
    : expanded = null;

  /// Collapsible headers (Earlier, Other conversations) also carry the
  /// current expansion state for their chevron.
  const SidebarSectionHeaderItem.collapsible(
    this.kind, {
    required bool this.expanded,
    required this.count,
  }) : weekday = 0;

  final SidebarSectionHeaderKind kind;

  /// `DateTime.weekday` (1-7) backing a [SidebarSectionHeaderKind.weekday]
  /// label; zero for every other kind.
  final int weekday;

  /// Trailing tally for the collapsible sections (Earlier, Other
  /// conversations); null elsewhere.
  final int? count;

  /// Chevron state for the collapsible sections; null for plain labels.
  final bool? expanded;
}

/// A conversation row in the sidebar list.
final class SidebarConversationRowItem extends SidebarListItem {
  const SidebarConversationRowItem(this.entry);

  final SidebarConversationEntry entry;
}

/// Builds the flat item model [SidebarConversationListView] renders: the
/// priority section (pinned group-assistant thread plus running rows), the
/// time-bucket groups with the collapsible Earlier section, and the optional
/// collapsed "Other conversations" section for unrelated agents. This is the
/// exact structural pass the eager list performed per build, kept as a pure
/// function so the widget can memoize it on its inputs' identity.
List<SidebarListItem> buildSidebarListItems({
  required List<SidebarConversationEntry> entries,
  required String selectedSessionId,
  required bool earlierExpanded,
  required bool Function(AgentConversationSession session)? runningFor,
  required String priorityAgentId,
  required Set<String>? relatedAgentIds,
  required bool otherConversationsExpanded,
  required DateTime now,
}) {
  bool isRelated(SidebarConversationEntry entry) {
    if (relatedAgentIds == null) return true;
    return relatedAgentIds.contains(entry.owner.id) ||
        relatedAgentIds.contains(entry.owner.target) ||
        relatedAgentIds.contains(entry.brandTarget.id) ||
        relatedAgentIds.contains(entry.brandTarget.target);
  }

  final primaryEntries = entries.where(isRelated).toList(growable: false);
  final otherEntries = relatedAgentIds == null
      ? const <SidebarConversationEntry>[]
      : entries.where((entry) => !isRelated(entry)).toList(growable: false);
  final items = <SidebarListItem>[];
  final runningSessionIds = <String>{};
  // The assistant's latest thread pins above everything else by default:
  // entries arrive newest-first, so the first match is that conversation.
  final priorityAgent = priorityAgentId.trim();
  SidebarConversationEntry? pinnedEntry;
  if (priorityAgent.isNotEmpty) {
    for (final entry in primaryEntries) {
      if (entry.owner.target == priorityAgent ||
          entry.owner.id == priorityAgent) {
        pinnedEntry = entry;
        break;
      }
    }
    if (pinnedEntry != null) {
      runningSessionIds.add(pinnedEntry.session.id);
    }
  }
  final runningEntries = primaryEntries
      .where((entry) {
        if (entry.session.id == pinnedEntry?.session.id) return false;
        final running = runningFor?.call(entry.session) ?? false;
        if (running) runningSessionIds.add(entry.session.id);
        return running;
      })
      .toList(growable: false);
  if (pinnedEntry != null || runningEntries.isNotEmpty) {
    items.add(
      const SidebarSectionHeaderItem(SidebarSectionHeaderKind.priority),
    );
    if (pinnedEntry != null) {
      items.add(SidebarConversationRowItem(pinnedEntry));
    }
    for (final entry in runningEntries) {
      items.add(SidebarConversationRowItem(entry));
    }
  }
  var currentHeader = '';
  var earlierCount = 0;
  var earlierHeaderIndex = -1;
  // A selected conversation stays visible: when it lives in Earlier, the
  // group renders expanded even before the user opens it.
  var earlierContainsSelected = false;
  for (final entry in primaryEntries) {
    if (runningSessionIds.contains(entry.session.id)) {
      continue;
    }
    final updated =
        DateTime.tryParse(entry.session.updatedAt.trim())?.toLocal() ?? now;
    final group = sidebarTimeGroupFor(updated, now);
    final header = switch (group) {
      SidebarTimeGroup.today => 'today',
      SidebarTimeGroup.yesterday => 'yesterday',
      SidebarTimeGroup.weekday => 'weekday:${updated.weekday}',
      SidebarTimeGroup.earlier => 'earlier',
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
        items.add(
          const SidebarSectionHeaderItem.collapsible(
            SidebarSectionHeaderKind.earlier,
            expanded: false,
            count: 0,
          ),
        );
      }
      if (earlierExpanded || earlierContainsSelected) {
        items.add(SidebarConversationRowItem(entry));
      }
      continue;
    }
    if (header != currentHeader) {
      currentHeader = header;
      items.add(switch (group) {
        SidebarTimeGroup.today => const SidebarSectionHeaderItem(
          SidebarSectionHeaderKind.today,
        ),
        SidebarTimeGroup.yesterday => const SidebarSectionHeaderItem(
          SidebarSectionHeaderKind.yesterday,
        ),
        SidebarTimeGroup.weekday => SidebarSectionHeaderItem(
          SidebarSectionHeaderKind.weekday,
          weekday: updated.weekday,
        ),
        SidebarTimeGroup.earlier => throw StateError('earlier handled above'),
      });
    }
    items.add(SidebarConversationRowItem(entry));
  }
  if (earlierHeaderIndex >= 0) {
    items[earlierHeaderIndex] = SidebarSectionHeaderItem.collapsible(
      SidebarSectionHeaderKind.earlier,
      expanded: earlierExpanded || earlierContainsSelected,
      count: earlierCount,
    );
  }
  if (otherEntries.isNotEmpty) {
    final containsSelected = otherEntries.any(
      (entry) => entry.session.id == selectedSessionId,
    );
    final expanded = otherConversationsExpanded || containsSelected;
    items.add(
      SidebarSectionHeaderItem.collapsible(
        SidebarSectionHeaderKind.otherConversations,
        expanded: expanded,
        count: otherEntries.length,
      ),
    );
    if (expanded) {
      for (final entry in otherEntries) {
        items.add(SidebarConversationRowItem(entry));
      }
    }
  }
  return List<SidebarListItem>.unmodifiable(items);
}

class SidebarConversationListView extends StatefulWidget {
  const SidebarConversationListView({
    super.key,
    required this.entries,
    required this.selectedSessionId,
    required this.earlierExpanded,
    required this.onToggleEarlier,
    required this.onSelectSession,
    this.runningFor,
    this.priorityAgentId = '',
    this.relatedAgentIds,
    this.otherConversationsExpanded = false,
    this.onToggleOtherConversations,
    this.showAgentIcons = true,
  });

  final List<SidebarConversationEntry> entries;
  final String selectedSessionId;
  final bool earlierExpanded;
  final VoidCallback onToggleEarlier;
  final void Function(String agentId, String sessionId) onSelectSession;
  final bool Function(AgentConversationSession session)? runningFor;

  /// The group assistant's agent id in the group drill-in list: its latest
  /// conversation pins to the top by default.
  final String priorityAgentId;

  /// When present, conversations owned by these current or historical group
  /// Agents stay in the main timeline. Every unrelated Agent conversation is
  /// kept under the collapsed "Other conversations" section.
  final Set<String>? relatedAgentIds;
  final bool otherConversationsExpanded;
  final VoidCallback? onToggleOtherConversations;
  final bool showAgentIcons;

  @override
  State<SidebarConversationListView> createState() =>
      _SidebarConversationListViewState();
}

class _SidebarConversationListViewState
    extends State<SidebarConversationListView> {
  /// Memoized item model: workspace rebuilds republish identical inputs on
  /// every streaming frame, and the grouping pass costs one timestamp parse
  /// per entry, so it re-runs only when an input actually changes. The day
  /// boundary is part of the key because time buckets follow the calendar.
  List<SidebarListItem> _items = const [];
  List<SidebarConversationEntry>? _memoEntries;
  String _memoSelectedSessionId = '';
  bool _memoEarlierExpanded = false;
  bool _memoOtherConversationsExpanded = false;
  Set<String>? _memoRelatedAgentIds;
  String _memoPriorityAgentId = '';
  String _memoRunningSignature = '';
  DateTime? _memoBucketDay;

  /// Decorative row animations (pulse dots, running spinners) pause while the
  /// list scrolls; data keeps flowing because this only gates tickers.
  bool _scrollActive = false;

  List<SidebarListItem> _resolveItems() {
    final now = DateTime.now();
    final bucketDay = DateTime(now.year, now.month, now.day);
    final runningSignature = _runningSignature(
      widget.entries,
      widget.runningFor,
    );
    final memoEntries = _memoEntries;
    if (memoEntries != null &&
        identical(memoEntries, widget.entries) &&
        _memoSelectedSessionId == widget.selectedSessionId &&
        _memoEarlierExpanded == widget.earlierExpanded &&
        _memoOtherConversationsExpanded == widget.otherConversationsExpanded &&
        _memoPriorityAgentId == widget.priorityAgentId &&
        _memoRunningSignature == runningSignature &&
        _memoBucketDay == bucketDay &&
        _relatedAgentIdsEquivalent(
          _memoRelatedAgentIds,
          widget.relatedAgentIds,
        )) {
      return _items;
    }
    final items = buildSidebarListItems(
      entries: widget.entries,
      selectedSessionId: widget.selectedSessionId,
      earlierExpanded: widget.earlierExpanded,
      runningFor: widget.runningFor,
      priorityAgentId: widget.priorityAgentId,
      relatedAgentIds: widget.relatedAgentIds,
      otherConversationsExpanded: widget.otherConversationsExpanded,
      now: now,
    );
    _memoEntries = widget.entries;
    _memoSelectedSessionId = widget.selectedSessionId;
    _memoEarlierExpanded = widget.earlierExpanded;
    _memoOtherConversationsExpanded = widget.otherConversationsExpanded;
    _memoRelatedAgentIds = widget.relatedAgentIds;
    _memoPriorityAgentId = widget.priorityAgentId;
    _memoRunningSignature = runningSignature;
    _memoBucketDay = bucketDay;
    _items = items;
    return items;
  }

  static String _runningSignature(
    List<SidebarConversationEntry> entries,
    bool Function(AgentConversationSession session)? runningFor,
  ) {
    if (runningFor == null) {
      return '';
    }
    final signature = StringBuffer();
    for (final entry in entries) {
      signature.write(runningFor(entry.session) ? '1' : '0');
    }
    return signature.toString();
  }

  static bool _relatedAgentIdsEquivalent(
    Set<String>? cached,
    Set<String>? next,
  ) {
    if (identical(cached, next)) {
      return true;
    }
    if (cached == null || next == null || cached.length != next.length) {
      return false;
    }
    for (final id in cached) {
      if (!next.contains(id)) {
        return false;
      }
    }
    return true;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    _syncScrollActiveFromNotification(notification);
    return false;
  }

  /// Scroll notifications can be dispatched mid-frame (a scroll activity
  /// going idle during layout fires [ScrollEndNotification] synchronously),
  /// so the ticker gate always applies on the next frame instead of calling
  /// setState inside the notification.
  void _syncScrollActiveFromNotification(ScrollNotification notification) {
    if (notification.depth != 0) {
      return;
    }
    if (notification is ScrollStartNotification) {
      _setScrollActive(true);
    } else if (notification is ScrollEndNotification) {
      _setScrollActive(false);
    }
  }

  void _setScrollActive(bool active) {
    if (_scrollActive == active) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollActive != active) {
        setState(() => _scrollActive = active);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    if (widget.entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Text(
          strings.noConversationsYet,
          style: TextStyle(color: colors.textMuted, fontSize: 12),
        ),
      );
    }
    final items = _resolveItems();
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: TickerMode(
        enabled: !_scrollActive,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          scrollCacheExtent: const ScrollCacheExtent.pixels(400),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return switch (item) {
              SidebarConversationRowItem() => _buildRow(item),
              SidebarSectionHeaderItem() => _buildHeader(item),
            };
          },
        ),
      ),
    );
  }

  Widget _buildRow(SidebarConversationRowItem item) {
    final entry = item.entry;
    return _SidebarConversationRow(
      key: Key('agents-sidebar-conversation-${entry.session.id}'),
      entry: entry,
      selected: entry.session.id == widget.selectedSessionId,
      running: widget.runningFor?.call(entry.session) ?? false,
      showAgentIcon: widget.showAgentIcons,
      onTap: () => widget.onSelectSession(entry.owner.id, entry.session.id),
    );
  }

  Widget _buildHeader(SidebarSectionHeaderItem item) {
    final strings = LicoStrings.of(context);
    final label = switch (item.kind) {
      SidebarSectionHeaderKind.priority => strings.priority,
      SidebarSectionHeaderKind.today => strings.today,
      SidebarSectionHeaderKind.yesterday => strings.yesterday,
      SidebarSectionHeaderKind.weekday => strings.conversationWeekdayLabel(
        item.weekday,
      ),
      SidebarSectionHeaderKind.earlier => strings.earlier,
      SidebarSectionHeaderKind.otherConversations => strings.otherConversations,
    };
    final collapsible =
        item.kind == SidebarSectionHeaderKind.earlier ||
        item.kind == SidebarSectionHeaderKind.otherConversations;
    return LicoGroupHeader(
      label: label,
      count: item.count,
      expanded: collapsible ? item.expanded : null,
      onToggle: switch (item.kind) {
        SidebarSectionHeaderKind.earlier => widget.onToggleEarlier,
        SidebarSectionHeaderKind.otherConversations =>
          widget.onToggleOtherConversations,
        _ => null,
      },
      toggleKey: switch (item.kind) {
        SidebarSectionHeaderKind.earlier => const Key(
          'agents-sidebar-earlier-toggle',
        ),
        SidebarSectionHeaderKind.otherConversations => const Key(
          'agents-sidebar-other-conversations-toggle',
        ),
        _ => null,
      },
      padding: collapsible
          ? const EdgeInsets.fromLTRB(4, 14, 4, 2)
          : const EdgeInsets.fromLTRB(10, 14, 10, 4),
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
    final title = historySessionDisplayTitle(
      session.title.trim().isEmpty ? session.id : session.title,
      fallback: strings.untitledConversation,
    );
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
    // The pulse loops forever; its own repaint boundary keeps the repeating
    // repaint from invalidating the whole sidebar layer.
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _opacity,
        child: ScaleTransition(scale: _scale, child: widget.child),
      ),
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
