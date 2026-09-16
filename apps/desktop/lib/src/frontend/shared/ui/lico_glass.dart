import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/glass_lens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Size of a glass slab. Large surfaces are thicker (more blur, more fill).
enum LicoGlassSize { small, large }

/// Saturate + contrast with brightness held at 1. Applied after blur so the
/// backdrop reads as luminous glass rather than a grey veil.
const ColorFilter _glassLuminosity = ColorFilter.matrix(<double>[
  1.247,
  -0.260,
  -0.026,
  0,
  -5.1,
  -0.077,
  1.075,
  -0.026,
  0,
  -5.1,
  -0.077,
  -0.260,
  1.308,
  0,
  -5.1,
  0,
  0,
  0,
  1,
  0,
]);

/// Control-layer Liquid Glass: shadows, optional lensed blur, luminosity
/// fill, then a thin, softly lit rim in the foreground. Content-layer
/// cards must not use this widget.
class LicoGlass extends StatefulWidget {
  const LicoGlass({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.fill,
    this.shadows,
    this.size = LicoGlassSize.small,
    this.readBackdrop = false,
    this.blurSigma,
    this.drawRim = true,
    this.trackLight = false,
    this.gelPress = false,
    this.pressed = false,
    this.chroma = false,
    this.focused = false,
    this.focusColor,
    this.focusWidth = 2,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color fill;
  final List<BoxShadow>? shadows;
  final LicoGlassSize size;
  final bool readBackdrop;
  final double? blurSigma;
  final bool drawRim;
  final bool trackLight;
  final bool gelPress;
  final bool pressed;
  final bool chroma;
  final bool focused;
  final Color? focusColor;
  final double focusWidth;

  /// Resting light comes from above-left (east is zero, clockwise is positive).
  static const restLightAngle = -135 * math.pi / 180;

  @override
  State<LicoGlass> createState() => _LicoGlassState();
}

class _LicoGlassState extends State<LicoGlass> with TickerProviderStateMixin {
  static const _flexX = 1.06;
  static const _flexY = 1.03;

  late final AnimationController _light;
  late final AnimationController _press;
  final GlobalKey _hoverKey = GlobalKey();
  Size? _slabSize;
  GlassLensFilter? _lens;
  ({double radius, double displace, double chroma})? _lensParameters;
  double _fromAngle = LicoGlass.restLightAngle;
  double _toAngle = LicoGlass.restLightAngle;

  @override
  void initState() {
    super.initState();
    _light = AnimationController(vsync: this, duration: LicoMotion.short)
      ..value = 1;
    _press = AnimationController(
      vsync: this,
      duration: LicoMotion.micro,
      value: widget.pressed ? 1 : 0,
    );
    unawaited(
      GlassLens.ensureLoaded().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _press.duration = context.motion(LicoMotion.micro);
    _light.duration = context.motion(LicoMotion.short);
  }

  @override
  void didUpdateWidget(LicoGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pressed != oldWidget.pressed) {
      if (widget.pressed) {
        _press.forward();
      } else {
        _press.reverse();
      }
    }
  }

  @override
  void dispose() {
    _lens?.dispose();
    _light.dispose();
    _press.dispose();
    super.dispose();
  }

  double get _angle {
    final t = Curves.easeOutCubic.transform(_light.value);
    return _fromAngle + (_toAngle - _fromAngle) * t;
  }

  void _aim(double next, {required bool animate}) {
    var target = next;
    var delta = target - _angle;
    while (delta > math.pi) {
      target -= 2 * math.pi;
      delta = target - _angle;
    }
    while (delta < -math.pi) {
      target += 2 * math.pi;
      delta = target - _angle;
    }
    if (!animate) {
      _fromAngle = target;
      _toAngle = target;
      _light.value = 1;
      setState(() {});
      return;
    }
    _fromAngle = _angle;
    _toAngle = target;
    _light
      ..duration = context.motion(LicoMotion.short)
      ..forward(from: 0);
  }

  Color _resolvedFill({required bool liftOpacity}) {
    if (!liftOpacity || widget.fill.a >= 0.92) return widget.fill;
    return widget.fill.withValues(
      alpha: (widget.fill.a + (0.92 - widget.fill.a) * 0.65).clamp(0.0, 0.92),
    );
  }

  void _captureSlabSize(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      if (_slabSize == box.size) return;
      setState(() => _slabSize = box.size);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final highContrast = MediaQuery.highContrastOf(context);
    // Flutter 3.44 does not expose Reduce Transparency. Increased Contrast
    // is the accessible-material switch we can honor: skip lensing, lift fill.
    final reduceTransparency = highContrast;
    final isDark = context.licoColors.isDark;
    final fill = _resolvedFill(liftOpacity: reduceTransparency);
    final blur =
        widget.blurSigma ??
        (widget.size == LicoGlassSize.large
            ? MessagingDesktopMetrics.conversationOverlayGlassBlurSigma
            : 8.0);

    final useBackdrop =
        widget.readBackdrop && blur > 0 && fill.a < 0.98 && !reduceTransparency;
    ImageFilter filter = ImageFilter.blur(sigmaX: 0, sigmaY: 0);
    if (useBackdrop) {
      filter = ImageFilter.blur(
        sigmaX: blur,
        sigmaY: blur,
        tileMode: TileMode.clamp,
      );
      final size = _slabSize;
      if (size != null &&
          size.width > 0 &&
          size.height > 0 &&
          GlassLens.isSupported) {
        final parameters = (
          radius: _uniformRadius(widget.borderRadius, size),
          displace: widget.size == LicoGlassSize.large ? 6.0 : 4.0,
          chroma: widget.chroma ? 0.04 : 0.0,
        );
        if (_lens == null || _lensParameters != parameters) {
          _lens?.dispose();
          _lens = GlassLens.createFilter(
            size: size,
            radius: parameters.radius,
            displace: parameters.displace,
            chroma: parameters.chroma,
          );
          _lensParameters = parameters;
        }
        final lens = _lens;
        if (lens != null) {
          filter = ImageFilter.compose(inner: lens.filter, outer: filter);
        }
      }
      filter = ImageFilter.compose(inner: filter, outer: _glassLuminosity);
    }
    final inner = BackdropFilter(
      enabled: useBackdrop,
      filter: filter,
      child: ColoredBox(color: fill, child: widget.child),
    );

    Widget slab = ClipRRect(
      borderRadius: widget.borderRadius,
      clipBehavior: Clip.antiAlias,
      child: Builder(
        builder: (context) {
          _captureSlabSize(context);
          return inner;
        },
      ),
    );

    // Keep the child at the same element position as interaction and
    // accessibility settings change. Replacing wrappers would close an
    // EditableText connection and discard descendant state on focus.
    slab = AnimatedBuilder(
      animation: _light,
      builder: (context, child) => CustomPaint(
        foregroundPainter: widget.drawRim && !widget.focused && !highContrast
            ? GlassSpecularRimPainter(
                borderRadius: widget.borderRadius,
                rimWidth: MessagingDesktopMetrics.glassEdgeRimWidth,
                lightAngle: widget.trackLight && !reduceMotion
                    ? _angle
                    : LicoGlass.restLightAngle,
                rimHi: MessagingDesktopMetrics.glassEdgeRimHi(isDark: isDark),
                rimLo: MessagingDesktopMetrics.glassEdgeRimLo(isDark: isDark),
              )
            : null,
        child: child,
      ),
      child: slab,
    );

    final trackLight = widget.trackLight && !reduceMotion;
    slab = MouseRegion(
      key: _hoverKey,
      opaque: trackLight,
      onHover: trackLight
          ? (event) {
              final box = _hoverKey.currentContext?.findRenderObject();
              if (box is! RenderBox || !box.hasSize) return;
              final center = box.size.center(Offset.zero);
              final local = event.localPosition;
              _aim(
                math.atan2(local.dy - center.dy, local.dx - center.dx),
                animate: false,
              );
            }
          : null,
      onExit: trackLight
          ? (_) => _aim(LicoGlass.restLightAngle, animate: true)
          : null,
      child: slab,
    );

    final BorderSide interactionSide;
    if (widget.focused && widget.focusColor != null && widget.focusWidth > 0) {
      interactionSide = BorderSide(
        color: widget.focusColor!,
        width: widget.focusWidth,
      );
    } else if (highContrast && widget.drawRim) {
      interactionSide = BorderSide(color: isDark ? Colors.white : Colors.black);
    } else {
      interactionSide = BorderSide.none;
    }
    slab = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: ContinuousRoundedBorder(
          borderRadius: widget.borderRadius,
          side: interactionSide,
        ),
      ),
      child: slab,
    );
    slab = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        boxShadow: widget.shadows,
      ),
      child: slab,
    );
    slab = AnimatedBuilder(
      animation: _press,
      builder: (context, child) {
        final value = widget.gelPress && !reduceMotion
            ? LicoMotion.emphasized.transform(_press.value)
            : 0.0;
        return Transform.scale(
          scaleX: 1 + (_flexX - 1) * value,
          scaleY: 1 + (_flexY - 1) * value,
          child: child,
        );
      },
      child: slab,
    );

    return slab;
  }

  double _uniformRadius(BorderRadius radius, Size size) {
    final resolved = radius.topLeft.x;
    return math.min(resolved, math.min(size.width, size.height) / 2);
  }
}

/// Foreground edge light fades broadly toward the far side. Its brightness
/// varies continuously along straight edges and corners without a bright pole.
class GlassEdgeLight extends StatelessWidget {
  const GlassEdgeLight({
    super.key,
    required this.borderRadius,
    required this.child,
    this.drawRim = true,
    this.lightAngle = LicoGlass.restLightAngle,
    this.rimWidth = MessagingDesktopMetrics.glassEdgeRimWidth,
    this.rimHi,
    this.rimLo,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool drawRim;
  final double lightAngle;
  final double rimWidth;
  final Color? rimHi;
  final Color? rimLo;

  @override
  Widget build(BuildContext context) {
    if (!drawRim || rimWidth <= 0) return child;
    final isDark = context.licoColors.isDark;
    return CustomPaint(
      foregroundPainter: GlassSpecularRimPainter(
        borderRadius: borderRadius,
        rimWidth: rimWidth,
        lightAngle: lightAngle,
        rimHi: rimHi ?? MessagingDesktopMetrics.glassEdgeRimHi(isDark: isDark),
        rimLo: rimLo ?? MessagingDesktopMetrics.glassEdgeRimLo(isDark: isDark),
      ),
      child: child,
    );
  }
}

class GlassSpecularRimPainter extends CustomPainter {
  const GlassSpecularRimPainter({
    required this.borderRadius,
    required this.rimHi,
    required this.rimLo,
    required this.lightAngle,
    this.rimWidth = 1,
  });

  final BorderRadius borderRadius;
  final Color rimHi;
  final Color rimLo;
  final double lightAngle;
  final double rimWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || rimWidth <= 0) return;
    final rect = Offset.zero & size;
    final outer = borderRadius.toRRect(rect).scaleRadii();
    final inner = outer.deflate(rimWidth);
    if (inner.width <= 0 || inner.height <= 0) return;
    // Project the entire slab onto the light direction. A broad ramp avoids
    // the concentrated bright pole a conic gradient creates on long edges.
    final dx = math.cos(lightAngle);
    final dy = math.sin(lightAngle);
    final extent = dx.abs() * size.width + dy.abs() * size.height;
    final direction = Alignment(
      dx * extent / size.width,
      dy * extent / size.height,
    );
    final shader = LinearGradient(
      begin: -direction,
      end: direction,
      colors: [rimLo, rimHi],
    ).createShader(rect);
    canvas.drawDRRect(
      outer,
      inner,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.fill
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(GlassSpecularRimPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.rimHi != rimHi ||
      oldDelegate.rimLo != rimLo ||
      oldDelegate.lightAngle != lightAngle ||
      oldDelegate.rimWidth != rimWidth;
}
