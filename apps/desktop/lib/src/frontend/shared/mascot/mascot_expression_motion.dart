import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_expression_rig.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// How one expression carries itself while it idles on screen.
enum MascotExpressionMotionKind { bounce, sway, breathe }

/// The bundled expressions carry a layered SVG skeleton, so motion binds to
/// parts — head, body, arms, ground shadow and effect marks each move on
/// their own phase, the way a rigged character idles, instead of sliding the
/// whole image around. Bouncy faces hop, pondering faces sway, and the rest
/// breathe gently. The picker grid and transcript share the same behavior so
/// an expression moves the same way wherever it appears.
MascotExpressionMotionKind mascotExpressionMotionKind(String expressionId) {
  return switch (expressionId) {
    'happy' ||
    'laugh' ||
    'hi' ||
    'celebrate' ||
    'starstruck' ||
    'approve' => MascotExpressionMotionKind.bounce,
    'wink' ||
    'surprised' ||
    'thinking' ||
    'confused' ||
    'listening' => MascotExpressionMotionKind.sway,
    _ => MascotExpressionMotionKind.breathe,
  };
}

/// Wraps a mascot expression with the demo's pop-in entrance followed by a
/// rigged idle loop in the expression's own motion kind.
///
/// When the expression's layered SVG is available the rig is painted part by
/// part; otherwise — including while the source still loads — the same
/// per-kind loop is applied to the flattened child image so nothing stands
/// still waiting on the bundle.
///
/// Reduced-motion settings hold the expression completely still: no entrance
/// and no loop, matching the ambient-motion contract in [LicoMotion].
class MascotExpressionMotion extends StatefulWidget {
  const MascotExpressionMotion({
    super.key,
    required this.expressionId,
    required this.child,
  });

  final String expressionId;
  final Widget child;

  @override
  State<MascotExpressionMotion> createState() => _MascotExpressionMotionState();
}

final class _MascotExpressionMotionState extends State<MascotExpressionMotion>
    with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: LicoMotion.medium,
  );

  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    // A tiny phase offset per expression keeps a grid of them from marching
    // in lockstep.
    _idle.value = (widget.expressionId.hashCode % 24) / 24;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    final animate = context.allowsAmbientMotion;
    if (animate) {
      if (!_entrance.isCompleted) _entrance.forward();
      if (!_idle.isAnimating) _idle.repeat();
    } else {
      _entrance
        ..stop()
        ..value = 1;
      _idle
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    _idle.dispose();
    super.dispose();
  }

  /// Part pivots authored in the SVG viewBox space; the character art is
  /// centered on x=100, feet at y≈210.
  static const _headPivot = Offset(100, 150);
  static const _bodyPivot = Offset(100, 205);
  static const _armLeftPivot = Offset(69, 128);
  static const _armRightPivot = Offset(130, 128);
  static const _shadowPivot = Offset(100, 212);

  Matrix4 _partTransform(
    String part,
    MascotExpressionMotionKind kind,
    double phase,
    Rect viewBox,
    double extent,
  ) {
    // Live2D-style follow-through: the head leads, the body lags a beat, and
    // the arms trail further behind. The shadow answers the head's height.
    var tx = 0.0, ty = 0.0, rotation = 0.0, sx = 1.0, sy = 1.0;
    final pivot = switch (part) {
      MascotExpressionRig.partHead => _headPivot,
      MascotExpressionRig.partBody => _bodyPivot,
      MascotExpressionRig.partArmLeft => _armLeftPivot,
      MascotExpressionRig.partArmRight => _armRightPivot,
      _ => _shadowPivot,
    };
    switch (kind) {
      case MascotExpressionMotionKind.bounce:
        final hop = math.sin(phase).clamp(0.0, 1.0);
        switch (part) {
          case MascotExpressionRig.partHead:
            ty = -7 * hop;
            rotation = 0.035 * math.sin(phase + 0.35);
          case MascotExpressionRig.partBody:
            ty = -3 * math.sin(phase - 0.4).clamp(0.0, 1.0);
            final squash = 1 + 0.03 * math.sin(phase - 0.4);
            sy = squash;
          case MascotExpressionRig.partArmLeft:
            ty = -4.5 * math.sin(phase - 0.7).clamp(0.0, 1.0);
            rotation = -0.09 * math.sin(phase - 0.7);
          case MascotExpressionRig.partArmRight:
            ty = -4.5 * math.sin(phase - 0.7).clamp(0.0, 1.0);
            rotation = 0.09 * math.sin(phase - 0.7);
          case MascotExpressionRig.partShadow:
            sx = 1 - 0.10 * hop;
            sy = 1 - 0.10 * hop;
        }
      case MascotExpressionMotionKind.sway:
        switch (part) {
          case MascotExpressionRig.partHead:
            rotation = 0.05 * math.sin(phase);
            tx = 2.2 * math.sin(phase + 0.3);
            ty = -1.4 * math.sin(phase);
          case MascotExpressionRig.partBody:
            rotation = 0.022 * math.sin(phase - 0.5);
          case MascotExpressionRig.partArmLeft:
            rotation = -0.07 * math.sin(phase - 0.85);
          case MascotExpressionRig.partArmRight:
            rotation = 0.07 * math.sin(phase - 0.85);
          case MascotExpressionRig.partShadow:
            tx = 1.2 * math.sin(phase);
        }
      case MascotExpressionMotionKind.breathe:
        switch (part) {
          case MascotExpressionRig.partHead:
            ty = -2.0 * math.sin(phase + 0.3);
            rotation = 0.014 * math.sin(phase + 0.55);
          case MascotExpressionRig.partBody:
            sy = 1 + 0.028 * math.sin(phase);
          case MascotExpressionRig.partArmLeft:
            ty = -1.2 * math.sin(phase - 0.3);
            rotation = -0.03 * math.sin(phase - 0.3);
          case MascotExpressionRig.partArmRight:
            ty = -1.2 * math.sin(phase - 0.3);
            rotation = 0.03 * math.sin(phase - 0.3);
          case MascotExpressionRig.partShadow:
            sx = 1 + 0.03 * math.sin(phase);
        }
    }
    final toWidget = extent / viewBox.width;
    final px = (pivot.dx - viewBox.left) * toWidget;
    final py = (pivot.dy - viewBox.top) * toWidget;
    final transform = Matrix4.identity()
      ..translateByDouble(tx * toWidget, ty * toWidget, 0, 1)
      ..translateByDouble(px, py, 0, 1)
      ..rotateZ(rotation)
      ..scaleByDouble(sx, sy, 1, 1)
      ..translateByDouble(-px, -py, 0, 1);
    return transform;
  }

  @override
  Widget build(BuildContext context) {
    if (!context.allowsAmbientMotion) return widget.child;
    final kind = mascotExpressionMotionKind(widget.expressionId);
    return FutureBuilder<MascotExpressionRig?>(
      future: MascotExpressionRig.load(widget.expressionId),
      builder: (context, snapshot) {
        final rig = snapshot.data;
        return AnimatedBuilder(
          animation: Listenable.merge([_entrance, _idle]),
          child: widget.child,
          builder: (context, child) {
            final entrance = CurvedAnimation(
              parent: _entrance,
              curve: const Cubic(0.34, 1.56, 0.64, 1),
            ).value;
            final phase = _idle.value * 2 * math.pi;
            final entranceScale = 0.55 + 0.45 * entrance;

            if (rig == null) {
              // Flat-image fallback while the rig source loads (or for
              // sources that do not match the layered skeleton): the same
              // per-kind loop applied to the whole figure.
              var transform = Matrix4.identity();
              switch (kind) {
                case MascotExpressionMotionKind.bounce:
                  final hop = -2.4 * math.sin(phase);
                  final squash = 1 + 0.03 * math.sin(phase);
                  transform
                    ..translateByDouble(0, hop, 0, 1)
                    ..scaleByDouble(squash, squash, 1, 1);
                case MascotExpressionMotionKind.sway:
                  transform
                    ..rotateZ(0.05 * math.sin(phase))
                    ..translateByDouble(0, -1.2 * math.sin(phase), 0, 1);
                case MascotExpressionMotionKind.breathe:
                  final breath = 1 + 0.025 * math.sin(phase);
                  transform
                    ..translateByDouble(0, -1.0 * math.sin(phase), 0, 1)
                    ..scaleByDouble(breath, breath, 1, 1);
              }
              return Opacity(
                opacity: entrance.clamp(0.0, 1.0),
                child: Transform(
                  alignment: Alignment.bottomCenter,
                  transform: transform
                    ..scaleByDouble(entranceScale, entranceScale, 1, 1),
                  child: child,
                ),
              );
            }
            final childImage = child;
            final childExtent = childImage is MascotImage
                ? childImage.size
                : 120.0;
            return Opacity(
              opacity: entrance.clamp(0.0, 1.0),
              child: Transform(
                alignment: Alignment.bottomCenter,
                transform: Matrix4.identity()
                  ..scaleByDouble(entranceScale, entranceScale, 1, 1),
                child: SizedBox(
                  width: childExtent,
                  height: childExtent,
                  child: Stack(
                    children: [
                      for (final layer in rig.layers)
                        Positioned.fill(
                          child: Opacity(
                            opacity: _partOpacity(layer.id, kind, phase),
                            child: Transform(
                              transform: _partTransform(
                                layer.id,
                                kind,
                                phase,
                                rig.viewBox,
                                childExtent,
                              ),
                              child: SvgPicture.string(
                                layer.svg,
                                fit: BoxFit.fill,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  double _partOpacity(
    String part,
    MascotExpressionMotionKind kind,
    double phase,
  ) {
    return switch (part) {
      MascotExpressionRig.partEffects => switch (kind) {
        MascotExpressionMotionKind.bounce => 0.72 + 0.28 * math.sin(phase * 2),
        MascotExpressionMotionKind.sway =>
          0.72 + 0.28 * math.sin(phase * 2 + 1.2),
        MascotExpressionMotionKind.breathe => 0.7 + 0.3 * math.sin(phase * 2),
      },
      _ => 1.0,
    };
  }
}
