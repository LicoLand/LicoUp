import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';

/// Owns appearance preference and catalog state independently of locale and
/// functional status.
final class AppearancePreferenceOwner extends ApplicationStateOwner {
  AppearancePreferenceOwner({
    String presetId = AppearancePresetIds.licoSoda,
    List<AppearancePresetConfig> presets = builtInAppearancePresetConfigs,
  }) : _presetId = presetId,
       _presets = List.unmodifiable(presets);

  String _presetId;
  String _fontPreference = 'system';
  List<AppearancePresetConfig> _presets;
  String _directoryPath = '';
  List<String> _loadErrors = const [];

  String get presetId => _presetId;
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
