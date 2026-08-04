import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/disclosures.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = widget.message.cardTitle.trim().isEmpty
        ? strings.subagentTask
        : widget.message.cardTitle.trim();
    final subtitle = widget.message.cardSubtitle.trim().isEmpty
        ? '${strings.subagentTask} · ${strings.messagesCount(widget.message.childMessages.length)}'
        : widget.message.cardSubtitle.trim();
    final preview = conversationMessagePreviewText(widget.message.text);
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
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
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
                      const SizedBox(width: 8),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: colors.textMuted,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
              if (!_expanded && preview.isNotEmpty)
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
              if (_expanded) ...[
                Divider(height: 1, color: colors.line),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (
                        var index = 0;
                        index < widget.message.childMessages.length;
                        index++
                      ) ...[
                        _SubagentChildMessageBlock(
                          message: widget.message.childMessages[index],
                          adapter: widget.adapter,
                        ),
                        if (index != widget.message.childMessages.length - 1)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Divider(height: 1, color: colors.line),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
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
}

class _SubagentChildMessageBlock extends StatelessWidget {
  const _SubagentChildMessageBlock({
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
