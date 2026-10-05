import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/appearance/appearance_projection.dart';

/// Builds the application theme for one appearance projection.
///
/// This is the production path: the projection's own font preference reaches
/// the type scale, so changing the preference changes what the interface
/// renders. A theme built from the projection's preset alone would ignore the
/// user's preference.
ThemeData buildAppearanceTheme(
  AppearanceProjection projection, {
  required Brightness platformBrightness,
  TargetPlatform? platform,
}) {
  return buildLicoTheme(
    presetId: projection.presetId,
    presets: appearancePresetConfigsFromProjection(projection),
    platformBrightness: platformBrightness,
    fontPreference: projection.fontPreference,
    platform: platform,
  );
}

/// Adapts renderer-independent appearance values to the existing Flutter
/// theme model without exposing Application-owned configuration objects.
///
/// A published appearance resource's tokens are applied to every preset the
/// projection carries, so the appearance the plan selected renders whichever
/// preset the brightness resolution reaches. The tokens are plain role/value
/// pairs; nothing else about a preset can be replaced by a resource.
List<AppearancePresetConfig> appearancePresetConfigsFromProjection(
  AppearanceProjection projection,
) {
  final planTokens = projection.planTokens;
  final lightPresetId = _fixedPresetId(
    projection,
    mode: AppearancePresetMode.light,
    preferredId: AppearancePresetIds.licoSodaLight,
  );
  final darkPresetId = _fixedPresetId(
    projection,
    mode: AppearancePresetMode.dark,
    preferredId: AppearancePresetIds.licoSoda,
  );
  return List.unmodifiable(
    projection.presets.map((preset) {
      final mode = AppearancePresetMode.parse(preset.modeId);
      if (mode == null) {
        throw const FormatException('appearance_projection_mode_invalid');
      }
      return AppearancePresetConfig(
        schemaVersion: appearancePresetSchemaVersion,
        id: preset.id,
        label: {'en': preset.label, 'zh-CN': preset.label},
        mode: mode,
        lightPresetId: mode == AppearancePresetMode.system
            ? lightPresetId
            : null,
        darkPresetId: mode == AppearancePresetMode.system ? darkPresetId : null,
        tokens: Map.unmodifiable({
          for (final token in preset.tokens) token.name: token.value,
          ...planTokens,
        }),
      );
    }),
  );
}

String? _fixedPresetId(
  AppearanceProjection projection, {
  required AppearancePresetMode mode,
  required String preferredId,
}) {
  for (final preset in projection.presets) {
    if (preset.id == preferredId && preset.modeId == mode.id) {
      return preset.id;
    }
  }
  for (final preset in projection.presets) {
    if (preset.modeId == mode.id) return preset.id;
  }
  return null;
}
