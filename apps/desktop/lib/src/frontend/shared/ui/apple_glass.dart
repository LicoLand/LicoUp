import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Translucent glass surface with a specular rim — Flutter-first stand-in
/// for system materials on Apple clients.
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
    this.drawRim = true,
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
    this.focused = false,
    this.focusColor,
  }) : borderRadius = const BorderRadius.all(
         Radius.circular(AppleControlMetrics.searchCornerRadius),
       ),
       focusedBorderWidth = AppleControlMetrics.searchFocusRingWidth,
       idleBorderColor = null,
       borderAlpha = null,
       drawRim = true,
       _brandFocusDefault = true;

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final int? fillAlpha;
  final int? borderAlpha;
  final bool focused;
  final Color? focusColor;

  /// Signal outline while unfocused (e.g. warning). Not the glass rim.
  final Color? idleBorderColor;
  final double? focusedBorderWidth;
  final bool drawRim;
  final bool _brandFocusDefault;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final fill = fillAlpha != null
        ? colors.text.withAlpha(fillAlpha!)
        : (focused ? colors.surfaceRaised : colors.surfaceLow);
    final accent =
        focusColor ??
        (_brandFocusDefault ? colors.primaryStrong : colors.accent);
    final readBackdrop = fillAlpha != null && blurSigma > 0;
    final warning = !focused ? idleBorderColor : null;
    final rimAllowed = borderAlpha == null || borderAlpha! > 0;
    final glass = LicoGlass(
      borderRadius: borderRadius,
      fill: fill,
      size: LicoGlassSize.small,
      readBackdrop: readBackdrop,
      blurSigma: readBackdrop ? blurSigma : null,
      drawRim: drawRim && warning == null && rimAllowed,
      trackLight: true,
      gelPress: false,
      focused: focused,
      focusColor: focused ? accent : null,
      focusWidth:
          focusedBorderWidth ?? AppleControlMetrics.searchFocusRingWidth,
      child: child,
    );
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: ContinuousRoundedBorder(
          borderRadius: borderRadius,
          side: warning == null
              ? BorderSide.none
              : BorderSide(color: warning, width: AppleControlMetrics.hairline),
        ),
      ),
      child: glass,
    );
  }
}

/// Shared fill for remaining page-action surfaces that are not glass chrome.
Decoration appleGlassControlDecoration({
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
  return ShapeDecoration(
    color: fill,
    shape: RoundedRectangleBorder(borderRadius: borderRadius),
  );
}
