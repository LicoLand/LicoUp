import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

LayoutPalette nativeDesktopTestPalette(BuildContext context) {
  final colors = context.licoColors;
  return LayoutPalette(
    background: colors.background,
    surface: colors.surface,
    surfaceLow: colors.surfaceLow,
    surfaceHigh: colors.surfaceHigh,
    surfaceHighest: colors.surfaceHighest,
    line: colors.line,
    text: colors.text,
    textMuted: colors.textMuted,
    primary: colors.primary,
    primaryStrong: colors.primaryStrong,
    primaryFixed: colors.primaryFixed,
    textOnPrimary: colors.textOnPrimary,
    info: colors.info,
    infoMuted: colors.infoMuted,
    success: colors.success,
    warning: colors.warning,
    error: colors.error,
  );
}

Widget withNativeDesktopTestPalette(BuildContext context, Widget child) =>
    LayoutPaletteScope(
      palette: nativeDesktopTestPalette(context),
      child: child,
    );
