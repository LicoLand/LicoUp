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
/// Plain profile (opaque): a quiet brand-family tint — the pale violet brand
/// surface in light presets, the violet accent surface in dark presets — so
/// the other speaker's words sit on the scheme's own wash. Card profile
/// (glass): the interior stays a neutral veil; on hover the **edge light**
/// fades in, in the speaking agent's brand hue — light lives on the rim,
/// never in the fill.
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
    final fill = opaque
        ? (isDark ? colors.accentSurface : colors.brandSurface)
        : MessagingDesktopMetrics.agentBubbleVeilFill(isDark: isDark);
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
