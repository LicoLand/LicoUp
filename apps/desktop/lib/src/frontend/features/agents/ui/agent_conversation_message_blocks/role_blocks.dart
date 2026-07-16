import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_message_blocks/disclosures.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentConversationUserMessageBlock extends StatelessWidget {
  const AgentConversationUserMessageBlock({
    super.key,
    required this.message,
    required this.adapter,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.userBubble.maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _bubbleColor(colors, adapter.userBubble.tone),
            borderRadius: BorderRadius.circular(adapter.userBubble.radius),
            border: Border.all(color: colors.line),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: adapter.userBubble.paddingX,
              vertical: adapter.userBubble.paddingY,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (adapter.showUserRoleLabel) ...[
                  Text(
                    strings.you,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                AgentConversationMessageContent(
                  data: message.text,
                  foreground: colors.text,
                  accent: colors.primary,
                  codeBackground: agentConversationToneColor(colors, 'subtle'),
                  blockBackground: agentConversationToneColor(
                    colors,
                    'surface',
                  ),
                  borderColor: colors.line,
                  renderStyle: adapter.markdownStyle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AgentConversationAssistantDocumentBlock extends StatelessWidget {
  const AgentConversationAssistantDocumentBlock({
    super.key,
    required this.message,
    required this.adapter,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.assistantMaxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: adapter.assistantHorizontalInset,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (adapter.showAssistantRoleLabel) ...[
                Text(
                  strings.agent,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              AgentConversationMessageContent(
                data: message.text,
                foreground: agentConversationMessageForeground(
                  colors,
                  message.role,
                ),
                accent: colors.primary,
                codeBackground: agentConversationToneColor(
                  colors,
                  adapter.codeTone,
                ),
                blockBackground: agentConversationToneColor(
                  colors,
                  adapter.quoteTone,
                ),
                borderColor: colors.line,
                renderStyle: adapter.markdownStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AgentConversationAssistantBubbleBlock extends StatelessWidget {
  const AgentConversationAssistantBubbleBlock({
    super.key,
    required this.message,
    required this.adapter,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.assistantMaxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: AgentConversationMessageContent(
              data: message.text,
              foreground: agentConversationMessageForeground(
                colors,
                message.role,
              ),
              accent: colors.primary,
              codeBackground: agentConversationToneColor(
                colors,
                adapter.codeTone,
              ),
              blockBackground: agentConversationToneColor(
                colors,
                adapter.quoteTone,
              ),
              borderColor: colors.line,
              renderStyle: adapter.markdownStyle,
            ),
          ),
        ),
      ),
    );
  }
}

Color _bubbleColor(LicoThemeColors colors, String tone) {
  return switch (tone) {
    'primary' => colors.primary,
    'subtle' => colors.surfaceLow,
    'raised' => colors.surface,
    _ => colors.surfaceLow,
  };
}
