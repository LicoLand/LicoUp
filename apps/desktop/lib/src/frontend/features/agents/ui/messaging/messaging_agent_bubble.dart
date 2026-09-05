import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Agent-side message bubble: dark readability veil with a thin neutral
/// hairline at rest. On hover the **edge light** fades in, in the speaking
/// agent's brand hue — light lives on the rim, never in the fill. This
/// replaces the former solid `accentSurface` tint, which read as a flat 底色
/// slab on the glass canvas.
class MessagingAgentBubble extends StatelessWidget {
  const MessagingAgentBubble({
    super.key,
    required this.child,
    required this.borderRadius,
    this.padding,
    this.hovered = false,
    this.agentKey = '',
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool hovered;

  /// Agent target key selecting the rim-light palette; empty is the default
  /// white light.
  final String agentKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final isDark = colors.isDark;
    var fill = MessagingDesktopMetrics.agentBubbleVeilFill(isDark: isDark);
    if (hovered) {
      fill = Color.alphaBlend(colors.hoverOverlay, fill);
    }
    final restingBorder = MessagingDesktopMetrics.bubbleRestingBorder(
      colors.line,
      isDark: isDark,
    );
    return MessagingBubbleEdgeGlow(
      borderRadius: borderRadius,
      agentKey: agentKey,
      lit: hovered,
      child: AnimatedContainer(
        duration: context.motion(LicoMotion.micro),
        curve: LicoMotion.standard,
        padding: padding,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: borderRadius,
          border: Border.all(
            color: hovered ? restingBorder.withAlpha(0) : restingBorder,
            width: MessagingDesktopMetrics.hairline,
          ),
        ),
        child: child,
      ),
    );
  }
}
