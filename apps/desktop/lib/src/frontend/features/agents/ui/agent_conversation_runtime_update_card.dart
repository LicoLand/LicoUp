import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter/material.dart';

/// One in-place card describing an agent runtime auto-update (cursor-agent)
/// blocking the turn. While active it shows an indeterminate progress bar —
/// no vendor signal exposes a real percentage, so a determinate value would
/// be fabricated — plus phase/version text from the projected message.
class AgentRuntimeUpdateCard extends StatelessWidget {
  const AgentRuntimeUpdateCard({
    super.key,
    required this.message,
    required this.adapter,
    this.active = false,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final terminal = message.text == 'completed' || message.text == 'interrupted';
    final IconData leadingIcon;
    final Color leadingColor;
    if (message.text == 'completed') {
      leadingIcon = Icons.check_circle_rounded;
      leadingColor = colors.success;
    } else if (message.text == 'interrupted') {
      leadingIcon = Icons.error_rounded;
      leadingColor = colors.error;
    } else {
      leadingIcon = Icons.system_update_alt_rounded;
      leadingColor = colors.textMuted;
    }
    final title = message.text == 'completed'
        ? strings.runtimeUpdateCompleted
        : message.text == 'interrupted'
            ? strings.runtimeUpdateInterrupted
            : strings.runtimeUpdateTitle;
    final subtitle = message.cardSubtitle;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.assistantMaxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(colors.isDark ? 14 : 18),
            borderRadius: BorderRadius.circular(AppleControlMetrics.menuCornerRadius),
            border: Border.all(
              color: Colors.white.withAlpha(colors.isDark ? 42 : 64),
              width: AppleControlMetrics.hairline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (terminal)
                      Icon(leadingIcon, size: 15, color: leadingColor)
                    else
                      LicoSpinningRefreshIcon(size: 15, color: leadingColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LicoShimmerText(
                        text: title,
                        enabled: active && !terminal,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.08,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                Padding(
                  padding: const EdgeInsets.only(left: 23),
                  child: LicoShimmerText(
                    text: subtitle,
                    enabled: active && !terminal,
                    maxLines: 2,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      letterSpacing: -0.04,
                    ),
                  ),
                ),
                if (active && !terminal) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 23),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        key: const ValueKey('runtime-update-progress'),
                        minHeight: 2,
                        backgroundColor: colors.text.withAlpha(26),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          colors.accent,
                        ),
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
