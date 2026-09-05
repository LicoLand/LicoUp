import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Rim-light palette for one bubble: the crisp rim stroke plus three
/// distance-decay field passes (near → mid → far).
class MessagingBubbleGlow {
  const MessagingBubbleGlow({
    required this.rimGradient,
    required this.nearGradient,
    required this.midGradient,
    required this.farGradient,
  });

  final Gradient rimGradient;
  final Gradient nearGradient;
  final Gradient midGradient;
  final Gradient farGradient;
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

  Gradient field(int alpha) => rainbow
      ? SweepGradient(colors: _rainbowColors(alpha))
      : MessagingDesktopMetrics.bubbleEdgeGlowAura(glow, alpha: alpha);

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
    nearGradient: field(
      isDark
          ? MessagingDesktopMetrics.bubbleEdgeGlowNearAlphaDark
          : MessagingDesktopMetrics.bubbleEdgeGlowNearAlphaLight,
    ),
    midGradient: field(
      isDark
          ? MessagingDesktopMetrics.bubbleEdgeGlowMidAlphaDark
          : MessagingDesktopMetrics.bubbleEdgeGlowMidAlphaLight,
    ),
    farGradient: field(
      isDark
          ? MessagingDesktopMetrics.bubbleEdgeGlowFarAlphaDark
          : MessagingDesktopMetrics.bubbleEdgeGlowFarAlphaLight,
    ),
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

/// Rim-light for conversation bubbles (Kiro-style): a thin, bright rim line
/// plus a lamp-like light field that decays outward from the rim. The bubble
/// interior stays dark glass — the light lives on and around the edge.
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
          nearGradient: glow.nearGradient,
          midGradient: glow.midGradient,
          farGradient: glow.farGradient,
          strokeWidth: MessagingDesktopMetrics.bubbleEdgeRimWidth,
          opacity: opacity,
        ),
        child: child,
      ),
    );
  }
}

/// Paints the rim light around a bubble as bloom: one thin bright rim line
/// and three gaussian passes whose blur radius grows while their alpha falls,
/// so the field is brightest right at the line and fades with distance —
/// light cast outward like a lamp, not a painted outline.
///
/// The mid/far passes are clipped to the **outside** of the rim (a blurred
/// silhouette under the translucent fill would wash the interior, the
/// `boxShadow` mistake); the tight near pass straddles the rim deliberately,
/// leaving the few-pixel inner edge tint seen in the reference.
class MessagingBubbleEdgeGlowPainter extends CustomPainter {
  const MessagingBubbleEdgeGlowPainter({
    required this.borderRadius,
    required this.rimGradient,
    required this.nearGradient,
    required this.midGradient,
    required this.farGradient,
    required this.strokeWidth,
    this.opacity = 1,
  });

  final BorderRadius borderRadius;
  final Gradient rimGradient;
  final Gradient nearGradient;
  final Gradient midGradient;
  final Gradient farGradient;
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

    Paint pass(Gradient gradient, double width, double sigma) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma)
      ..shader = gradient.createShader(rect);

    // A saveLayer only while fading; steady state (fully lit) draws directly.
    final fading = opacity < 0.999;
    if (fading) {
      canvas.saveLayer(
        rect.inflate(96),
        Paint()..color = Colors.white.withValues(alpha: opacity),
      );
    }
    // Mid and far field: outward only (even-odd: inflated outer rect minus
    // the interior rrect).
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(96))
        ..addRRect(borderRadius.toRRect(rect).deflate(strokeWidth)),
    );
    canvas.drawRRect(rrect, pass(farGradient, strokeWidth * 8, 24));
    canvas.drawRRect(rrect, pass(midGradient, strokeWidth * 3, 10));
    canvas.restore();
    // Near field straddles the rim: brightest at the line, a few pixels of
    // inner edge tint, and the first step of the outward falloff.
    canvas.drawRRect(rrect, pass(nearGradient, strokeWidth, 3.5));
    // Thin, bright, crisp rim line.
    final rim = Paint()
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
      oldDelegate.nearGradient != nearGradient ||
      oldDelegate.midGradient != midGradient ||
      oldDelegate.farGradient != farGradient ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.opacity != opacity;
}
