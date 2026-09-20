import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// A small living energy orb for the assistant's thinking state, in the
/// tradition of the Siri / Apple Intelligence sphere: three luminous color
/// currents orbit inside a soft sphere at different integral speeds, so the
/// loop is mathematically seamless and never repeats a visible pattern within
/// one cycle.
///
/// Blob angles advance by whole revolutions per loop (1, −2 and 3), which
/// keeps the seam identical at phase 0 and 1 while the interference of the
/// three rates reads as continuous fluid motion. The core breathes twice per
/// loop and the outer halo follows it. Everything is constant-time sampling of
/// the loop phase — no integration, no accumulated state.
class OrbSystem {
  const OrbSystem();

  /// Blob orbit rates in whole revolutions per loop; the sign reverses
  /// direction. Integral rates are what make the loop seamless.
  static const List<double> _rates = [1, -2, 3];

  /// Per-blob phase offsets so the currents never stack.
  static const List<double> _phases = [0.0, 0.33, 0.66];

  /// Orbit radii as a fraction of the orb radius.
  static const List<double> _orbits = [0.34, 0.42, 0.27];

  /// Blob radii as a fraction of the orb radius (base, amplitude).
  static const List<(double, double)> _radii = [
    (0.56, 0.10),
    (0.48, 0.12),
    (0.52, 0.08),
  ];

  /// Sample the three blob centers and radii for [phase] ∈ [0, 1).
  List<(Offset, double)> blobs(double phase, Offset center, double radius) {
    return [
      for (var i = 0; i < 3; i++)
        (
          center +
              Offset(
                    math.cos(2 * math.pi * (_rates[i] * phase + _phases[i])),
                    math.sin(2 * math.pi * (_rates[i] * phase + _phases[i])),
                  ) *
                  (radius * _orbits[i]),
          radius *
              (_radii[i].$1 +
                  _radii[i].$2 *
                      math.sin(
                        2 * math.pi * (_rates[i].abs() * phase + _phases[i]),
                      )),
        ),
    ];
  }

  /// Core breath 0..1, twice per loop, seamless.
  double breath(double phase) => 0.5 + 0.5 * math.sin(4 * math.pi * phase);
}

/// Activity is owned by the caller; the indicator has no message or run state.
class OrbWaitingIndicator extends StatefulWidget {
  const OrbWaitingIndicator({super.key, required this.active, this.size = 28})
    : assert(size > 0);

  final bool active;
  final double size;

  @override
  State<OrbWaitingIndicator> createState() => _OrbWaitingIndicatorState();
}

class _OrbWaitingIndicatorState extends State<OrbWaitingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(OrbWaitingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final duration = context.motion(LicoMotion.loopLong);
    if (!widget.active ||
        duration == Duration.zero ||
        !context.allowsAmbientMotion) {
      _controller.stop();
      return;
    }
    if (!_controller.isAnimating || _controller.duration != duration) {
      _controller.duration = duration;
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final colors = context.licoColors;
    final secondary = HSLColor.fromColor(
      colors.accent,
    ).withHue((HSLColor.fromColor(colors.accent).hue + 48) % 360).toColor();
    final tertiary = HSLColor.fromColor(colors.accentStrong)
        .withHue((HSLColor.fromColor(colors.accentStrong).hue + 320) % 360)
        .toColor();
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: OrbWaitingPainter(
            phase: _controller,
            palette: [colors.accent, secondary, tertiary],
            halo: colors.accent,
            reducedMotion: context.motion(LicoMotion.loopLong) == Duration.zero,
          ),
          size: Size(widget.size * 1.6, widget.size),
        ),
      ),
    );
  }
}

class OrbWaitingPainter extends CustomPainter {
  OrbWaitingPainter({
    required this.phase,
    required this.palette,
    required this.halo,
    this.reducedMotion = false,
  }) : assert(palette.length == 3),
       super(repaint: phase);

  final Animation<double> phase;

  /// The three current hues: base accent, its two hue-shifted companions.
  final List<Color> palette;

  /// Halo and rim tint.
  final Color halo;
  final bool reducedMotion;

  static const _system = OrbSystem();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 * 0.88;
    final p = reducedMotion ? 0.0 : phase.value;
    final breath = reducedMotion ? 0.5 : _system.breath(p);

    // Halo: the sphere's light spilling onto the bubble, breathing with the
    // core.
    canvas.drawCircle(
      center,
      radius * (1.42 + 0.05 * breath),
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          radius * 1.5,
          [
            halo.withValues(alpha: 0.16 + 0.08 * breath),
            halo.withValues(alpha: 0.05),
            halo.withValues(alpha: 0),
          ],
          [0, 0.55, 1],
        ),
    );

    canvas.save();
    canvas.clipRect(Rect.fromCircle(center: center, radius: radius));
    // Deep base wash so the currents have something to glow against.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(center, radius, [
          palette[0].withValues(alpha: 0.34),
          palette[2].withValues(alpha: 0.16),
        ]),
    );
    // The three currents, added onto each other so overlaps ignite.
    final blobs = _system.blobs(p, center, radius);
    for (var i = 0; i < blobs.length; i++) {
      final (blobCenter, blobRadius) = blobs[i];
      canvas.drawCircle(
        blobCenter,
        blobRadius,
        Paint()
          ..blendMode = BlendMode.plus
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blobRadius * 0.28)
          ..shader = ui.Gradient.radial(blobCenter, blobRadius, [
            palette[i].withValues(alpha: 0.7),
            palette[i].withValues(alpha: 0),
          ]),
      );
    }
    // Bright core, breathing.
    final coreCenter = center + Offset(-radius * 0.16, -radius * 0.2);
    final coreRadius = radius * (0.30 + 0.05 * breath);
    canvas.drawCircle(
      coreCenter,
      coreRadius,
      Paint()
        ..blendMode = BlendMode.plus
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, coreRadius * 0.35)
        ..shader = ui.Gradient.radial(coreCenter, coreRadius, [
          Colors.white.withValues(alpha: 0.55 + 0.2 * breath),
          Colors.white.withValues(alpha: 0),
        ]),
    );
    canvas.restore();

    // Rim: the sphere's edge keeps the glow contained.
    canvas.drawCircle(
      center,
      radius - 0.4,
      Paint()
        ..color = halo.withValues(alpha: 0.2 + 0.08 * breath)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(OrbWaitingPainter oldDelegate) =>
      phase != oldDelegate.phase ||
      halo != oldDelegate.halo ||
      reducedMotion != oldDelegate.reducedMotion ||
      !listEquals(palette, oldDelegate.palette);
}
