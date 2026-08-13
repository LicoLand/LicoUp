import 'package:flutter/material.dart';

/// Layout-neutral projection of the active appearance palette.
///
/// Profiles may consume these color roles, but cannot import the application's
/// concrete theme implementation or become an appearance authority themselves.
///
/// Equality is derived from [_roles] so adding a role is a single edit. A
/// hand-maintained `==` here previously meant three synchronized edits per
/// role, where missing one silently dropped the role from change detection.
@immutable
final class LayoutPalette {
  const LayoutPalette({
    required this.background,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.line,
    required this.lineStrong,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textDisabled,
    required this.primary,
    required this.primaryStrong,
    required this.brandSurface,
    required this.brandBorder,
    required this.textOnPrimary,
    required this.accent,
    required this.accentStrong,
    required this.accentSurface,
    required this.accentBorder,
    required this.textOnAccent,
    required this.success,
    required this.warning,
    required this.error,
    required this.hoverOverlay,
    required this.pressedOverlay,
    required this.selectedSurface,
    required this.brandGlow,
    required this.accentGlow,
  });

  final Color background;
  final Color surface;
  final Color surfaceLow;
  final Color surfaceRaised;
  final Color surfaceSunken;
  final Color line;
  final Color lineStrong;
  final Color text;
  final Color textSecondary;
  final Color textMuted;
  final Color textDisabled;
  final Color primary;
  final Color primaryStrong;
  final Color brandSurface;
  final Color brandBorder;
  final Color textOnPrimary;
  final Color accent;
  final Color accentStrong;
  final Color accentSurface;
  final Color accentBorder;
  final Color textOnAccent;
  final Color success;
  final Color warning;
  final Color error;
  final Color hoverOverlay;
  final Color pressedOverlay;
  final Color selectedSurface;
  final Color brandGlow;
  final Color accentGlow;

  bool get isDark =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark;

  List<Color> get _roles => [
    background,
    surface,
    surfaceLow,
    surfaceRaised,
    surfaceSunken,
    line,
    lineStrong,
    text,
    textSecondary,
    textMuted,
    textDisabled,
    primary,
    primaryStrong,
    brandSurface,
    brandBorder,
    textOnPrimary,
    accent,
    accentStrong,
    accentSurface,
    accentBorder,
    textOnAccent,
    success,
    warning,
    error,
    hoverOverlay,
    pressedOverlay,
    selectedSurface,
    brandGlow,
    accentGlow,
  ];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! LayoutPalette) {
      return false;
    }
    final mine = _roles;
    final theirs = other._roles;
    for (var index = 0; index < mine.length; index += 1) {
      if (mine[index] != theirs[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_roles);
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
