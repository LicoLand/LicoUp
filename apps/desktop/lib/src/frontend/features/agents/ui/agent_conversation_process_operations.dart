import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_event_details_builder.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_process_projection.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

final class ConversationProcessOperationList extends StatelessWidget {
  const ConversationProcessOperationList({
    super.key,
    required this.operations,
    required this.adapter,
    required this.detailsBuilder,
    required this.truncated,
    this.activeStepIndex = -1,
  });

  final List<AgentConversationMessage> operations;
  final AgentRenderAdapter adapter;
  final ConversationEventDetailsBuilder detailsBuilder;
  final bool truncated;
  final int activeStepIndex;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final operationKeys = uniqueConversationProcessOperationKeys(operations);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < operations.length; index++) ...[
            if (index > 0) Divider(height: 1, indent: 46, color: colors.line),
            _ProcessOperationRow(
              message: operations[index],
              adapter: adapter,
              detailsBuilder: detailsBuilder,
              operationKey: operationKeys[index],
              executing: index == activeStepIndex,
            ),
          ],
          if (truncated) ...[
            if (operations.isNotEmpty)
              Divider(height: 1, indent: 46, color: colors.line),
            const _ProcessTruncationRow(),
          ],
        ],
      ),
    );
  }
}

final class _ProcessTruncationRow extends StatelessWidget {
  const _ProcessTruncationRow();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.more_horiz_rounded, size: 17, color: colors.textMuted),
            const SizedBox(width: 15),
            Expanded(
              child: Text(
                strings.additionalOperationsHidden,
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ProcessOperationRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
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

    return Semantics(
      key: ValueKey('conversation-process-operation-$operationKey'),
      container: true,
      label: '$title. $subtitle. $details',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: executing
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
                        enabled: executing,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        LicoShimmerText(
                          text: subtitle,
                          enabled: executing,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (details.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        detailsBuilder(
                          data: details,
                          foreground: mutedDetails
                              ? colors.textMuted
                              : colors.text,
                          accent: presentation.accent,
                          codeBackground: _toneColor(colors, adapter.codeTone),
                          blockBackground: _toneColor(
                            colors,
                            adapter.quoteTone,
                          ),
                          borderColor: colors.line,
                          renderStyle: adapter.markdownStyle,
                        ),
                      ],
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
      accent: colors.info,
    ),
    AgentConversationMessageKind.toolResult => (
      title: strings.toolResult,
      subtitle: strings.nativeAgentResult,
      icon: Icons.check_circle_outline_rounded,
      accent: colors.success,
    ),
    AgentConversationMessageKind.reasoning => (
      title: strings.reasoning,
      subtitle: strings.sensitiveDetailsHidden,
      icon: Icons.psychology_alt_outlined,
      accent: colors.textMuted,
    ),
    AgentConversationMessageKind.metadata => (
      title: strings.metadata,
      subtitle: strings.sensitiveDetailsHidden,
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
    'raised' => colors.surfaceHigh,
    'surface' => colors.surface,
    'muted' => colors.surfaceHighest,
    _ => colors.surfaceLow,
  };
}
