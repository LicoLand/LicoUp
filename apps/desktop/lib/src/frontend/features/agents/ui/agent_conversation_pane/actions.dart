import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_controls.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class AgentConversationEmptySelection extends StatelessWidget {
  const AgentConversationEmptySelection({
    super.key,
    required this.allowManualTargetActions,
    required this.onAddTarget,
  });

  final bool allowManualTargetActions;
  final VoidCallback onAddTarget;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, color: colors.textMuted, size: 28),
            const SizedBox(height: 10),
            Text(
              strings.selectAgentToView,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textMuted),
            ),
            if (allowManualTargetActions) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onAddTarget,
                icon: const Icon(Icons.add, size: 18),
                label: Text(strings.addTarget),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ArchiveAgentConversationsButton extends StatelessWidget {
  const ArchiveAgentConversationsButton({
    super.key,
    required this.busy,
    required this.tooltip,
    required this.onPressed,
  });

  final bool busy;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ConversationIconButton(
      key: key,
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      busy: busy,
      icon: Icons.archive_outlined,
      color: context.licoColors.textMuted,
    );
  }
}

class NewAgentConversationButton extends StatelessWidget {
  const NewAgentConversationButton({
    super.key,
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final bool enabled;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ConversationIconButton(
      key: key,
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      icon: Icons.add_comment_outlined,
      color: context.licoColors.primary,
    );
  }
}
