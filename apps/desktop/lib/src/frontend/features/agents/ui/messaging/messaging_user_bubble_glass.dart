import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Frosted user message bubble: transparent fill, shared blur, **neutral**
/// hairline on [colors.line]. No brand/primary rim or lemon glow — those
/// read as olive 泛黄 on the dark chat canvas.
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
    return ClipRRect(
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
              color: MessagingDesktopMetrics.userBubbleGlassBorder(
                colors.line,
                isDark: isDark,
              ),
              width: MessagingDesktopMetrics.hairline,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
