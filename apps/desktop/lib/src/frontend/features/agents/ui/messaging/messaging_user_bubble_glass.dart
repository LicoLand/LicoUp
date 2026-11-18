import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// User message surface: the demo's own-speaker bubble — a solid violet
/// body bordered by a hairline rim. Dark presets paint a deep violet
/// diagonal lifted toward the top edge by the accent lamp, with a soft
/// violet glow underneath; light presets keep the taro brand gradient.
/// On hover the **edge light** fades in — a thin bright rim in the
/// shared white light, nothing more.
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

  /// The dark bubble body — the shared [licoDeepViolet] recipe: a deep
  /// violet re-saturated from the preset's pale accent hue so the "深紫色"
  /// body stays vivid on glass, brighter toward the top where the lamp
  /// light lands.
  @visibleForTesting
  static List<Color> deepVioletBody(Color accent) => [
    licoDeepViolet(accent, lightness: 0.38),
    licoDeepViolet(accent, lightness: 0.24),
  ];

  /// The matching rim and under-glow — same saturated hue, lighter, so the
  /// edge reads as violet light rather than a neutral hairline.
  static Color _violetRim(Color accent) =>
      licoDeepViolet(accent, lightness: 0.58);

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final isDark = colors.isDark;
    // The dark bubble is a solid deep violet, brighter toward the top
    // where the lamp light lands, with a faint violet glow beneath it;
    // light presets keep the taro brand gradient.
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? deepVioletBody(colors.accent)
          : [colors.primaryStrong, colors.primary],
    );
    final restingBorder = isDark
        ? _violetRim(colors.accent).withAlpha(140)
        : colors.brandBorder.withAlpha(110);
    final content = AnimatedContainer(
      duration: context.motion(LicoMotion.micro),
      curve: LicoMotion.standard,
      padding: padding,
      decoration: continuousHairlineDecoration(
        gradient: gradient,
        borderRadius: borderRadius,
        stroke: hovered ? restingBorder.withAlpha(0) : restingBorder,
        shadows: isDark
            ? [
                BoxShadow(
                  color: _violetRim(colors.accent).withValues(alpha: 0.30),
                  blurRadius: 16,
                  offset: const Offset(0, 3),
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: child,
    );
    return MessagingBubbleEdgeGlow(
      borderRadius: borderRadius,
      lit: hovered,
      child: ClipRRect(borderRadius: borderRadius, child: content),
    );
  }
}
