import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/presentation_plan_appearance.dart';

/// Owns appearance preference and catalog state independently of locale and
/// functional status.
final class AppearancePreferenceOwner extends ApplicationStateOwner {
  AppearancePreferenceOwner({
    String presetId = AppearancePresetIds.licoSoda,
    bool reduceMotion = false,
    List<AppearancePresetConfig> presets = builtInAppearancePresetConfigs,
  }) : _presetId = presetId,
       _reduceMotion = reduceMotion,
       _presets = List.unmodifiable(presets);

  String _presetId;
  bool _reduceMotion;
  String _loadingEffectId = 'spinner';
  String get loadingEffectId => _loadingEffectId;
  String _fontPreference = 'system';
  List<AppearancePresetConfig> _presets;
  String _directoryPath = '';
  List<String> _loadErrors = const [];
  PresentationPlanAppearance? _planAppearance;

  String get presetId => _presetId;
  bool get reduceMotion => _reduceMotion;
  String get fontPreference => _fontPreference;
  List<AppearancePresetConfig> get presets => _presets;
  List<AppearancePresetConfig> get selectablePresets => _presets
      .where(
        (config) =>
            !AppearancePresetIds.resolutionOnly.contains(config.id) &&
            config.mode != AppearancePresetMode.system,
      )
      .toList(growable: false);
  String get directoryPath => _directoryPath;
  List<String> get loadErrors => _loadErrors;

  /// The appearance the native mount plan projects, or `null` while no plan is
  /// published and the client renders its built-in appearance.
  PresentationPlanAppearance? get planAppearance => _planAppearance;

  /// Adopts the appearance a published native mount plan resolved.
  ///
  /// The caller resolved it through the host registry, so this owner stores the
  /// projection instead of interpreting a plan document. Passing `null`
  /// withdraws it and returns rendering to the built-in appearance.
  bool replacePlanAppearance(
    PresentationPlanAppearance? appearance, {
    ApplicationCause? cause,
  }) {
    if (_planAppearance == appearance) return false;
    _planAppearance = appearance;
    publishChange(cause);
    return true;
  }

  bool replacePreset(String value, {ApplicationCause? cause}) {
    final normalized = hasAppearancePresetConfig(value, _presets)
        ? value
        : AppearancePresetIds.licoSoda;
    if (_presetId == normalized) return false;
    _presetId = normalized;
    publishChange(cause);
    return true;
  }

  bool replaceFontPreference(String value, {ApplicationCause? cause}) {
    final normalized = value.trim().isEmpty ? 'system' : value.trim();
    if (_fontPreference == normalized) return false;
    _fontPreference = normalized;
    publishChange(cause);
    return true;
  }

  bool replaceReduceMotion(bool value, {ApplicationCause? cause}) {
    if (_reduceMotion == value) return false;
    _reduceMotion = value;
    publishChange(cause);
    return true;
  }

  bool replaceLoadingEffect(String id, {ApplicationCause? cause}) {
    if (_loadingEffectId == id) return false;
    _loadingEffectId = id;
    publishChange(cause);
    return true;
  }

  bool applyCatalog({
    required List<AppearancePresetConfig> configs,
    required String directoryPath,
    Iterable<String> errorCodes = const [],
  }) {
    _presets = List.unmodifiable(mergeAppearancePresetConfigs(configs));
    _directoryPath = directoryPath;
    _loadErrors = List.unmodifiable(
      errorCodes.map(_safeCode).where((code) => code.isNotEmpty),
    );
    final fellBack = !hasAppearancePresetConfig(_presetId, _presets);
    if (fellBack) _presetId = AppearancePresetIds.licoSoda;
    publishChange();
    return fellBack;
  }

  static final RegExp _stableCode = RegExp(
    r'^[a-z][a-z0-9]*(?:[._:-][a-z0-9]+)*$',
  );

  static String _safeCode(String value) {
    final normalized = value.trim().toLowerCase();
    return _stableCode.hasMatch(normalized) ? normalized : '';
  }
}
