import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_details_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_lifecycle_indicator.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_operations.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_projection.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class ConversationProcessCard extends StatefulWidget {
  const ConversationProcessCard({
    super.key,
    required this.events,
    required this.adapter,
    required this.detailsBuilder,
    this.active = false,
  }) : assert(events.length > 0);

  final List<AgentConversationMessage> events;
  final AgentRenderAdapter adapter;
  final ConversationEventDetailsBuilder detailsBuilder;
  final bool active;

  @override
  State<ConversationProcessCard> createState() =>
      _ConversationProcessCardState();
}

final class _ConversationProcessCardState
    extends State<ConversationProcessCard> {
  final FocusNode _headerFocusNode = FocusNode(
    debugLabel: 'conversation-process-header',
  );
  bool _expanded = false;
  bool _focused = false;

  String get _processId => widget.events.first.id;

  @override
  void dispose() {
    _headerFocusNode.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    final expanding = !_expanded;
    setState(() => _expanded = expanding);
    if (!expanding) return;
    final delay = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 210);
    void scheduleEnsureVisible() {
      if (!mounted || !_expanded) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_expanded) return;
        final headerContext = _headerFocusNode.context;
        if (headerContext == null || !headerContext.mounted) return;
        Scrollable.ensureVisible(
          headerContext,
          alignment: 0.08,
          duration: Duration.zero,
        );
      });
      WidgetsBinding.instance.scheduleFrame();
    }

    if (delay == Duration.zero) {
      scheduleEnsureVisible();
    } else {
      Future<void>.delayed(delay, scheduleEnsureVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final projection = projectConversationProcessEvents(widget.events);
    final lifecycle = projectConversationTurnLifecycle(widget.events);
    final operations = projection.events
        .where((event) => !isConversationLifecycleEvent(event))
        .toList(growable: false);
    final durationTitle = conversationProcessDurationTitle(
      projection.startedAt,
      projection.endedAt,
      strings,
    );
    final title = lifecycle == null
        ? conversationProcessSemanticTitle(operations, strings)
        : conversationLifecycleStageLabel(lifecycle.stage, strings);
    final summary = lifecycle == null
        ? '${widget.active ? strings.working : durationTitle} · ${conversationProcessSummary(projection.totalOperations, projection.issues, projection.countTruncated, strings)}'
        : lifecycle.terminal
        ? '$durationTitle · ${strings.lifecycleObserved(lifecycle.observedStages.length, 5)}'
        : strings.lifecycleObserved(lifecycle.observedStages.length, 5);
    final motionDisabled = MediaQuery.disableAnimationsOf(context);
    final containerDuration = motionDisabled
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final sizeDuration = motionDisabled
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final actionHint = _expanded
        ? strings.collapseProcessDetails
        : strings.expandProcessDetails;
    final operationList = ConversationProcessOperationList(
      operations: operations,
      adapter: widget.adapter,
      detailsBuilder: widget.detailsBuilder,
      truncated: projection.renderTruncated,
      activeStepIndex: widget.active ? operations.length - 1 : -1,
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.adapter.assistantMaxWidth),
        child: AnimatedContainer(
          key: ValueKey('conversation-process-$_processId'),
          duration: containerDuration,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: _expanded
                ? Colors.white.withAlpha(colors.isDark ? 22 : 28)
                : Colors.white.withAlpha(colors.isDark ? 14 : 18),
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.menuCornerRadius,
            ),
            border: Border.all(
              color: _focused
                  ? colors.accent.withAlpha(170)
                  : Colors.white.withAlpha(colors.isDark ? 42 : 64),
              width: AppleControlMetrics.hairline,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  key: ValueKey('conversation-process-semantics-$_processId'),
                  container: true,
                  button: true,
                  focusable: true,
                  focused: _focused,
                  expanded: _expanded,
                  label: '${strings.agentProcess}. $title. $summary.',
                  hint: actionHint,
                  onTap: _toggleExpanded,
                  child: ExcludeSemantics(
                    child: Tooltip(
                      message: actionHint,
                      child: InkWell(
                        key: ValueKey(
                          'conversation-process-toggle-$_processId',
                        ),
                        focusNode: _headerFocusNode,
                        onFocusChange: (focused) {
                          if (_focused != focused) {
                            setState(() => _focused = focused);
                          }
                        },
                        onTap: _toggleExpanded,
                        focusColor: colors.accent.withValues(alpha: 0.10),
                        hoverColor: colors.text.withValues(alpha: 0.04),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                widget.active && lifecycle?.terminal != true
                                    ? LicoSpinningRefreshIcon(
                                        size: 15,
                                        color: colors.textMuted,
                                      )
                                    : lifecycle?.stage ==
                                          ConversationTurnLifecycleStage
                                              .completed
                                    ? Icon(
                                        Icons.check_circle_rounded,
                                        size: 16,
                                        color: colors.success,
                                      )
                                    : lifecycle?.stage ==
                                          ConversationTurnLifecycleStage.failed
                                    ? Icon(
                                        Icons.error_rounded,
                                        size: 16,
                                        color: colors.error,
                                      )
                                    : Icon(
                                        Icons.format_list_bulleted_rounded,
                                        size: 16,
                                        color: colors.textMuted,
                                      ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      LicoShimmerText(
                                        text: title,
                                        enabled: widget.active,
                                        style: TextStyle(
                                          color: colors.text,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -0.08,
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      LicoShimmerText(
                                        text: summary,
                                        enabled:
                                            widget.active &&
                                            lifecycle?.terminal != true,
                                        style: TextStyle(
                                          color: colors.textMuted,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w400,
                                          letterSpacing: -0.04,
                                        ),
                                      ),
                                      if (lifecycle != null &&
                                          (!lifecycle.terminal ||
                                              lifecycle.observedStages.length <
                                                  5)) ...[
                                        const SizedBox(height: 8),
                                        ConversationLifecycleSteps(
                                          projection: lifecycle,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                AnimatedRotation(
                                  turns: _expanded ? 0.5 : 0,
                                  duration: containerDuration,
                                  curve: Curves.easeOutCubic,
                                  child: Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    size: 18,
                                    color: colors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (motionDisabled)
                  _expanded ? operationList : const SizedBox.shrink()
                else
                  AnimatedSize(
                    duration: sizeDuration,
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _expanded ? operationList : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String conversationProcessSemanticTitle(
  Iterable<AgentConversationMessage> events,
  LicoStrings strings,
) {
  var hasReasoning = false;
  var hasToolActivity = false;
  for (final event in events) {
    hasReasoning =
        hasReasoning || event.kind == AgentConversationMessageKind.reasoning;
    hasToolActivity =
        hasToolActivity ||
        event.kind == AgentConversationMessageKind.toolCall ||
        event.kind == AgentConversationMessageKind.toolResult;
  }
  if (hasReasoning && !hasToolActivity) return strings.reasoningProcess;
  if (hasToolActivity && !hasReasoning) return strings.toolExecution;
  return strings.agentActivity;
}

/// Shared "Worked for …" title for process presentations (console card and
/// messaging inline status row).
String conversationProcessDurationTitle(
  DateTime? start,
  DateTime? end,
  LicoStrings strings,
) {
  if (start == null || end == null || end.isBefore(start)) {
    return strings.agentProcess;
  }
  final elapsedMilliseconds = end.difference(start).inMilliseconds;
  if (elapsedMilliseconds <= 0) return strings.workedBriefly;
  final seconds = (elapsedMilliseconds + 999) ~/ 1000;
  if (seconds < 60) return strings.workedForSeconds(seconds);
  return strings.workedForMinutes(seconds ~/ 60, seconds % 60);
}

/// Shared "N steps · N issues" summary for process presentations (console
/// card and messaging inline status row).
String conversationProcessSummary(
  int totalOperations,
  int issues,
  bool truncated,
  LicoStrings strings,
) {
  final steps = strings.processSteps(totalOperations, truncated: truncated);
  return issues == 0 ? steps : '$steps · ${strings.processIssues(issues)}';
}
