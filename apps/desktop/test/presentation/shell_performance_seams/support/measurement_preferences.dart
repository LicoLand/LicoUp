import 'package:licoup/src/contracts/presentation/appearance_resource_state.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';

/// Presentation preferences a measurement owns instead of the developer.
///
/// A counted or deterministic test installs this through the real controller,
/// so the run never reads and never writes the presentation preferences of the
/// machine it happens to run on. It keeps no history and writes nowhere.
final class MeasurementPreferences
    implements PresentationPreferencesRepository {
  MeasurementPreferences(this._preferences);

  PresentationPreferences _preferences;

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: _preferences);

  @override
  Future<PresentationPreferences> setReduceMotion(
    ReduceMotionPreference preference,
  ) async => _preferences = _preferences.copyWith(reduceMotion: preference);

  @override
  Future<PresentationPreferences> setLoadingEffect(String id) async =>
      _preferences = _preferences.copyWith(loadingEffectId: id);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      _preferences = _preferences.copyWith(appearancePresetId: id);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      _preferences = _preferences.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLayoutStyle(
    LayoutProfileId profile,
    LayoutStyleId style,
  ) async => _preferences = _preferences.copyWith(
    layoutStyleIds: {..._preferences.layoutStyleIds, profile: style},
  );

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => _preferences = _preferences.copyWith(localePreference: preference);

  @override
  Future<PresentationPreferences> setResourceSelection(
    PresentationResourceKind kind,
    PresentationResourceSelection? selection,
  ) async => _preferences = _preferences.withResourceSelection(kind, selection);
}
