import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_session_ordering.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/projection.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/sidebar.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_group_mosaic_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_member_profile_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_profile_registry.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_filter_chips.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_foundation.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_list_refresh.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_loading_bar.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_unread_cursor_store.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_list_typography.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Messaging contact list: one row per local conversation agent or group,
/// like the contact list of a messaging app. Merged products (for example
/// Codex CLI and Codex Desktop) stay one contact with the group
/// representative's brand icon. Rows carry the latest parent conversation's
/// preview and relative activity time, sort pinned contacts first then by
/// most recent activity, and tapping a contact opens that agent's most recent
/// conversation — earlier conversations live in the chat header's History
/// menu; there is no drill-down level.
class MessagingContactList extends StatefulWidget {
  const MessagingContactList({
    super.key,
    required this.targets,
    required this.sessionsByAgent,
    required this.selectedAgentId,
    this.selectedSessionId = '',
    required this.activityFor,
    required this.onSelectAgent,
    this.onSelectAgentSession,
    required this.onNewConversation,
    this.onSearch,
    this.onRefresh,
    this.runningFor,
    this.groupConversations = const [],
    this.directConversations = const [],
    this.selectedGroupConversationId = '',
    this.onSelectGroupConversation,
    this.onSetGroupConversationPinned,
    this.onArchiveGroupConversation,
    this.onNewGroupConversation,
    this.onNewAgentProfile,
    this.onPrefetchSessions,
    this.isPinned,
    this.onTogglePinned,
    this.scanning = false,
    this.loading = false,
    this.loadingAgentIds = const <String>{},
    this.loadingGroupConversationId = '',
    this.activeDestination = ClientSection.agents,
    this.onSelectDestination,
    this.settingsSectionIndex = 0,
    this.onSelectSettingsSection,
    this.avatarColumn = false,
    this.avatarColumnLeading,
    this.unreadCursorStore,
  });

  final List<TargetCandidate> targets;
  final Map<String, List<AgentConversationSession>> sessionsByAgent;
  final String selectedAgentId;

  /// The session actually open in the pane for [selectedAgentId]; the
  /// "open conversation stays read" rule follows this identity, not the
  /// contact's newest session.
  final String selectedSessionId;
  final AgentConversationTabActivity Function(String agentId) activityFor;

  /// Opens the agent's most recent conversation; the workspace maps this to
  /// the `OpenAgentConversation` intent (a fresh conversation when none
  /// exists).
  final ValueChanged<String> onSelectAgent;

  /// Opens one specific session of the agent. Row taps route here when the
  /// contact has unread sessions: each tap opens the newest session that
  /// still has unread, until none remain (see
  /// docs/functionality/MESSAGING-UNREAD-NAVIGATION.md).
  final void Function(String agentId, String sessionId)? onSelectAgentSession;
  final VoidCallback onNewConversation;
  final VoidCallback? onSearch;
  final VoidCallback? onRefresh;
  final bool Function(AgentConversationSession session)? runningFor;
  final List<ClientConversationSummary> groupConversations;

  /// Direct (non-group) canonical Conversations — Profile persona chats —
  /// rendered as mascot-avatar contact rows. They belong to the Agents
  /// filter, never to Groups.
  final List<ClientConversationSummary> directConversations;
  final String selectedGroupConversationId;
  final ValueChanged<String>? onSelectGroupConversation;
  final void Function(String conversationId, bool pinned)?
  onSetGroupConversationPinned;
  final ValueChanged<String>? onArchiveGroupConversation;
  final VoidCallback? onNewGroupConversation;

  /// Opens the "创建智能体" dialog — a named Agent persona (Profile) with a
  /// mascot avatar and its own model/effort preferences.
  final VoidCallback? onNewAgentProfile;

  /// Kicks a first-page session load for one agent that does not yet have a
  /// catalog entry in [sessionsByAgent]. An empty list counts as loaded.
  final ValueChanged<String>? onPrefetchSessions;
  final bool Function(String targetId)? isPinned;
  final ValueChanged<String>? onTogglePinned;
  final bool scanning;
  final bool loading;

  /// Agents whose conversation content is loading right now. A matching row
  /// swaps its preview and timestamp for [MessagingLoadingBar] skeletons —
  /// per-row loading never raises the list-level refresh indicator (see
  /// docs/functionality/MESSAGING-LOADING-PRESENTATION.md).
  final Set<String> loadingAgentIds;

  /// The group conversation whose events are loading; that row shows the
  /// same skeleton treatment as a loading agent row.
  final String loadingGroupConversationId;

  /// Which of the three sidebar tabs is active. The list body follows this
  /// identity; the bottom nav stays mounted across the destinations.
  final ClientSection activeDestination;
  final ValueChanged<ClientSection>? onSelectDestination;
  final int settingsSectionIndex;
  final ValueChanged<int>? onSelectSettingsSection;

  /// Renders the conversations as a narrow column of avatars with activity
  /// and working badges instead of full rows; names move to tooltips.
  final bool avatarColumn;

  /// Pinned above the avatar column (the shell's rail expand control).
  final Widget? avatarColumnLeading;

  /// Read-cursor store for the unread badge; defaults to the installed
  /// platform port. Tests inject a double so no host file is touched.
  final MessagingUnreadCursorStore? unreadCursorStore;

  @override
  State<MessagingContactList> createState() => _MessagingContactListState();
}

class _MessagingContactListState extends State<MessagingContactList> {
  final _createMenuAnchorKey = GlobalKey();
  final Set<String> _prefetchedTargetIds = <String>{};
  _MessagingConversationFilter _filter = _MessagingConversationFilter.all;

  /// Conversation id → last-seen event count. Seeded from the store's
  /// last-known map for a flicker-free first frame; [null] markers count as
  /// "never opened" once [_unreadLoaded] is set.
  Map<String, int> _unreadCursors =
      MessagingUnreadCursorStore.lastKnownCursors ?? const <String, int>{};
  bool _unreadLoaded = false;

  /// Coverage baseline from the durable document (unix ms, 0 = none yet):
  /// a conversation whose last activity predates it is pre-existing
  /// history adopted on first sight rather than flagged fully unread.
  int _unreadBaselineAtUnixMs = 0;

  /// Historical conversations adopted during the current build pass; the
  /// merge persists once per frame so badge math stays synchronous.
  final Map<String, int> _pendingUnreadAdoptions = <String, int>{};

  @override
  void initState() {
    super.initState();
    _loadUnreadCursors();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchUnloadedSessions();
    });
  }

  @override
  void didUpdateWidget(covariant MessagingContactList oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchUnloadedSessions();
      _markSelectedConversationSeen();
    });
  }

  MessagingUnreadCursorStore get _unreadStore =>
      widget.unreadCursorStore ?? ClientPlatformPorts.unreadCursorStore();

  /// The installed portable-data root, or a throwaway token in tests where no
  /// composition ran; the volatile store ignores it either way.
  Object get _unreadData => ClientPlatformPorts.portableData ?? const Object();

  /// Conversation id → total event/message count for every surface that can
  /// carry an unread badge: canonical group conversations and every session
  /// of every contact (the badge sums per-session unread, so first-run
  /// seeding must adopt all of them).
  Map<String, int> _conversationTotals() {
    final totals = <String, int>{
      for (final conversation in widget.groupConversations)
        conversation.id: conversation.eventCount,
    };
    for (final entry in _entries()) {
      for (final session in entry.sessions) {
        totals[session.id] = session.messageCount;
      }
    }
    return totals;
  }

  /// Unread delta for one conversation. A missing cursor means the
  /// conversation is either genuinely new (activity after the coverage
  /// baseline → fully unread) or pre-existing history ([activityAtUnixMs]
  /// at or before the baseline → adopted read at its current count, with
  /// the adoption queued for one persistence pass per frame).
  int _unreadFor(String id, int total, {int? activityAtUnixMs}) {
    if (!_unreadLoaded) {
      return 0;
    }
    final seen = _unreadCursors[id];
    if (seen != null) {
      return total > seen ? total - seen : 0;
    }
    if (total > 0 &&
        _unreadBaselineAtUnixMs > 0 &&
        activityAtUnixMs != null &&
        activityAtUnixMs <= _unreadBaselineAtUnixMs) {
      if (_pendingUnreadAdoptions.isEmpty) {
        // Rows may build lazily after this build returns — the flush must
        // wait for the whole frame, not just the current call site.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _flushUnreadAdoptions(),
        );
      }
      _pendingUnreadAdoptions[id] = total;
      return 0;
    }
    return total;
  }

  Future<void> _loadUnreadCursors() async {
    final stored = await _unreadStore.load(_unreadData);
    if (!mounted) {
      return;
    }
    if (stored == null) {
      // No durable document yet — adopt every currently known conversation
      // at its current count so pre-existing history never badges.
      final seeded = _conversationTotals();
      setState(() {
        _unreadCursors = seeded;
        _unreadBaselineAtUnixMs = DateTime.now().millisecondsSinceEpoch;
        _unreadLoaded = true;
      });
      unawaited(_unreadStore.save(_unreadData, seeded));
      _markSelectedConversationSeen();
      return;
    }
    setState(() {
      _unreadCursors = stored.cursors;
      _unreadBaselineAtUnixMs = stored.baselineAtUnixMs;
      _unreadLoaded = true;
    });
    _markSelectedConversationSeen();
  }

  /// Merges the adoptions queued by [_unreadFor] into the cursor map and
  /// persists them once. Adopted conversations already badge zero, so the
  /// only visible effect is that later growth reports the right delta.
  void _flushUnreadAdoptions() {
    if (!mounted || _pendingUnreadAdoptions.isEmpty) {
      _pendingUnreadAdoptions.clear();
      return;
    }
    final next = <String, int>{..._unreadCursors, ..._pendingUnreadAdoptions};
    _pendingUnreadAdoptions.clear();
    setState(() => _unreadCursors = next);
    unawaited(_unreadStore.save(_unreadData, next));
  }

  void _markSeen(String id, int total) {
    if (total <= 0 || _unreadCursors[id] == total) {
      return;
    }
    final next = <String, int>{..._unreadCursors, id: total};
    setState(() => _unreadCursors = next);
    unawaited(_unreadStore.save(_unreadData, next));
  }

  /// An open conversation can never show unread — when its count grows while
  /// selected, the cursor follows it so the badge never flickers on.
  void _markSelectedConversationSeen() {
    final groupId = widget.selectedGroupConversationId;
    if (groupId.isNotEmpty) {
      for (final conversation in widget.groupConversations) {
        if (conversation.id == groupId) {
          _markSeen(conversation.id, conversation.eventCount);
          return;
        }
      }
      return;
    }
    if (widget.selectedAgentId.isEmpty) {
      return;
    }
    for (final entry in _entries()) {
      final isSelected = entry.group.members.any(
        (member) =>
            member.id == widget.selectedAgentId ||
            member.target == widget.selectedAgentId,
      );
      if (!isSelected) {
        continue;
      }
      // The open session stays read; an older session open in the pane must
      // not clear newer sessions that were never opened. When the caller
      // does not report the open session, fall back to the newest one —
      // the historical behavior for selection without a session identity.
      // A reported session outside the loaded catalog page marks nothing:
      // it cannot be confused with a different loaded session.
      AgentConversationSession? open;
      if (widget.selectedSessionId.isEmpty) {
        open = entry.latestSession;
      } else {
        for (final session in entry.sessions) {
          if (session.id == widget.selectedSessionId ||
              session.nativeSessionId.trim() == widget.selectedSessionId) {
            open = session;
            break;
          }
        }
      }
      if (open != null) {
        _markSeen(open.id, open.messageCount);
      }
      return;
    }
  }

  /// Total unread across all of the contact's sessions — the row badge shows
  /// this, so it survives until every session is read.
  int _unreadTotal(_MessagingContactEntry entry) {
    var total = 0;
    for (final session in entry.sessions) {
      total += _unreadFor(
        session.id,
        session.messageCount,
        activityAtUnixMs: conversationSessionSortTime(session),
      );
    }
    return total;
  }

  /// The newest session that still has unread, or null when all are read.
  /// Sessions are most-recent-first, so the first hit is the click target.
  AgentConversationSession? _nextUnreadSession(_MessagingContactEntry entry) {
    for (final session in entry.sessions) {
      if (_unreadFor(
            session.id,
            session.messageCount,
            activityAtUnixMs: conversationSessionSortTime(session),
          ) >
          0) {
        return session;
      }
    }
    return null;
  }

  /// Row-tap contract (docs/functionality/MESSAGING-UNREAD-NAVIGATION.md):
  /// open the newest session that still has unread; once every session is
  /// read, fall back to the contact's most recent conversation.
  void _openContact(_MessagingContactEntry entry) {
    final agentId = entry.group.members.first.id;
    final unread = _nextUnreadSession(entry);
    final openSession = widget.onSelectAgentSession;
    if (unread != null && openSession != null) {
      _markSeen(unread.id, unread.messageCount);
      openSession(agentId, unread.id);
      return;
    }
    final latest = entry.latestSession;
    if (latest != null) {
      _markSeen(latest.id, latest.messageCount);
    }
    widget.onSelectAgent(agentId);
  }

  void _prefetchUnloadedSessions() {
    final prefetch = widget.onPrefetchSessions;
    if (prefetch == null) {
      return;
    }
    for (final target in widget.targets) {
      if (!target.isConversationAgent) {
        continue;
      }
      final hasCatalog =
          widget.sessionsByAgent.containsKey(target.id) ||
          widget.sessionsByAgent.containsKey(target.target);
      if (hasCatalog) {
        continue;
      }
      if (!_prefetchedTargetIds.add(target.id)) {
        continue;
      }
      prefetch(target.id);
    }
  }

  bool _isPinned(TargetCandidate target) {
    final check = widget.isPinned;
    if (check == null) {
      return false;
    }
    return check(target.id) || check(target.target);
  }

  /// Targets that share a canonical product name collapse into one contact,
  /// mirroring the tree sidebar's agent grouping; the first target in the
  /// incoming order represents the contact and supplies its brand icon.
  List<_MessagingContactGroup> _groups() {
    final groups = <_MessagingContactGroup>[];
    final indexByName = <String, int>{};
    for (final target in widget.targets) {
      if (!target.isConversationAgent) {
        continue;
      }
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
          // Sub-agent threads merge into their parent conversation and never
          // count as a contact's latest conversation.
          if (session.parentSessionId.trim().isNotEmpty) {
            continue;
          }
          if (seenSessionIds.add(session.id)) {
            sessions.add(session);
          }
        }
      }
      final sorted = sessions.isEmpty
          ? const <AgentConversationSession>[]
          : sortConversationSessionsByUpdatedAt(sessions);
      entries.add(
        _MessagingContactEntry(
          group: group,
          sessions: sorted,
          latestSession: sorted.isEmpty ? null : sorted.first,
          activity: group.members
              .map((member) => widget.activityFor(member.id))
              .firstWhere(
                (value) => value != AgentConversationTabActivity.none,
                orElse: () => AgentConversationTabActivity.none,
              ),
          pinned: group.members.any(_isPinned),
        ),
      );
    }
    entries.sort((left, right) {
      if (left.pinned != right.pinned) {
        return left.pinned ? -1 : 1;
      }
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

  void _toggleContactPinned(_MessagingContactEntry entry) {
    final onToggle = widget.onTogglePinned;
    if (onToggle == null) return;
    // Toggle the member that actually carries the pinned state (the pin check
    // keys on `id` or `target`); default to the group representative when
    // nothing is pinned yet.
    final check = widget.isPinned;
    String? pinnedKey;
    if (check != null) {
      for (final member in entry.group.members) {
        if (check(member.id)) {
          pinnedKey = member.id;
          break;
        }
        if (check(member.target)) {
          pinnedKey = member.target;
          break;
        }
      }
    }
    onToggle(pinnedKey ?? entry.group.members.first.id);
  }

  Future<void> _showItemMenu({
    required BuildContext context,
    required Offset globalPosition,
    required bool pinned,
    VoidCallback? onTogglePinned,
    VoidCallback? onArchive,
  }) async {
    final strings = LicoStrings.of(context);
    final selected = await showMessagingGlassMenu<_MessagingItemAction>(
      context: context,
      globalPosition: globalPosition,
      menuKey: const Key('messaging-conversation-item-menu'),
      actions: [
        if (onTogglePinned != null)
          MessagingGlassMenuAction(
            value: _MessagingItemAction.togglePin,
            label: pinned ? strings.unpinFromTop : strings.pinToTop,
            leading: Icon(
              pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
              size: 16,
            ),
          ),
        if (onArchive != null)
          MessagingGlassMenuAction(
            value: _MessagingItemAction.archive,
            label: strings.archive,
            leading: const Icon(Icons.archive_outlined, size: 16),
          ),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case _MessagingItemAction.togglePin:
        onTogglePinned?.call();
        break;
      case _MessagingItemAction.archive:
        onArchive?.call();
        break;
      case null:
        break;
    }
  }

  Future<void> _showCreateMenu() async {
    final anchor = _createMenuAnchorKey.currentContext?.findRenderObject();
    if (anchor is! RenderBox || !anchor.hasSize) return;
    final strings = LicoStrings.of(context);
    final selected = await showMessagingGlassMenu<_MessagingCreateAction>(
      context: context,
      globalPosition: anchor.localToGlobal(Offset(anchor.size.width + 6, 0)),
      menuKey: const Key('messaging-create-conversation-menu'),
      actions: [
        MessagingGlassMenuAction(
          value: _MessagingCreateAction.conversation,
          label: strings.newConversation,
          leading: const Icon(Icons.edit_square, size: 16),
        ),
        if (widget.onNewGroupConversation != null)
          MessagingGlassMenuAction(
            value: _MessagingCreateAction.group,
            label: strings.newGroupConversation,
            leading: const Icon(Icons.group_add_outlined, size: 16),
          ),
        if (widget.onNewAgentProfile != null)
          MessagingGlassMenuAction(
            value: _MessagingCreateAction.profile,
            label: strings.newAgentProfile,
            leading: const Icon(Icons.smart_toy_outlined, size: 16),
          ),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case _MessagingCreateAction.conversation:
        widget.onNewConversation();
        break;
      case _MessagingCreateAction.group:
        widget.onNewGroupConversation?.call();
        break;
      case _MessagingCreateAction.profile:
        widget.onNewAgentProfile?.call();
        break;
      case null:
        break;
    }
  }

  bool get _showsConversations =>
      widget.activeDestination == ClientSection.agents;

  /// Filter chips appear only on the conversation list, and only when the
  /// active profile asks for them.
  bool _showsFilters(LayoutAgentsPresentation? presentation) =>
      (presentation?.showConversationFilters ?? false) && _showsConversations;

  _MessagingConversationFilter get _effectiveFilter =>
      _showsFilters(maybeLayoutAgentsPresentationOf(context))
      ? _filter
      : _MessagingConversationFilter.all;

  String _sidebarTitle(LicoStrings strings) {
    if (_showsConversations) return strings.messages;
    if (widget.activeDestination == ClientSection.settings) {
      return strings.settings;
    }
    return strings.features;
  }

  Widget _conversationFilters(LicoStrings strings) {
    return MessagingFilterChips<_MessagingConversationFilter>(
      key: const Key('messaging-conversation-filters'),
      semanticLabel: strings.conversationFilters,
      selected: _filter,
      onSelected: (filter) => setState(() => _filter = filter),
      options: [
        MessagingFilterChipOption(
          value: _MessagingConversationFilter.all,
          label: strings.conversationFilterAll,
          key: const Key('messaging-conversation-filter-all'),
        ),
        MessagingFilterChipOption(
          value: _MessagingConversationFilter.agents,
          label: strings.conversationFilterAgents,
          key: const Key('messaging-conversation-filter-agents'),
        ),
        MessagingFilterChipOption(
          value: _MessagingConversationFilter.groups,
          label: strings.conversationFilterGroups,
          key: const Key('messaging-conversation-filter-groups'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.avatarColumn) return _avatarColumnBody();
    final presentation = maybeLayoutAgentsPresentationOf(context);
    final strings = LicoStrings.of(context);
    final sidebarHeader = presentation?.sidebarHeader;
    return MessagingSidebarFoundation(
      key: const Key('messaging-contact-list'),
      title: sidebarHeader == LayoutAgentsSidebarHeader.title
          ? _sidebarTitle(strings)
          : null,
      topSearchRow: sidebarHeader == LayoutAgentsSidebarHeader.search,
      headingActions: _showsConversations
          ? _conversationHeadingActions()
          : null,
      onSearch: widget.onSearch,
      searchBottomPadding: LicoContentSpacing.compact,
      filters: _showsFilters(presentation)
          ? _conversationFilters(strings)
          : null,
      list: _showsConversations
          ? MessagingListRefresh(
              onRefresh: widget.onRefresh,
              // The top slot is reserved for list-level work — an agent
              // discovery scan. One conversation loading marks only its own
              // row; the right pane keeps the spinner for opened content.
              refreshing: widget.scanning,
              child: ValueListenableBuilder(
                valueListenable: conversationProfiles,
                builder: (context, profiles, child) => _sidebarBody(),
              ),
            )
          : _sidebarBody(),
      // The active profile decides whether its chrome already provides the
      // 功能/对话/设置 navigation: the Desktop dock does, so the
      // fullscreen-exclusive conversation app hides this Dashboard row.
      bottomNav: (presentation?.showSidebarBottomNav ?? true)
          ? MessagingSidebarBottomNav(
              current: widget.activeDestination,
              onSelectDestination: widget.onSelectDestination ?? (_) {},
            )
          : null,
    );
  }

  Widget _sidebarBody() {
    if (!_showsConversations) {
      return messagingSidebarListFor(
        destination: widget.activeDestination,
        onSelectDestination: widget.onSelectDestination ?? (_) {},
        settingsSectionIndex: widget.settingsSectionIndex,
        onSelectSettings: widget.onSelectSettingsSection,
      );
    }
    return _contactListBody();
  }

  List<Widget> _conversationHeadingActions() {
    final strings = LicoStrings.of(context);
    return [
      MessagingGhostIconButton(
        key: _createMenuAnchorKey,
        inkWellKey: const Key('messaging-create-conversation'),
        tooltip: strings.createConversation,
        onPressed: _showCreateMenu,
        icon: Icons.add_rounded,
      ),
    ];
  }

  List<ClientConversationSummary> get _archivedContinuityChildren => [
    for (final conversation in widget.groupConversations)
      ...conversation.archivedChildren,
    for (final conversation in widget.directConversations)
      if (conversationProfileByConversationId(conversation.id) != null)
        ...conversation.archivedChildren,
  ];

  /// The backing local Agent of a Profile — the row subtitle names the
  /// product that executes the persona's turns.
  TargetCandidate? _targetById(String id) {
    final normalized = id.trim();
    if (normalized.isEmpty) return null;
    for (final target in widget.targets) {
      if (target.target == normalized || target.id == normalized) {
        return target;
      }
    }
    return null;
  }

  Widget _contactListBody() {
    final filter = _effectiveFilter;
    final listItems = _combinedItems(_entries())
        .where(
          (item) => switch (filter) {
            _MessagingConversationFilter.all => true,
            _MessagingConversationFilter.agents =>
              item.contact != null || item.profileConversation,
            _MessagingConversationFilter.groups =>
              item.groupConversation != null && !item.profileConversation,
          },
        )
        .toList(growable: false);
    final archivedChildren = filter == _MessagingConversationFilter.agents
        ? const <ClientConversationSummary>[]
        : _archivedContinuityChildren;
    if (listItems.isEmpty && archivedChildren.isEmpty) {
      if (filter == _MessagingConversationFilter.groups) {
        return const _MessagingNoGroupsEmpty();
      }
      return _MessagingContactListEmpty(
        scanning: widget.scanning,
        loading: widget.loading,
      );
    }
    final footerCount = archivedChildren.isEmpty ? 0 : 1;
    return ScrollConfiguration(
      behavior: const _MessagingSlimScrollbarBehavior(),
      child: ListView.builder(
        key: const Key('messaging-contact-scroll'),
        physics: messagingListScrollPhysics,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        itemCount: listItems.length + footerCount,
        itemBuilder: (context, index) {
          if (index >= listItems.length) {
            return CanonicalArchivedContinuityChildren(
              toggleKey: const Key('messaging-archived-continuity-toggle'),
              children: archivedChildren,
              highlightedChildConversationId:
                  widget.selectedGroupConversationId,
              onSelect: widget.onSelectGroupConversation ?? (_) {},
            );
          }
          final item = listItems[index];
          final conversation = item.groupConversation;
          if (conversation != null) {
            final setPinned = widget.onSetGroupConversationPinned;
            final archive = widget.onArchiveGroupConversation;
            if (item.profileConversation) {
              final profile = conversationProfileByConversationId(
                conversation.id,
              );
              final backingTarget = _targetById(profile?.agentId ?? '');
              return _MessagingCanonicalGroupRow(
                key: ValueKey<String>(
                  'messaging-profile-conversation-${conversation.id}',
                ),
                conversation: conversation,
                memberTargets: const [],
                hasLocalOwner: false,
                avatarOverride: ClipRRect(
                  borderRadius: BorderRadius.circular(LicoRadius.floating),
                  child: MascotImage.avatar(
                    profile?.mascotAvatarId ?? 'lico',
                    key: ValueKey<String>(
                      'messaging-profile-avatar-${conversation.id}',
                    ),
                    semanticLabel: profile?.name ?? conversation.title,
                    size: 44,
                  ),
                ),
                memberTagLabel: '',
                subtitleLabel: backingTarget == null
                    ? null
                    : agentConversationTargetDisplayName(backingTarget),
                selected: conversation.id == widget.selectedGroupConversationId,
                loading: conversation.id == widget.loadingGroupConversationId,
                unreadCount: _unreadFor(
                  conversation.id,
                  conversation.eventCount,
                  activityAtUnixMs: conversation.updatedAtUnixMs,
                ),
                onAvatarTap: (rect) =>
                    _openGroupProfile(context, conversation, rect),
                onTap: widget.onSelectGroupConversation == null
                    ? null
                    : () {
                        _markSeen(conversation.id, conversation.eventCount);
                        widget.onSelectGroupConversation!(conversation.id);
                      },
                onSecondaryTapDown: setPinned == null && archive == null
                    ? null
                    : (details) => _showItemMenu(
                        context: context,
                        globalPosition: details.globalPosition,
                        pinned: conversation.pinned,
                        onTogglePinned: setPinned == null
                            ? null
                            : () => setPinned(
                                conversation.id,
                                !conversation.pinned,
                              ),
                        onArchive: archive == null
                            ? null
                            : () => archive(conversation.id),
                      ),
              );
            }
            return _MessagingCanonicalGroupRow(
              key: ValueKey<String>(
                'messaging-group-conversation-${conversation.id}',
              ),
              conversation: conversation,
              memberTargets: resolveCanonicalGroupSummaryMemberTargets(
                conversation.memberAgentIds,
                widget.targets,
              ),
              hasLocalOwner: conversation.hasLocalOwner,
              selected: conversation.id == widget.selectedGroupConversationId,
              loading: conversation.id == widget.loadingGroupConversationId,
              unreadCount: _unreadFor(
                conversation.id,
                conversation.eventCount,
                activityAtUnixMs: conversation.updatedAtUnixMs,
              ),
              onAvatarTap: (rect) =>
                  _openGroupProfile(context, conversation, rect),
              onTap: widget.onSelectGroupConversation == null
                  ? null
                  : () {
                      _markSeen(conversation.id, conversation.eventCount);
                      widget.onSelectGroupConversation!(conversation.id);
                    },
              onSecondaryTapDown: setPinned == null && archive == null
                  ? null
                  : (details) => _showItemMenu(
                      context: context,
                      globalPosition: details.globalPosition,
                      pinned: conversation.pinned,
                      onTogglePinned: setPinned == null
                          ? null
                          : () => setPinned(
                              conversation.id,
                              !conversation.pinned,
                            ),
                      onArchive: archive == null
                          ? null
                          : () => archive(conversation.id),
                    ),
            );
          }
          final entry = item.contact!;
          final latest = entry.latestSession;
          return _MessagingContactRow(
            key: ValueKey<String>(
              'messaging-contact-${entry.group.members.first.id}',
            ),
            entry: entry,
            working:
                latest != null && (widget.runningFor?.call(latest) ?? false),
            selected:
                widget.selectedGroupConversationId.isEmpty &&
                entry.group.members.any(
                  (member) =>
                      member.id == widget.selectedAgentId ||
                      member.target == widget.selectedAgentId,
                ),
            unreadCount: _unreadTotal(entry),
            loading: entry.group.members.any(
              (member) =>
                  widget.loadingAgentIds.contains(member.id) ||
                  widget.loadingAgentIds.contains(member.target),
            ),
            onAvatarTap: (rect) => _openContactProfile(context, entry, rect),
            onTap: () => _openContact(entry),
            onSecondaryTapDown: widget.onTogglePinned == null
                ? null
                : (details) => _showItemMenu(
                    context: context,
                    globalPosition: details.globalPosition,
                    pinned: entry.pinned,
                    onTogglePinned: () => _toggleContactPinned(entry),
                  ),
          );
        },
      ),
    );
  }

  Widget _avatarColumnBody() {
    final strings = LicoStrings.of(context);
    final items = _combinedItems(_entries());
    return Column(
      key: const Key('messaging-avatar-column'),
      children: [
        ?widget.avatarColumnLeading,
        Expanded(
          child: ScrollConfiguration(
            behavior: const _MessagingSlimScrollbarBehavior(),
            child: ListView.builder(
              key: const Key('messaging-avatar-column-scroll'),
              physics: messagingListScrollPhysics,
              padding: const EdgeInsets.only(bottom: 6),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final conversation = item.groupConversation;
                if (conversation != null) {
                  final profile = item.profileConversation
                      ? conversationProfileByConversationId(conversation.id)
                      : null;
                  return _MessagingAvatarTile(
                    key: ValueKey<String>(
                      'messaging-avatar-group-${conversation.id}',
                    ),
                    label: historySessionDisplayTitle(
                      conversation.title,
                      fallback: strings.groupConversation,
                    ),
                    selected:
                        conversation.id == widget.selectedGroupConversationId,
                    working: false,
                    onTap: widget.onSelectGroupConversation == null
                        ? null
                        : () => widget.onSelectGroupConversation!(
                            conversation.id,
                          ),
                    avatar: profile != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: MascotImage.avatar(
                              profile.mascotAvatarId,
                              semanticLabel: profile.name,
                              size: 40,
                            ),
                          )
                        : MessagingGroupMosaicAvatar(
                            rosterTargets:
                                resolveCanonicalGroupSummaryMemberTargets(
                                  conversation.memberAgentIds,
                                  widget.targets,
                                ),
                            hasLocalOwner: conversation.hasLocalOwner,
                            extent: 40,
                          ),
                  );
                }
                final entry = item.contact!;
                final latest = entry.latestSession;
                return _MessagingAvatarTile(
                  key: ValueKey<String>(
                    'messaging-avatar-contact-${entry.group.members.first.id}',
                  ),
                  label: entry.group.displayName,
                  selected:
                      widget.selectedGroupConversationId.isEmpty &&
                      entry.group.members.any(
                        (member) =>
                            member.id == widget.selectedAgentId ||
                            member.target == widget.selectedAgentId,
                      ),
                  working:
                      latest != null &&
                      (widget.runningFor?.call(latest) ?? false),
                  onTap: () => _openContact(entry),
                  avatar: MessagingAgentAvatar(
                    target: entry.group.members.first,
                    activity: entry.activity,
                    size: 40,
                    iconSize: 22,
                  ),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 10),
          child: MessagingGhostIconButton(
            key: _createMenuAnchorKey,
            inkWellKey: const Key('messaging-create-conversation'),
            tooltip: strings.createConversation,
            onPressed: _showCreateMenu,
            icon: Icons.add_rounded,
            dimension: 32,
            iconExtent: 18,
          ),
        ),
      ],
    );
  }

  /// The contact row's avatar affordance: the agent's profile card opens
  /// anchored to the avatar's right edge, like the demo's `openProfile` on
  /// list avatars — the row tap itself still selects the conversation.
  void _openContactProfile(
    BuildContext context,
    _MessagingContactEntry entry,
    Rect anchorRect,
  ) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final member = entry.group.members.first;
    final sessions =
        widget.sessionsByAgent[member.id] ??
        widget.sessionsByAgent[member.target];
    final navigate = widget.onSelectDestination;
    showMessagingMemberProfile(
      context: context,
      anchorRect: anchorRect,
      card: messagingAgentProfileCard(
        context: context,
        strings: strings,
        target: member,
        name: entry.group.displayName,
        tag: strings.memberTagAgent,
        statusLabel: member.canRelayRuntime
            ? strings.memberStatusOnline
            : strings.memberStatusOffline,
        statusDot: member.canRelayRuntime
            ? colors.success
            : colors.textDisabled,
        sessionCount: sessions?.length ?? 0,
        actions: [
          (
            label: strings.memberProfileMessage,
            filled: true,
            onPressed: () {
              Navigator.of(context, rootNavigator: false).pop();
              widget.onSelectAgent(member.id);
            },
          ),
          if (navigate != null)
            (
              label: strings.memberProfileDetails,
              filled: false,
              onPressed: () {
                Navigator.of(context, rootNavigator: false).pop();
                navigate(ClientSection.agentHub);
              },
            ),
        ],
      ),
    );
  }

  /// The group row's avatar affordance: the group profile card — cover, group
  /// mark, title and member count — opens to the avatar's right; 成员 selects
  /// the group conversation, 群设置 follows the settings destination.
  void _openGroupProfile(
    BuildContext context,
    ClientConversationSummary conversation,
    Rect anchorRect,
  ) {
    final strings = LicoStrings.of(context);
    final navigate = widget.onSelectDestination;
    showMessagingMemberProfile(
      context: context,
      anchorRect: anchorRect,
      card: messagingGroupProfileCard(
        strings: strings,
        title: historySessionDisplayTitle(
          conversation.title,
          fallback: strings.groupConversation,
        ),
        memberCount: conversation.membershipCount,
        avatar: MessagingGroupMosaicAvatar(
          rosterTargets: resolveCanonicalGroupSummaryMemberTargets(
            conversation.memberAgentIds,
            widget.targets,
          ),
          hasLocalOwner: conversation.hasLocalOwner,
          extent: 72,
        ),
        actions: [
          if (widget.onSelectGroupConversation != null)
            (
              label: strings.memberProfileMembers,
              filled: true,
              onPressed: () {
                Navigator.of(context, rootNavigator: false).pop();
                widget.onSelectGroupConversation!(conversation.id);
              },
            ),
          if (navigate != null)
            (
              label: strings.memberProfileGroupSettings,
              filled: false,
              onPressed: () {
                Navigator.of(context, rootNavigator: false).pop();
                navigate(ClientSection.settings);
              },
            ),
        ],
      ),
    );
  }

  List<_MessagingListItem> _combinedItems(
    List<_MessagingContactEntry> entries,
  ) {
    var ordinal = 0;
    final items = <_MessagingListItem>[
      for (final conversation in widget.groupConversations)
        _MessagingListItem.group(conversation, ordinal++),
      // Only Profile-backed direct conversations earn a contact row —
      // legacy 1:1 agent conversations stay routable data, not list noise.
      for (final conversation in widget.directConversations)
        if (conversationProfileByConversationId(conversation.id) != null)
          _MessagingListItem.profile(conversation, ordinal++),
      for (final entry in entries) _MessagingListItem.contact(entry, ordinal++),
    ];
    items.sort((left, right) {
      if (left.pinned != right.pinned) return left.pinned ? -1 : 1;
      final byTime = right.updatedAt.compareTo(left.updatedAt);
      return byTime != 0 ? byTime : left.ordinal.compareTo(right.ordinal);
    });
    return List<_MessagingListItem>.unmodifiable(items);
  }
}

enum _MessagingCreateAction { conversation, group, profile }

enum _MessagingConversationFilter { all, agents, groups }

enum _MessagingItemAction { togglePin, archive }

class _MessagingCanonicalGroupRow extends StatelessWidget {
  const _MessagingCanonicalGroupRow({
    super.key,
    required this.conversation,
    required this.memberTargets,
    required this.hasLocalOwner,
    required this.selected,
    required this.onTap,
    this.unreadCount = 0,
    this.loading = false,
    this.onAvatarTap,
    this.onSecondaryTapDown,
    this.avatarOverride,
    this.memberTagLabel,
    this.subtitleLabel,
  });

  final ClientConversationSummary conversation;

  /// Replaces the group mosaic avatar — Profile rows pass their mascot.
  final Widget? avatarOverride;

  /// Replaces the "N members" helper tag; an empty string hides it.
  final String? memberTagLabel;

  /// Replaces the static group subtitle — Profile rows show the backing
  /// Agent's product name.
  final String? subtitleLabel;

  /// Mosaic cells resolved from `conversation.memberAgentIds` against the
  /// live target catalog; empty keeps the generic group mark inside
  /// [MessagingGroupMosaicAvatar].
  final List<TargetCandidate> memberTargets;
  final bool hasLocalOwner;
  final bool selected;
  final VoidCallback? onTap;

  /// Unread events since the local read cursor; zero hides the badge.
  final int unreadCount;

  /// Whether the conversation's content is loading — the subtitle and the
  /// timestamp render as [MessagingLoadingBar] skeletons.
  final bool loading;

  /// Avatar tap opens the group profile card beside the avatar; it does not
  /// select the conversation — the demo's `stopPropagation` semantics.
  final ValueChanged<Rect>? onAvatarTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final ramp = LicoListTypeRamp.of(context);
    final title = historySessionDisplayTitle(
      conversation.title,
      fallback: strings.groupConversation,
    );
    return Padding(
      padding: const EdgeInsets.only(
        bottom: MessagingDesktopMetrics.sidebarRowGap,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
          hoverColor: LicoSelectionLight.hoverFill(context),
          child: LicoSelectionLight(
            selected: selected,
            radius: LicoRadius.floating,
            child: AnimatedContainer(
              duration: LicoMotion.micro,
              height: MessagingDesktopMetrics.sidebarRowExtent,
              padding: const EdgeInsets.symmetric(
                horizontal: MessagingDesktopMetrics.sidebarRowHorizontalInset,
              ),
              decoration: BoxDecoration(
                // Selected rows fill with the Demo's violet surface; foreground
                // content keeps its normal tones on top.
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(LicoRadius.floating),
              ),
              child: Row(
                children: [
                  _MemberCardTapTarget(
                    onOpenCard: onAvatarTap,
                    child:
                        avatarOverride ??
                        MessagingGroupMosaicAvatar(
                          key: ValueKey<String>(
                            'messaging-group-avatar-${conversation.id}',
                          ),
                          rosterTargets: memberTargets,
                          hasLocalOwner: hasLocalOwner,
                          extent: 44,
                        ),
                  ),
                  const SizedBox(
                    width: MessagingDesktopMetrics.sidebarRowLabelGap,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The Demo's name row: pin + member tag follow the
                        // shrinking title and drop out — rather than overflow —
                        // once the row is too narrow for all three.
                        LayoutBuilder(
                          builder: (context, nameConstraints) => Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      (unreadCount > 0
                                              ? ramp.titleUnread
                                              : ramp.title)
                                          .copyWith(
                                            color:
                                                selected &&
                                                    !LicoSelectionLight.isStarlight(
                                                      context,
                                                    )
                                                ? colors.selectionInk
                                                : null,
                                          ),
                                ),
                              ),
                              if (conversation.pinned &&
                                  nameConstraints.maxWidth >= 44) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.push_pin_rounded,
                                  size: 12,
                                  color: colors.textDisabled,
                                ),
                              ],
                              if (memberTagLabel != '' &&
                                  nameConstraints.maxWidth >= 96) ...[
                                const SizedBox(width: 6),
                                ramp.memberCountAsText
                                    ? Text(
                                        memberTagLabel ??
                                            strings.groupConversationMemberTag(
                                              conversation.membershipCount,
                                            ),
                                        maxLines: 1,
                                        style: ramp.meta,
                                      )
                                    : _MessagingRowTag(
                                        label:
                                            memberTagLabel ??
                                            strings.groupConversationMemberTag(
                                              conversation.membershipCount,
                                            ),
                                        helper: true,
                                      ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        if (loading)
                          const FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: 0.72,
                            child: MessagingLoadingBar(
                              key: Key('messaging-row-loading-preview'),
                            ),
                          )
                        else
                          Text(
                            subtitleLabel ?? strings.groupConversation,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ramp.descriptor,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (loading)
                        const MessagingLoadingBar(
                          key: Key('messaging-row-loading-time'),
                          width: 36,
                          height: 9,
                        )
                      else
                        Text(
                          conversationRelativeUpdatedAtLabel(
                            DateTime.fromMillisecondsSinceEpoch(
                              conversation.updatedAtUnixMs,
                            ),
                            chinese: strings.isChinese,
                          ),
                          maxLines: 1,
                          style: unreadCount > 0 ? ramp.metaUnread : ramp.meta,
                        ),
                      if (unreadCount > 0)
                        _MessagingUnreadBadge(
                          key: Key('messaging-unread-badge-${conversation.id}'),
                          count: unreadCount,
                        ),
                    ],
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

/// One avatar in the avatar column: a selection ring, the agent's activity
/// dot from its avatar, and a working badge while a turn runs.
final class _MessagingAvatarTile extends StatefulWidget {
  const _MessagingAvatarTile({
    super.key,
    required this.label,
    required this.selected,
    required this.working,
    required this.onTap,
    required this.avatar,
  });

  final String label;
  final bool selected;
  final bool working;
  final VoidCallback? onTap;
  final Widget avatar;

  @override
  State<_MessagingAvatarTile> createState() => _MessagingAvatarTileState();
}

final class _MessagingAvatarTileState extends State<_MessagingAvatarTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final selected = widget.selected;
    final duration = context.motion(LicoMotion.micro);
    // Selected: 1.5 accent ring at 85% plus an accent-glow halo; hover on an
    // unselected tile paints a quiet white ring.
    final ring = selected
        ? colors.accent.withValues(alpha: 0.85)
        : _hovered
        ? colors.line
        : Colors.transparent;
    final ringWidth = selected ? 1.5 : (_hovered ? 1.0 : 0.0);
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        waitDuration: LicoMotion.tooltipWait,
        preferBelow: false,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: SizedBox(
              height: MessagingDesktopMetrics.avatarColumnTileExtent,
              width: double.infinity,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  AnimatedContainer(
                    duration: duration,
                    curve: LicoMotion.standard,
                    padding: const EdgeInsets.all(2),
                    decoration: continuousHairlineDecoration(
                      // Avatars are circles: the ring is a concentric circle
                      // — avatar radius + 2 pt gap + stroke centre — which is
                      // the square container's half-extent.
                      borderRadius: BorderRadius.circular(999),
                      stroke: ring,
                      strokeWidth: ringWidth,
                      shadows: selected
                          ? [
                              BoxShadow(
                                color: colors.accentGlow,
                                blurRadius: 12,
                              ),
                            ]
                          : null,
                    ),
                    child: widget.avatar,
                  ),
                  if (widget.working)
                    Positioned(
                      right: 6,
                      top: 8,
                      child: Container(
                        key: const Key('messaging-avatar-working-badge'),
                        width: 9,
                        height: 9,
                        decoration: continuousHairlineDecoration(
                          color: colors.accent,
                          borderRadius: BorderRadius.circular(999),
                          // Matches the pane surface behind the avatar so
                          // the badge reads as a cutout, not a ring.
                          stroke: colors.surface,
                          strokeWidth: 2,
                        ),
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

/// Wraps a row avatar so tapping it opens the member profile card beside the
/// avatar without triggering the row's own select-on-tap.
final class _MemberCardTapTarget extends StatelessWidget {
  const _MemberCardTapTarget({
    super.key,
    required this.onOpenCard,
    required this.child,
  });

  final ValueChanged<Rect>? onOpenCard;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final open = onOpenCard;
    if (open == null) return child;
    return Builder(
      builder: (anchorContext) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final box = anchorContext.findRenderObject();
            open(
              box is RenderBox && box.hasSize
                  ? box.localToGlobal(Offset.zero) & box.size
                  : Rect.zero,
            );
          },
          child: child,
        ),
      ),
    );
  }
}

final class _MessagingListItem {
  const _MessagingListItem._({
    required this.groupConversation,
    required this.contact,
    required this.ordinal,
    this.profileConversation = false,
  });

  factory _MessagingListItem.group(
    ClientConversationSummary conversation,
    int ordinal,
  ) => _MessagingListItem._(
    groupConversation: conversation,
    contact: null,
    ordinal: ordinal,
  );

  /// A direct (non-group) canonical Conversation backing a Profile persona.
  /// Renders as a contact row with the mascot avatar, not the group mosaic.
  factory _MessagingListItem.profile(
    ClientConversationSummary conversation,
    int ordinal,
  ) => _MessagingListItem._(
    groupConversation: conversation,
    contact: null,
    ordinal: ordinal,
    profileConversation: true,
  );

  factory _MessagingListItem.contact(
    _MessagingContactEntry contact,
    int ordinal,
  ) => _MessagingListItem._(
    groupConversation: null,
    contact: contact,
    ordinal: ordinal,
  );

  final ClientConversationSummary? groupConversation;
  final _MessagingContactEntry? contact;
  final int ordinal;

  /// True when [groupConversation] is a direct Profile chat rather than a
  /// group — the row keeps the same summary but a different presentation.
  final bool profileConversation;

  bool get pinned => groupConversation?.pinned ?? contact!.pinned;

  int get updatedAt {
    final conversation = groupConversation;
    if (conversation != null) return conversation.updatedAtUnixMs;
    final latest = contact!.latestSession;
    return latest == null ? -1 : conversationSessionSortTime(latest);
  }
}

/// One contact row: the agent group plus its most recent conversation.
final class _MessagingContactEntry {
  const _MessagingContactEntry({
    required this.group,
    required this.sessions,
    required this.latestSession,
    required this.activity,
    required this.pinned,
  });

  final _MessagingContactGroup group;

  /// Parent sessions most-recent-first; unread cycling walks this order.
  final List<AgentConversationSession> sessions;
  final AgentConversationSession? latestSession;
  final AgentConversationTabActivity activity;
  final bool pinned;
}

/// Targets merged under one canonical product name, mirroring the tree
/// sidebar's agent grouping.
final class _MessagingContactGroup {
  _MessagingContactGroup(this.displayName, this.members);

  final String displayName;
  final List<TargetCandidate> members;
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
    return ListView(
      key: const Key('messaging-contact-list-empty'),
      physics: messagingListScrollPhysics,
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Icon(
            Icons.people_outline_rounded,
            size: 22,
            color: colors.textMuted,
          ),
        ),
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
    );
  }
}

class _MessagingNoGroupsEmpty extends StatelessWidget {
  const _MessagingNoGroupsEmpty();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return ListView(
      key: const Key('messaging-contact-list-no-groups'),
      physics: messagingListScrollPhysics,
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Icon(
            Icons.groups_2_outlined,
            size: 22,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          strings.noGroupConversationsYet,
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _MessagingContactRow extends StatelessWidget {
  const _MessagingContactRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    this.unreadCount = 0,
    this.working = false,
    this.loading = false,
    this.onAvatarTap,
    this.onSecondaryTapDown,
  });

  final _MessagingContactEntry entry;
  final bool selected;
  final VoidCallback onTap;

  /// Unread events in the contact's latest session; zero hides the badge.
  final int unreadCount;

  /// Whether the contact's most recent conversation is running a turn — the
  /// Demo's pulsing 工作中 indicator under the timestamp.
  final bool working;

  /// Whether this contact's conversation content is loading — the preview
  /// line and the timestamp render as [MessagingLoadingBar] skeletons.
  final bool loading;

  /// Avatar tap opens the agent's profile card beside the avatar; it does
  /// not select the conversation — the demo's `stopPropagation` semantics.
  final ValueChanged<Rect>? onAvatarTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final ramp = LicoListTypeRamp.of(context);
    final latest = entry.latestSession;
    String subtitle;
    if (latest == null) {
      subtitle = strings.noConversationsYet;
    } else {
      final preview = conversationMessagePreviewText(
        latest.preview,
        chinese: strings.isChinese,
      );
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
        subtitle = historySessionDisplayTitle(
          latest.title.trim().isEmpty ? latest.id : latest.title,
          fallback: '',
        );
      }
    }
    // The tail slot is exclusive: any status pill (working, approval,
    // finished) owns it and the unread badge yields — matching the Demo's
    // one-or-the-other `.conv-side` rule.
    final status = _status(context);
    return Padding(
      padding: const EdgeInsets.only(
        bottom: MessagingDesktopMetrics.sidebarRowGap,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
          hoverColor: LicoSelectionLight.hoverFill(context),
          child: LicoSelectionLight(
            selected: selected,
            radius: LicoRadius.floating,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: MessagingDesktopMetrics.sidebarRowExtent,
              padding: const EdgeInsets.symmetric(
                horizontal: MessagingDesktopMetrics.sidebarRowHorizontalInset,
              ),
              decoration: BoxDecoration(
                // Selected rows fill with the Demo's violet surface; foreground
                // content keeps its normal tones on top.
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(LicoRadius.floating),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _MemberCardTapTarget(
                    key: ValueKey<String>(
                      'messaging-contact-avatar-${entry.group.members.first.target}',
                    ),
                    onOpenCard: onAvatarTap,
                    child: MessagingAgentAvatar(
                      target: entry.group.members.first,
                      activity: entry.activity,
                      size: MessagingDesktopMetrics.sidebarRowLeadingExtent,
                      iconSize: 24,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The Demo's name row: pin + agent tag follow the
                        // shrinking name and drop out — rather than overflow —
                        // once the row is too narrow for all three.
                        LayoutBuilder(
                          builder: (context, nameConstraints) => Row(
                            children: [
                              Flexible(
                                child: Text(
                                  entry.group.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      (unreadCount > 0
                                              ? ramp.titleUnread
                                              : ramp.title)
                                          .copyWith(
                                            color:
                                                selected &&
                                                    !LicoSelectionLight.isStarlight(
                                                      context,
                                                    )
                                                ? colors.selectionInk
                                                : null,
                                          ),
                                ),
                              ),
                              if (entry.pinned &&
                                  nameConstraints.maxWidth >= 44) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.push_pin_rounded,
                                  size: 12,
                                  color: colors.textDisabled,
                                ),
                              ],
                              if (nameConstraints.maxWidth >= 76) ...[
                                const SizedBox(width: 6),
                                _MessagingRowTag(label: strings.memberTagAgent),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        // While the conversation loads, the preview line and
                        // the timestamp become anonymous bars pulsing leading→
                        // trailing instead of showing stale or invented text.
                        if (loading)
                          const FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: 0.72,
                            child: MessagingLoadingBar(
                              key: Key('messaging-row-loading-preview'),
                            ),
                          )
                        else
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: latest == null
                                ? ramp.placeholder
                                : unreadCount > 0
                                ? ramp.previewUnread
                                : ramp.preview,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (loading)
                        const MessagingLoadingBar(
                          key: Key('messaging-row-loading-time'),
                          width: 36,
                          height: 9,
                        )
                      else if (latest != null)
                        Text(
                          conversationSessionRelativeUpdatedAtLabel(
                            latest,
                            chinese: strings.isChinese,
                          ),
                          maxLines: 1,
                          style: unreadCount > 0 ? ramp.metaUnread : ramp.meta,
                        ),
                      if (unreadCount > 0 && status == null)
                        _MessagingUnreadBadge(
                          key: Key(
                            'messaging-unread-badge-${latest?.id ?? ''}',
                          ),
                          count: unreadCount,
                        ),
                      ?status,
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The Demo `.conv-side` status slot under the timestamp: a running turn
  /// pulses green, pending approvals warn gold, finished work glows accent.
  Widget? _status(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    if (working) {
      return _MessagingRowStatus(
        key: const Key('messaging-row-status-working'),
        label: strings.memberStatusWorking,
        color: colors.success,
        pulsing: true,
      );
    }
    switch (entry.activity) {
      case AgentConversationTabActivity.needsApproval:
        return _MessagingRowStatus(
          key: const Key('messaging-row-status-approval'),
          label: strings.memberStatusNeedsApproval,
          color: colors.warning,
        );
      case AgentConversationTabActivity.workFinished:
        return _MessagingRowStatus(
          key: const Key('messaging-row-status-finished'),
          label: strings.agentTabWorkFinished,
          color: colors.accent,
        );
      case AgentConversationTabActivity.none:
        return null;
    }
  }
}

/// Demo `.tag`: a compact identity pill on the name row — `AI` for agent
/// contacts, `N 人` for groups. [helper] picks the accent variant.
final class _MessagingRowTag extends StatelessWidget {
  const _MessagingRowTag({required this.label, this.helper = false});

  final String label;
  final bool helper;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ramp = LicoListTypeRamp.of(context);
    if (ramp.quietTags) {
      // Graded: a quiet hairline token, not a filled chip.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: continuousHairlineDecoration(
          stroke: colors.textMuted.withValues(alpha: 0.35),
          strokeWidth: 0.5,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, maxLines: 1, style: ramp.tag),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
      decoration: BoxDecoration(
        color: helper ? colors.accentSurface : colors.brandSurface,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: ramp.tag.copyWith(
          color: helper ? colors.accent : colors.primaryStrong,
        ),
      ),
    );
  }
}

/// Demo `.unread`: the violet count badge on the row's trailing edge.
/// Counts above 99 collapse to `99+` so the pill never stretches the row.
final class _MessagingUnreadBadge extends StatelessWidget {
  const _MessagingUnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final label = count > 99 ? '99+' : '$count';
    return Semantics(
      label: LicoStrings.of(context).unreadMessagesLabel(count),
      child: Container(
        constraints: const BoxConstraints(minWidth: 18),
        height: 18,
        margin: const EdgeInsets.only(top: 3),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: ConversationVisualTokens.unreadBadgeFill(colors),
          borderRadius: BorderRadius.circular(9),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          maxLines: 1,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// Demo `.conv-status`: a small status readout under the timestamp — a 6px
/// dot plus an 11px label; [pulsing] replays the Demo's `pulse-dot` beat.
final class _MessagingRowStatus extends StatefulWidget {
  const _MessagingRowStatus({
    super.key,
    required this.label,
    required this.color,
    this.pulsing = false,
  });

  final String label;
  final Color color;
  final bool pulsing;

  @override
  State<_MessagingRowStatus> createState() => _MessagingRowStatusState();
}

class _MessagingRowStatusState extends State<_MessagingRowStatus>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _MessagingRowStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulsing != widget.pulsing) _syncPulse();
  }

  void _syncPulse() {
    if (widget.pulsing && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.pulsing
            ? FadeTransition(
                opacity: _pulse
                    .drive(CurveTween(curve: Curves.easeInOut))
                    .drive(Tween(begin: 1.0, end: 0.45)),
                child: ScaleTransition(
                  scale: _pulse
                      .drive(CurveTween(curve: Curves.easeInOut))
                      .drive(Tween(begin: 1.0, end: 0.8)),
                  child: dot,
                ),
              )
            : dot,
        const SizedBox(width: 4),
        Text(
          widget.label,
          maxLines: 1,
          style: LicoListTypeRamp.of(context).status,
        ),
      ],
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
