import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_details_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_metadata_fields.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// A full-width, visually subdued card for provider runtime records.
/// Expanding the card reveals each event's recorded detail — metadata events
/// render as aligned key/value fields, while run records render their text.
class ConversationLogEventRow extends StatefulWidget {
  const ConversationLogEventRow({
    super.key,
    required this.events,
    this.detailsBuilder,
  });

  final List<AgentConversationMessage> events;
  final ConversationEventDetailsBuilder? detailsBuilder;

  @override
  State<ConversationLogEventRow> createState() =>
      _ConversationLogEventRowState();
}

class _ConversationLogEventRowState extends State<ConversationLogEventRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final borderRadius = BorderRadius.circular(10);
    final decoration = BoxDecoration(
      color: MessagingDesktopMetrics.conversationOverlayGlassFill(
        isDark: colors.isDark,
      ),
      borderRadius: borderRadius,
      border: Border.all(
        color: MessagingDesktopMetrics.conversationOverlayGlassBorder(
          colors.line,
          isDark: colors.isDark,
        ),
        width: MessagingDesktopMetrics.hairline,
      ),
      boxShadow: MessagingDesktopMetrics.conversationOverlayGlassShadows(
        isDark: colors.isDark,
      ),
    );
    return SizedBox(
      width: double.infinity,
      child: Container(
        key: const Key('conversation-runtime-log-card'),
        width: double.infinity,
        decoration: decoration,
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('conversation-runtime-log-toggle'),
            borderRadius: borderRadius,
            hoverColor: colors.text.withAlpha(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        size: 14,
                        color: colors.textMuted.withAlpha(170),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          strings.runtimeLogEntries(widget.events.length),
                          style: TextStyle(
                            color: colors.textMuted.withAlpha(190),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 15,
                        color: colors.textMuted.withAlpha(150),
                      ),
                    ],
                  ),
                  if (_expanded) ...[
                    const SizedBox(height: LicoContentSpacing.compact),
                    for (final event in widget.events)
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 24,
                          right: LicoContentSpacing.inline,
                          bottom: LicoContentSpacing.inline,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              event.cardTitle.trim().isNotEmpty
                                  ? event.cardTitle.trim()
                                  : strings.runtimeLog,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textMuted.withAlpha(170),
                                fontSize: 10.5,
                              ),
                            ),
                            if (_eventDetails(
                              event,
                              strings,
                            ).trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              _LogEventDetails(
                                message: event,
                                details: _eventDetails(event, strings),
                                detailsBuilder: widget.detailsBuilder,
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _eventDetails(AgentConversationMessage event, LicoStrings strings) {
    final text = event.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
    return switch (event.kind) {
      AgentConversationMessageKind.metadata => strings.nativeMetadataHidden,
      AgentConversationMessageKind.event => strings.nativeEventDetailsHidden,
      AgentConversationMessageKind.error => strings.nativeAgentErrorReported,
      _ => '',
    };
  }
}

final class _LogEventDetails extends StatelessWidget {
  const _LogEventDetails({
    required this.message,
    required this.details,
    this.detailsBuilder,
  });

  final AgentConversationMessage message;
  final String details;
  final ConversationEventDetailsBuilder? detailsBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    if (message.kind == AgentConversationMessageKind.metadata) {
      return ConversationMetadataFields(
        data: details,
        foreground: colors.textMuted,
      );
    }
    final builder = detailsBuilder;
    if (builder == null) {
      return Text(
        details,
        style: TextStyle(
          color: colors.textMuted.withAlpha(170),
          fontSize: 11,
          height: 1.35,
        ),
      );
    }
    return builder(
      data: details,
      foreground: colors.textMuted,
      accent: colors.accent,
      codeBackground: colors.surfaceLow,
      blockBackground: colors.surfaceLow,
      borderColor: colors.line,
      renderStyle: const MessageMarkdownStyle(),
    );
  }
}
