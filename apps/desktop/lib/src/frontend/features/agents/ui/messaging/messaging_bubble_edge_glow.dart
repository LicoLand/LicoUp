import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Rim-light palette for one bubble: a single crisp rim stroke — no fog.
class MessagingBubbleGlow {
  const MessagingBubbleGlow({required this.rimGradient});

  final Gradient rimGradient;
}

/// Brand hue for one agent target. Unlisted targets share the default white
/// light — OpenCode, Codex, Cursor, Kimi, and Pi are white by contract.
const Map<String, Color> _agentBubbleGlowColors = {
  // Claude terracotta orange.
  'claude-code': Color(0xFFD97757),
  // Kilo yellow.
  'kilo-code': Color(0xFFFACC15),
  // DeepSeek Harness blue.
  'deepseek-harness': Color(0xFF4D6BFE),
};

/// Multicolor brands light the rim with a rainbow sweep instead of one hue.
const Set<String> _agentBubbleGlowRainbowKeys = {'copilot', 'antigravity'};

/// Resolve the rim-light palette for one bubble: the agent's brand hue, a
/// rainbow sweep for multicolor brands, or the default white light.
MessagingBubbleGlow messagingBubbleGlow({
  required bool isDark,
  String agentKey = '',
}) {
  final key = agentKey.trim().toLowerCase();
  final rainbow = _agentBubbleGlowRainbowKeys.contains(key);
  final glow = _agentBubbleGlowColors[key] ?? Colors.white;

  return MessagingBubbleGlow(
    rimGradient: rainbow
        ? SweepGradient(
            colors: _rainbowColors(
              isDark
                  ? MessagingDesktopMetrics.bubbleEdgeGlowAlphaDark
                  : MessagingDesktopMetrics.bubbleEdgeGlowAlphaLight,
            ),
          )
        : MessagingDesktopMetrics.bubbleEdgeGlowBand(glow, isDark: isDark),
  );
}

/// Glow key for one conversation target, resolved in the same order as the
/// brand-icon assets (target first, then id). Unlisted targets return the
/// empty key — the shared white light.
String messagingAgentBubbleGlowKey(TargetCandidate? candidate) {
  if (candidate == null) {
    return '';
  }
  final target = candidate.target.trim().toLowerCase();
  if (_agentBubbleGlowColors.containsKey(target) ||
      _agentBubbleGlowRainbowKeys.contains(target)) {
    return target;
  }
  final id = candidate.id.trim().toLowerCase();
  if (_agentBubbleGlowColors.containsKey(id) ||
      _agentBubbleGlowRainbowKeys.contains(id)) {
    return id;
  }
  return '';
}

List<Color> _rainbowColors(int alpha) => const [
  Color(0xFFFF6B6B),
  Color(0xFFFFB86B),
  Color(0xFFF9F871),
  Color(0xFF7BD88F),
  Color(0xFF5BC0EB),
  Color(0xFFB28DFF),
  Color(0xFFFF6B6B),
].map((color) => color.withAlpha(alpha)).toList(growable: false);

/// Rim-light for conversation bubbles: a thin, bright rim line and nothing
/// else — no lamp field, no fog. The bubble interior stays unchanged.
///
/// The light is **hover-lit**: it fades in while [lit] is true and fades back
/// out to the plain resting bubble when false. A fully unlit painter paints
/// nothing, so a resting transcript carries zero glow cost.
class MessagingBubbleEdgeGlow extends StatelessWidget {
  const MessagingBubbleEdgeGlow({
    super.key,
    required this.child,
    required this.borderRadius,
    this.agentKey = '',
    this.lit = true,
  });

  final Widget child;
  final BorderRadius borderRadius;

  /// Agent target key selecting the glow palette; empty is the default
  /// white light (own messages, unlisted agents).
  final String agentKey;

  /// Whether the edge light is on (row hover).
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final glow = messagingBubbleGlow(isDark: colors.isDark, agentKey: agentKey);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: lit ? 1 : 0, end: lit ? 1 : 0),
      duration: context.motion(LicoMotion.micro),
      curve: LicoMotion.standard,
      child: child,
      builder: (context, opacity, child) => CustomPaint(
        painter: MessagingBubbleEdgeGlowPainter(
          borderRadius: borderRadius,
          rimGradient: glow.rimGradient,
          strokeWidth: MessagingDesktopMetrics.bubbleEdgeRimWidth,
          opacity: opacity,
        ),
        child: child,
      ),
    );
  }
}

/// Paints the hover rim light: one thin, bright, crisp line on the bubble's
/// silhouette. Nothing blurs outward — the light is the border itself.
class MessagingBubbleEdgeGlowPainter extends CustomPainter {
  const MessagingBubbleEdgeGlowPainter({
    required this.borderRadius,
    required this.rimGradient,
    required this.strokeWidth,
    this.opacity = 1,
  });

  final BorderRadius borderRadius;
  final Gradient rimGradient;
  final double strokeWidth;

  /// Hover fade, 0–1. At 0 the painter is a no-op — resting bubbles carry
  /// zero glow cost.
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.001) {
      return;
    }
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect).deflate(strokeWidth / 2);

    // A saveLayer only while fading; steady state (fully lit) draws directly.
    final fading = opacity < 0.999;
    if (fading) {
      canvas.saveLayer(
        rect.inflate(8),
        Paint()..color = Colors.white.withValues(alpha: opacity),
      );
    }
    final rim = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = rimGradient.createShader(rect);
    canvas.drawRRect(rrect, rim);
    if (fading) {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(MessagingBubbleEdgeGlowPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.rimGradient != rimGradient ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.opacity != opacity;
}
