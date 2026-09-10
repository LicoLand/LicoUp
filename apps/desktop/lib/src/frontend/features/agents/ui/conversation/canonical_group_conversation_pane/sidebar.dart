import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class CanonicalGroupConversationSidebar extends StatelessWidget {
  const CanonicalGroupConversationSidebar({
    super.key,
    required this.conversations,
    required this.selectedConversationId,
    required this.onSelect,
    required this.onCreate,
    this.highlightedChildConversationId = '',
  });

  final List<ClientConversationSummary> conversations;
  final String selectedConversationId;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final String highlightedChildConversationId;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 42,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.push_pin_rounded,
                    size: 13,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      strings.groupConversation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('canonical-group-sidebar-create'),
                    tooltip: strings.newGroupConversation,
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded, size: 17),
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          for (final conversation in conversations.take(3)) ...[
            _CanonicalGroupSidebarRow(
              conversation: conversation,
              selected: conversation.id == selectedConversationId,
              onTap: () => onSelect(conversation.id),
            ),
            for (final child in conversation.children)
              Padding(
                padding: const EdgeInsets.only(left: 18, right: 8, bottom: 6),
                child: ContinuousAssistantChildEntry(
                  task: _childTaskView(conversation.id, child),
                  highlighted: highlightedChildConversationId == child.id,
                  onOpenChild: (_) => onSelect(child.id),
                ),
              ),
          ],
          CanonicalArchivedContinuityChildren(
            children: [
              for (final conversation in conversations.take(3))
                ...conversation.archivedChildren,
            ],
            highlightedChildConversationId: highlightedChildConversationId,
            onSelect: onSelect,
          ),
          if (conversations.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.noGroupConversationsYet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 10.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Collapsed footer for Continuity children that were archived by
/// `conversation.clear`. Hidden until the header is opened; a selected
/// child forces the section open so the current row stays visible.
class CanonicalArchivedContinuityChildren extends StatefulWidget {
  const CanonicalArchivedContinuityChildren({
    super.key,
    required this.children,
    required this.onSelect,
    this.highlightedChildConversationId = '',
    this.toggleKey = const Key('canonical-archived-continuity-toggle'),
  });

  final List<ClientConversationSummary> children;
  final ValueChanged<String> onSelect;
  final String highlightedChildConversationId;
  final Key toggleKey;

  @override
  State<CanonicalArchivedContinuityChildren> createState() =>
      _CanonicalArchivedContinuityChildrenState();
}

class _CanonicalArchivedContinuityChildrenState
    extends State<CanonicalArchivedContinuityChildren> {
  bool _expanded = false;

  bool get _containsHighlighted => widget.children.any(
    (child) => child.id == widget.highlightedChildConversationId,
  );

  @override
  void initState() {
    super.initState();
    _expanded = _containsHighlighted;
  }

  @override
  void didUpdateWidget(
    covariant CanonicalArchivedContinuityChildren oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (_containsHighlighted && !_expanded) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    final strings = LicoStrings.of(context);
    final visible = _expanded || _containsHighlighted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LicoGroupHeader(
          label: strings.archivedContinuityChildren,
          count: widget.children.length,
          expanded: visible,
          onToggle: () => setState(() => _expanded = !_expanded),
          toggleKey: widget.toggleKey,
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
        ),
        if (visible)
          for (final child in widget.children)
            Padding(
              padding: const EdgeInsets.only(left: 18, right: 8, bottom: 6),
              child: ContinuousAssistantChildEntry(
                task: _childTaskView(child.parentConversationId ?? '', child),
                highlighted: widget.highlightedChildConversationId == child.id,
                onOpenChild: (_) => widget.onSelect(child.id),
              ),
            ),
      ],
    );
  }
}

ContinuousAssistantTaskView _childTaskView(
  String parentId,
  ClientConversationSummary child,
) {
  return continuousAssistantTaskFromCardMetadata(
    metadata: <String, dynamic>{
      'goalId': child.taskGoalId ?? child.id,
      'childConversationId': child.id,
    },
    parentConversationId: parentId,
    eventId: child.id,
    sequence: child.eventCount,
  )!;
}

class _CanonicalGroupSidebarRow extends StatelessWidget {
  const _CanonicalGroupSidebarRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final ClientConversationSummary conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? colors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(LicoRadius.floating),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.groups_2_rounded,
                  size: 20,
                  color: selected
                      ? colors.textOnPrimary
                      : ConversationVisualTokens.groupIdentityMark(colors),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? colors.textOnPrimary : colors.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        strings.groupConversationMemberCount(
                          conversation.membershipCount,
                        ),
                        style: TextStyle(
                          color: selected
                              ? colors.textOnPrimary.withAlpha(180)
                              : colors.textMuted,
                          fontSize: 10.5,
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
