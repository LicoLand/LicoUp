import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_ambient_clock.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground_scope.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Cached Impeller fragment program for the ambient galaxy.
///
/// One procedural fragment shader paints the whole sky — density-wave
/// spiral arms, orbiting star rings, twinkling background, glass transfer —
/// so there is no particle state, atlas or per-frame buffer work. When the
/// program cannot load the painter falls back to the ground base colour.
abstract final class LicoGalaxyProgram {
  static const asset = 'shaders/lico_galaxy.frag';

  static ui.FragmentProgram? _program;
  static Future<void>? _loading;
  static bool _failed = false;

  /// Fires once when the program finishes loading; the owning ground
  /// republishes `paintsGlassSmoke` so the pane glass restyles.
  static final ValueNotifier<bool> loaded = ValueNotifier<bool>(false);

  // Canvas `Paint.shader` works wherever Impeller runs; the check that
  // gates `ImageFilter.shader` does not apply here, so support is decided
  // by whether the program loads.
  static bool get isSupported => true;

  static bool get isLoaded => _program != null || _debugLoaded;

  /// Test seam: pretends the program loaded so `paintsGlassSmoke` exercises
  /// the sheen-only pane path without a GPU context.
  @visibleForTesting
  static set debugLoaded(bool value) {
    _debugLoaded = value;
    loaded.value = value || _program != null;
  }

  static bool _debugLoaded = false;

  static Future<void> ensureLoaded() {
    if (_program != null || _failed || !isSupported) {
      return Future<void>.value();
    }
    return _loading ??= () async {
      try {
        _program = await ui.FragmentProgram.fromAsset(asset);
        loaded.value = true;
      } catch (error) {
        _failed = true;
      }
    }();
  }

  static ui.FragmentShader? createShader() => _program?.fragmentShader();
}

/// One closed-form critically damped spring step, exact for any [dt]:
/// returns `(error, velocity)` after stepping `e = x − target` toward zero
/// with natural frequency [omega]. Explicit Euler goes unstable above
/// ω·dt ≈ 2 and exploded after one janky frame; the closed form never does.
(double, double) licoDampedSpringStep(
  double error,
  double velocity, {
  required double omega,
  required double dt,
}) {
  final c = velocity + omega * error;
  final k = math.exp(-omega * dt);
  return ((error + c * dt) * k, (velocity - omega * c * dt) * k);
}

/// One pointer-trail slot: position plus its spring amplitude.
typedef LicoGalaxyTrailPoint = ({double x, double y, double amp});

/// The six-slot pointer trail the shader reads as `u_trail0..5`.
///
/// While the pointer hovers, the newest slot tracks it; a new slot is pushed
/// (dropping the oldest) when the pointer moved more than
/// [pushDistance] pt from the newest, or when the newest is older than
/// [slotAge] and the pointer still moved. Every slot's amplitude is a
/// critically damped spring ([omega]): the newest targets 1
/// while the pointer is inside (rise ≈ 0.12 s), everything else targets 0
/// and settles within ≈ 1.5 s after the pointer leaves.
final class LicoGalaxyTrail {
  static const slotCount = 6;
  static const pushDistance = 24.0;
  static const slotAge = LicoMotion.ambientTrailSlotAge;

  /// Critically damped spring (ω = 18): ≥ 0.97 of the target in 0.3 s and
  /// under 2% remaining at 1.5 s.
  static const omega = 18.0;

  final Float32List _x = Float32List(slotCount);
  final Float32List _y = Float32List(slotCount);
  final Float32List _amp = Float32List(slotCount);
  final Float32List _vel = Float32List(slotCount);
  final List<Duration> _stamp = List.filled(slotCount, Duration.zero);
  int _count = 0;
  bool _inside = false;

  /// The newest slot's live amplitude — the spring target while hovering.
  double get newestAmplitude => _count == 0 ? 0 : _amp[0];

  /// A hover input at [position] (ground coordinates) and [now]. Pushes a
  /// new slot when the pointer moved past [pushDistance] from the newest or
  /// the newest went stale while still moving; otherwise the newest tracks.
  void recordHover(Offset position, Duration now) {
    _inside = true;
    if (_count > 0) {
      final dx = position.dx - _x[0];
      final dy = position.dy - _y[0];
      final moved = dx * dx + dy * dy;
      final stale = now - _stamp[0] > slotAge;
      if (moved <= pushDistance * pushDistance && !(stale && moved > 0.25)) {
        _x[0] = position.dx;
        _y[0] = position.dy;
        return;
      }
    }
    // Push: shift the train down, the oldest slot falls off.
    final keep = _count < slotCount ? _count : slotCount - 1;
    for (var i = keep; i > 0; i--) {
      _x[i] = _x[i - 1];
      _y[i] = _y[i - 1];
      _amp[i] = _amp[i - 1];
      _vel[i] = _vel[i - 1];
      _stamp[i] = _stamp[i - 1];
    }
    _x[0] = position.dx;
    _y[0] = position.dy;
    _amp[0] = 0;
    _vel[0] = 0;
    _stamp[0] = now;
    if (_count < slotCount) _count++;
  }

  /// The pointer left the ground: every slot eases out.
  void recordExit() => _inside = false;

  /// Advances every spring by [dt] seconds.
  void advance(double dt) {
    if (dt <= 0) return;
    for (var i = 0; i < _count; i++) {
      final target = _inside && i == 0 ? 1.0 : 0.0;
      final (e, v) = licoDampedSpringStep(
        _amp[i] - target,
        _vel[i],
        omega: omega,
        dt: dt,
      );
      _amp[i] = (target + e).clamp(0.0, 1.0);
      _vel[i] = v;
    }
  }

  /// Uniform values, newest first; missing slots read as zero.
  List<LicoGalaxyTrailPoint> get points => [
    for (var i = 0; i < slotCount; i++)
      (
        x: i < _count ? _x[i] : 0.0,
        y: i < _count ? _y[i] : 0.0,
        amp: i < _count ? _amp[i] : 0.0,
      ),
  ];

  /// Clears all slots (reduced motion disables the pointer entirely).
  void reset() {
    _count = 0;
    _inside = false;
  }
}

/// Packs the fragment shader's uniform floats in declaration order.
abstract final class LicoGalaxyUniforms {
  /// Float slots: size(2) dpr(1) time(1) glassCount(1) glass rects(16)
  /// radii(4) trail(24) parallax(4).
  static const floatCount = 53;
  static const maxGlassRects = 4;

  static List<double> pack({
    required Size size,
    required double dpr,
    required double time,
    required List<RRect> glassRects,
    required List<LicoGalaxyTrailPoint> trail,
    required Offset parallax,
  }) {
    final out = List<double>.filled(floatCount, 0);
    packInto(
      out,
      size: size,
      dpr: dpr,
      time: time,
      glassRects: glassRects,
      trail: trail,
      parallax: parallax,
    );
    return out;
  }

  /// Writes the uniforms into [out] in place — the painter reuses one
  /// [Float32List] per frame so painting never allocates.
  static void packInto(
    List<double> out, {
    required Size size,
    required double dpr,
    required double time,
    required List<RRect> glassRects,
    required List<LicoGalaxyTrailPoint> trail,
    required Offset parallax,
  }) {
    out.fillRange(0, floatCount, 0);
    out[0] = size.width;
    out[1] = size.height;
    out[2] = dpr;
    out[3] = time;
    final count = glassRects.length.clamp(0, maxGlassRects);
    out[4] = count.toDouble();
    for (var i = 0; i < count; i++) {
      final rect = glassRects[i].outerRect;
      final base = 5 + i * 4;
      out[base] = rect.left;
      out[base + 1] = rect.top;
      out[base + 2] = rect.right;
      out[base + 3] = rect.bottom;
      out[21 + i] = glassRects[i].tlRadiusX;
    }
    for (var i = 0; i < trail.length && i < 6; i++) {
      final base = 25 + i * 4;
      out[base] = trail[i].x;
      out[base + 1] = trail[i].y;
      out[base + 2] = trail[i].amp;
    }
    out[49] = parallax.dx;
    out[50] = parallax.dy;
  }
}

/// Procedural spiral galaxy for presets that declare
/// `ambient-effect: starfield`.
///
/// Painted on the ambient-owning [LicoWindowGround] by one fragment shader:
/// wherever the content leaves the ground transparent the galaxy shows
/// through, and glass surfaces registered through `LicoGlassRegion` get the
/// soft rendering plus the smoke transfer inside the shader. It is pointer-
/// and semantics-transparent and renders nothing when the resolved preset
/// does not request the effect.
///
/// The shared ambient clock feeds the painter through its `repaint` listenable at most
/// [LicoGalaxyPainter.maxFramesPerSecond] times per second, so no widget
/// rebuild happens per frame, and it runs only while ambient motion is
/// allowed — under reduced motion the galaxy paints static at `t = 0` with
/// no pointer response. While motion is allowed, a six-slot pointer trail
/// displaces and brightens the sky near the cursor on damped springs, and
/// the layers drift slightly against the pointer by depth.
final class LicoGalaxy extends StatefulWidget {
  const LicoGalaxy({super.key, this.site});

  /// The owning ground's ambient site: shared pointer input, registered
  /// glass regions and the ground's render box. `null` renders the galaxy
  /// without interaction or glass softening.
  final LicoWindowGroundSite? site;

  @override
  State<LicoGalaxy> createState() => _LicoGalaxyState();
}

final class _LicoGalaxyState extends State<LicoGalaxy> {
  final ValueNotifier<double> _clock = ValueNotifier<double>(0);
  double _lastT = 0;
  bool _ambientSubscribed = false;

  /// The pointer trail and parallax spring live here — the painter only
  /// reads them; the ticker steps them at the capped ambient cadence.
  final LicoGalaxyTrail trail = LicoGalaxyTrail();
  Offset _parallax = Offset.zero;
  Offset _parallaxVel = Offset.zero;

  /// Created once when the program finishes loading, disposed with the
  /// widget — the painter never owns or recreates it.
  ui.FragmentShader? _shader;

  /// Parallax spring (critically damped, ω = 6 — eases out in ≈ 1 s).
  static const parallaxOmega = 6.0;

  @override
  void initState() {
    super.initState();
    _loadProgram();
  }

  void _loadProgram() {
    // When the program is already loaded (fixture/test stubs, or a second
    // galaxy widget), create the shader synchronously so the first painted
    // frame is the sky, not the fallback — matches the old paint-time
    // creation determinism.
    if (LicoGalaxyProgram.isLoaded) {
      _shader ??= LicoGalaxyProgram.createShader();
      return;
    }
    LicoGalaxyProgram.ensureLoaded().then((_) {
      if (mounted && LicoGalaxyProgram.isLoaded) {
        _shader ??= LicoGalaxyProgram.createShader();
        setState(() {});
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAmbientClock();
  }

  bool get _wantsGalaxy {
    final colors = Theme.of(context).extension<LicoThemeColors>();
    return colors != null &&
        colors.ambientEffect == LicoAmbientEffect.starfield;
  }

  bool get _animate => _wantsGalaxy && context.allowsAmbientMotion;

  void _syncAmbientClock() {
    if (_animate) {
      if (!_ambientSubscribed) {
        _ambientSubscribed = true;
        LicoAmbientClock.shared
          ..acquire()
          ..addListener(_onAmbientTick);
      }
      return;
    }
    _releaseAmbientClock();
  }

  void _releaseAmbientClock() {
    if (_ambientSubscribed) {
      _ambientSubscribed = false;
      LicoAmbientClock.shared
        ..removeListener(_onAmbientTick)
        ..release();
    }
  }

  void _onAmbientTick() {
    final elapsed = LicoAmbientClock.shared.value;
    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final dt = (t - _lastT).clamp(0.0, double.infinity);
    _lastT = t;
    _stepMotion(dt, t);
    _clock.value = t;
  }

  /// Feeds the pointer into the trail and advances the slot springs and
  /// the parallax easing by [dt] seconds.
  void _stepMotion(double dt, double t) {
    final animate = _animate;
    final pointer = widget.site?.interaction.pointer.value;
    final now = Duration(microseconds: (t * 1e6).round());
    if (animate && pointer != null) {
      trail.recordHover(pointer, now);
    } else {
      trail.recordExit();
    }
    trail.advance(dt);
    final size = context.size;
    final target = animate && pointer != null && size != null
        ? Offset.zero - pointer + size.center(Offset.zero)
        : Offset.zero;
    final (ex, vx) = licoDampedSpringStep(
      _parallax.dx - target.dx,
      _parallaxVel.dx,
      omega: parallaxOmega,
      dt: dt,
    );
    final (ey, vy) = licoDampedSpringStep(
      _parallax.dy - target.dy,
      _parallaxVel.dy,
      omega: parallaxOmega,
      dt: dt,
    );
    _parallax = Offset(target.dx + ex, target.dy + ey);
    _parallaxVel = Offset(vx, vy);
  }

  @override
  void dispose() {
    _shader?.dispose();
    _releaseAmbientClock();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LicoThemeColors>();
    if (colors == null || colors.ambientEffect != LicoAmbientEffect.starfield) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            key: const Key('lico-galaxy-paint'),
            painter: LicoGalaxyPainter(
              clock: _clock,
              site: widget.site,
              animate: _animate,
              dpr: MediaQuery.devicePixelRatioOf(context),
              fallbackColor: colors.background,
              shader: _shader,
              trail: trail,
              parallax: () => _parallax,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

/// Paints the fragment-shader sky; [clock] is the ambient frame input and
/// [site] carries the ground's pointer, glass regions and render box. With
/// [animate] off the painter renders the static `t = 0` frame and ignores
/// the pointer entirely.
final class LicoGalaxyPainter extends CustomPainter {
  LicoGalaxyPainter({
    required this.clock,
    this.site,
    this.animate = true,
    this.dpr = 1,
    this.fallbackColor = const Color(0xFF060609),
    this.shader,
    required this.trail,
    required this.parallax,
  }) : super(
         repaint: Listenable.merge([
           clock,
           site?.interaction.pointer,
           site?.glassRegions,
         ]),
       );

  /// Ceiling on ambient repaint notifications: one emit per ~33.3 ms keeps
  /// the drift at or under 30 repaints per second. Interaction repaints
  /// (pointer, region mounts) are input-driven and uncapped.
  static const frameInterval = LicoMotion.ambientFrame;
  static const maxFramesPerSecond = 30;

  final ValueListenable<double> clock;
  final LicoWindowGroundSite? site;
  final bool animate;
  final double dpr;
  final Color fallbackColor;

  /// Owned by the state: created once on load, reused every paint, and
  /// disposed there — the painter is a pure reader.
  final ui.FragmentShader? shader;

  /// State-owned pointer trail and parallax readout.
  final LicoGalaxyTrail trail;
  final Offset Function() parallax;

  final Float32List _uniforms = Float32List(LicoGalaxyUniforms.floatCount);
  final List<RRect> _regionRects = <RRect>[];

  @override
  void paint(Canvas canvas, Size size) {
    final shader = this.shader;
    if (shader == null) {
      // Fallback: the ground base colour only.
      canvas.drawRect(Offset.zero & size, Paint()..color = fallbackColor);
      return;
    }

    _regionRects.clear();
    final site = this.site;
    final ground = site?.renderBox;
    if (ground != null && ground.hasSize) {
      for (final region in site!.glassRegions.regions) {
        if (!region.softens) continue;
        final box = region.renderBox;
        if (box == null || !box.hasSize) continue;
        final topLeft = ground.globalToLocal(box.localToGlobal(Offset.zero));
        _regionRects.add(
          region.borderRadius.toRRect(topLeft & box.size).scaleRadii(),
        );
      }
    }

    LicoGalaxyUniforms.packInto(
      _uniforms,
      size: size,
      dpr: dpr,
      time: animate ? clock.value : 0,
      glassRects: _regionRects,
      trail: animate ? trail.points : const [],
      parallax: animate ? parallax() : Offset.zero,
    );
    for (var i = 0; i < _uniforms.length; i++) {
      shader.setFloat(i, _uniforms[i]);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(LicoGalaxyPainter oldDelegate) {
    return !identical(oldDelegate.clock, clock) ||
        !identical(oldDelegate.site, site) ||
        oldDelegate.animate != animate ||
        oldDelegate.fallbackColor != fallbackColor;
  }
}
