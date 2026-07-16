import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

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
    final colors = context.licoColors;
    return IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      color: colors.primary,
      disabledColor: colors.textMuted,
      hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.textMuted,
              ),
            )
          : const Icon(Icons.archive_outlined, size: 18),
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
    final colors = context.licoColors;
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      color: colors.primary,
      disabledColor: colors.textMuted,
      hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: const Icon(Icons.add_comment_outlined, size: 18),
    );
  }
}

class MobileComposerSurface extends StatelessWidget {
  const MobileComposerSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: child,
    );
  }
}
