import 'layout_profile.dart';

final class PresentationPreferences {
  const PresentationPreferences({
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
}
