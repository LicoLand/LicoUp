import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_material_scope.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Agent-side message bubble: profile-owned material when requested, or a
/// readability veil with a thin neutral hairline at rest.
///
/// Plain profile: the demo's neutral `bg-subtle`/`bg-surface` fill — dark
/// carries a faint violet hairline (`rgba(169,140,246,.18)`), light the
/// neutral border. On hover the **edge light** fades in, in the speaking
/// agent's brand hue — light lives on the rim, never in the fill.
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
    final opaque = ConversationMaterialScope.opaqueBubblesOf(context);
    // Demo [data-theme="dark"] --bubble-other-bg is `bg-subtle` with a faint
    // violet-tinted border rgba(169,140,246,.18); light is `bg-surface` with
    // the plain neutral border-subtle.
    // Dark on glass: a white 5.5% veil so the ambient reads through; opaque
    // material profiles (Dashboard) keep the solid surface fill.
    // Black mask over the ambient — slightly translucent, never a
    // white/gray wash, matching the floating-card recipe.
    final fill = isDark ? const Color(0xB807070A) : colors.surface;
    final restingBorder = opaque && isDark
        ? colors.accent.withAlpha(46)
        : (isDark
              ? const Color(0x12FFFFFF)
              : MessagingDesktopMetrics.bubbleRestingBorder(
                  colors.line,
                  isDark: isDark,
                ));
    return MessagingBubbleEdgeGlow(
      borderRadius: borderRadius,
      agentKey: agentKey,
      lit: hovered,
      child: AnimatedContainer(
        duration: context.motion(LicoMotion.micro),
        curve: LicoMotion.standard,
        padding: padding,
        decoration: continuousHairlineDecoration(
          color: fill,
          borderRadius: borderRadius,
          stroke: hovered ? restingBorder.withAlpha(0) : restingBorder,
        ),
        child: child,
      ),
    );
  }
}
