import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_session_ordering.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

const int messagingChromeTabsMaxCount = 6;

/// Browser-style semantic conversation tabs. Preview/pin/close state remains
/// renderer-local; native catalog ownership and navigation stay in bindings.
class MessagingConversationTabStrip extends StatefulWidget {
  const MessagingConversationTabStrip({
    super.key,
    required this.agents,
    required this.conversation,
    this.onCloseAuxChromePanel,
  });

  final AgentsBinding agents;
  final ConversationBinding conversation;
  final VoidCallback? onCloseAuxChromePanel;

  @override
  State<MessagingConversationTabStrip> createState() =>
      _MessagingConversationTabStripState();
}

class _MessagingConversationTabStripState
    extends State<MessagingConversationTabStrip> {
  final List<String> _pinnedIds = <String>[];
  final Set<String> _userClosedIds = <String>{};
  String _previewId = '';
  bool _previewSuppressed = false;
  String _lastHandledSelectionId = '';

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<AgentsProjection, AgentsProjection>(
      source: widget.agents.projection,
      select: (projection) => projection,
      builder: (context, agents) =>
          ProjectionBuilder<
            NativeConversationCatalogProjection,
            NativeConversationCatalogProjection
          >(
            source: widget.conversation.nativeCatalog,
            select: (projection) => projection,
            builder: (context, catalog) => _buildTabs(context, agents, catalog),
          ),
    );
  }

  Widget _buildTabs(
    BuildContext context,
    AgentsProjection agents,
    NativeConversationCatalogProjection catalog,
  ) {
    final entriesById = _entriesById(agents, catalog);
    final selectedId = _selectedSessionId(catalog);
    _synchronize(selectedId, catalog.runningSessionIds, entriesById);
    final tabIds = <String>[
      ..._pinnedIds,
      if (_previewId.isNotEmpty && !_pinnedIds.contains(_previewId)) _previewId,
    ];
    final colors = context.licoColors;
    return SizedBox(
      key: const Key('messaging-chrome-tab-strip'),
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          for (final sessionId in tabIds.take(messagingChromeTabsMaxCount))
            if (entriesById[sessionId] case final entry?) ...[
              _MessagingChromeTab(
                key: ValueKey<String>('messaging-chrome-tab-$sessionId'),
                entry: entry,
                pinned: _pinnedIds.contains(sessionId),
                selected: sessionId == selectedId,
                onTap: () => _open(entry, catalog),
                onDoubleTap: _pinnedIds.contains(sessionId)
                    ? null
                    : () => _pin(sessionId),
                onClose: _pinnedIds.contains(sessionId)
                    ? () => _close(sessionId, selectedId)
                    : null,
              ),
              const SizedBox(width: 6),
            ],
          _MessagingChromeNewTabButton(
            key: const Key('messaging-chrome-new-tab'),
            tooltip: LicoStrings.of(context).newConversation,
            enabled: agents.selectedAgentId.isNotEmpty,
            onPressed: agents.selectedAgentId.isEmpty
                ? null
                : () => widget.conversation.intents.send(
                    const StartConversationSession(),
                  ),
            colors: colors,
          ),
        ],
      ),
    );
  }

  void _synchronize(
    String selectedId,
    List<String> runningIds,
    Map<String, _MessagingChromeTabEntry> entries,
  ) {
    if (selectedId != _lastHandledSelectionId) {
      _lastHandledSelectionId = selectedId;
      _previewSuppressed = false;
      _userClosedIds.remove(selectedId);
      _previewId = selectedId.isEmpty || _pinnedIds.contains(selectedId)
          ? ''
          : selectedId;
    } else if (_previewSuppressed) {
      _previewId = '';
    }
    for (final runningId in runningIds) {
      if (runningId.isEmpty ||
          _pinnedIds.contains(runningId) ||
          _userClosedIds.contains(runningId) ||
          !entries.containsKey(runningId)) {
        continue;
      }
      _pinnedIds.add(runningId);
      if (_previewId == runningId) _previewId = '';
    }
    _pinnedIds.removeWhere((id) => !entries.containsKey(id));
    if (_previewId.isNotEmpty && !entries.containsKey(_previewId)) {
      _previewId = '';
    }
  }

  void _pin(String sessionId) {
    if (sessionId.isEmpty || _pinnedIds.contains(sessionId)) return;
    setState(() {
      _pinnedIds.add(sessionId);
      _userClosedIds.remove(sessionId);
      if (_previewId == sessionId) _previewId = '';
    });
  }

  void _close(String sessionId, String selectedId) {
    setState(() {
      _pinnedIds.remove(sessionId);
      _userClosedIds.add(sessionId);
      if (sessionId == selectedId) _previewSuppressed = true;
    });
  }

  Map<String, _MessagingChromeTabEntry> _entriesById(
    AgentsProjection agents,
    NativeConversationCatalogProjection catalog,
  ) {
    final targets = agents.targetDetails
        .where((target) => target.visibleInClient && target.isConversationAgent)
        .toList(growable: false);
    final byAgent = <String, List<AgentConversationSession>>{
      for (final group in catalog.agentCatalogs) group.agentId: group.sessions,
    };
    if (agents.selectedAgentId.isNotEmpty &&
        catalog.nativeSessions.isNotEmpty) {
      byAgent.putIfAbsent(agents.selectedAgentId, () => catalog.nativeSessions);
    }
    final result = <String, _MessagingChromeTabEntry>{};
    for (final target in targets) {
      final sessions = byAgent[target.id] ?? byAgent[target.target] ?? const [];
      for (final session in sortConversationSessionsByUpdatedAt(sessions)) {
        result.putIfAbsent(
          session.id,
          () => _MessagingChromeTabEntry(
            session: session,
            owner: target,
            iconTarget: target,
          ),
        );
      }
    }
    return result;
  }

  String _selectedSessionId(NativeConversationCatalogProjection catalog) {
    for (final session in catalog.sessions) {
      if (session.selected) return session.id;
    }
    return '';
  }

  void _open(
    _MessagingChromeTabEntry entry,
    NativeConversationCatalogProjection catalog,
  ) {
    final resolvedId = _currentSessionId(entry, catalog);
    if (resolvedId == null) return;
    widget.onCloseAuxChromePanel?.call();
    widget.agents.intents.send(
      SelectAgentConversationSession(
        agentId: entry.owner.id,
        sessionId: resolvedId,
        nativeSessionId: entry.session.nativeSessionId,
      ),
    );
  }

  String? _currentSessionId(
    _MessagingChromeTabEntry entry,
    NativeConversationCatalogProjection catalog,
  ) {
    final groups = catalog.agentCatalogs.where(
      (group) =>
          group.agentId == entry.owner.id ||
          group.agentId == entry.owner.target,
    );
    final sessions = groups.isEmpty
        ? catalog.nativeSessions
        : groups.expand((group) => group.sessions);
    for (final session in sessions) {
      if (session.id == entry.session.id) return session.id;
    }
    final nativeId = entry.session.nativeSessionId.trim();
    if (nativeId.isNotEmpty) {
      for (final session in sessions) {
        if (session.nativeSessionId.trim() == nativeId) return session.id;
      }
    }
    return null;
  }
}

final class _MessagingChromeTabEntry {
  const _MessagingChromeTabEntry({
    required this.session,
    required this.owner,
    required this.iconTarget,
  });

  final AgentConversationSession session;
  final TargetCandidate owner;
  final TargetCandidate iconTarget;
}

class _MessagingChromeTab extends StatefulWidget {
  const _MessagingChromeTab({
    super.key,
    required this.entry,
    required this.pinned,
    required this.selected,
    required this.onTap,
    this.onDoubleTap,
    this.onClose,
  });

  final _MessagingChromeTabEntry entry;
  final bool pinned;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onClose;

  @override
  State<_MessagingChromeTab> createState() => _MessagingChromeTabState();
}

class _MessagingChromeTabState extends State<_MessagingChromeTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final session = widget.entry.session;
    final title = historySessionDisplayTitle(
      session.title,
      fallback: conversationSessionRelativeUpdatedAtLabel(session),
    );
    return Tooltip(
      message: title,
      waitDuration: LicoMotion.tooltipWait,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            height: 30,
            constraints: const BoxConstraints(maxWidth: 176),
            padding: EdgeInsets.only(left: 10, right: widget.pinned ? 6 : 10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? MessagingDesktopMetrics.chromeTabSelectedFill(
                      isDark: colors.isDark,
                    )
                  : _hovered
                  ? MessagingDesktopMetrics.chromeControlHover(
                      isDark: colors.isDark,
                    )
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              border: widget.selected
                  ? Border.all(color: colors.line.withAlpha(70), width: 0.5)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AgentBrandIcon(
                  target: widget.entry.iconTarget,
                  size: 18,
                  iconSize: 13,
                  selected: false,
                  detected:
                      widget.entry.iconTarget.status ==
                          TargetCandidateStatus.detected ||
                      widget.entry.iconTarget.configured,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.selected
                          ? MessagingDesktopMetrics.chromeForeground()
                          : MessagingDesktopMetrics.chromeIconMuted(),
                      fontSize: 12,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      fontStyle: widget.pinned
                          ? FontStyle.normal
                          : FontStyle.italic,
                      height: 1.1,
                    ),
                  ),
                ),
                if (widget.onClose != null) ...[
                  const SizedBox(width: 4),
                  AnimatedOpacity(
                    opacity: _hovered ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: GestureDetector(
                      key: const Key('messaging-chrome-tab-close'),
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onClose,
                      child: SizedBox.square(
                        dimension: 16,
                        child: Icon(
                          Icons.close_rounded,
                          size: 13,
                          color: MessagingDesktopMetrics.chromeIconMuted(),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessagingChromeNewTabButton extends StatelessWidget {
  const _MessagingChromeNewTabButton({
    super.key,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
    required this.colors,
  });

  final String tooltip;
  final bool enabled;
  final VoidCallback? onPressed;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: LicoMotion.tooltipWait,
    child: InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      hoverColor: MessagingDesktopMetrics.chromeControlHover(
        isDark: colors.isDark,
      ),
      child: SizedBox.square(
        dimension: 30,
        child: Icon(
          Icons.add_rounded,
          size: 17,
          color: enabled
              ? MessagingDesktopMetrics.chromeIconMuted()
              : MessagingDesktopMetrics.chromeIconDisabled(),
        ),
      ),
    ),
  );
}
