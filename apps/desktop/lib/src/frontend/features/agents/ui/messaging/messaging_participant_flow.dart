import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_log_event_row.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_update_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_details_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_message_group.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_process_status_row.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_scroll_to_latest_button.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

/// Longest silence between two consecutive same-author messages that still
/// renders as one participant-flow group.
const Duration messagingFlowMaxGroupGap = Duration(minutes: 7);

/// One entry of the messaging participant flow, derived from the shared
/// conversation timeline.
sealed class MessagingFlowEntry {
  const MessagingFlowEntry();
}

/// Hairline day divider with a centered Today / Yesterday / date label.
final class MessagingFlowDayDivider extends MessagingFlowEntry {
  const MessagingFlowDayDivider(this.day);

  final DateTime day;
}

/// Consecutive messages from one author, rendered under one group header.
final class MessagingFlowMessageGroup extends MessagingFlowEntry {
  const MessagingFlowMessageGroup({
    required this.authorIsUser,
    required this.participantAgentId,
    required this.participantLabel,
    required this.participantRole,
    required this.messages,
  });

  final bool authorIsUser;
  final String participantAgentId;
  final String participantLabel;
  final String participantRole;
  final List<AgentConversationMessage> messages;
}

/// A structured process run, rendered as an inline status row.
final class MessagingFlowProcess extends MessagingFlowEntry {
  const MessagingFlowProcess(this.item, {required this.active});

  final ConversationProcessTimelineItem item;
  final bool active;
}

final class MessagingFlowLog extends MessagingFlowEntry {
  const MessagingFlowLog(this.item);

  final ConversationLogTimelineItem item;
}

/// The agent runtime auto-update card, kept in its existing rendering.
final class MessagingFlowRuntimeUpdate extends MessagingFlowEntry {
  const MessagingFlowRuntimeUpdate(this.item);

  final ConversationRuntimeUpdateTimelineItem item;
}

/// A subagent card, kept in its existing rendering inside the content column.
final class MessagingFlowSubagent extends MessagingFlowEntry {
  const MessagingFlowSubagent(this.item);

  final ConversationMessageTimelineItem item;
}

/// The shared truncation notice, unchanged inside the flow.
final class MessagingFlowTruncation extends MessagingFlowEntry {
  const MessagingFlowTruncation(this.item);

  final ConversationTruncationTimelineItem item;
}

/// Projects chronological timeline items into participant-flow entries:
/// consecutive same-author user/assistant messages group together, groups
/// break on process items, subagent cards, and silences longer than
/// [maxGroupGap], and local-day changes insert day dividers.
///
/// When [preferPeerAgents] is true (Lico group Conversation), subagent cards
/// are projected as ordinary peer assistant message groups instead of nested
/// cards.
List<MessagingFlowEntry> buildMessagingFlowEntries(
  List<ConversationTimelineItem> chronologicalItems, {
  String activeProcessStorageKey = '',
  Duration maxGroupGap = messagingFlowMaxGroupGap,
  bool preferPeerAgents = false,
}) {
  final entries = <MessagingFlowEntry>[];
  var currentAuthorIsUser = false;
  var currentParticipantAgentId = '';
  var currentParticipantLabel = '';
  var currentParticipantRole = '';
  var currentMessages = <AgentConversationMessage>[];
  DateTime? lastMessageTime;
  DateTime? lastDay;

  void flushGroup() {
    if (currentMessages.isEmpty) {
      return;
    }
    entries.add(
      MessagingFlowMessageGroup(
        authorIsUser: currentAuthorIsUser,
        participantAgentId: currentParticipantAgentId,
        participantLabel: currentParticipantLabel,
        participantRole: currentParticipantRole,
        messages: List<AgentConversationMessage>.unmodifiable(currentMessages),
      ),
    );
    currentMessages = <AgentConversationMessage>[];
    currentParticipantAgentId = '';
    currentParticipantLabel = '';
    currentParticipantRole = '';
  }

  void trackDay(DateTime? time) {
    if (time == null) {
      return;
    }
    final day = DateTime(time.year, time.month, time.day);
    if (lastDay == null || day != lastDay) {
      flushGroup();
      entries.add(MessagingFlowDayDivider(day));
      lastDay = day;
    }
  }

  for (final item in chronologicalItems) {
    switch (item) {
      case ConversationMessageTimelineItem(:final message):
        final kind = message.kind;
        final isUser = kind == AgentConversationMessageKind.user;
        final isAssistant = kind == AgentConversationMessageKind.assistant;
        if (!isUser && !isAssistant) {
          if (preferPeerAgents && message.isSubagentCard) {
            flushGroup();
            trackDay(parseAgentConversationTimestamp(message.createdAt));
            final peerText = message.text.trim().isNotEmpty
                ? message.text
                : message.cardTitle;
            final peer = AgentConversationMessage(
              id: message.id,
              role: 'assistant',
              text: peerText,
              createdAt: message.createdAt,
              layer: AgentConversationSemanticLayer.thread,
              participantAgentId: message.participantAgentId,
              participantLabel: message.participantLabel.trim().isNotEmpty
                  ? message.participantLabel
                  : message.cardTitle,
              participantRole: message.participantRole.trim().isNotEmpty
                  ? message.participantRole
                  : 'peer-agent',
              images: message.images,
            );
            entries.add(
              MessagingFlowMessageGroup(
                authorIsUser: false,
                participantAgentId: peer.participantAgentId.trim(),
                participantLabel: peer.participantLabel.trim(),
                participantRole: peer.participantRole.trim(),
                messages: List<AgentConversationMessage>.unmodifiable([peer]),
              ),
            );
            lastMessageTime =
                parseAgentConversationTimestamp(message.createdAt) ??
                lastMessageTime;
            continue;
          }
          flushGroup();
          entries.add(MessagingFlowSubagent(item));
          continue;
        }
        final time = parseAgentConversationTimestamp(message.createdAt);
        trackDay(time);
        final gap = time != null && lastMessageTime != null
            ? time.difference(lastMessageTime)
            : null;
        final participantAgentId = isUser
            ? ''
            : message.participantAgentId.trim();
        final participantLabel = isUser ? '' : message.participantLabel.trim();
        final participantRole = isUser ? '' : message.participantRole.trim();
        final participantChanged =
            currentMessages.isNotEmpty &&
            (currentParticipantAgentId != participantAgentId ||
                currentParticipantLabel != participantLabel ||
                currentParticipantRole != participantRole);
        if (currentMessages.isNotEmpty &&
            (currentAuthorIsUser != isUser ||
                participantChanged ||
                (gap != null && gap > maxGroupGap))) {
          flushGroup();
        }
        currentAuthorIsUser = isUser;
        currentParticipantAgentId = participantAgentId;
        currentParticipantLabel = participantLabel;
        currentParticipantRole = participantRole;
        currentMessages.add(message);
        lastMessageTime = time ?? lastMessageTime;
      case ConversationProcessTimelineItem():
        flushGroup();
        entries.add(
          MessagingFlowProcess(
            item,
            active: item.storageKey == activeProcessStorageKey,
          ),
        );
      case ConversationLogTimelineItem():
        flushGroup();
        entries.add(MessagingFlowLog(item));
      case ConversationRuntimeUpdateTimelineItem():
        flushGroup();
        entries.add(MessagingFlowRuntimeUpdate(item));
      case ConversationTruncationTimelineItem():
        flushGroup();
        entries.add(MessagingFlowTruncation(item));
    }
  }
  flushGroup();
  return List<MessagingFlowEntry>.unmodifiable(entries);
}

/// Discord-style participant flow: messages group by author under one header
/// (avatar, name, AGENT badge), process runs collapse into inline status rows,
/// and day dividers separate local days. The same timeline data the console
/// transcript renders, projected into a chat surface.
///
/// Long transcripts load in pages: the newest [initialEntryWindow] flow
/// entries render first and scrolling to the top pulls in earlier entries,
/// so exploring history is progressive instead of truncated.
class MessagingParticipantFlow extends StatefulWidget {
  const MessagingParticipantFlow({
    super.key,
    required this.items,
    required this.adapter,
    required this.target,
    this.activeProcessStorageKey = '',
    this.sessionKey = '',
    this.participantTargets = const [],
    this.participantConversationIds = const {},
    this.primaryConversationId = '',
    this.preferPeerAgents = false,
    this.topOverlayInset = 0,
    this.bottomOverlayInset = 0,
    this.scrollController,
  });

  /// Flow entries (after author grouping) shown before the user scrolls.
  static const int initialEntryWindow = 50;

  /// Flow entries added each time the user scrolls to the top of the loaded
  /// history.
  static const int earlierEntryPage = 50;

  /// Distance from the top of the loaded history that starts loading the
  /// earlier page, so the request finishes before the user hits the edge.
  static const double earlierPageLeadIn = 120;

  /// Timeline items in the message-list cache order (newest first).
  final List<ConversationTimelineItem> items;
  final AgentRenderAdapter adapter;
  final TargetCandidate target;
  final String activeProcessStorageKey;
  final String sessionKey;
  final List<TargetCandidate> participantTargets;

  /// Agent id → that agent's conversation id for hover metadata.
  final Map<String, String> participantConversationIds;

  /// Fallback conversation id when a message has no participant agent id.
  final String primaryConversationId;

  /// Lico group Conversation: render delegated agents as peer bubbles.
  final bool preferPeerAgents;

  /// Extra top padding when a floating header overlays the transcript.
  final double topOverlayInset;

  /// Extra bottom padding when a floating composer overlays the transcript.
  final double bottomOverlayInset;

  /// Optional owner for coordinating a floating child scroll surface with
  /// the transcript viewport.
  final ScrollController? scrollController;

  @override
  State<MessagingParticipantFlow> createState() =>
      _MessagingParticipantFlowState();
}

class _MessagingParticipantFlowState extends State<MessagingParticipantFlow> {
  late int _visibleEntryCount;
  ScrollController? _ownedScrollController;
  bool _atLatest = true;

  /// Reverse lists keep the newest rows at offset 0. Treat a small residual
  /// as still "at latest" so the control does not flicker.
  static const double _atLatestThreshold = 48;

  ScrollController get _scrollController =>
      widget.scrollController ?? _ownedScrollController!;

  @override
  void initState() {
    super.initState();
    _visibleEntryCount = MessagingParticipantFlow.initialEntryWindow;
    if (widget.scrollController == null) {
      _ownedScrollController = ScrollController();
    }
    _scrollController.addListener(_syncAtLatest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAtLatest());
  }

  @override
  void didUpdateWidget(MessagingParticipantFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionKey != widget.sessionKey) {
      // A different conversation starts from its own newest window.
      _visibleEntryCount = MessagingParticipantFlow.initialEntryWindow;
      _atLatest = true;
    }
    if (oldWidget.scrollController != widget.scrollController) {
      (oldWidget.scrollController ?? _ownedScrollController)?.removeListener(
        _syncAtLatest,
      );
      if (widget.scrollController == null) {
        _ownedScrollController ??= ScrollController();
      } else {
        _ownedScrollController?.dispose();
        _ownedScrollController = null;
      }
      _scrollController.addListener(_syncAtLatest);
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncAtLatest());
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_syncAtLatest);
    _ownedScrollController?.dispose();
    super.dispose();
  }

  void _syncAtLatest() {
    final atLatest =
        !_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent <= 0 ||
        _scrollController.position.pixels <= _atLatestThreshold;
    if (atLatest == _atLatest || !mounted) {
      return;
    }
    setState(() => _atLatest = atLatest);
  }

  void _jumpToLatest() {
    if (!_scrollController.hasClients) {
      return;
    }
    _scrollController.jumpTo(0);
    _syncAtLatest();
  }

  TargetCandidate? _participantTarget(String participantAgentId) {
    final normalized = participantAgentId.trim();
    if (normalized.isEmpty) return null;
    for (final candidate in widget.participantTargets) {
      if (candidate.target == normalized) return candidate;
    }
    return null;
  }

  bool _loadEarlierOnScroll(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }
    final metrics = notification.metrics;
    final total = _displayEntries.length;
    if (_visibleEntryCount >= total) {
      return false;
    }
    if (metrics.pixels <
        metrics.maxScrollExtent - MessagingParticipantFlow.earlierPageLeadIn) {
      return false;
    }
    setState(() {
      _visibleEntryCount =
          (_visibleEntryCount + MessagingParticipantFlow.earlierEntryPage)
              .clamp(0, total);
    });
    return false;
  }

  List<MessagingFlowEntry> get _displayEntries {
    final entries = buildMessagingFlowEntries(
      widget.items.reversed.toList(growable: false),
      activeProcessStorageKey: widget.activeProcessStorageKey,
      preferPeerAgents: widget.preferPeerAgents,
    );
    return entries.reversed.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final displayEntries = _displayEntries;
    final visibleEntries = displayEntries.take(_visibleEntryCount).toList();
    // Conversation text must be selectable and copyable. Selection is hosted at
    // the scroll level so a drag can span several messages; it only reaches the
    // rows the list has built, which is why individual messages also expose an
    // explicit copy action. Chrome that would pollute a selection — process
    // rows, log rows — opts out with SelectionContainer.disabled at its own
    // site.
    return NotificationListener<ScrollNotification>(
      onNotification: _loadEarlierOnScroll,
      child: SelectionArea(
        child: Stack(
          children: [
            ListView.builder(
              controller: _scrollController,
              key: PageStorageKey<String>(
                'messaging-participant-flow-${widget.sessionKey}',
              ),
              reverse: true,
              padding: EdgeInsets.fromLTRB(
                LicoContentSpacing.item,
                LicoContentSpacing.item + widget.topOverlayInset,
                LicoContentSpacing.item,
                LicoContentSpacing.item +
                    widget.adapter.assistantVerticalPadding +
                    widget.bottomOverlayInset,
              ),
              itemCount: visibleEntries.length,
              itemBuilder: (context, index) {
                final entry = visibleEntries[index];
                // A streamed reply changes one entry per frame. Without a
                // repaint boundary per entry the whole visible flow
                // repaints with it.
                return RepaintBoundary(child: _entryContent(context, entry));
              },
            ),
            if (!_atLatest)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom:
                        widget.bottomOverlayInset +
                        MessagingDesktopMetrics.conversationScrollToLatestGap,
                  ),
                  child: SelectionContainer.disabled(
                    child: MessagingScrollToLatestButton(
                      key: const Key('conversation-scroll-to-latest'),
                      onPressed: _jumpToLatest,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _entryContent(BuildContext context, MessagingFlowEntry entry) {
    return switch (entry) {
      MessagingFlowDayDivider(:final day) => _MessagingDayDividerRow(day: day),
      MessagingFlowMessageGroup(
        :final authorIsUser,
        :final participantAgentId,
        :final participantLabel,
        :final participantRole,
        :final messages,
      ) =>
        Padding(
          padding: LicoContentSpacing.peerItem,
          child: MessagingMessageGroup(
            authorIsUser: authorIsUser,
            participantLabel: participantLabel,
            participantRole: participantRole,
            participantTarget: _participantTarget(participantAgentId),
            messages: messages,
            target: widget.target,
            adapter: widget.adapter,
            conversationId: messagingHoverConversationId(
              authorIsUser: authorIsUser,
              participantAgentId: participantAgentId,
              participantConversationIds: widget.participantConversationIds,
              primaryConversationId: widget.primaryConversationId,
            ),
          ),
        ),
      MessagingFlowProcess(:final item, :final active) => Padding(
        padding: LicoContentSpacing.peerItem,
        child: SelectionContainer.disabled(
          child: MessagingProcessStatusRow(
            events: item.events,
            adapter: widget.adapter,
            detailsBuilder: buildAgentConversationEventDetails,
            active: active,
            topOverlayInset: widget.topOverlayInset,
          ),
        ),
      ),
      MessagingFlowLog(:final item) => Padding(
        padding: LicoContentSpacing.peerItem,
        child: SelectionContainer.disabled(
          child: ConversationLogEventRow(
            events: item.events,
            detailsBuilder: buildAgentConversationEventDetails,
          ),
        ),
      ),
      MessagingFlowRuntimeUpdate(:final item) => Padding(
        padding: LicoContentSpacing.peerItem,
        child: SelectionContainer.disabled(
          child: AgentRuntimeUpdateCard(
            message: item.message,
            adapter: widget.adapter,
          ),
        ),
      ),
      MessagingFlowSubagent(:final item) => Padding(
        padding: LicoContentSpacing.peerItem,
        child: AgentConversationSubagentCardBlock(
          message: item.message,
          adapter: widget.adapter,
          fullWidth: true,
        ),
      ),
      MessagingFlowTruncation(:final item) => Padding(
        padding: LicoContentSpacing.peerItem,
        child: ConversationTruncationNotice(
          historyTruncated: item.historyTruncated,
          messageTreeTruncated: item.messageTreeTruncated,
        ),
      ),
    };
  }
}

class _MessagingDayDividerRow extends StatelessWidget {
  const _MessagingDayDividerRow({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final label = day == today
        ? strings.today
        : day == today.subtract(const Duration(days: 1))
        ? strings.yesterday
        : MaterialLocalizations.of(context).formatMediumDate(day);
    return Padding(
      key: const Key('messaging-day-divider'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(child: Divider(height: 1, color: colors.line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Divider(height: 1, color: colors.line)),
        ],
      ),
    );
  }
}
