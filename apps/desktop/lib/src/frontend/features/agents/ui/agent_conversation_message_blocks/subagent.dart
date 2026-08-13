import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/disclosures.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Deepest delegated task nesting the card renders inline. Beyond it a task is
/// summarized by its header only, so one runaway orchestration cannot build an
/// unbounded widget tree.
const int _maxInlineSubagentDepth = 4;

/// Height cap of the expanded card body. The delegated task content scrolls
/// inside this bounded frame like a page, instead of stretching the whole
/// conversation to the length of one subagent run.
const double _maxExpandedCardHeight = 320;

class AgentConversationSubagentCardBlock extends StatefulWidget {
  const AgentConversationSubagentCardBlock({
    super.key,
    required this.message,
    required this.adapter,
    this.fullWidth = false,
    this.depth = 0,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;
  final bool fullWidth;

  /// Nesting level of this card inside the conversation. A delegated task that
  /// delegated further renders its children one level in, so the lineage stays
  /// readable instead of collapsing into one flat list.
  final int depth;

  @override
  State<AgentConversationSubagentCardBlock> createState() =>
      _AgentConversationSubagentCardBlockState();
}

class _AgentConversationSubagentCardBlockState
    extends State<AgentConversationSubagentCardBlock> {
  late bool _expanded = !widget.message.collapsed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final children = widget.message.childMessages;
    final title = widget.message.cardTitle.trim().isEmpty
        ? strings.subagentTask
        : widget.message.cardTitle.trim();
    final subtitle = _subtitle(strings, children);
    final preview = conversationMessagePreviewText(widget.message.text);
    final canExpandInline =
        children.isNotEmpty && widget.depth < _maxInlineSubagentDepth;
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(colors.isDark ? 18 : 24),
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.menuCornerRadius,
        ),
        border: Border.all(
          color: Colors.white.withAlpha(colors.isDark ? 48 : 70),
          width: AppleControlMetrics.hairline,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.menuCornerRadius,
            ),
            onTap: canExpandInline
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    color: colors.accent.withAlpha(200),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.text,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            letterSpacing: -0.08,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (canExpandInline) ...[
                    const SizedBox(width: 8),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: colors.textMuted,
                      size: 18,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if ((!_expanded || !canExpandInline) && preview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 14, 12),
              child: Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          if (_expanded && canExpandInline) ...[
            Divider(height: 1, color: colors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: _maxExpandedCardHeight,
                ),
                child: SingleChildScrollView(
                  child: _SubagentChildList(
                    children: children,
                    adapter: widget.adapter,
                    depth: widget.depth,
                  ),
                ),
              ),
            ),
          ],
          if (widget.message.childMessagesTruncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 14, 10),
              child: Text(
                strings.conversationDetailsTruncated,
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ),
        ],
      ),
    );

    if (widget.fullWidth) {
      return SizedBox(width: double.infinity, child: card);
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.adapter.assistantMaxWidth),
        child: card,
      ),
    );
  }

  /// Factual header line: the declared task type when the store recorded one,
  /// then how much work the task did. A task that is pure tool activity used to
  /// read as an empty message list, which said nothing about it.
  String _subtitle(
    LicoStrings strings,
    List<AgentConversationMessage> children,
  ) {
    final declared = widget.message.cardSubtitle.trim();
    final toolCalls = children
        .where(
          (child) =>
              child.kind == AgentConversationMessageKind.toolCall ||
              child.kind == AgentConversationMessageKind.toolResult,
        )
        .length;
    final nested = children.where((child) => child.isSubagentCard).length;
    final parts = <String>[
      if (declared.isNotEmpty) declared,
      strings.subagentSteps(children.length),
      if (toolCalls > 0) strings.subagentToolCalls(toolCalls),
      if (nested > 0) strings.subagentNestedTasks(nested),
    ];
    return parts.join(' · ');
  }
}

class _SubagentChildList extends StatelessWidget {
  const _SubagentChildList({
    required this.children,
    required this.adapter,
    required this.depth,
  });

  final List<AgentConversationMessage> children;
  final AgentRenderAdapter adapter;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final rows = <Widget>[];
    var pendingSteps = <AgentConversationMessage>[];

    void flushSteps() {
      if (pendingSteps.isEmpty) {
        return;
      }
      rows.add(_SubagentStepRun(steps: List.of(pendingSteps)));
      pendingSteps = <AgentConversationMessage>[];
    }

    for (final child in children) {
      if (child.isSubagentCard) {
        flushSteps();
        rows.add(
          AgentConversationSubagentCardBlock(
            key: ValueKey('subagent-child-${child.id}'),
            message: child,
            adapter: adapter,
            fullWidth: true,
            depth: depth + 1,
          ),
        );
        continue;
      }
      if (child.isStructuredEvent) {
        pendingSteps.add(child);
        continue;
      }
      flushSteps();
      rows.add(
        _SubagentChildMessageBlock(
          key: ValueKey('subagent-text-${child.id}'),
          message: child,
          adapter: adapter,
        ),
      );
    }
    flushSteps();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < rows.length; index++) ...[
          rows[index],
          if (index != rows.length - 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, color: colors.line),
            ),
        ],
      ],
    );
  }
}

/// A run of consecutive tool and reasoning steps inside one delegated task.
/// Collapsed by default: the task's outcome matters more than each step, and an
/// exploration task can be hundreds of steps long.
class _SubagentStepRun extends StatefulWidget {
  const _SubagentStepRun({required this.steps});

  final List<AgentConversationMessage> steps;

  @override
  State<_SubagentStepRun> createState() => _SubagentStepRunState();
}

class _SubagentStepRunState extends State<_SubagentStepRun> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('subagent-step-run-toggle'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bolt_outlined,
                      size: 12,
                      color: colors.textMuted.withAlpha(150),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      strings.subagentSteps(widget.steps.length),
                      style: TextStyle(
                        color: colors.textMuted.withAlpha(190),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 13,
                      color: colors.textMuted.withAlpha(140),
                    ),
                  ],
                ),
                if (_expanded)
                  for (final step in widget.steps)
                    Padding(
                      padding: const EdgeInsets.only(left: 18, top: 6),
                      child: Text(
                        _stepLabel(step),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11.5,
                          height: 1.3,
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

  String _stepLabel(AgentConversationMessage step) {
    final title = step.cardTitle.trim();
    if (title.isNotEmpty) {
      return title;
    }
    final text = step.text.trim();
    return text.isEmpty ? step.role : conversationMessagePreviewText(text);
  }
}

class _SubagentChildMessageBlock extends StatelessWidget {
  const _SubagentChildMessageBlock({
    super.key,
    required this.message,
    required this.adapter,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return AgentConversationMessageContent(
      data: message.text,
      foreground: agentConversationMessageForeground(colors, message.role),
      accent: colors.primary,
      codeBackground: agentConversationToneColor(colors, adapter.codeTone),
      blockBackground: agentConversationToneColor(colors, adapter.quoteTone),
      borderColor: colors.line,
      renderStyle: adapter.markdownStyle,
    );
  }
}
