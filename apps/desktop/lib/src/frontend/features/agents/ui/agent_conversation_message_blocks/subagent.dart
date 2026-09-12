import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/disclosures.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/native_subagent_history_scope.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/base_surface.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Height cap of the expanded card body. The delegated task content scrolls
/// inside this bounded frame like a page, instead of stretching the whole
/// conversation to the length of one subagent run.
const double _maxExpandedCardHeight = 320;

/// Native lineage cards own this treatment while the base supplies the active
/// theme's fill, opacity and continuous outline.
final class AgentConversationSubagentSurface extends BaseSurface {
  const AgentConversationSubagentSurface({super.key, required super.child})
    : super(radius: AppleControlMetrics.menuCornerRadius);
}

class AgentConversationSubagentCardBlock extends StatefulWidget {
  const AgentConversationSubagentCardBlock({
    super.key,
    required this.message,
    required this.adapter,
    this.fullWidth = false,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;
  final bool fullWidth;

  @override
  State<AgentConversationSubagentCardBlock> createState() =>
      _AgentConversationSubagentCardBlockState();
}

class _AgentConversationSubagentCardBlockState
    extends State<AgentConversationSubagentCardBlock> {
  late bool _expanded = !widget.message.collapsed;
  final _scrollController = ScrollController();
  (String, int, String)? _requestedChildVersion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _requestInitialPage();
  }

  @override
  void didUpdateWidget(AgentConversationSubagentCardBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.childMessageCount !=
            widget.message.childMessageCount ||
        oldWidget.message.childSessionId != widget.message.childSessionId) {
      _requestInitialPage();
    } else if (oldWidget.message.childSourceRevision !=
        widget.message.childSourceRevision) {
      _requestInitialPage();
    }
  }

  void _requestInitialPage() {
    final childId = widget.message.childSessionId;
    final scope = NativeSubagentHistoryScope.maybeOf(context, childId);
    final version = (
      childId,
      widget.message.childMessageCount,
      widget.message.childSourceRevision,
    );
    if (!_expanded ||
        childId.isEmpty ||
        scope == null ||
        _requestedChildVersion == version) {
      return;
    }
    final history = scope.histories[childId];
    if (history?.loading == true ||
        history?.errorCode.isNotEmpty == true ||
        (history?.session != null &&
            history!.session!.sourceMessageCount >=
                widget.message.childMessageCount &&
            history.session!.sourceRevision ==
                widget.message.childSourceRevision)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _expanded) {
        _requestedChildVersion = version;
        scope.onLoad(childId, false);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final childId = widget.message.childSessionId;
    final scope = NativeSubagentHistoryScope.maybeOf(context, childId);
    final history = scope?.histories[childId];
    final children = history?.session?.messages ?? widget.message.childMessages;
    final canLoad = childId.isNotEmpty && scope != null;
    final loading = history?.loading ?? false;
    final errorCode = history?.errorCode ?? '';
    final page =
        history?.session?.messagePage ?? widget.message.childMessagePage;
    final title = widget.message.cardTitle.trim().isEmpty
        ? strings.subagentTask
        : widget.message.cardTitle.trim();
    final subtitle = _subtitle(
      strings,
      children,
      history?.session?.sourceMessageCount,
    );
    final preview = conversationMessagePreviewText(widget.message.text);
    // Native lineage owns the tree. Build each descendant only when its
    // parent is expanded so every recorded task remains reachable.
    final canExpandInline = children.isNotEmpty || canLoad;
    final card = AgentConversationSubagentSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.menuCornerRadius,
            ),
            onTap: canExpandInline
                ? () {
                    setState(() => _expanded = !_expanded);
                    _requestInitialPage();
                  }
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
                child: children.isEmpty
                    ? Center(
                        child: loading || (canLoad && history == null)
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(),
                              )
                            : errorCode.isNotEmpty
                            ? _ChildHistoryPageControl(
                                loading: false,
                                errorCode: errorCode,
                                onLoad: () => scope!.onLoad(childId, false),
                              )
                            : Text(strings.noMessagesInHistory),
                      )
                    : _SubagentChildList(
                        children: children,
                        adapter: widget.adapter,
                        controller: _scrollController,
                        loading: loading,
                        errorCode: errorCode,
                        onLoadEarlier: canLoad && (page?.hasEarlier ?? false)
                            ? () => scope.onLoad(childId, true)
                            : null,
                      ),
              ),
            ),
          ],
          if (widget.message.childMessagesTruncated && !canLoad)
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
    int? sourceMessageCount,
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
      strings.subagentSteps(
        sourceMessageCount ??
            (widget.message.childSessionId.isNotEmpty
                ? widget.message.childMessageCount
                : children.length),
      ),
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
    required this.controller,
    required this.loading,
    required this.errorCode,
    this.onLoadEarlier,
  });

  final List<AgentConversationMessage> children;
  final AgentRenderAdapter adapter;
  final ScrollController controller;
  final bool loading;
  final String errorCode;
  final VoidCallback? onLoadEarlier;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final rows = <Widget>[];
    var pendingSteps = <AgentConversationMessage>[];

    void flushSteps() {
      if (pendingSteps.isEmpty) {
        return;
      }
      rows.add(
        _SubagentStepRun(steps: List.of(pendingSteps), adapter: adapter),
      );
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

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        final delta = switch (notification) {
          ScrollUpdateNotification(:final scrollDelta) => scrollDelta ?? 0,
          OverscrollNotification(:final overscroll) => overscroll,
          _ => 0.0,
        };
        if (notification.depth == 0 &&
            delta > 0 &&
            !loading &&
            errorCode.isEmpty &&
            notification.metrics.extentAfter < 120) {
          onLoadEarlier?.call();
        }
        return false;
      },
      child: ListView.separated(
        controller: controller,
        reverse: true,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount:
            rows.length +
            (onLoadEarlier != null || loading || errorCode.isNotEmpty ? 1 : 0),
        separatorBuilder: (context, index) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Divider(height: 1, color: colors.line),
        ),
        itemBuilder: (context, index) => index < rows.length
            ? rows[rows.length - 1 - index]
            : _ChildHistoryPageControl(
                loading: loading,
                errorCode: errorCode,
                onLoad: onLoadEarlier,
              ),
      ),
    );
  }
}

class _ChildHistoryPageControl extends StatelessWidget {
  const _ChildHistoryPageControl({
    required this.loading,
    required this.errorCode,
    required this.onLoad,
  });

  final bool loading;
  final String errorCode;
  final VoidCallback? onLoad;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (errorCode.isNotEmpty)
          Text(errorCode, style: Theme.of(context).textTheme.bodySmall),
        SizedBox(
          height: 40,
          child: loading
              ? const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : TextButton.icon(
                  onPressed: onLoad,
                  icon: Icon(
                    errorCode.isEmpty ? Icons.expand_less : Icons.refresh,
                    size: 16,
                  ),
                  label: Text(
                    errorCode.isEmpty ? strings.earlier : strings.retry,
                  ),
                ),
        ),
      ],
    );
  }
}

/// A run of consecutive tool and reasoning steps inside one delegated task.
/// Collapsed by default: the task's outcome matters more than each step, and an
/// exploration task can be hundreds of steps long.
class _SubagentStepRun extends StatefulWidget {
  const _SubagentStepRun({required this.steps, required this.adapter});

  final List<AgentConversationMessage> steps;
  final AgentRenderAdapter adapter;

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
                      child: _SubagentChildMessageBlock(
                        message: step,
                        adapter: widget.adapter,
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
      images: message.images,
    );
  }
}
