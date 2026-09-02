import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Frosted user message bubble: transparent fill, shared blur, and a thin
/// neutral hairline at rest. On hover the **edge light** fades in — a thin
/// bright rim plus a lamp-like field in the shared white light (Kiro-style).
/// Never brand/primary: lemon rims read as olive 泛黄 on the dark chat canvas.
class MessagingUserBubbleGlass extends StatelessWidget {
  const MessagingUserBubbleGlass({
    super.key,
    required this.child,
    required this.borderRadius,
    this.padding,
    this.hovered = false,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final isDark = colors.isDark;
    final sigma = MessagingDesktopMetrics.userBubbleGlassBlurSigma;
    var fill = MessagingDesktopMetrics.userBubbleGlassFill(isDark: isDark);
    if (hovered) {
      fill = Color.alphaBlend(colors.hoverOverlay, fill);
    }
    final restingBorder = MessagingDesktopMetrics.bubbleRestingBorder(
      colors.line,
      isDark: isDark,
    );
    return MessagingBubbleEdgeGlow(
      borderRadius: borderRadius,
      lit: hovered,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
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
        ),
      ),
    );
  }
}
