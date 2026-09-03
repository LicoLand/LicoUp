import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_details_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_metadata_fields.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_projection.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Redacted one-line headline for a process operation (title · subtitle).
/// Safe for inline Working summaries — never exposes raw tool args or CoT.
({String title, String subtitle}) conversationProcessOperationHeadline(
  AgentConversationMessage message,
  LicoThemeColors colors,
  LicoStrings strings,
) {
  final presentation = _eventPresentation(message.kind, colors, strings);
  final defaultReasoningTitle =
      message.kind == AgentConversationMessageKind.reasoning &&
      message.providerSummary;
  final rawTitle = message.cardTitle.trim();
  final title =
      rawTitle.isEmpty ||
          defaultReasoningTitle ||
          _isDefaultProcessTitle(message.kind, rawTitle)
      ? (defaultReasoningTitle ? strings.reasoningSummary : presentation.title)
      : rawTitle;
  final rawSubtitle = message.cardSubtitle.trim();
  final subtitle = defaultReasoningTitle
      ? strings.providerSummary
      : rawSubtitle.isEmpty || _isDefaultProcessSubtitle(rawSubtitle)
      ? presentation.subtitle
      : rawSubtitle;
  return (title: title, subtitle: subtitle);
}

double conversationProcessExpandedBodyMaxHeight(double viewportHeight) {
  return (viewportHeight * 0.52).clamp(240.0, 560.0);
}

void pinConversationProcessHeaderBelowOverlay(
  BuildContext headerContext,
  double topOverlayInset,
) {
  final scrollable = Scrollable.maybeOf(headerContext);
  final headerBox = headerContext.findRenderObject();
  final viewportBox = scrollable?.context.findRenderObject();
  if (scrollable == null ||
      headerBox is! RenderBox ||
      viewportBox is! RenderBox ||
      !headerBox.hasSize ||
      !viewportBox.hasSize) {
    return;
  }
  final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
  final desiredTop =
      viewportTop +
      (topOverlayInset > 0 ? topOverlayInset : viewportBox.size.height * 0.08);
  final physicalDelta = headerBox.localToGlobal(Offset.zero).dy - desiredTop;
  if (physicalDelta.abs() < 0.5) return;
  final position = scrollable.position;
  final pixelDelta = switch (position.axisDirection) {
    AxisDirection.down => physicalDelta,
    AxisDirection.up => -physicalDelta,
    _ => 0.0,
  };
  if (pixelDelta == 0) return;
  position.jumpTo(
    (position.pixels + pixelDelta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    ),
  );
}

final class ConversationProcessOperationViewport extends StatelessWidget {
  const ConversationProcessOperationViewport({
    super.key,
    required this.processId,
    required this.controller,
    required this.child,
  });

  final String processId;
  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: conversationProcessExpandedBodyMaxHeight(
          MediaQuery.sizeOf(context).height,
        ),
      ),
      child: Scrollbar(
        controller: controller,
        child: PrimaryScrollController(
          controller: controller,
          child: KeyedSubtree(
            key: ValueKey('conversation-process-operation-scroll-$processId'),
            child: child,
          ),
        ),
      ),
    );
  }
}

final class ConversationProcessOperationList extends StatelessWidget {
  const ConversationProcessOperationList({
    super.key,
    required this.operations,
    required this.adapter,
    required this.detailsBuilder,
    this.activeStepIndex = -1,
  });

  final List<AgentConversationMessage> operations;
  final AgentRenderAdapter adapter;
  final ConversationEventDetailsBuilder detailsBuilder;
  final int activeStepIndex;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final operationKeys = uniqueConversationProcessOperationKeys(operations);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: SizedBox(
        height: operations.isEmpty
            ? 0
            : (operations.length * 56.0).clamp(120.0, 560.0),
        child: ListView.separated(
          primary: true,
          itemCount: operations.length,
          separatorBuilder: (context, index) =>
              Divider(height: 1, indent: 46, color: colors.line),
          itemBuilder: (context, index) => _ProcessOperationRow(
            message: operations[index],
            adapter: adapter,
            detailsBuilder: detailsBuilder,
            operationKey: operationKeys[index],
            executing: index == activeStepIndex,
          ),
        ),
      ),
    );
  }
}

final class _ProcessOperationRow extends StatefulWidget {
  const _ProcessOperationRow({
    required this.message,
    required this.adapter,
    required this.detailsBuilder,
    required this.operationKey,
    this.executing = false,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;
  final ConversationEventDetailsBuilder detailsBuilder;
  final String operationKey;
  final bool executing;

  @override
  State<_ProcessOperationRow> createState() => _ProcessOperationRowState();
}

final class _ProcessOperationRowState extends State<_ProcessOperationRow> {
  // Rows follow the projection's collapsed default: everything except errors
  // starts collapsed and expands on tap to reveal the detail body.
  late bool _expanded = !widget.message.collapsed;

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final message = widget.message;
    final presentation = _eventPresentation(message.kind, colors, strings);
    final defaultReasoningTitle =
        message.kind == AgentConversationMessageKind.reasoning &&
        message.providerSummary;
    final rawTitle = message.cardTitle.trim();
    final title =
        rawTitle.isEmpty ||
            defaultReasoningTitle ||
            _isDefaultProcessTitle(message.kind, rawTitle)
        ? (defaultReasoningTitle
              ? strings.reasoningSummary
              : presentation.title)
        : rawTitle;
    final rawSubtitle = message.cardSubtitle.trim();
    final subtitle = defaultReasoningTitle
        ? strings.providerSummary
        : rawSubtitle.isEmpty || _isDefaultProcessSubtitle(rawSubtitle)
        ? presentation.subtitle
        : rawSubtitle;
    final details = message.text.trim().isNotEmpty
        ? message.text.trim()
        : _localizedHiddenProcessDetails(message.kind, strings);
    final mutedDetails =
        message.kind == AgentConversationMessageKind.metadata ||
        message.kind == AgentConversationMessageKind.toolCall ||
        (message.kind == AgentConversationMessageKind.reasoning &&
            !message.providerSummary);
    final motionDisabled = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      key: ValueKey('conversation-process-operation-${widget.operationKey}'),
      container: true,
      button: true,
      expanded: _expanded,
      label: _expanded && details.isNotEmpty
          ? '$title. $subtitle. $details'
          : '$title. $subtitle',
      hint: strings.showDetails,
      onTap: _toggleExpanded,
      child: ExcludeSemantics(
        child: InkWell(
          key: ValueKey(
            'conversation-process-operation-toggle-${widget.operationKey}',
          ),
          onTap: _toggleExpanded,
          hoverColor: colors.text.withAlpha(6),
          focusColor: colors.accent.withValues(alpha: 0.06),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 22,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: widget.executing
                              ? LicoSpinningRefreshIcon(
                                  size: 15,
                                  color: presentation.accent,
                                )
                              : Icon(
                                  presentation.icon,
                                  size: 17,
                                  color: presentation.accent,
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LicoShimmerText(
                              text: title,
                              enabled: widget.executing,
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (subtitle.isNotEmpty)
                              LicoShimmerText(
                                text: subtitle,
                                enabled: widget.executing,
                                style: TextStyle(
                                  color: colors.textMuted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: motionDisabled
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            _expanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 17,
                            color: colors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (motionDisabled)
                    _expanded && details.isNotEmpty
                        ? _OperationDetails(
                            message: message,
                            details: details,
                            mutedDetails: mutedDetails,
                            presentation: presentation,
                            adapter: widget.adapter,
                            detailsBuilder: widget.detailsBuilder,
                          )
                        : const SizedBox.shrink()
                  else
                    AnimatedSize(
                      duration: motionDisabled
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: _expanded && details.isNotEmpty
                          ? _OperationDetails(
                              message: message,
                              details: details,
                              mutedDetails: mutedDetails,
                              presentation: presentation,
                              adapter: widget.adapter,
                              detailsBuilder: widget.detailsBuilder,
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The expandable detail body of one operation row. Metadata renders as
/// aligned key/value fields; every other kind renders the markdown details.
final class _OperationDetails extends StatelessWidget {
  const _OperationDetails({
    required this.message,
    required this.details,
    required this.mutedDetails,
    required this.presentation,
    required this.adapter,
    required this.detailsBuilder,
  });

  final AgentConversationMessage message;
  final String details;
  final bool mutedDetails;
  final ({String title, String subtitle, IconData icon, Color accent})
  presentation;
  final AgentRenderAdapter adapter;
  final ConversationEventDetailsBuilder detailsBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(left: 32, top: 6),
      child: message.kind == AgentConversationMessageKind.metadata
          ? ConversationMetadataFields(
              data: details,
              foreground: mutedDetails ? colors.textMuted : colors.text,
            )
          : detailsBuilder(
              data: details,
              foreground: mutedDetails ? colors.textMuted : colors.text,
              accent: presentation.accent,
              codeBackground: _toneColor(colors, adapter.codeTone),
              blockBackground: _toneColor(colors, adapter.quoteTone),
              borderColor: colors.line,
              renderStyle: adapter.markdownStyle,
            ),
    );
  }
}

String _localizedHiddenProcessDetails(
  AgentConversationMessageKind kind,
  LicoStrings strings,
) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => strings.invocationDetailsHidden,
    AgentConversationMessageKind.toolResult => strings.toolResultRecorded,
    AgentConversationMessageKind.reasoning => strings.reasoningDetailsRedacted,
    AgentConversationMessageKind.metadata => strings.nativeMetadataHidden,
    AgentConversationMessageKind.error => strings.nativeAgentErrorReported,
    _ => strings.nativeEventDetailsHidden,
  };
}

bool _isDefaultProcessTitle(AgentConversationMessageKind kind, String value) {
  final normalized = value.trim().toLowerCase();
  return switch (kind) {
    AgentConversationMessageKind.toolCall => normalized == 'tool call',
    AgentConversationMessageKind.toolResult => normalized == 'tool result',
    AgentConversationMessageKind.reasoning => normalized == 'reasoning',
    AgentConversationMessageKind.metadata => normalized == 'metadata',
    AgentConversationMessageKind.error => normalized == 'error',
    _ => normalized == 'native event',
  };
}

bool _isDefaultProcessSubtitle(String value) {
  return const {
    'native agent activity',
    'native agent result',
    'reasoning summary',
    'sensitive details hidden',
    'native agent error',
    'native agent event',
  }.contains(value.trim().toLowerCase());
}

({String title, String subtitle, IconData icon, Color accent})
_eventPresentation(
  AgentConversationMessageKind kind,
  LicoThemeColors colors,
  LicoStrings strings,
) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => (
      title: strings.toolCall,
      subtitle: strings.nativeAgentActivity,
      icon: Icons.terminal_rounded,
      accent: colors.accent,
    ),
    AgentConversationMessageKind.toolResult => (
      title: strings.toolResult,
      subtitle: strings.nativeAgentResult,
      icon: Icons.check_circle_outline_rounded,
      accent: colors.success,
    ),
    AgentConversationMessageKind.reasoning => (
      title: strings.reasoning,
      subtitle: '',
      icon: Icons.psychology_alt_outlined,
      accent: colors.textMuted,
    ),
    AgentConversationMessageKind.metadata => (
      title: strings.metadata,
      subtitle: '',
      icon: Icons.info_outline_rounded,
      accent: colors.textMuted,
    ),
    AgentConversationMessageKind.error => (
      title: strings.processError,
      subtitle: strings.nativeAgentError,
      icon: Icons.error_outline_rounded,
      accent: colors.error,
    ),
    _ => (
      title: strings.nativeEvent,
      subtitle: strings.nativeAgentEvent,
      icon: Icons.bolt_outlined,
      accent: colors.textMuted,
    ),
  };
}

Color _toneColor(LicoThemeColors colors, String tone) {
  return switch (tone) {
    'raised' => colors.surfaceRaised,
    'surface' => colors.surface,
    'muted' => colors.surfaceLow,
    _ => colors.surfaceLow,
  };
}
