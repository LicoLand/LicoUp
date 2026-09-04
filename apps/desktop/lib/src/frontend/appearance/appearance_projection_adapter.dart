import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

/// Adapts renderer-independent appearance values to the existing Flutter
/// theme model without exposing Application-owned configuration objects.
List<AppearancePresetConfig> appearancePresetConfigsFromProjection(
  AppearanceProjection projection,
) {
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
