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
    bool reduceMotion = false,
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
      reduceMotion: reduceMotion,
    );
  }

  factory PresentationPreferences.fromJson(
    Map<String, Object?> json, {
    required PresentationPreferences fallback,
  }) {
    final schema = json['schemaVersion'];
    if (schema != schemaVersion) {
      throw const FormatException('presentation_schema_unsupported');
    }
    final rawLayout = json['layoutProfileId'];
    final rawAppearance = json['appearancePresetId'];
    final rawLocale = json['localePreference'];
    final rawReduceMotion = json['reduceMotion'];
    return PresentationPreferences(
      layoutProfileId: rawLayout is String && rawLayout.trim().isNotEmpty
          ? LayoutProfileId.parse(resolveLegacyLayoutProfileId(rawLayout))
          : fallback.layoutProfileId,
      appearancePresetId:
          rawAppearance is String && rawAppearance.trim().isNotEmpty
          ? rawAppearance
          : fallback.appearancePresetId,
      localePreference: rawLocale is String && rawLocale.trim().isNotEmpty
          ? rawLocale
          : fallback.localePreference,
      reduceMotion: rawReduceMotion is bool ? rawReduceMotion : false,
    );
  }

  const PresentationPreferences._({
    required this.layoutProfileId,
    required this.appearancePresetId,
    required this.localePreference,
    required this.reduceMotion,
  });

  static const schemaVersion = 1;

  /// Read-side one-time id aliases for documents persisted before the
  /// dashboard/desktop profile rename.
  ///
  /// Only values the current write path can never produce are remapped, so a
  /// canonical document always round-trips: the retired Default/messaging id
  /// moves to the renamed dashboard profile. The former dashboard profile id
  /// ('dashboard') is intentionally not aliased: after the rename it is the
  /// canonical id of the new default profile, and remapping it to 'desktop'
  /// would silently flip users who saved the current default. Legacy
  /// old-dashboard documents are byte-identical to canonical default
  /// documents, so they resolve to the current Dashboard default.
  static const Map<String, String> legacyLayoutProfileIdAliases = {
    'messaging': 'dashboard',
  };

  /// Resolves a persisted layout id to its canonical profile id, leaving
  /// every non-retired value unchanged.
  static String resolveLegacyLayoutProfileId(String raw) {
    final normalized = raw.trim();
    return legacyLayoutProfileIdAliases[normalized] ?? normalized;
  }

  final LayoutProfileId layoutProfileId;
  final String appearancePresetId;
  final String localePreference;
  final bool reduceMotion;

  PresentationPreferences copyWith({
    LayoutProfileId? layoutProfileId,
    String? appearancePresetId,
    String? localePreference,
    bool? reduceMotion,
  }) {
    return PresentationPreferences(
      layoutProfileId: layoutProfileId ?? this.layoutProfileId,
      appearancePresetId: appearancePresetId ?? this.appearancePresetId,
      localePreference: localePreference ?? this.localePreference,
      reduceMotion: reduceMotion ?? this.reduceMotion,
    );
  }

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'layoutProfileId': layoutProfileId.value,
    'appearancePresetId': appearancePresetId,
    'localePreference': localePreference,
    'reduceMotion': reduceMotion,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationPreferences &&
          other.layoutProfileId == layoutProfileId &&
          other.appearancePresetId == appearancePresetId &&
          other.localePreference == localePreference &&
          other.reduceMotion == reduceMotion;

  @override
  int get hashCode => Object.hash(
    layoutProfileId,
    appearancePresetId,
    localePreference,
    reduceMotion,
  );
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

  Future<PresentationPreferences> setReduceMotion(bool enabled);
}
