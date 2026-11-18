import 'dart:collection';

import 'appearance_resource_state.dart';
import 'layout_profile.dart';
import 'layout_style.dart';
import 'reduce_motion_preference.dart';

export 'reduce_motion_preference.dart' show ReduceMotionPreference;

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
    ReduceMotionPreference reduceMotion = ReduceMotionPreference.system,
    String loadingEffectId = 'spinner',
    Map<LayoutProfileId, LayoutStyleId> layoutStyleIds = const {},
    Map<String, PresentationResourceSelection> resourceSelections = const {},
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
      loadingEffectId: loadingEffectId,
      layoutStyleIds: UnmodifiableMapView(
        Map<LayoutProfileId, LayoutStyleId>.of(layoutStyleIds),
      ),
      resourceSelections:
          Map<String, PresentationResourceSelection>.unmodifiable(
            Map<String, PresentationResourceSelection>.of(resourceSelections),
          ),
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
    final rawStyleIds = json['layoutStyleIds'];
    final layoutStyleIds = <LayoutProfileId, LayoutStyleId>{};
    // Additive schema-1 field: a missing or malformed member never fails the
    // document — each entry is validated independently and dropped on error.
    if (rawStyleIds is Map) {
      for (final entry in rawStyleIds.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) {
          continue;
        }
        try {
          layoutStyleIds[LayoutProfileId.parse(
            resolveLegacyLayoutProfileId(key),
          )] = LayoutStyleId.parse(
            value,
          );
        } on FormatException {
          continue;
        }
      }
    }
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
      reduceMotion: ReduceMotionPreference.parse(rawReduceMotion),
      loadingEffectId: json['loadingEffectId'] is String
          ? json['loadingEffectId']! as String
          : 'spinner',
      layoutStyleIds: layoutStyleIds,
      resourceSelections: readResourceSelections(json['resourceSelections']),
    );
  }

  /// Reads the stored resource requests strictly.
  ///
  /// A key this build does not know is kept with the identity it was written
  /// with, so a newer client's request survives an older client's write. A
  /// value this build cannot read refuses the document instead of being
  /// dropped or reinterpreted: an unreadable request is not a different
  /// request.
  static Map<String, PresentationResourceSelection> readResourceSelections(
    Object? value,
  ) => readPresentationResourceSelections(value);

  const PresentationPreferences._({
    required this.layoutProfileId,
    required this.appearancePresetId,
    required this.localePreference,
    required this.reduceMotion,
    required this.loadingEffectId,
    required this.layoutStyleIds,
    required this.resourceSelections,
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
  final ReduceMotionPreference reduceMotion;
  final String loadingEffectId;

  /// Per-profile column-style choices. Entries for profiles that declare no
  /// styles are inert: the effective style always comes from the profile's
  /// declared styles or default.
  final Map<LayoutProfileId, LayoutStyleId> layoutStyleIds;

  /// The resource the user asked this client to serve, per resource kind id.
  ///
  /// An absent kind is not "unavailable" and not "the declared default was
  /// chosen": it records no request for that kind. The map is the only durable
  /// owner of a resource request; whether the request is served is the package
  /// owner's answer and is never written here.
  final Map<String, PresentationResourceSelection> resourceSelections;

  /// The stored request for one kind, if the user made one.
  PresentationResourceSelection? resourceSelection(
    PresentationResourceKind kind,
  ) => resourceSelections[kind.id];

  PresentationPreferences copyWith({
    LayoutProfileId? layoutProfileId,
    String? appearancePresetId,
    String? localePreference,
    ReduceMotionPreference? reduceMotion,
    String? loadingEffectId,
    Map<LayoutProfileId, LayoutStyleId>? layoutStyleIds,
    Map<String, PresentationResourceSelection>? resourceSelections,
  }) {
    return PresentationPreferences(
      layoutProfileId: layoutProfileId ?? this.layoutProfileId,
      appearancePresetId: appearancePresetId ?? this.appearancePresetId,
      localePreference: localePreference ?? this.localePreference,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      loadingEffectId: loadingEffectId ?? this.loadingEffectId,
      layoutStyleIds: layoutStyleIds ?? this.layoutStyleIds,
      resourceSelections: resourceSelections ?? this.resourceSelections,
    );
  }

  /// Records, or clears, one kind's request.
  ///
  /// Clearing means the user asked for the client's own declared default; it is
  /// not a fallback and leaves no entry behind.
  PresentationPreferences withResourceSelection(
    PresentationResourceKind kind,
    PresentationResourceSelection? selection,
  ) {
    final next = Map<String, PresentationResourceSelection>.of(
      resourceSelections,
    );
    if (selection == null) {
      next.remove(kind.id);
    } else {
      next[kind.id] = selection;
    }
    return copyWith(resourceSelections: next);
  }

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'layoutProfileId': layoutProfileId.value,
    'appearancePresetId': appearancePresetId,
    'localePreference': localePreference,
    'reduceMotion': reduceMotion.name,
    'loadingEffectId': loadingEffectId,
    'layoutStyleIds': {
      for (final entry in layoutStyleIds.entries)
        entry.key.value: entry.value.value,
    },
    // Omitted while no resource request is recorded, so a document that never
    // made one keeps the shape the previous release wrote.
    if (resourceSelections.isNotEmpty)
      'resourceSelections': <String, Object>{
        for (final key in _sortedResourceKeys(resourceSelections))
          key: resourceSelections[key]!.toJson(),
      },
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationPreferences &&
          other.layoutProfileId == layoutProfileId &&
          other.appearancePresetId == appearancePresetId &&
          other.localePreference == localePreference &&
          other.reduceMotion == reduceMotion &&
          other.loadingEffectId == loadingEffectId &&
          _sameStyleIdMap(other.layoutStyleIds, layoutStyleIds) &&
          _sameResourceSelections(other.resourceSelections, resourceSelections);

  @override
  int get hashCode => Object.hash(
    layoutProfileId,
    appearancePresetId,
    localePreference,
    reduceMotion,
    loadingEffectId,
    Object.hashAllUnordered(
      layoutStyleIds.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
    Object.hashAll(
      _sortedResourceKeys(
        resourceSelections,
      ).map((key) => Object.hash(key, resourceSelections[key])),
    ),
  );

  static bool _sameStyleIdMap(
    Map<LayoutProfileId, LayoutStyleId> left,
    Map<LayoutProfileId, LayoutStyleId> right,
  ) =>
      left.length == right.length &&
      left.entries.every((entry) => right[entry.key] == entry.value);
}

List<String> _sortedResourceKeys(
  Map<String, PresentationResourceSelection> selections,
) => selections.keys.toList(growable: false)..sort();

bool _sameResourceSelections(
  Map<String, PresentationResourceSelection> left,
  Map<String, PresentationResourceSelection> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
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

  Future<PresentationPreferences> setLayoutStyle(
    LayoutProfileId profile,
    LayoutStyleId style,
  );

  Future<PresentationPreferences> setAppearancePreset(String id);

  Future<PresentationPreferences> setLocalePreference(String preference);

  Future<PresentationPreferences> setReduceMotion(
    ReduceMotionPreference preference,
  );

  Future<PresentationPreferences> setLoadingEffect(String id);

  Future<PresentationPreferences> setResourceSelection(
    PresentationResourceKind kind,
    PresentationResourceSelection? selection,
  );
}
