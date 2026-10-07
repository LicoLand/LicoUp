import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_material_scope.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// User message surface: profile-owned material when requested, or frosted
/// transparent glass with a thin neutral hairline at rest.
///
/// Plain profile (opaque): the user's own bubble carries the brand as a
/// diagonal fill — violet in light presets, gold in dark presets — bordered
/// by the mandatory brand hairline. Card profile (glass): the interior stays
/// clear glass and never takes a brand tint, which would frost yellow into
/// the pill. On hover the **edge light** fades in — a thin bright rim in the
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

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final isDark = colors.isDark;
    final sigma = MessagingDesktopMetrics.userBubbleGlassBlurSigma;
    final opaque = ConversationMaterialScope.opaqueBubblesOf(context);
    final gradient = opaque
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colors.primary, colors.primaryStrong],
          )
        : null;
    final fill = opaque
        ? null
        : MessagingDesktopMetrics.userBubbleGlassFill(isDark: isDark);
    final restingBorder = opaque
        ? colors.brandBorder.withAlpha(isDark ? 150 : 110)
        : MessagingDesktopMetrics.bubbleRestingBorder(
            colors.line,
            isDark: isDark,
          );
    final content = AnimatedContainer(
      duration: context.motion(LicoMotion.micro),
      curve: LicoMotion.standard,
      padding: padding,
      decoration: continuousHairlineDecoration(
        color: fill,
        gradient: gradient,
        borderRadius: borderRadius,
        stroke: hovered ? restingBorder.withAlpha(0) : restingBorder,
      ),
      child: child,
    );
    return MessagingBubbleEdgeGlow(
      borderRadius: borderRadius,
      lit: hovered,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: opaque
            ? content
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: content,
              ),
      ),
    );
  }
}
