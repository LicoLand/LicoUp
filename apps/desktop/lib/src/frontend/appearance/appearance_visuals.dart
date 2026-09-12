import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';

/// Runtime visual values. Geometry and functionality never enter this type.
class AppearanceVisuals extends ThemeExtension<AppearanceVisuals> {
  const AppearanceVisuals({
    this.useSystemFont = false,
    this.roundedIcons = false,
    this.motionScale = 1,
    this.surfaceOpacity = 1,
    this.glassFinish = false,
  });

  factory AppearanceVisuals.fromTokens(Map<String, String> tokens) =>
      AppearanceVisuals(
        useSystemFont: tokens['font-family'] == 'system',
        roundedIcons: tokens['icon-style'] == 'rounded',
        motionScale: double.tryParse(tokens['motion-scale'] ?? '') ?? 1,
        surfaceOpacity: double.tryParse(tokens['surface-opacity'] ?? '') ?? 1,
        glassFinish: tokens['component-finish'] == 'glass',
      );

  final bool useSystemFont;
  final bool roundedIcons;
  final double motionScale;
  final double surfaceOpacity;
  final bool glassFinish;

  String? get fontFamily => useSystemFont ? null : LicoTypography.sansFamily;

  IconData iconFor(IconData icon) {
    if (!roundedIcons) {
      return switch (icon) {
        Icons.settings_rounded => Icons.settings_outlined,
        Icons.search_rounded => Icons.search_outlined,
        Icons.refresh_rounded => Icons.refresh_outlined,
        Icons.notifications_rounded => Icons.notifications_outlined,
        Icons.folder_rounded => Icons.folder_outlined,
        Icons.extension_rounded => Icons.extension_outlined,
        Icons.tune_rounded => Icons.tune_outlined,
        _ => icon,
      };
    }
    return switch (icon) {
      Icons.settings_outlined || Icons.settings => Icons.settings_rounded,
      Icons.search_outlined || Icons.search => Icons.search_rounded,
      Icons.refresh_outlined || Icons.refresh => Icons.refresh_rounded,
      Icons.notifications_outlined => Icons.notifications_rounded,
      Icons.folder_outlined => Icons.folder_rounded,
      Icons.extension_outlined => Icons.extension_rounded,
      Icons.tune_outlined || Icons.tune => Icons.tune_rounded,
      _ => icon,
    };
  }

  @override
  AppearanceVisuals copyWith({
    bool? useSystemFont,
    bool? roundedIcons,
    double? motionScale,
    double? surfaceOpacity,
    bool? glassFinish,
  }) => AppearanceVisuals(
    useSystemFont: useSystemFont ?? this.useSystemFont,
    roundedIcons: roundedIcons ?? this.roundedIcons,
    motionScale: motionScale ?? this.motionScale,
    surfaceOpacity: surfaceOpacity ?? this.surfaceOpacity,
    glassFinish: glassFinish ?? this.glassFinish,
  );

  @override
  AppearanceVisuals lerp(covariant AppearanceVisuals? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

extension AppearanceVisualContext on BuildContext {
  AppearanceVisuals get appearanceVisuals =>
      Theme.of(this).extension<AppearanceVisuals>() ??
      const AppearanceVisuals();
}
