import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_log_event_row.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_message_group.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_process_status_row.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
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
class MessagingParticipantFlow extends StatelessWidget {
  const MessagingParticipantFlow({
    super.key,
    required this.items,
    required this.adapter,
    required this.target,
    this.activeProcessStorageKey = '',
    this.sessionKey = '',
    this.participantTargets = const [],
    this.preferPeerAgents = false,
    this.topOverlayInset = 0,
    this.bottomOverlayInset = 0,
  });

  /// Timeline items in the message-list cache order (newest first).
  final List<ConversationTimelineItem> items;
  final AgentRenderAdapter adapter;
  final TargetCandidate target;
  final String activeProcessStorageKey;
  final String sessionKey;
  final List<TargetCandidate> participantTargets;

  /// Lico group Conversation: render delegated agents as peer bubbles.
  final bool preferPeerAgents;

  /// Extra top padding when a floating header overlays the transcript.
  final double topOverlayInset;

  /// Extra bottom padding when a floating composer overlays the transcript.
  final double bottomOverlayInset;

  TargetCandidate? _participantTarget(String participantAgentId) {
    final normalized = participantAgentId.trim();
    if (normalized.isEmpty) return null;
    for (final candidate in participantTargets) {
      if (candidate.target == normalized) return candidate;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final entries = buildMessagingFlowEntries(
      items.reversed.toList(growable: false),
      activeProcessStorageKey: activeProcessStorageKey,
      preferPeerAgents: preferPeerAgents,
    );
    final displayEntries = entries.reversed.toList(growable: false);
    // Conversation text must be selectable and copyable. Selection is hosted at
    // the scroll level so a drag can span several messages; it only reaches the
    // rows the list has built, which is why individual messages also expose an
    // explicit copy action. Chrome that would pollute a selection — process
    // rows, log rows — opts out with SelectionContainer.disabled at its own
    // site.
    return SelectionArea(
      child: ListView.builder(
        key: PageStorageKey<String>('messaging-participant-flow-$sessionKey'),
        reverse: true,
        padding: EdgeInsets.fromLTRB(
          LicoContentSpacing.item,
          LicoContentSpacing.item + topOverlayInset,
          LicoContentSpacing.item,
          LicoContentSpacing.item +
              adapter.assistantVerticalPadding +
              bottomOverlayInset,
        ),
        itemCount: displayEntries.length,
        itemBuilder: (context, index) {
          final entry = displayEntries[index];
          // A streamed reply changes one entry per frame. Without a repaint
          // boundary per entry the whole visible flow repaints with it.
          return RepaintBoundary(child: _entryContent(context, entry));
        },
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
            target: target,
            adapter: adapter,
          ),
        ),
      MessagingFlowProcess(:final item, :final active) => Padding(
        padding: LicoContentSpacing.peerItem,
        child: SelectionContainer.disabled(
          child: MessagingProcessStatusRow(
            events: item.events,
            adapter: adapter,
            detailsBuilder: buildAgentConversationEventDetails,
            active: active,
          ),
        ),
      ),
      MessagingFlowLog(:final item) => Padding(
        padding: const EdgeInsets.only(
          left: 48,
          bottom: LicoContentSpacing.item,
        ),
        child: SelectionContainer.disabled(
          child: ConversationLogEventRow(events: item.events),
        ),
      ),
      MessagingFlowSubagent(:final item) => Padding(
        padding: LicoContentSpacing.peerItem,
        child: AgentConversationSubagentCardBlock(
          message: item.message,
          adapter: adapter,
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
