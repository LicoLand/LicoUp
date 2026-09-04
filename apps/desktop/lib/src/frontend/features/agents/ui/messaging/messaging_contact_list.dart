import 'package:flutter/foundation.dart' show kDebugMode;
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
import 'package:licoup/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_foundation.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Messaging contact list: one row per local conversation agent, like the
/// contact list of a messaging app. Merged products (for example Codex CLI
/// and Codex Desktop) stay one contact with the group representative's brand
/// icon. Rows carry the latest conversation's preview and relative activity
/// time, sort pinned contacts first then by most recent activity, and tapping
/// a contact lands on that agent's new-conversation home (old conversations
/// stay reachable through the recent list and the switcher).
class MessagingContactList extends StatefulWidget {
  const MessagingContactList({
    super.key,
    required this.targets,
    required this.sessionsByAgent,
    required this.selectedAgentId,
    required this.activityFor,
    required this.onSelectAgent,
    required this.onNewConversation,
    this.onSearch,
    this.runningFor,
    this.groupConversations = const [],
    this.selectedGroupConversationId = '',
    this.onSelectGroupConversation,
    this.onSetGroupConversationPinned,
    this.onArchiveGroupConversation,
    this.onNewGroupConversation,
    this.onOpenWelcome,
    this.showConversationList = false,
    this.conversationListTargets = const [],
    this.conversationListRelatedAgentIds,
    this.selectedSessionId = '',
    this.showConversationAgentIcons = false,
    this.onSelectSession,
    this.onBack,
    this.onPrefetchSessions,
    this.isPinned,
    this.onTogglePinned,
    this.priorityAgentId = '',
    this.scanning = false,
    this.loading = false,
    this.activeDestination = ClientSection.agents,
    this.onSelectDestination,
    this.settingsSectionIndex = 0,
    this.onSelectSettingsSection,
  });

  final List<TargetCandidate> targets;
  final Map<String, List<AgentConversationSession>> sessionsByAgent;
  final String selectedAgentId;
  final AgentConversationTabActivity Function(String agentId) activityFor;

  /// Activates an agent, landing on its new-conversation home. Old
  /// conversations stay reachable through the recent list and the switcher.
  final ValueChanged<String> onSelectAgent;
  final VoidCallback onNewConversation;
  final VoidCallback? onSearch;
  final bool Function(AgentConversationSession session)? runningFor;
  final List<ClientConversationSummary> groupConversations;
  final String selectedGroupConversationId;
  final ValueChanged<String>? onSelectGroupConversation;
  final void Function(String conversationId, bool pinned)?
  onSetGroupConversationPinned;
  final ValueChanged<String>? onArchiveGroupConversation;
  final VoidCallback? onNewGroupConversation;
  final VoidCallback? onOpenWelcome;
  final bool showConversationList;
  final List<TargetCandidate> conversationListTargets;
  final Set<String>? conversationListRelatedAgentIds;
  final String selectedSessionId;
  final bool showConversationAgentIcons;
  final void Function(String agentId, String sessionId)? onSelectSession;
  final VoidCallback? onBack;

  /// Kicks a first-page session load for one agent. Invoked once on first
  /// build for every conversation agent without loaded sessions, mirroring
  /// the search palette prefetch.
  final ValueChanged<String>? onPrefetchSessions;
  final bool Function(String targetId)? isPinned;
  final ValueChanged<String>? onTogglePinned;

  /// The group assistant's agent id while the sidebar shows a group's member
  /// conversations: its latest thread pins to the top of the list.
  final String priorityAgentId;
  final bool scanning;
  final bool loading;

  /// Which of the four sidebar tabs is active. The list body follows this
  /// identity; the bottom nav stays mounted across the four destinations.
  final ClientSection activeDestination;
  final ValueChanged<ClientSection>? onSelectDestination;
  final int settingsSectionIndex;
  final ValueChanged<int>? onSelectSettingsSection;

  @override
  State<MessagingContactList> createState() => _MessagingContactListState();
}

class _MessagingContactListState extends State<MessagingContactList> {
  final _createMenuAnchorKey = GlobalKey();
  final Set<String> _prefetchedTargetIds = <String>{};
  bool _earlierExpanded = false;
  bool _otherConversationsExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchUnloadedSessions();
    });
  }

  @override
  void didUpdateWidget(covariant MessagingContactList oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchUnloadedSessions();
    });
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
      if (!_prefetchedTargetIds.add(target.id)) {
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
      case null:
        break;
    }
  }

  bool get _showsConversations =>
      widget.activeDestination == ClientSection.agents;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return MessagingSidebarFoundation(
      key: widget.showConversationList && _showsConversations
          ? const Key('messaging-conversation-list')
          : const Key('messaging-contact-list'),
      heading: messagingSidebarHeading(strings, widget.activeDestination),
      headingKey: const Key('messaging-contact-list-heading'),
      headingActions: _showsConversations
          ? _conversationHeadingActions()
          : null,
      onSearch: widget.onSearch,
      searchBottomPadding: widget.showConversationList
          ? 0
          : LicoContentSpacing.compact,
      contextualAction: _showsConversations && widget.showConversationList
          ? _contextualActionBar()
          : null,
      list: _sidebarBody(),
      bottomNav: MessagingSidebarBottomNav(
        current: widget.activeDestination,
        onSelectDestination: widget.onSelectDestination ?? (_) {},
      ),
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
    if (widget.showConversationList) {
      return SidebarConversationListView(
        entries: flattenSidebarConversations(
          targets: widget.conversationListTargets,
          sessionsByAgent: widget.sessionsByAgent,
          activityFor: widget.activityFor,
        ),
        selectedSessionId: widget.selectedSessionId,
        earlierExpanded: _earlierExpanded,
        relatedAgentIds: widget.conversationListRelatedAgentIds,
        otherConversationsExpanded: _otherConversationsExpanded,
        showAgentIcons: widget.showConversationAgentIcons,
        runningFor: widget.runningFor,
        priorityAgentId: widget.priorityAgentId,
        onToggleEarlier: () =>
            setState(() => _earlierExpanded = !_earlierExpanded),
        onToggleOtherConversations: () => setState(
          () => _otherConversationsExpanded = !_otherConversationsExpanded,
        ),
        onSelectSession: widget.onSelectSession ?? (_, _) {},
      );
    }
    return _contactListBody();
  }

  List<Widget> _conversationHeadingActions() {
    final strings = LicoStrings.of(context);
    return [
      if (kDebugMode && widget.onOpenWelcome != null)
        _MessagingContactActionButton(
          key: const Key('messaging-open-welcome'),
          tooltip: strings.welcome,
          onPressed: widget.onOpenWelcome!,
          icon: Icons.home_outlined,
        ),
      _MessagingContactActionButton(
        key: _createMenuAnchorKey,
        inkWellKey: const Key('messaging-create-conversation'),
        tooltip: strings.createConversation,
        onPressed: _showCreateMenu,
        icon: Icons.add_rounded,
      ),
    ];
  }

  Widget _contextualActionBar() {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        8,
        widget.onSearch == null
            ? 12
            : MessagingDesktopMetrics.sidebarPrimaryControlGap,
        8,
        0,
      ),
      child: SizedBox(
        height: 36,
        child: Tooltip(
          message: strings.conversationBack,
          waitDuration: LicoMotion.tooltipWait,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('messaging-conversation-list-back'),
              onTap: widget.onBack,
              borderRadius: BorderRadius.circular(LicoRadius.floating),
              hoverColor: ConversationVisualTokens.quietRowHover(colors),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.arrow_back_rounded,
                      size: 18,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        strings.conversationBack,
                        key: const Key(
                          'messaging-conversation-list-back-label',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LicoTypography.actionLabel(color: colors.text),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _contactListBody() {
    final listItems = _combinedItems(_entries());
    if (listItems.isEmpty) {
      return _MessagingContactListEmpty(
        scanning: widget.scanning,
        loading: widget.loading,
      );
    }
    return ScrollConfiguration(
      behavior: const _MessagingSlimScrollbarBehavior(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        itemCount: listItems.length,
        itemBuilder: (context, index) {
          final item = listItems[index];
          final conversation = item.groupConversation;
          if (conversation != null) {
            final setPinned = widget.onSetGroupConversationPinned;
            final archive = widget.onArchiveGroupConversation;
            return _MessagingCanonicalGroupRow(
              key: ValueKey<String>(
                'messaging-group-conversation-${conversation.id}',
              ),
              conversation: conversation,
              selected: conversation.id == widget.selectedGroupConversationId,
              onTap: widget.onSelectGroupConversation == null
                  ? null
                  : () => widget.onSelectGroupConversation!(conversation.id),
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
          return _MessagingContactRow(
            key: ValueKey<String>(
              'messaging-contact-${entry.group.members.first.id}',
            ),
            entry: entry,
            selected:
                widget.selectedGroupConversationId.isEmpty &&
                entry.group.members.any(
                  (member) =>
                      member.id == widget.selectedAgentId ||
                      member.target == widget.selectedAgentId,
                ),
            onTap: () => widget.onSelectAgent(entry.group.members.first.id),
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

  List<_MessagingListItem> _combinedItems(
    List<_MessagingContactEntry> entries,
  ) {
    var ordinal = 0;
    final items = <_MessagingListItem>[
      for (final conversation in widget.groupConversations)
        _MessagingListItem.group(conversation, ordinal++),
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

enum _MessagingCreateAction { conversation, group }

enum _MessagingItemAction { togglePin, archive }

class _MessagingCanonicalGroupRow extends StatelessWidget {
  const _MessagingCanonicalGroupRow({
    super.key,
    required this.conversation,
    required this.selected,
    required this.onTap,
    this.onSecondaryTapDown,
  });

  final ClientConversationSummary conversation;
  final bool selected;
  final VoidCallback? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
          hoverColor: ConversationVisualTokens.quietRowHover(colors),
          child: AnimatedContainer(
            duration: LicoMotion.micro,
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? colors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(LicoRadius.floating),
            ),
            child: Row(
              children: [
                Container(
                  key: ValueKey<String>(
                    'messaging-group-avatar-${conversation.id}',
                  ),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: ConversationVisualTokens.circularIdentityWellFill(
                      colors,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.groups_2_rounded,
                    size: 22,
                    color: colors.isDark
                        ? ConversationVisualTokens.groupIdentityMark(colors)
                        : selected
                        ? colors.textOnPrimary
                        : ConversationVisualTokens.groupIdentityMark(colors),
                  ),
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
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: selected
                                    ? colors.textOnPrimary
                                    : colors.text,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (conversation.pinned) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.push_pin_rounded,
                              size: 12,
                              color: selected
                                  ? colors.textOnPrimary.withAlpha(180)
                                  : colors.textMuted,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        strings.groupConversationMemberCount(
                          conversation.membershipCount,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? colors.textOnPrimary.withAlpha(180)
                              : colors.textMuted,
                          fontSize: 12,
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

final class _MessagingListItem {
  const _MessagingListItem._({
    required this.groupConversation,
    required this.contact,
    required this.ordinal,
  });

  factory _MessagingListItem.group(
    ClientConversationSummary conversation,
    int ordinal,
  ) => _MessagingListItem._(
    groupConversation: conversation,
    contact: null,
    ordinal: ordinal,
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
    required this.latestSession,
    required this.activity,
    required this.pinned,
  });

  final _MessagingContactGroup group;
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

class _MessagingContactActionButton extends StatelessWidget {
  const _MessagingContactActionButton({
    super.key,
    this.inkWellKey,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final Key? inkWellKey;
  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Tooltip(
      message: tooltip,
      waitDuration: LicoMotion.tooltipWait,
      child: InkWell(
        key: inkWellKey,
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
    return ListView(
      key: const Key('messaging-contact-list-empty'),
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

class _MessagingContactRow extends StatelessWidget {
  const _MessagingContactRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    this.onSecondaryTapDown,
  });

  final _MessagingContactEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final GestureTapDownCallback? onSecondaryTapDown;

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
          onSecondaryTapDown: onSecondaryTapDown,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
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
              borderRadius: BorderRadius.circular(LicoRadius.floating),
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
                          if (entry.pinned) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.push_pin_rounded,
                              size: 12,
                              color: selected
                                  ? colors.textOnPrimary.withAlpha(180)
                                  : colors.textMuted,
                            ),
                          ],
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
