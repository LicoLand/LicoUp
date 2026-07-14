import 'layout_profile.dart';

enum PresentationPreferencesLoadIssue { invalidDocument }

enum PresentationPreferencesRepositoryErrorCode { readFailed, writeFailed }

final class PresentationPreferencesRepositoryException implements Exception {
  const PresentationPreferencesRepositoryException(this.code);

  final PresentationPreferencesRepositoryErrorCode code;

  @override
  String toString() =>
      'PresentationPreferencesRepositoryException(${code.name})';
}

final class PresentationPreferences {
  factory PresentationPreferences({
    required LayoutProfileId layoutProfileId,
    required String appearancePresetId,
    required String localePreference,
  }) {
    final appearance = appearancePresetId.trim();
    final locale = localePreference.trim();
    if (appearance.isEmpty) {
      throw const FormatException('presentation_appearance_id_missing');
    }
    if (locale.isEmpty) {
      throw const FormatException('presentation_locale_missing');
    }
    return PresentationPreferences._(
      layoutProfileId: layoutProfileId,
      appearancePresetId: appearance,
      localePreference: locale,
    );
  }

  factory PresentationPreferences.fromJson(
    Map<String, Object?> json, {
    required PresentationPreferences fallback,
  }) {
    final schema = json['schemaVersion'];
    if (schema != null && schema != schemaVersion) {
      throw const FormatException('presentation_schema_unsupported');
    }
    final rawLayout = json['layoutProfileId'];
    final rawAppearance = json['appearancePresetId'];
    final rawLocale = json['localePreference'];
    return PresentationPreferences(
      layoutProfileId: rawLayout is String && rawLayout.trim().isNotEmpty
          ? LayoutProfileId.parse(rawLayout)
          : fallback.layoutProfileId,
      appearancePresetId:
          rawAppearance is String && rawAppearance.trim().isNotEmpty
          ? rawAppearance
          : fallback.appearancePresetId,
      localePreference: rawLocale is String && rawLocale.trim().isNotEmpty
          ? rawLocale
          : fallback.localePreference,
    );
  }

  const PresentationPreferences._({
    required this.layoutProfileId,
    required this.appearancePresetId,
    required this.localePreference,
  });

  static const schemaVersion = 1;

  final LayoutProfileId layoutProfileId;
  final String appearancePresetId;
  final String localePreference;

  PresentationPreferences copyWith({
    LayoutProfileId? layoutProfileId,
    String? appearancePresetId,
    String? localePreference,
  }) {
    return PresentationPreferences(
      layoutProfileId: layoutProfileId ?? this.layoutProfileId,
      appearancePresetId: appearancePresetId ?? this.appearancePresetId,
      localePreference: localePreference ?? this.localePreference,
    );
  }

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'layoutProfileId': layoutProfileId.value,
    'appearancePresetId': appearancePresetId,
    'localePreference': localePreference,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationPreferences &&
          other.layoutProfileId == layoutProfileId &&
          other.appearancePresetId == appearancePresetId &&
          other.localePreference == localePreference;

  @override
  int get hashCode =>
      Object.hash(layoutProfileId, appearancePresetId, localePreference);
}

final class PresentationPreferencesLoadResult {
  const PresentationPreferencesLoadResult({
    required this.preferences,
    this.issue,
  });

  final PresentationPreferences preferences;
  final PresentationPreferencesLoadIssue? issue;

  bool get recovered => issue != null;
}

abstract interface class PresentationPreferencesRepository {
  Future<PresentationPreferencesLoadResult> load();

  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id);

  Future<PresentationPreferences> setAppearancePreset(String id);

  Future<PresentationPreferences> setLocalePreference(String preference);
}
