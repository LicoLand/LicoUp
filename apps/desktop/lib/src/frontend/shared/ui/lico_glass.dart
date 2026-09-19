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
/// fill, then a 1 px conic specular rim in the foreground. Content-layer
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

  /// Resting light: CSS 145° from north, as Flutter sweep radians (east, clockwise).
  static const restLightAngle = 55 * math.pi / 180;

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
    final encloseRim = widget.size == LicoGlassSize.small;

    Widget inner = ColoredBox(color: fill, child: widget.child);
    final useBackdrop =
        widget.readBackdrop && blur > 0 && fill.a < 0.98 && !reduceTransparency;
    if (useBackdrop) {
      ImageFilter filter = ImageFilter.blur(
        sigmaX: blur,
        sigmaY: blur,
        tileMode: TileMode.clamp,
      );
      final size = _slabSize;
      if (size != null &&
          size.width > 0 &&
          size.height > 0 &&
          GlassLens.isSupported) {
        final lens = GlassLens.createFilter(
          size: size,
          radius: _uniformRadius(widget.borderRadius, size),
          displace: widget.size == LicoGlassSize.large ? 12 : 8,
          chroma: widget.chroma ? 0.08 : 0,
        );
        if (lens != null) {
          filter = ImageFilter.compose(inner: lens, outer: filter);
        }
      }
      filter = ImageFilter.compose(inner: filter, outer: _glassLuminosity);
      inner = BackdropFilter(filter: filter, child: inner);
    }

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

    // The wrapper stack around the child must stay structurally stable across
    // focus, rim and activity toggles: swapping wrapper widget types deactivates
    // the child's element subtree, which drops focus and the text input
    // connection of any field inside. Toggle painter/decoration parameters
    // instead of adding or removing wrapper widgets.
    slab = AnimatedBuilder(
      animation: _light,
      builder: (context, child) {
        final showRim = widget.drawRim && !widget.focused && !highContrast;
        return CustomPaint(
          foregroundPainter: showRim
              ? GlassSpecularRimPainter(
                  borderRadius: widget.borderRadius,
                  rimWidth: MessagingDesktopMetrics.glassEdgeRimWidth,
                  lightAngle: widget.trackLight && !reduceMotion
                      ? _angle
                      : LicoGlass.restLightAngle,
                  rimHi: MessagingDesktopMetrics.glassEdgeRimHi(isDark: isDark),
                  rimLo: MessagingDesktopMetrics.glassEdgeRimLo(isDark: isDark),
                  enclose: encloseRim,
                )
              : null,
          child: child,
        );
      },
      child: slab,
    );

    if (widget.trackLight && !reduceMotion) {
      slab = MouseRegion(
        key: _hoverKey,
        onHover: (event) {
          final box = _hoverKey.currentContext?.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          final center = box.size.center(Offset.zero);
          final local = event.localPosition;
          _aim(
            math.atan2(local.dy - center.dy, local.dx - center.dx),
            animate: false,
          );
        },
        onExit: (_) => _aim(LicoGlass.restLightAngle, animate: true),
        child: slab,
      );
    }

    final Color? interactionRingColor =
        widget.focused && widget.focusColor != null && widget.focusWidth > 0
        ? widget.focusColor!
        : highContrast && widget.drawRim
        ? (isDark ? Colors.white : Colors.black)
        : null;
    final double interactionRingWidth =
        widget.focused && widget.focusColor != null && widget.focusWidth > 0
        ? widget.focusWidth
        : 1;
    slab = CustomPaint(
      foregroundPainter: interactionRingColor == null
          ? null
          : ContinuousStrokePainter(
              borderRadius: widget.borderRadius,
              color: interactionRingColor,
              width: interactionRingWidth,
            ),
      child: slab,
    );

    if (widget.shadows != null && widget.shadows!.isNotEmpty) {
      slab = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          boxShadow: widget.shadows,
        ),
        child: slab,
      );
    }

    if (widget.gelPress && !reduceMotion) {
      slab = AnimatedBuilder(
        animation: _press,
        builder: (context, child) {
          final value = LicoMotion.emphasized.transform(_press.value);
          return Transform.scale(
            scaleX: 1 + (_flexX - 1) * value,
            scaleY: 1 + (_flexY - 1) * value,
            child: child,
          );
        },
        child: slab,
      );
    }

    return slab;
  }

  double _uniformRadius(BorderRadius radius, Size size) {
    final resolved = radius.topLeft.x;
    return math.min(resolved, math.min(size.width, size.height) / 2);
  }
}

/// Foreground specular rim. One dominant lit arc and a whisper on the far
/// edge — a uniform alpha ring reads as a drawn outline, not glass.
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
        enclose: false,
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
    this.enclose = false,
  });

  final BorderRadius borderRadius;
  final Color rimHi;
  final Color rimLo;
  final double lightAngle;
  final double rimWidth;

  /// When true, the light/shadow ring travels the full silhouette and never
  /// drops to transparent — buttons stay enclosed. Overlay glass keeps the
  /// open highlight (lit arc + far whisper).
  final bool enclose;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || rimWidth <= 0) return;
    final rect = Offset.zero & size;
    final outer = borderRadius.toRRect(rect).scaleRadii();
    final inner = outer.deflate(rimWidth);
    if (inner.width <= 0 || inner.height <= 0) return;
    final far = rimLo.withValues(alpha: rimLo.a * 0.65);
    final shader =
        (enclose
                ? SweepGradient(
                    startAngle: lightAngle,
                    endAngle: lightAngle + math.pi * 2,
                    colors: [rimHi, rimLo, far, rimLo, rimHi],
                    stops: const [0, 0.22, 0.5, 0.78, 1],
                  )
                : SweepGradient(
                    startAngle: lightAngle,
                    endAngle: lightAngle + math.pi * 2,
                    colors: [
                      rimHi,
                      rimLo,
                      Colors.transparent,
                      Colors.transparent,
                      far,
                      Colors.transparent,
                      Colors.transparent,
                      rimLo,
                      rimHi,
                    ],
                    stops: const [
                      0,
                      36 / 360,
                      88 / 360,
                      152 / 360,
                      180 / 360,
                      208 / 360,
                      286 / 360,
                      330 / 360,
                      1,
                    ],
                  ))
            .createShader(rect);
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
      oldDelegate.rimWidth != rimWidth ||
      oldDelegate.enclose != enclose;
}
