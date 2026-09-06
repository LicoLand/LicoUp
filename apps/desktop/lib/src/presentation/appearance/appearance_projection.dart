import 'package:licoup/src/presentation/presentation_semantics.dart';

final class AppearanceTokenProjection {
  const AppearanceTokenProjection({required this.name, required this.value});

  final String name;
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearanceTokenProjection &&
          other.name == name &&
          other.value == value;

  @override
  int get hashCode => Object.hash(name, value);
}

final class AppearancePresetProjection {
  AppearancePresetProjection({
    required this.id,
    required this.label,
    required this.modeId,
    required Iterable<AppearanceTokenProjection> tokens,
  }) : tokens = immutablePresentationList(tokens);

  final String id;
  final String label;
  final String modeId;
  final List<AppearanceTokenProjection> tokens;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearancePresetProjection &&
          other.id == id &&
          other.label == label &&
          other.modeId == modeId &&
          samePresentationList(other.tokens, tokens);

  @override
  int get hashCode => Object.hash(id, label, modeId, Object.hashAll(tokens));
}

final class AppearanceProjection {
  AppearanceProjection({
    required this.presetId,
    this.fontPreference = 'system',
    required Iterable<AppearancePresetProjection> presets,
  }) : presets = immutablePresentationList(presets);

  final String presetId;
  final String fontPreference;
  final List<AppearancePresetProjection> presets;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearanceProjection &&
          other.presetId == presetId &&
          other.fontPreference == fontPreference &&
          samePresentationList(other.presets, presets);

  @override
  int get hashCode =>
      Object.hash(presetId, fontPreference, Object.hashAll(presets));
}
