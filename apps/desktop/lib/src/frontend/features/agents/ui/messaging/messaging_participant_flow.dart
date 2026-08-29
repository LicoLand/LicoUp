import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_log_event_row.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_update_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
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
/// Long transcripts remain lazy through [ListView.builder]. Reaching the
/// oldest loaded edge asks the controller for the next native message page.
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
    this.participantRuntimeProfiles = const {},
    this.assistantActive = false,
    this.primaryConversationId = '',
    this.preferPeerAgents = false,
    this.topOverlayInset = 0,
    this.bottomOverlayInset = 0,
    this.scrollController,
    this.onCopyText,
    this.messagePageLoading = false,
    this.messagePageError = '',
    this.hasEarlier = false,
    this.onLoadEarlier,
  });

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
  final Map<String, AgentParticipantRuntimeProfile> participantRuntimeProfiles;

  /// Whether the group assistant lane is active; forwarded to assistant
  /// message groups so the header mark follows the toggle.
  final bool assistantActive;

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

  /// Clipboard write routed through the platform boundary; message rows
  /// expose an explicit copy action when present.
  final Future<void> Function(String)? onCopyText;
  final bool messagePageLoading;
  final String messagePageError;
  final bool hasEarlier;
  final Future<void> Function()? onLoadEarlier;

  @override
  State<MessagingParticipantFlow> createState() =>
      _MessagingParticipantFlowState();
}

/// Incremental patch for streamed-text revisions anywhere in the timeline.
///
/// A streaming reply republishes the timeline every few frames while usually
/// only text changes. With multiple concurrent group turns, the changed
/// message may sit anywhere in the live list, not just at the newest item.
/// Rebuilding the whole entry list on each publish is O(history); this patch
/// instead swaps the affected flow entries and keeps every other entry's
/// object identity so Flutter skips their rebuild.
///
/// Returns null when the change is not a pure set of message text revisions —
/// the caller then rebuilds the entry list, which stays the only path allowed
/// to change structure.
List<MessagingFlowEntry>? patchMessagingFlowStreamedMessages({
  required List<ConversationTimelineItem> previousItems,
  required List<ConversationTimelineItem> nextItems,
  required List<MessagingFlowEntry> previousEntries,
}) {
  if (previousItems.length != nextItems.length || previousEntries.isEmpty) {
    return null;
  }
  final changedIndices = <int>[];
  for (var index = 0; index < nextItems.length; index += 1) {
    if (identical(previousItems[index], nextItems[index])) continue;
    final previous = previousItems[index];
    final next = nextItems[index];
    if (previous is! ConversationMessageTimelineItem ||
        next is! ConversationMessageTimelineItem) {
      return null;
    }
    if (previous.storageKey != next.storageKey) return null;
    if (!_isStreamedTextRevision(previous.message, next.message)) return null;
    changedIndices.add(index);
  }
  if (changedIndices.isEmpty) return null;

  final patched = List<MessagingFlowEntry>.of(previousEntries);
  for (final changed in changedIndices) {
    final previousMessage =
        (previousItems[changed] as ConversationMessageTimelineItem).message;
    final nextMessage =
        (nextItems[changed] as ConversationMessageTimelineItem).message;
    final entryIndex = _entryIndexOfMessage(patched, previousMessage);
    if (entryIndex < 0) return null;
    patched[entryIndex] = _patchedMessageEntry(
      patched[entryIndex],
      previousMessage,
      nextMessage,
    );
  }
  return List<MessagingFlowEntry>.unmodifiable(patched);
}

bool _isStreamedTextRevision(
  AgentConversationMessage previous,
  AgentConversationMessage next,
) {
  return previous.id == next.id &&
      previous.role == next.role &&
      previous.createdAt == next.createdAt &&
      previous.cardType == next.cardType &&
      previous.stableIdentity == next.stableIdentity &&
      previous.participantAgentId == next.participantAgentId &&
      previous.participantLabel == next.participantLabel &&
      previous.participantRole == next.participantRole &&
      previous.childMessages.isEmpty &&
      next.childMessages.isEmpty &&
      !previous.isStructuredEvent &&
      !next.isStructuredEvent;
}

int _entryIndexOfMessage(
  List<MessagingFlowEntry> entries,
  AgentConversationMessage message,
) {
  for (var index = 0; index < entries.length; index += 1) {
    final entry = entries[index];
    if (entry is MessagingFlowMessageGroup) {
      for (final candidate in entry.messages) {
        if (identical(candidate, message)) return index;
      }
    } else if (entry is MessagingFlowSubagent) {
      if (identical(entry.item.message, message)) return index;
    }
  }
  return -1;
}

MessagingFlowEntry _patchedMessageEntry(
  MessagingFlowEntry entry,
  AgentConversationMessage previousMessage,
  AgentConversationMessage nextMessage,
) {
  if (entry is MessagingFlowSubagent) {
    return MessagingFlowSubagent(
      ConversationMessageTimelineItem(entry.item.storageKey, nextMessage),
    );
  }
  final group = entry as MessagingFlowMessageGroup;
  final messages = List<AgentConversationMessage>.of(group.messages);
  for (var index = 0; index < messages.length; index += 1) {
    if (identical(messages[index], previousMessage)) {
      messages[index] = nextMessage;
    }
  }
  return MessagingFlowMessageGroup(
    authorIsUser: group.authorIsUser,
    participantAgentId: group.participantAgentId,
    participantLabel: group.participantLabel,
    participantRole: group.participantRole,
    messages: List<AgentConversationMessage>.unmodifiable(messages),
  );
}

class _MessagingParticipantFlowState extends State<MessagingParticipantFlow> {
  ScrollController? _ownedScrollController;
  bool _atLatest = true;
  List<MessagingFlowEntry>? _cachedEntries;
  List<ConversationTimelineItem>? _cachedItems;
  bool _pageRequestInFlight = false;

  /// Reverse lists keep the newest rows at offset 0. Treat a small residual
  /// as still "at latest" so the control does not flicker.
  static const double _atLatestThreshold = 48;

  ScrollController get _scrollController =>
      widget.scrollController ?? _ownedScrollController!;

  @override
  void initState() {
    super.initState();
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
      _atLatest = true;
      _pageRequestInFlight = false;
    }
    if (oldWidget.activeProcessStorageKey != widget.activeProcessStorageKey ||
        oldWidget.preferPeerAgents != widget.preferPeerAgents) {
      _cachedEntries = null;
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
    if (!widget.hasEarlier ||
        widget.messagePageLoading ||
        _pageRequestInFlight) {
      return false;
    }
    if (metrics.pixels <
        metrics.maxScrollExtent - MessagingParticipantFlow.earlierPageLeadIn) {
      return false;
    }
    final request = widget.onLoadEarlier;
    if (request != null) {
      _pageRequestInFlight = true;
      request().whenComplete(() {
        if (mounted) _pageRequestInFlight = false;
      });
    }
    return false;
  }

  List<MessagingFlowEntry> get _displayEntries {
    final items = widget.items;
    final cached = _cachedEntries;
    if (cached == null) return _rebuildEntries(items);
    if (identical(items, _cachedItems)) return cached;
    final patched = patchMessagingFlowStreamedMessages(
      previousItems: _cachedItems!,
      nextItems: items,
      previousEntries: cached,
    );
    if (patched != null) {
      _cachedItems = items;
      _cachedEntries = patched;
      return patched;
    }
    return _rebuildEntries(items);
  }

  List<MessagingFlowEntry> _rebuildEntries(
    List<ConversationTimelineItem> items,
  ) {
    final entries = buildMessagingFlowEntries(
      items.reversed.toList(growable: false),
      activeProcessStorageKey: widget.activeProcessStorageKey,
      preferPeerAgents: widget.preferPeerAgents,
    );
    final display = entries.reversed.toList(growable: false);
    _cachedItems = items;
    _cachedEntries = display;
    return display;
  }

  @override
  Widget build(BuildContext context) {
    final displayEntries = _displayEntries;
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
              itemCount:
                  displayEntries.length +
                  ((widget.hasEarlier ||
                          widget.messagePageLoading ||
                          widget.messagePageError.isNotEmpty)
                      ? 1
                      : 0),
              itemBuilder: (context, index) {
                if (index == displayEntries.length) {
                  return _MessagingEarlierPageRow(
                    loading: widget.messagePageLoading,
                    errorCode: widget.messagePageError,
                    onRetry: widget.onLoadEarlier,
                  );
                }
                final entry = displayEntries[index];
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
            assistantActive: widget.assistantActive,
            runtimeProfile:
                widget.participantRuntimeProfiles[participantAgentId],
            messages: messages,
            target: widget.target,
            adapter: widget.adapter,
            conversationId: messagingHoverConversationId(
              authorIsUser: authorIsUser,
              participantAgentId: participantAgentId,
              participantConversationIds: widget.participantConversationIds,
              primaryConversationId: widget.primaryConversationId,
            ),
            onCopyText: widget.onCopyText,
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

final class _MessagingEarlierPageRow extends StatelessWidget {
  const _MessagingEarlierPageRow({
    required this.loading,
    required this.errorCode,
    required this.onRetry,
  });

  final bool loading;
  final String errorCode;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (errorCode.isEmpty) return const SizedBox(height: 1);
    return Center(
      child: TextButton.icon(
        key: const Key('messaging-message-page-retry'),
        onPressed: onRetry == null ? null : () => onRetry!.call(),
        icon: const Icon(Icons.refresh_rounded, size: 17),
        label: Text('History page failed: $errorCode'),
      ),
    );
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
