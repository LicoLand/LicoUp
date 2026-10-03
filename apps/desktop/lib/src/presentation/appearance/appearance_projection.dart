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
    this.reduceMotion = false,
    this.loadingEffectId = 'spinner',
    this.planTokens = const {},
    this.planFallbackReason,
    required Iterable<AppearancePresetProjection> presets,
  }) : presets = immutablePresentationList(presets);

  final String presetId;
  final String fontPreference;
  final bool reduceMotion;
  final String loadingEffectId;
  final List<AppearancePresetProjection> presets;

  /// Token roles a published appearance resource supplied, if any.
  ///
  /// Empty while the client renders its built-in appearance, so the renderer
  /// needs no separate "which appearance" branch.
  final Map<String, String> planTokens;

  /// Why the declared default is serving instead of a selected resource, when
  /// a published plan recorded a fallback.
  final String? planFallbackReason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearanceProjection &&
          other.presetId == presetId &&
          other.fontPreference == fontPreference &&
          other.reduceMotion == reduceMotion &&
          other.loadingEffectId == loadingEffectId &&
          other.planFallbackReason == planFallbackReason &&
          samePresentationMap(other.planTokens, planTokens) &&
          samePresentationList(other.presets, presets);

  @override
  int get hashCode => Object.hash(
    presetId,
    fontPreference,
    reduceMotion,
    loadingEffectId,
    planFallbackReason,
    Object.hashAll(
      planTokens.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    Object.hashAll(presets),
  );
}
