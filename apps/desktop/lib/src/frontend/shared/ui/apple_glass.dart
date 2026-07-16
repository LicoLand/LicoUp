import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme_colors.dart';

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
    final dark = colors.isDark;
    final fill = dark
        ? Colors.white.withAlpha(fillAlpha ?? (focused ? 36 : 22))
        : Colors.black.withAlpha(fillAlpha ?? (focused ? 18 : 10));
    final accent =
        focusColor ?? (_brandFocusDefault ? colors.primaryStrong : colors.info);
    final border = focused
        ? accent.withAlpha(borderAlpha ?? 200)
        : (idleBorderColor ??
              Colors.white.withAlpha(borderAlpha ?? (dark ? 48 : 70)));
    final borderWidth = focused
        ? (focusedBorderWidth ?? AppleControlMetrics.hairline)
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
  final dark = colors.isDark;
  final fill = emphasized
      ? Colors.white.withAlpha(dark ? 40 : 28)
      : Colors.white.withAlpha(dark ? (enabled ? 22 : 12) : (enabled ? 14 : 8));
  final border = emphasized
      ? colors.info.withAlpha(140)
      : Colors.white.withAlpha(
          dark ? (enabled ? 52 : 28) : (enabled ? 70 : 36),
        );
  return BoxDecoration(
    color: fill,
    borderRadius: borderRadius,
    border: Border.all(color: border, width: AppleControlMetrics.hairline),
  );
}
