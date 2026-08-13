import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Most tabs hosted at once in the chrome band (permanent first, the
/// temporary preview tab last).
const int messagingChromeTabsMaxCount = 6;

/// Browser-style conversation tabs with the VSCode preview-tab convention:
/// opening a conversation from anywhere (this strip, the contact list, or
/// the switcher) shows it as one italic TEMPORARY tab that replaces any
/// previous temporary tab; a tab pins PERMANENT once the user sends a
/// message in that session or double-clicks the temporary tab. Permanent
/// tabs render non-italic and offer a hover close affordance that removes
/// only the tab. State is session-scoped presentation state held by this
/// widget — nothing is persisted.
class MessagingConversationTabStrip extends StatefulWidget {
  const MessagingConversationTabStrip({
    super.key,
    required this.controller,
    this.onCloseAuxChromePanel,
  });

  final ClientController controller;

  /// Invoked when a tab opens a conversation so an auxiliary chrome panel
  /// (for example the messaging profile page) closes alongside the
  /// destination switch.
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

  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_sync);
    controller.conversationStructureListenable.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant MessagingConversationTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      oldWidget.controller.conversationStructureListenable.removeListener(
        _sync,
      );
      controller.addListener(_sync);
      controller.conversationStructureListenable.addListener(_sync);
      _pinnedIds.clear();
      _userClosedIds.clear();
      _previewId = '';
      _previewSuppressed = false;
      _lastHandledSelectionId = '';
      _sync();
    }
  }

  @override
  void dispose() {
    controller.removeListener(_sync);
    controller.conversationStructureListenable.removeListener(_sync);
    super.dispose();
  }

  /// Same conversation-agent catalog the workspace sidebar uses.
  List<TargetCandidate> _conversationTabTargets() {
    return controller.orderedConversationTargets(
      controller.scannedTargets.where((target) => target.visibleInClient),
    );
  }

  /// The session that counts as "the user executed this conversation":
  /// the in-flight send's session, falling back to the selected session
  /// during an active turn (first send of a new conversation), matched by
  /// native id once readback lands.
  String _sendingSessionId() {
    final direct = controller.sendingConversationSessionId.trim();
    if (direct.isNotEmpty) {
      return direct;
    }
    if (!controller.isSendingConversationMessage) {
      return '';
    }
    final nativeId = controller.sendingConversationNativeSessionId.trim();
    if (nativeId.isNotEmpty) {
      for (final session in controller.selectedConversationSessions) {
        if (session.nativeSessionId.trim() == nativeId) {
          return session.id;
        }
      }
    }
    return controller.selectedConversationSession?.id.trim() ?? '';
  }

  void _pin(String sessionId) {
    if (sessionId.isEmpty || _pinnedIds.contains(sessionId)) {
      return;
    }
    setState(() {
      _pinnedIds.add(sessionId);
      _userClosedIds.remove(sessionId);
      if (_previewId == sessionId) {
        _previewId = '';
      }
    });
  }

  void _close(String sessionId) {
    final selectedId = controller.selectedConversationSession?.id.trim() ?? '';
    setState(() {
      _pinnedIds.remove(sessionId);
      // An explicit close wins over the in-flight auto-pin: the tab must not
      // be re-added by the next controller notification while this session
      // is still sending.
      _userClosedIds.add(sessionId);
      // Closing the open conversation's tab hides it without reviving the
      // preview slot until the user opens another conversation.
      if (sessionId == selectedId) {
        _previewSuppressed = true;
      }
    });
  }

  void _sync() {
    if (!mounted) {
      return;
    }
    final selectedId = controller.selectedConversationSession?.id.trim() ?? '';
    final sendingId = _sendingSessionId();

    var nextPreview = _previewId;
    var nextSuppressed = _previewSuppressed;
    if (selectedId != _lastHandledSelectionId) {
      _lastHandledSelectionId = selectedId;
      nextSuppressed = false;
      // Reopening a conversation restores its auto-pin rights: only a close
      // while the tab is hidden counts as user intent to keep it hidden.
      _userClosedIds.remove(selectedId);
      if (selectedId.isEmpty || _pinnedIds.contains(selectedId)) {
        nextPreview = '';
      } else if (selectedId == sendingId) {
        nextPreview = '';
      } else {
        // Opening a conversation from anywhere previews it, replacing any
        // previous temporary tab.
        nextPreview = selectedId;
      }
    } else if (nextSuppressed) {
      nextPreview = '';
    }

    var pinnedChanged = false;
    if (sendingId.isNotEmpty &&
        !_pinnedIds.contains(sendingId) &&
        !_userClosedIds.contains(sendingId)) {
      pinnedChanged = true;
    }
    final previewChanged =
        nextPreview != _previewId || nextSuppressed != _previewSuppressed;
    final catalogCanRenderPreview =
        nextPreview.isEmpty || _entriesById().containsKey(nextPreview);
    if (!pinnedChanged && !previewChanged && catalogCanRenderPreview) {
      return;
    }
    setState(() {
      if (pinnedChanged) {
        _pinnedIds.add(sendingId);
        if (nextPreview == sendingId) {
          nextPreview = '';
        }
      }
      _previewId = nextPreview;
      _previewSuppressed = nextSuppressed;
    });
  }

  Map<String, _MessagingChromeTabEntry> _entriesById() {
    final groups = <_MessagingChromeTabGroup>[];
    final indexByName = <String, int>{};
    for (final target in _conversationTabTargets()) {
      if (!target.isConversationAgent) {
        continue;
      }
      final name = agentConversationTargetDisplayName(target);
      final key = name.toLowerCase();
      final index = indexByName[key];
      if (index == null) {
        indexByName[key] = groups.length;
        groups.add(_MessagingChromeTabGroup([target]));
      } else {
        groups[index].members.add(target);
      }
    }
    final ownerBySessionId = <String, TargetCandidate>{};
    final iconBySessionId = <String, TargetCandidate>{};
    final seenSessionIds = <String>{};
    final sessions = <AgentConversationSession>[];
    for (final group in groups) {
      for (final member in group.members) {
        final memberSessions =
            controller.conversationSessionsByAgent[member.id] ??
            controller.conversationSessionsByAgent[member.target] ??
            const <AgentConversationSession>[];
        for (final session in memberSessions) {
          if (seenSessionIds.add(session.id)) {
            sessions.add(session);
            ownerBySessionId[session.id] = member;
            iconBySessionId[session.id] = group.members.first;
          }
        }
      }
    }
    final sorted = sortConversationSessionsByUpdatedAt(sessions);
    return {
      for (final session in sorted)
        session.id: _MessagingChromeTabEntry(
          session: session,
          owner: ownerBySessionId[session.id]!,
          iconTarget: iconBySessionId[session.id]!,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final entriesById = _entriesById();
    final tabIds = [
      ..._pinnedIds,
      if (_previewId.isNotEmpty && !_pinnedIds.contains(_previewId)) _previewId,
    ];
    // Highlight follows the selected session, not the agent: several tabs of
    // one agent must not all light up, and a selected session without a
    // rendered tab (suppressed preview or closed tab) highlights nothing.
    final selectedSessionId =
        controller.selectedConversationSession?.id.trim() ?? '';
    final canStartNew = controller.selectedConversationAgent != null;
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
                selected: sessionId == selectedSessionId,
                onTap: () => unawaited(_open(entry)),
                onDoubleTap: _pinnedIds.contains(sessionId)
                    ? null
                    : () => _pin(sessionId),
                onClose: _pinnedIds.contains(sessionId)
                    ? () => _close(sessionId)
                    : null,
              ),
              const SizedBox(width: 6),
            ],
          _MessagingChromeNewTabButton(
            key: const Key('messaging-chrome-new-tab'),
            tooltip: strings.newConversation,
            enabled: canStartNew,
            onPressed: canStartNew
                ? controller.startNewConversationSession
                : null,
            colors: colors,
          ),
        ],
      ),
    );
  }

  Future<void> _open(_MessagingChromeTabEntry entry) async {
    final resolvedId = _currentSessionId(entry);
    if (resolvedId == null) {
      // The session vanished from the local catalog (a refresh re-emitted it
      // without an id or native-id match). Keep the current view instead of
      // navigating into an empty "no messages" state.
      return;
    }
    controller.selectSection(ClientSection.agents);
    widget.onCloseAuxChromePanel?.call();
    if (controller.selectedConversationAgentId != entry.owner.target) {
      await controller.selectConversationAgent(entry.owner.id);
    }
    controller.selectConversationSession(resolvedId);
  }

  /// Resolves the tab's session against the catalog as it stands at tap
  /// time: the exact id first, then the stable native session id so a tab
  /// survives a refresh that re-emitted the session under a fresh id.
  String? _currentSessionId(_MessagingChromeTabEntry entry) {
    final sessions =
        controller.conversationSessionsByAgent[entry.owner.id] ??
        controller.conversationSessionsByAgent[entry.owner.target] ??
        const <AgentConversationSession>[];
    final wantedId = entry.session.id;
    for (final session in sessions) {
      if (session.id == wantedId) {
        return session.id;
      }
    }
    final nativeId = entry.session.nativeSessionId.trim();
    if (nativeId.isNotEmpty) {
      for (final session in sessions) {
        if (session.nativeSessionId.trim() == nativeId) {
          return session.id;
        }
      }
    }
    return null;
  }
}

final class _MessagingChromeTabGroup {
  _MessagingChromeTabGroup(this.members);

  final List<TargetCandidate> members;
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
    final dark = colors.isDark;
    final session = widget.entry.session;
    final title = session.title.trim().isEmpty
        ? conversationSessionRelativeUpdatedAtLabel(session)
        : session.title;
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
                  ? MessagingDesktopMetrics.chromeTabSelectedFill(isDark: dark)
                  : _hovered
                  ? MessagingDesktopMetrics.chromeControlHover(isDark: dark)
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
                      widget.entry.iconTarget.status == 'detected' ||
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
  Widget build(BuildContext context) {
    return Tooltip(
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
}
