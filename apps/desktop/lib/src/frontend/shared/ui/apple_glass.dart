import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Translucent glass surface with continuous-feeling corners and a hairline
/// border — Flutter-first stand-in for system materials on Apple clients.
class AppleGlassSurface extends StatelessWidget {
  const AppleGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(AppleControlMetrics.controlCornerRadius),
    ),
    this.blurSigma = 18,
    this.fillAlpha,
    this.borderAlpha,
    this.focused = false,
    this.focusColor,
    this.idleBorderColor,
    this.focusedBorderWidth,
    this.clipBehavior = Clip.antiAlias,
  }) : _brandFocusDefault = false;

  /// Rounded-rect glass search field aligned with menu panel corners.
  ///
  /// Focus ring defaults to brand-strong gold (`colors.primaryStrong`) —
  /// a soft light yellow suitable on dark charcoal fields.
  const AppleGlassSurface.searchField({
    super.key,
    required this.child,
    this.blurSigma = 18,
    this.fillAlpha,
    this.borderAlpha,
    this.focused = false,
    this.focusColor,
    this.clipBehavior = Clip.antiAlias,
  }) : borderRadius = const BorderRadius.all(
         Radius.circular(AppleControlMetrics.searchCornerRadius),
       ),
       focusedBorderWidth = AppleControlMetrics.searchFocusRingWidth,
       idleBorderColor = null,
       _brandFocusDefault = true;

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final int? fillAlpha;
  final int? borderAlpha;
  final bool focused;
  final Color? focusColor;

  /// Unfocused hairline color (e.g. warning outline). Ignored while focused.
  final Color? idleBorderColor;
  final double? focusedBorderWidth;
  final Clip clipBehavior;
  final bool _brandFocusDefault;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    // Fills and rims come from the neutral ramp rather than white/black alpha
    // so a preset with an unusual background does not get a foreign haze laid
    // over it. `fillAlpha`/`borderAlpha` remain honoured for callers that need
    // a specific translucency over live blurred content.
    final fill = fillAlpha != null
        ? colors.text.withAlpha(fillAlpha!)
        : (focused ? colors.surfaceRaised : colors.surfaceLow);
    // Focus is an interaction: the ring is the accent. The brand-focus variant
    // exists only for the search capsule, which is a brand-owned surface.
    final accent =
        focusColor ??
        (_brandFocusDefault ? colors.primaryStrong : colors.accent);
    final border = focused
        ? (borderAlpha == null ? accent : accent.withAlpha(borderAlpha!))
        : (idleBorderColor ??
              (borderAlpha == null
                  ? colors.line
                  : colors.lineStrong.withAlpha(borderAlpha!)));
    final borderWidth = focused
        ? (focusedBorderWidth ?? AppleControlMetrics.searchFocusRingWidth)
        : AppleControlMetrics.hairline;

    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(color: border, width: borderWidth),
      ),
      clipBehavior: clipBehavior,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: ColoredBox(color: fill, child: child),
      ),
    );
  }
}

/// Shared Apple-leaning secondary / glass control decoration for buttons.
BoxDecoration appleGlassControlDecoration({
  required LicoThemeColors colors,
  required BorderRadius borderRadius,
  bool enabled = true,
  bool emphasized = false,
}) {
  final fill = emphasized
      ? colors.surfaceRaised
      : (enabled
            ? colors.surfaceLow
            : colors.surfaceLow.withValues(alpha: 0.5));
  final border = emphasized
      ? colors.accentBorder
      : (enabled ? colors.line : colors.line.withValues(alpha: 0.5));
  return BoxDecoration(
    color: fill,
    borderRadius: borderRadius,
    border: Border.all(color: border, width: AppleControlMetrics.hairline),
  );
}
