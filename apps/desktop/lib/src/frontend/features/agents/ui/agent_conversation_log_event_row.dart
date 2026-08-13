import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// A deliberately quiet projection of provider bookkeeping. This is not a
/// reasoning disclosure or tool activity and therefore never uses a card.
class ConversationLogEventRow extends StatefulWidget {
  const ConversationLogEventRow({super.key, required this.events});

  final List<AgentConversationMessage> events;

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
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('conversation-runtime-log-toggle'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LicoContentSpacing.inline,
              vertical: LicoContentSpacing.inline,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.terminal_rounded,
                      size: 12,
                      color: colors.textMuted.withAlpha(150),
                    ),
                    const SizedBox(width: LicoContentSpacing.compact),
                    Text(
                      strings.runtimeLogEntries(widget.events.length),
                      style: TextStyle(
                        color: colors.textMuted.withAlpha(180),
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(width: LicoContentSpacing.inline),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 13,
                      color: colors.textMuted.withAlpha(140),
                    ),
                  ],
                ),
                if (_expanded) ...[
                  const SizedBox(height: LicoContentSpacing.compact),
                  for (final event in widget.events)
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 20,
                        bottom: LicoContentSpacing.inline,
                      ),
                      child: Text(
                        event.cardTitle.trim().isNotEmpty
                            ? event.cardTitle.trim()
                            : strings.runtimeLog,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textMuted.withAlpha(160),
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
