import 'package:flutter/material.dart';

/// Layout-neutral projection of the active appearance palette.
///
/// Profiles may consume these color roles, but cannot import the application's
/// concrete theme implementation or become an appearance authority themselves.
@immutable
final class LayoutPalette {
  const LayoutPalette({
    required this.background,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceHigh,
    required this.surfaceHighest,
    required this.line,
    required this.text,
    required this.textMuted,
    required this.primary,
    required this.primaryStrong,
    required this.primaryFixed,
    required this.textOnPrimary,
    required this.info,
    required this.infoMuted,
    required this.success,
    required this.warning,
    required this.error,
  });

  final Color background;
  final Color surface;
  final Color surfaceLow;
  final Color surfaceHigh;
  final Color surfaceHighest;
  final Color line;
  final Color text;
  final Color textMuted;
  final Color primary;
  final Color primaryStrong;
  final Color primaryFixed;
  final Color textOnPrimary;
  final Color info;
  final Color infoMuted;
  final Color success;
  final Color warning;
  final Color error;

  bool get isDark =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutPalette &&
          background == other.background &&
          surface == other.surface &&
          surfaceLow == other.surfaceLow &&
          surfaceHigh == other.surfaceHigh &&
          surfaceHighest == other.surfaceHighest &&
          line == other.line &&
          text == other.text &&
          textMuted == other.textMuted &&
          primary == other.primary &&
          primaryStrong == other.primaryStrong &&
          primaryFixed == other.primaryFixed &&
          textOnPrimary == other.textOnPrimary &&
          info == other.info &&
          infoMuted == other.infoMuted &&
          success == other.success &&
          warning == other.warning &&
          error == other.error;

  @override
  int get hashCode => Object.hashAll([
    background,
    surface,
    surfaceLow,
    surfaceHigh,
    surfaceHighest,
    line,
    text,
    textMuted,
    primary,
    primaryStrong,
    primaryFixed,
    textOnPrimary,
    info,
    infoMuted,
    success,
    warning,
    error,
  ]);
}

final class LayoutPaletteScope extends InheritedWidget {
  const LayoutPaletteScope({
    super.key,
    required this.palette,
    required super.child,
  });

  final LayoutPalette palette;

  static LayoutPalette of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LayoutPaletteScope>();
    if (scope == null) {
      throw StateError('layout_palette_scope_missing');
    }
    return scope.palette;
  }

  @override
  bool updateShouldNotify(LayoutPaletteScope oldWidget) =>
      oldWidget.palette != palette;
}

extension LayoutPaletteContext on BuildContext {
  LayoutPalette get layoutPalette => LayoutPaletteScope.of(this);
}
