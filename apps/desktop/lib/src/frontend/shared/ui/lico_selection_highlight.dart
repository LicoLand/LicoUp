import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/shared/ui/lico_ambient_clock.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Shared state colors for rows and buttons sitting on clear glass.
///
/// Highlight on glass reads as light, never as a mask or a slab: a lamp
/// glows at the indicator edge and spills across the rounded bounds,
/// falling off to nothing partway across. Hover is the same lamp turned
/// down — faint and neutral. These roles give feature widgets one place
/// to resolve state tints instead of restating raw overlays.
abstract final class LicoSelectionGlow {
  /// The faint neutral light under the pointer on list rows and nav
  /// buttons: white light in dark mode, a whisper of the selection ink in
  /// light mode where white on cream would be invisible.
  static Color hover({required bool isDark, required Color selectionInk}) =>
      isDark ? const Color(0x0FFFFFFF) : selectionInk.withValues(alpha: 0.07);
}

/// The selection light a layout × theme set renders. Each layout shell
/// declares its own; sets without a declaration keep [lamp].
enum LicoSelectionTreatment {
  /// The lamp light: a wash and rim over the row's rounded bounds plus the
  /// glowing edge indicator — the original shared highlight.
  lamp,

  /// The starlight light: a glow spilling from a floating light bar at the
  /// row's leading edge, with stardust drifting off it. Dark sets only.
  starlight,
}

/// Declares which [LicoSelectionTreatment] the rows below resolve.
final class LicoSelectionTreatmentScope extends InheritedWidget {
  const LicoSelectionTreatmentScope({
    super.key,
    required this.treatment,
    required super.child,
  });

  final LicoSelectionTreatment treatment;

  static LicoSelectionTreatment of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LicoSelectionTreatmentScope>()
          ?.treatment ??
      LicoSelectionTreatment.lamp;

  @override
  bool updateShouldNotify(LicoSelectionTreatmentScope oldWidget) =>
      oldWidget.treatment != treatment;
}

/// Which edge of a row the selection light anchors to.
enum LicoSelectionAxis {
  /// The 3pt bar at the row's leading edge.
  leading,

  /// The centred bar along the item's bottom edge — horizontal tab bars.
  /// Under the starlight treatment it renders the still variant: the same
  /// spill and glowing bar as the leading light, without the stardust —
  /// navigation never drifts.
  bottom,
}

/// The selected-state light shared by every generic row and button.
///
/// One seam: call sites wrap their row in [LicoSelectionLight] and take the
/// hover fill from [LicoSelectionLight.hoverFill]; the active
/// [LicoSelectionTreatmentScope] picks the renderer so the painter's
/// arguments are stated once, here.
final class LicoSelectionLight extends StatelessWidget {
  const LicoSelectionLight({
    super.key,
    required this.selected,
    required this.radius,
    this.axis = LicoSelectionAxis.leading,
    required this.child,
  });

  final bool selected;

  /// The host row's corner radius — the light is clipped to it.
  final double radius;

  /// The edge the light anchors to.
  final LicoSelectionAxis axis;

  final Widget child;

  /// The neutral hover fill for the current treatment.
  static Color hoverFill(BuildContext context) =>
      switch (LicoSelectionTreatmentScope.of(context)) {
        LicoSelectionTreatment.starlight => const Color(0x0AFFFFFF),
        LicoSelectionTreatment.lamp => LicoSelectionGlow.hover(
          isDark: context.licoColors.isDark,
          selectionInk: context.licoColors.selectionInk,
        ),
      };

  /// Whether the starlight light is active here. Under it, selected rows
  /// keep their normal content tones instead of tinting into the lamp ink.
  static bool isStarlight(BuildContext context) =>
      LicoSelectionTreatmentScope.of(context) ==
      LicoSelectionTreatment.starlight;

  @override
  Widget build(BuildContext context) {
    if (!selected) {
      return child;
    }
    final colors = context.licoColors;
    final treatment = LicoSelectionTreatmentScope.of(context);
    if (treatment == LicoSelectionTreatment.starlight) {
      if (axis == LicoSelectionAxis.bottom) {
        return CustomPaint(
          painter: LicoStarlightTabHighlightPainter(
            accent: colors.selectionInk,
            glow: colors.accentGlow,
            radius: radius,
          ),
          child: child,
        );
      }
      return _LicoStarlightRow(
        radius: radius,
        ink: colors.selectionInk,
        glow: colors.accentGlow,
        accentStrong: colors.accentStrong,
        child: child,
      );
    }
    return CustomPaint(
      painter: LicoSelectionHighlightPainter(
        accent: colors.selectionInk,
        glow: colors.isDark
            ? colors.accentGlow
            : colors.selectionInk.withValues(alpha: 0.30),
        radius: radius,
        isDark: colors.isDark,
        horizontal: axis == LicoSelectionAxis.bottom,
      ),
      child: child,
    );
  }
}

/// The shared fluorescent selection highlight for navigation surfaces.
///
/// Painted over the row's full rounded bounds: a lamp-light wash that
/// fades from the indicator edge toward the far side, a rim that catches
/// the same light along the border, and the glowing indicator itself —
/// a 3×20 pt accent pill at the leading edge, or a 20×3 bar centred on
/// the bottom edge for horizontal tab bars. The wash and rim follow the
/// row's own corner radius; content on top keeps its normal tones, with
/// the icon and label taking `selectionInk` when selected.
final class LicoSelectionHighlightPainter extends CustomPainter {
  const LicoSelectionHighlightPainter({
    required this.accent,
    required this.glow,
    required this.radius,
    required this.isDark,
    this.horizontal = false,
  });

  /// The bottom tab bar's indicator: a short horizontal glowing bar
  /// centred on the item's bottom edge instead of the leading pill, with
  /// the light spilling upward from it.
  const LicoSelectionHighlightPainter.horizontal({
    required this.accent,
    required this.glow,
    required this.radius,
    required this.isDark,
  }) : horizontal = true;

  /// The lamp's color — the selection ink for the current preset.
  final Color accent;

  /// The blur color behind the indicator pill.
  final Color glow;

  /// The host row's corner radius — the light is clipped to it.
  final double radius;

  /// Bottom-bar indicator instead of the leading vertical pill.
  final bool horizontal;

  /// Dark presets carry a slightly stronger lamp than light ones.
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final begin = horizontal ? Alignment.bottomCenter : Alignment.centerLeft;
    final end = horizontal ? Alignment.topCenter : Alignment.centerRight;
    // The wash: lamp light at the indicator edge, gone partway across.
    final wash = LinearGradient(
      begin: begin,
      end: end,
      colors: [
        accent.withValues(alpha: isDark ? 0.20 : 0.12),
        accent.withValues(alpha: 0),
      ],
      stops: const [0.0, 0.62],
    ).createShader(rect);
    // The rim: the border nearest the lamp catches the most light.
    final rim = LinearGradient(
      begin: begin,
      end: end,
      colors: [
        accent.withValues(alpha: isDark ? 0.40 : 0.26),
        accent.withValues(alpha: 0.05),
      ],
      stops: const [0.0, 0.7],
    ).createShader(rect);
    canvas
      ..save()
      ..clipRRect(rrect)
      ..drawRect(rect, Paint()..shader = wash)
      ..drawRRect(
        rrect.deflate(0.5),
        Paint()
          ..shader = rim
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    final pill = horizontal
        // 20×3 bar centred on the item's bottom edge.
        ? RRect.fromLTRBR(
            size.width / 2 - 10,
            size.height - 4,
            size.width / 2 + 10,
            size.height - 1,
            const Radius.circular(1.5),
          )
        // 3×20 pill at the leading edge, vertically centred.
        : RRect.fromLTRBR(
            0,
            (size.height - 20) / 2,
            3,
            (size.height + 20) / 2,
            const Radius.circular(1.5),
          );
    canvas
      ..drawRRect(
        pill,
        Paint()
          ..color = glow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      )
      ..drawRRect(pill, Paint()..color = accent)
      ..restore();
  }

  @override
  bool shouldRepaint(LicoSelectionHighlightPainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.glow != glow ||
      oldDelegate.radius != radius ||
      oldDelegate.isDark != isDark ||
      oldDelegate.horizontal != horizontal;
}

/// One selected row under the starlight light. Owns the drift ticker so it
/// exists only while the row is selected.
final class _LicoStarlightRow extends StatefulWidget {
  const _LicoStarlightRow({
    required this.radius,
    required this.ink,
    required this.glow,
    required this.accentStrong,
    required this.child,
  });

  final double radius;
  final Color ink;
  final Color glow;
  final Color accentStrong;
  final Widget child;

  @override
  State<_LicoStarlightRow> createState() => _LicoStarlightRowState();
}

final class _LicoStarlightRowState extends State<_LicoStarlightRow> {
  /// The dust phase — stays at the static mid-flight pose until ambient
  /// motion runs; each clock tick advances it.
  final ValueNotifier<double> _drift = ValueNotifier<double>(0.3);
  bool _ambientSubscribed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.allowsAmbientMotion) {
      if (!_ambientSubscribed) {
        _ambientSubscribed = true;
        LicoAmbientClock.shared
          ..acquire()
          ..addListener(_onAmbientTick);
      }
    } else {
      _releaseAmbientClock();
      // Reduced motion: the dust holds a static mid-flight pose.
      _drift.value = 0.3;
    }
  }

  void _onAmbientTick() {
    final elapsed = LicoAmbientClock.shared.value;
    _drift.value =
        (elapsed.inMicroseconds % LicoMotion.driftLong.inMicroseconds) /
        LicoMotion.driftLong.inMicroseconds;
  }

  void _releaseAmbientClock() {
    if (_ambientSubscribed) {
      _ambientSubscribed = false;
      LicoAmbientClock.shared
        ..removeListener(_onAmbientTick)
        ..release();
    }
  }

  @override
  void dispose() {
    _releaseAmbientClock();
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: LicoStarlightHighlightPainter(
        repaint: _drift,
        accent: widget.ink,
        glow: widget.glow,
        accentStrong: widget.accentStrong,
        radius: widget.radius,
      ),
      child: widget.child,
    ),
  );
}

/// The starlight selection light for dark sets: light spilling from a
/// small floating bar at the row's leading edge, stardust drifting off it
/// across the row. No rim, no flat fill — everything is glow, clipped to
/// the row's rounded bounds.
final class LicoStarlightHighlightPainter extends CustomPainter {
  const LicoStarlightHighlightPainter({
    required ValueListenable<double> repaint,
    required this.accent,
    required this.glow,
    required this.accentStrong,
    required this.radius,
  }) : _repaint = repaint,
       super(repaint: repaint);

  /// The drift clock driving the stardust.
  final ValueListenable<double> _repaint;

  /// The light's color — the selection ink for the current preset.
  final Color accent;

  /// The blur color behind the bar.
  final Color glow;

  /// The odd motes' color.
  final Color accentStrong;

  /// The host row's corner radius — the light is clipped to it.
  final double radius;

  static const _amplitudes = <double>[5, 8, 3.5, 7];
  static const _moteRadii = <double>[0.9, 0.6, 1.1, 0.7];
  static const _motePeaks = <double>[0.55, 0.40, 0.60, 0.35];

  static double _fadeIn(double t) {
    final u = (t / 0.12).clamp(0.0, 1.0);
    return u * u * (3 - 2 * u);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas
      ..save()
      ..clipRRect(rrect);
    // The spill: elliptical glow centred on the bar, a circular gradient
    // under a y-scale so the light reaches further along the row than up.
    final spillRx = math.max(96.0, size.width * 0.45);
    final spillRy = size.height * 0.85;
    canvas
      ..translate(3.5, size.height / 2)
      ..scale(spillRx, spillRy)
      ..drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = RadialGradient(
            colors: [
              accent.withValues(alpha: 0.20),
              accent.withValues(alpha: 0.08),
              accent.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1)),
      )
      ..restore();
    // The bar: a 3×18 light floating just inside the leading edge, halo
    // first, then the bright core.
    final barTop = (size.height - 18) / 2;
    final bar = RRect.fromLTRBR(
      2,
      barTop,
      5,
      barTop + 18,
      const Radius.circular(1.5),
    );
    final halo = RRect.fromLTRBR(
      0,
      barTop - 4,
      7,
      barTop + 22,
      const Radius.circular(3.5),
    );
    canvas
      ..drawRRect(
        halo,
        Paint()
          ..color = glow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      )
      ..drawRRect(
        bar,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [accent, const Color(0xFFF1ECFF), accent],
          ).createShader(bar.outerRect),
      );
    // Stardust: four motes drifting rightward off the bar, fading in then
    // dissolving as they cross the row.
    final t0 = _repaint.value % 1;
    for (var i = 0; i < 4; i += 1) {
      final t = (t0 + i / 4) % 1;
      final alpha = _motePeaks[i] * math.pow(1 - t, 1.6) * _fadeIn(t);
      if (alpha <= 0) {
        continue;
      }
      final mote = i.isEven ? const Color(0xFFFFFFFF) : accentStrong;
      canvas.drawCircle(
        Offset(
          6 + t * 0.42 * size.width,
          size.height / 2 +
              _amplitudes[i] * math.sin(2 * math.pi * (t + 0.37 * i)),
        ),
        _moteRadii[i],
        Paint()..color = mote.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(LicoStarlightHighlightPainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.glow != glow ||
      oldDelegate.accentStrong != accentStrong ||
      oldDelegate.radius != radius;
}

/// The starlight selection light for horizontal tab bars: light rising
/// from a glowing bar that sits on the button's bottom edge, still — no
/// ticker, no stardust. Painted behind content, clipped to the button's
/// rounded bounds; no rim, no flat fill.
final class LicoStarlightTabHighlightPainter extends CustomPainter {
  const LicoStarlightTabHighlightPainter({
    required this.accent,
    required this.glow,
    required this.radius,
  });

  /// The light's color — the selection ink for the current preset.
  final Color accent;

  /// The blur color behind the bar.
  final Color glow;

  /// The host button's corner radius — the light is clipped to it.
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas
      ..save()
      ..clipRRect(rrect);
    // The spill: elliptical glow centred just under the bottom edge, a
    // circular gradient under a y-scale so it reaches further across the
    // button than up into it.
    canvas
      ..translate(size.width / 2, size.height - 2.5)
      ..scale(size.width * 0.5, size.height * 0.9)
      ..drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = RadialGradient(
            colors: [
              accent.withValues(alpha: 0.18),
              accent.withValues(alpha: 0.06),
              accent.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1)),
      )
      ..restore();
    // The bar: a 20×3 light centred on the bottom edge — the same seat
    // the lamp's horizontal pill takes — halo first, then the bright core.
    final bar = RRect.fromLTRBR(
      size.width / 2 - 10,
      size.height - 4,
      size.width / 2 + 10,
      size.height - 1,
      const Radius.circular(1.5),
    );
    final halo = RRect.fromLTRBR(
      bar.left - 4,
      bar.top - 2,
      bar.right + 4,
      bar.bottom + 2,
      const Radius.circular(3.5),
    );
    canvas
      ..drawRRect(
        halo,
        Paint()
          ..color = glow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      )
      ..drawRRect(
        bar,
        Paint()
          ..shader = LinearGradient(
            colors: [accent, const Color(0xFFF1ECFF), accent],
          ).createShader(bar.outerRect),
      );
  }

  @override
  bool shouldRepaint(LicoStarlightTabHighlightPainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.glow != glow ||
      oldDelegate.radius != radius;
}
