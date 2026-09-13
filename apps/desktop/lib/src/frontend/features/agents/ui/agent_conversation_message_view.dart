import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_truncation_notice.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_details_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_participant_flow.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_failure_notice.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_message_group.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/reading_position_scroll_controller.dart';

class AgentConversationMessageList extends StatefulWidget {
  const AgentConversationMessageList({
    super.key,
    required this.loading,
    required this.session,
    required this.target,
    this.messagePageLoading = false,
    this.hasEarlierMessages,
    this.messagePageError = '',
    this.onLoadEarlier,
    this.turnActive = false,
    this.liveMessages = const [],
    this.messageStyle = AgentsMessageStyle.documentTranscript,
    this.participantTargets = const [],
    this.participantConversationIds = const {},
    this.participantRuntimeProfiles = const {},
    this.assistantActive = false,
    this.topOverlayInset = 0,
    this.bottomOverlayInset = 0,
    this.scrollController,
    this.onCopyText,
    this.onRetryMessage,
    this.onDeleteMessage,
  });

  final bool loading;
  final AgentConversationSession? session;
  final TargetCandidate target;
  final bool messagePageLoading;
  final bool? hasEarlierMessages;
  final String messagePageError;
  final Future<void> Function()? onLoadEarlier;
  final bool turnActive;
  final List<AgentConversationMessage> liveMessages;

  /// Clipboard write routed through the platform boundary (client clipboard
  /// service); message rows expose an explicit copy action when present.
  final Future<void> Function(String)? onCopyText;
  final Future<void> Function(String)? onRetryMessage;
  final Future<void> Function(String)? onDeleteMessage;

  /// How messages render: the shared document transcript or the messaging
  /// participant flow.
  final AgentsMessageStyle messageStyle;

  final List<TargetCandidate> participantTargets;

  /// Agent id → conversation id used on hover next to message timestamps.
  final Map<String, String> participantConversationIds;
  final Map<String, AgentParticipantRuntimeProfile> participantRuntimeProfiles;

  /// Whether the group assistant lane is active; assistant message headers
  /// render the agent's brand mark while active, the sparkles mark otherwise.
  final bool assistantActive;

  /// Extra top padding when a floating header overlays the transcript.
  final double topOverlayInset;

  /// Extra bottom padding when a floating composer overlays the transcript.
  final double bottomOverlayInset;

  /// Optional owner for coordinating a floating child scroll surface with
  /// the transcript viewport.
  final ScrollController? scrollController;

  @override
  State<AgentConversationMessageList> createState() =>
      AgentConversationMessageListState();
}

class AgentConversationMessageListState
    extends State<AgentConversationMessageList> {
  bool get _hasEarlierMessages =>
      widget.hasEarlierMessages ??
      widget.session?.messagePage.hasEarlier ??
      false;
  bool _showDiagnostics = false;
  final _messageMergeCache = ConversationMessageMergeCache();
  late Future<AgentRenderAdapter> _adapterFuture;
  (AgentRenderAdapterRegistry, String, String, String, String)?
  _adapterResolutionKey;
  AgentConversationSession? _timelineSession;
  List<AgentConversationMessage>? _timelineLiveMessages;
  String _timelineSessionIdentity = '';
  String _timelineSessionKey = '';
  List<ConversationTimelineItem> _timelineItems = const [];
  Map<String, int> _timelineIndexByStorageKey = const {};
  List<AgentSemanticArtifactRef> _artifacts = const [];
  int _footerCount = 0;

  /// Minimum distance from the top of the loaded history that starts loading
  /// the earlier page. The effective lead-in is one full viewport (see
  /// [_loadEarlierOnScroll]) so the request lands before a fast fling reaches
  /// the oldest loaded edge.
  static const double _earlierPageLeadIn = 120;

  int _timelineTotal = 0;
  bool _pageRequestInFlight = false;
  bool _hasMessages = false;

  /// Owned anchor controller used when the pane does not provide one; keeps
  /// the reader's position pinned while streamed content grows at the newest
  /// end of the reversed list.
  ScrollController? _ownedScrollController;

  ScrollController get _effectiveScrollController =>
      widget.scrollController ??
      (_ownedScrollController ??= ReadingPositionScrollController());

  @override
  void initState() {
    super.initState();
    _syncAdapterFuture();
    _syncTimelineCache();
  }

  @override
  void didUpdateWidget(covariant AgentConversationMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final readingController = _effectiveScrollController;
    if (readingController is ReadingPositionScrollController) {
      final sameConversation =
          oldWidget.target.target == widget.target.target &&
          oldWidget.session?.id == widget.session?.id &&
          oldWidget.session?.nativeSessionId == widget.session?.nativeSessionId;
      if (sameConversation) {
        readingController.captureReadingAnchor();
      } else {
        readingController.clearReadingAnchor();
      }
    }
    _syncAdapterFuture();
    _syncTimelineCache();
  }

  @override
  void dispose() {
    _ownedScrollController?.dispose();
    super.dispose();
  }

  void _syncAdapterFuture() {
    final registry = AgentRenderAdapterRegistry.instance;
    final session = widget.session;
    final nextKey = (
      registry,
      widget.target.target,
      session?.sourceClient ?? '',
      session?.sourceTool ?? '',
      session?.adapterId ?? '',
    );
    if (_adapterResolutionKey == nextKey) {
      return;
    }
    _adapterResolutionKey = nextKey;
    _adapterFuture = registry.resolve(
      agentId: nextKey.$2,
      sourceClient: nextKey.$3,
      sourceTool: nextKey.$4,
      adapterId: nextKey.$5,
    );
  }

  bool _syncTimelineCache() {
    final session = widget.session;
    final sessionIdentity = [
      widget.target.target,
      session?.id ?? '',
      session?.nativeSessionId ?? '',
    ].join('|');
    if (_timelineSessionIdentity.isNotEmpty &&
        _timelineSessionIdentity != sessionIdentity) {
      _pageRequestInFlight = false;
    }
    if (identical(_timelineSession, session) &&
        identical(_timelineLiveMessages, widget.liveMessages) &&
        _timelineSessionIdentity == sessionIdentity) {
      return false;
    }
    if (_reuseTimelineForStreamedText(session, sessionIdentity)) {
      return true;
    }

    final messages = _messageMergeCache.merge(
      session?.messages ?? const [],
      widget.liveMessages,
    );
    final timelineItems = buildConversationTimelineItems(
      messages,
      sessionIdentity,
    ).reversed.toList(growable: false);
    final artifacts = session?.artifacts ?? const <AgentSemanticArtifactRef>[];
    final hasDiagnostics = session?.hasDiagnostics ?? false;
    final footerCount =
        (artifacts.isNotEmpty ? 1 : 0) + (hasDiagnostics ? 1 : 0);
    final indexByStorageKey = <String, int>{};
    var footerIndex = 0;
    if (hasDiagnostics) {
      indexByStorageKey['conversation-diagnostics'] = footerIndex;
      footerIndex += 1;
    }
    if (artifacts.isNotEmpty) {
      indexByStorageKey['conversation-artifacts'] = footerIndex;
    }
    for (var index = 0; index < timelineItems.length; index += 1) {
      indexByStorageKey[timelineItems[index].storageKey] = index + footerCount;
    }

    _timelineSession = session;
    _timelineLiveMessages = widget.liveMessages;
    _timelineSessionIdentity = sessionIdentity;
    _timelineSessionKey = sessionIdentity.hashCode
        .toUnsigned(32)
        .toRadixString(16);
    _timelineItems = timelineItems;
    _timelineTotal = timelineItems.length + footerCount;
    _timelineIndexByStorageKey = Map<String, int>.unmodifiable(
      indexByStorageKey,
    );
    _artifacts = artifacts;
    _footerCount = footerCount;
    _hasMessages = messages.isNotEmpty;
    return true;
  }

  /// Reuse the built timeline while replies stream in.
  ///
  /// A streamed turn republishes the live list every few frames, and usually
  /// only text changes: with multiple concurrent group turns the changed
  /// message may sit anywhere in the live list, not just at the tail. A full
  /// rebuild re-derives every item, every storage key, and the whole key index
  /// for a conversation that can hold hundreds of messages, which is work
  /// proportional to history length on every frame of every reply. Timeline
  /// identity is derived from message id, timestamp, role, and card type —
  /// never from text — so a changed message item can be swapped in place and
  /// every key stays stable.
  ///
  /// Returns false whenever anything but message text revisions differs, so
  /// the full rebuild stays the only path that can change structure.
  bool _reuseTimelineForStreamedText(
    AgentConversationSession? session,
    String sessionIdentity,
  ) {
    if (!identical(_timelineSession, session) ||
        _timelineSessionIdentity != sessionIdentity) {
      return false;
    }
    final previous = _timelineLiveMessages;
    final next = widget.liveMessages;
    if (previous == null || previous.length != next.length) {
      return false;
    }
    final changedIndices = <int>[];
    for (var index = 0; index < next.length; index += 1) {
      if (identical(previous[index], next[index])) continue;
      if (!_isStreamedTextRevision(previous[index], next[index])) {
        return false;
      }
      changedIndices.add(index);
    }
    if (changedIndices.isEmpty) {
      // The wrapper list was replaced (for example by an immutable copy made
      // while assembling pane state) but every message object is identical:
      // adopt the new reference and skip the rebuild entirely.
      _timelineLiveMessages = next;
      return true;
    }
    final items = List<ConversationTimelineItem>.of(_timelineItems);
    for (final changed in changedIndices) {
      final previousMessage = previous[changed];
      final itemIndex = _timelineIndexOfMessage(items, previousMessage);
      if (itemIndex < 0) return false;
      final item = items[itemIndex];
      if (item is! ConversationMessageTimelineItem) return false;
      items[itemIndex] = ConversationMessageTimelineItem(
        item.storageKey,
        next[changed],
      );
    }
    _timelineItems = List<ConversationTimelineItem>.unmodifiable(items);
    _timelineLiveMessages = next;
    return true;
  }

  int _timelineIndexOfMessage(
    List<ConversationTimelineItem> items,
    AgentConversationMessage message,
  ) {
    for (var index = 0; index < items.length; index += 1) {
      final item = items[index];
      if (item is ConversationMessageTimelineItem &&
          identical(item.message, message)) {
        return index;
      }
    }
    return -1;
  }

  /// Whether two versions of one live message differ only in streamed content.
  static bool _isStreamedTextRevision(
    AgentConversationMessage previous,
    AgentConversationMessage next,
  ) {
    return previous.id == next.id &&
        previous.role == next.role &&
        previous.createdAt == next.createdAt &&
        previous.cardType == next.cardType &&
        previous.stableIdentity == next.stableIdentity &&
        previous.participantAgentId == next.participantAgentId &&
        previous.participantRole == next.participantRole &&
        previous.childMessages.isEmpty &&
        next.childMessages.isEmpty &&
        !previous.isStructuredEvent &&
        !next.isStructuredEvent;
  }

  /// Ids of the live assistant replies whose bodies are still streaming.
  ///
  /// The signal is the real turn state, never text shape: a message streams
  /// only while the pane's turn is active AND the message object is one of
  /// the live turn's assistant replies (identity '$turnId-assistant…' in the
  /// live list). User echoes, lifecycle/evidence events, subagent cards, and
  /// readback history are excluded. Once the turn settles, [widget.turnActive]
  /// flips false and every message returns to the finalized rendering.
  Set<String> _streamingMessageIds() {
    if (!widget.turnActive) {
      return const <String>{};
    }
    final ids = <String>{};
    for (final message in widget.liveMessages) {
      if (message.kind == AgentConversationMessageKind.assistant &&
          !message.isStructuredEvent &&
          message.childMessages.isEmpty) {
        ids.add(message.id);
      }
    }
    return ids;
  }

  String get _motionAvatarMessageId =>
      _timelineItems.reversed
          .whereType<ConversationMessageTimelineItem>()
          .where(
            (item) =>
                item.message.kind == AgentConversationMessageKind.assistant,
          )
          .firstOrNull
          ?.message
          .id ??
      '';

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    if ((widget.loading || widget.messagePageLoading) && !_hasMessages) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_hasMessages) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            strings.noMessagesInHistory,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted),
          ),
        ),
      );
    }
    return FutureBuilder<AgentRenderAdapter>(
      future: _adapterFuture,
      builder: (context, snapshot) {
        final adapter = snapshot.data ?? AgentRenderAdapter.fallback();
        final streamingMessageIds = _streamingMessageIds();
        if (widget.messageStyle == AgentsMessageStyle.participantFlow) {
          final session = widget.session;
          final primaryConversationId = session == null
              ? ''
              : messagingDetailsConversationId(session);
          // Text selection is hosted once at the pane level
          // (AgentConversationActivePane); nested SelectionAreas would
          // register every visible RichText twice and fan selection geometry
          // updates out on every scroll frame.
          return MessagingParticipantFlow(
            scrollController: widget.scrollController,
            items: _timelineItems,
            adapter: adapter,
            target: widget.target,
            sessionKey: _timelineSessionKey,
            motionAvatarMessageId: _motionAvatarMessageId,
            participantTargets: widget.participantTargets,
            participantConversationIds: widget.participantConversationIds,
            participantRuntimeProfiles: widget.participantRuntimeProfiles,
            assistantActive: widget.assistantActive,
            primaryConversationId: primaryConversationId,
            preferPeerAgents: false,
            streamingMessageIds: streamingMessageIds,
            topOverlayInset: widget.topOverlayInset,
            bottomOverlayInset: widget.bottomOverlayInset,
            messagePageLoading: widget.messagePageLoading,
            messagePageError: widget.messagePageError,
            hasEarlier: _hasEarlierMessages,
            onLoadEarlier: widget.onLoadEarlier,
            onCopyText: widget.onCopyText,
            onRetryMessage: widget.onRetryMessage,
            onDeleteMessage: widget.onDeleteMessage,
          );
        }
        final showPageRow =
            _hasEarlierMessages ||
            widget.messagePageLoading ||
            widget.messagePageError.isNotEmpty;
        return NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: ListView.builder(
            controller: _effectiveScrollController,
            key: PageStorageKey<String>(
              'agent-conversation-message-list-$_timelineSessionKey',
            ),
            reverse: true,
            scrollCacheExtent: const ScrollCacheExtent.viewport(2.0),
            padding: EdgeInsets.fromLTRB(
              LicoContentSpacing.item,
              LicoContentSpacing.item + widget.topOverlayInset,
              LicoContentSpacing.item,
              LicoContentSpacing.item +
                  adapter.assistantVerticalPadding +
                  widget.bottomOverlayInset,
            ),
            findChildIndexCallback: (key) {
              if (key case ValueKey<String>(:final value)) {
                return _timelineIndexByStorageKey[value];
              }
              return null;
            },
            itemCount: _timelineTotal + (showPageRow ? 1 : 0),
            itemBuilder: (context, index) {
              if (showPageRow && index == _timelineTotal) {
                return _ConversationEarlierPageRow(
                  loading: widget.messagePageLoading,
                  errorCode: widget.messagePageError,
                  onRetry: widget.onLoadEarlier,
                );
              }
              return _buildConsoleRow(
                context,
                adapter,
                index,
                streamingMessageIds,
              );
            },
          ),
        );
      },
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    return _loadEarlierOnScroll(notification);
  }

  bool _loadEarlierOnScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        widget.messagePageLoading ||
        _pageRequestInFlight) {
      return false;
    }
    final movingEarlier = switch (notification) {
      ScrollUpdateNotification(:final scrollDelta) => (scrollDelta ?? 0) > 0,
      OverscrollNotification(:final overscroll) => overscroll > 0,
      _ => false,
    };
    if (!movingEarlier) return false;
    final metrics = notification.metrics;
    if (!_hasEarlierMessages) {
      return false;
    }
    // Start the page one full viewport ahead of the oldest loaded edge so the
    // request lands before a fast fling reaches the wall; reaching the wall
    // kills the in-flight scroll and forces a second swipe.
    final leadIn = math.max(_earlierPageLeadIn, metrics.viewportDimension);
    if (metrics.pixels < metrics.maxScrollExtent - leadIn) {
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

  Widget _buildConsoleRow(
    BuildContext context,
    AgentRenderAdapter adapter,
    int index,
    Set<String> streamingMessageIds,
  ) {
    if (index < _footerCount) {
      if (widget.session?.hasDiagnostics ?? false) {
        if (index == 0) {
          return Padding(
            key: const ValueKey<String>('conversation-diagnostics'),
            padding: EdgeInsets.only(bottom: LicoContentSpacing.item),
            child: _ConversationDiagnosticsPanel(
              session: widget.session!,
              expanded: _showDiagnostics,
              onToggle: () {
                setState(() {
                  _showDiagnostics = !_showDiagnostics;
                });
              },
            ),
          );
        }
        if (_artifacts.isNotEmpty && index == 1) {
          return Padding(
            key: const ValueKey<String>('conversation-artifacts'),
            padding: EdgeInsets.only(bottom: LicoContentSpacing.item),
            child: _ConversationArtifactsPanel(artifacts: _artifacts),
          );
        }
      } else if (_artifacts.isNotEmpty && index == 0) {
        return Padding(
          key: const ValueKey<String>('conversation-artifacts'),
          padding: EdgeInsets.only(bottom: LicoContentSpacing.item),
          child: _ConversationArtifactsPanel(artifacts: _artifacts),
        );
      }
    }
    final item = _timelineItems[index - _footerCount];
    final content = switch (item) {
      ConversationMessageTimelineItem(:final message) =>
        message.kind == AgentConversationMessageKind.assistant
            ? MessagingMessageGroup(
                authorIsUser: false,
                motionAvatar: message.id == _motionAvatarMessageId,
                participantLabel: message.participantLabel,
                participantRole: message.participantRole,
                participantTarget: widget.participantTargets
                    .where(
                      (target) => target.target == message.participantAgentId,
                    )
                    .firstOrNull,
                messages: [message],
                target: widget.target,
                adapter: adapter,
                streamingMessageIds: streamingMessageIds,
                onCopyText: widget.onCopyText,
              )
            : AgentConversationMessageBlock(
                message: message,
                adapter: adapter,
                isStreaming: streamingMessageIds.contains(message.id),
              ),
      ConversationFailureTimelineItem(:final message) =>
        ConversationFailureNotice(message: message, target: widget.target),
      ConversationNoticeTimelineItem(:final message) => ConversationNotice(
        message: message,
      ),
      ConversationTruncationTimelineItem(
        :final historyTruncated,
        :final messageTreeTruncated,
      ) =>
        ConversationTruncationNotice(
          historyTruncated: historyTruncated,
          messageTreeTruncated: messageTreeTruncated,
        ),
    };
    // A streamed reply changes one item per frame. Without a repaint
    // boundary per item the whole visible transcript repaints with it.
    return ReadingPositionAnchor(
      key: ValueKey<String>(item.storageKey),
      controller: _effectiveScrollController,
      anchorId: item.storageKey,
      isRow: true,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: index + 1 < _timelineItems.length + _footerCount
              ? LicoContentSpacing.item
              : 0,
        ),
        child: RepaintBoundary(child: content),
      ),
    );
  }
}

final class _ConversationEarlierPageRow extends StatelessWidget {
  const _ConversationEarlierPageRow({
    required this.loading,
    required this.errorCode,
    required this.onRetry,
  });

  final bool loading;
  final String errorCode;
  final Future<void> Function()? onRetry;

  /// Fixed extent for the oldest-edge slot. The row sits exactly where the
  /// reader parks while a page loads; a height swap there would shift
  /// maxScrollExtent mid-gesture and cancel the in-flight scroll.
  static const double extent = 48;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: extent,
      child: Center(
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : errorCode.isNotEmpty
            ? TextButton.icon(
                key: const Key('conversation-message-page-retry'),
                onPressed: onRetry == null ? null : () => onRetry!.call(),
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: Text('History page failed: $errorCode'),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// One pane's last merge. Messages are immutable, so reference comparison
/// includes child content, attachments, and metadata without hashing their
/// contents or retaining another pane's conversation.
final class ConversationMessageMergeCache {
  List<AgentConversationMessage> _readBack = const [];
  List<AgentConversationMessage> _live = const [];
  List<AgentConversationMessage>? _merged;

  List<AgentConversationMessage> merge(
    List<AgentConversationMessage> readBack,
    List<AgentConversationMessage> live,
  ) {
    final cached = _merged;
    if (cached != null &&
        _sameMessages(_readBack, readBack) &&
        _sameMessages(_live, live)) {
      return cached;
    }
    _readBack = readBack;
    _live = live;
    return _merged = mergeConversationReadbackAndLiveMessages(readBack, live);
  }

  static bool _sameMessages(
    List<AgentConversationMessage> previous,
    List<AgentConversationMessage> next,
  ) {
    if (identical(previous, next)) return true;
    if (previous.length != next.length) return false;
    for (var index = 0; index < next.length; index += 1) {
      if (!identical(previous[index], next[index])) return false;
    }
    return true;
  }
}

/// Keeps a completed live turn visible until readback arrives without briefly
/// rendering the same user/assistant pair twice during convergence.
List<AgentConversationMessage> mergeConversationReadbackAndLiveMessages(
  List<AgentConversationMessage> readBack,
  List<AgentConversationMessage> live,
) {
  if (readBack.isEmpty || live.isEmpty) {
    return List<AgentConversationMessage>.unmodifiable([...readBack, ...live]);
  }
  // Canonical Events and live Membership frames share exact execution and
  // reply identities. Prefer available body text to its transient waiting slot
  // without inferring a match from a participant name or message contents.
  if (!live.any(
    (message) => message.kind == AgentConversationMessageKind.user,
  )) {
    final indexes = {
      for (var index = 0; index < readBack.length; index++)
        if (readBack[index].executionReference != null)
          (readBack[index].executionReference, readBack[index].stableIdentity):
              index,
    };
    final result = List<AgentConversationMessage>.of(readBack);
    var matched = false;
    for (final message in live) {
      final index =
          indexes[(message.executionReference, message.stableIdentity)];
      if (index == null || message.executionReference == null) {
        result.add(message);
      } else {
        matched = true;
        final stored = result[index];
        if (!message.waitingForReply &&
            !(stored.text.length > message.text.length &&
                stored.text.startsWith(message.text))) {
          result[index] = message;
        }
      }
    }
    if (matched) return List.unmodifiable(result);
  }
  final liveConversation = live
      .where(_isConversationParticipantMessage)
      .toList(growable: false);
  if (liveConversation.length < 2 ||
      !liveConversation.any(
        (message) => message.role.trim().toLowerCase() == 'assistant',
      )) {
    return List<AgentConversationMessage>.unmodifiable([...readBack, ...live]);
  }
  final persistedConversation = readBack
      .where(_isConversationParticipantMessage)
      .toList(growable: false);
  if (persistedConversation.length < liveConversation.length) {
    return List<AgentConversationMessage>.unmodifiable([...readBack, ...live]);
  }
  // The native transcript may record one assistant reply as several content
  // blocks (text before/after tool calls), so readback can carry more
  // participant messages than the live projection. The readback tail must
  // still end on the live tail; only the blocks between the live messages may
  // be extra.
  if (!_sameConversationMessage(
    persistedConversation.last,
    liveConversation.last,
  )) {
    return List<AgentConversationMessage>.unmodifiable([...readBack, ...live]);
  }
  var persistedIndex = persistedConversation.length - 2;
  for (var index = liveConversation.length - 2; index >= 0; index -= 1) {
    while (persistedIndex >= 0 &&
        !_sameConversationMessage(
          persistedConversation[persistedIndex],
          liveConversation[index],
        )) {
      persistedIndex -= 1;
    }
    if (persistedIndex < 0) {
      return List<AgentConversationMessage>.unmodifiable([
        ...readBack,
        ...live,
      ]);
    }
    persistedIndex -= 1;
  }
  // Readback covers the live participant messages, but the live turn's
  // structured events (lifecycle stages + evidence operations) never appear
  // in any native transcript and must survive the handover: drop them and
  // the blackboard card would disappear mid-turn. Retain them, pinned after
  // the turn's user message so the card keeps its place between the user
  // message and the reply. Entries the readback already carries (same kind,
  // card type, and content) are not duplicated.
  final liveStructured = live
      .where((message) => message.isStructuredEvent)
      .toList(growable: false);
  if (liveStructured.isEmpty) {
    return List<AgentConversationMessage>.unmodifiable(readBack);
  }
  // Readback convergence: the transcript records the same reasoning / tool
  // operations as the live projection but under transcript-owned identities,
  // so without a bridge the timeline would render them as a second process
  // card next to the turn's blackboard card. Rewrite the identities of the
  // covered turn's readback operations to the turn key; the timeline then
  // groups them into the same pinned card and both sources converge.
  final convergedReadBack = _convergeTurnReadbackOperations(
    readBack,
    live,
    liveStructured,
  );
  final readbackSignatures = convergedReadBack
      .where((message) => message.isStructuredEvent)
      .map(_structuredEventSignature)
      .toSet();
  final retained = <AgentConversationMessage>[
    for (final message in liveStructured)
      if (!readbackSignatures.contains(_structuredEventSignature(message)))
        message,
  ];
  if (retained.isEmpty) {
    return List<AgentConversationMessage>.unmodifiable(convergedReadBack);
  }
  var insertIndex = convergedReadBack.length;
  for (var index = convergedReadBack.length - 1; index >= 0; index -= 1) {
    if (convergedReadBack[index].role.trim().toLowerCase() == 'user') {
      insertIndex = index + 1;
      break;
    }
  }
  return List<AgentConversationMessage>.unmodifiable([
    ...convergedReadBack.take(insertIndex),
    ...retained,
    ...convergedReadBack.skip(insertIndex),
  ]);
}

/// Rewrite the stable identities of the covered turn's readback operations
/// (reasoning / tool calls / tool results) to the live turn key so the
/// timeline groups them into the same blackboard card as the live evidence.
///
/// The caller has already verified that the readback covers the live turn:
/// the last readback participant message is this turn's reply and one of the
/// earlier participant messages is this turn's user message. Operations
/// between those two boundaries belong to the turn; everything else keeps
/// its transcript identity. Returns [readBack] unchanged when no turn key or
/// turn span can be recovered.
List<AgentConversationMessage> _convergeTurnReadbackOperations(
  List<AgentConversationMessage> readBack,
  List<AgentConversationMessage> live,
  List<AgentConversationMessage> liveStructured,
) {
  String? turnKey;
  for (final message in liveStructured) {
    if (message.cardType.trim().toLowerCase() == 'lifecycle') {
      turnKey = liveTurnKeyOf(message);
      break;
    }
  }
  if (turnKey == null) {
    return readBack;
  }
  AgentConversationMessage? liveUser;
  for (final message in live) {
    if (_isConversationParticipantMessage(message)) {
      liveUser = message;
      break;
    }
  }
  if (liveUser == null) {
    return readBack;
  }
  final participantIndexes = <int>[];
  for (var index = 0; index < readBack.length; index += 1) {
    if (_isConversationParticipantMessage(readBack[index])) {
      participantIndexes.add(index);
    }
  }
  if (participantIndexes.isEmpty) {
    return readBack;
  }
  final tailIndex = participantIndexes.last;
  int? userIndex;
  for (var index = participantIndexes.length - 1; index >= 0; index -= 1) {
    if (_sameConversationMessage(
      readBack[participantIndexes[index]],
      liveUser,
    )) {
      userIndex = participantIndexes[index];
      break;
    }
  }
  if (userIndex == null || userIndex + 1 >= tailIndex) {
    return readBack;
  }
  final converged = List<AgentConversationMessage>.of(readBack);
  var operationIndex = 0;
  for (var index = userIndex + 1; index < tailIndex; index += 1) {
    final message = readBack[index];
    if (!_isBridgeableReadbackOperation(message)) {
      continue;
    }
    converged[index] = AgentConversationMessage(
      id: message.id,
      role: message.role,
      text: message.text,
      createdAt: message.createdAt,
      layer: message.layer,
      cardType: message.cardType,
      cardTitle: message.cardTitle,
      cardSubtitle: message.cardSubtitle,
      collapsed: message.collapsed,
      providerSummary: message.providerSummary,
      stableIdentity: '$turnKey-process-$operationIndex',
      participantAgentId: message.participantAgentId,
      participantLabel: message.participantLabel,
      participantRole: message.participantRole,
      executionReference: message.executionReference,
      waitingForReply: message.waitingForReply,
      replyTerminalState: message.replyTerminalState,
      childMessagesTruncated: message.childMessagesTruncated,
      childMessages: message.childMessages,
      images: message.images,
    );
    operationIndex += 1;
  }
  if (operationIndex == 0) {
    return readBack;
  }
  return converged;
}

/// Whether a readback structured event may join the turn's blackboard card.
/// Runtime log rows and runtime-update cards keep their own timeline items.
bool _isBridgeableReadbackOperation(AgentConversationMessage message) =>
    message.isStructuredEvent &&
    !isConversationRuntimeUpdateEvent(message) &&
    !isConversationRuntimeLogEvent(message);

String _structuredEventSignature(AgentConversationMessage message) =>
    '${message.kind}|${message.cardType}|${message.text.trim()}';

bool _isConversationParticipantMessage(AgentConversationMessage message) {
  final role = message.role.trim().toLowerCase();
  return message.text.trim().isNotEmpty &&
      (role == 'user' || role == 'assistant');
}

bool _sameConversationMessage(
  AgentConversationMessage first,
  AgentConversationMessage second,
) =>
    first.role.trim().toLowerCase() == second.role.trim().toLowerCase() &&
    first.text.trim() == second.text.trim();

class _ConversationArtifactsPanel extends StatelessWidget {
  const _ConversationArtifactsPanel({required this.artifacts});

  final List<AgentSemanticArtifactRef> artifacts;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line.withAlpha(80)),
        borderRadius: BorderRadius.circular(LicoRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Artifacts', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final artifact in artifacts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${artifact.label} (${artifact.kind})'
                  '${artifact.ref.isEmpty ? '' : ' → ${artifact.ref}'}',
                  style: TextStyle(color: colors.textMuted, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConversationDiagnosticsPanel extends StatelessWidget {
  const _ConversationDiagnosticsPanel({
    required this.session,
    required this.expanded,
    required this.onToggle,
  });

  final AgentConversationSession session;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final semantic = session.semantic;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line.withAlpha(80)),
        borderRadius: BorderRadius.circular(LicoRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(LicoRadius.card),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Diagnostics',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (expanded && semantic != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Audit',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Adapter: ${semantic.audit.adapterId}\n'
                    'Host: ${semantic.audit.hostApp}\n'
                    'Source: ${semantic.audit.sourceKind}\n'
                    'Session: ${semantic.audit.nativeSessionId}\n'
                    'Redaction: ${semantic.audit.redactionStatus}\n'
                    'Validation: ${semantic.audit.validationStatus}\n'
                    'Evidence: ${semantic.audit.sourceEvidence.pathRef}',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                  if (semantic.audit.parseWarnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Parse warnings: ${semantic.audit.parseWarnings.join('; ')}',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Raw evidence',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final evidence in semantic.rawEvidence)
                    Text(
                      '${evidence.kind}: ${evidence.pathRef} (${evidence.contentHash})',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
