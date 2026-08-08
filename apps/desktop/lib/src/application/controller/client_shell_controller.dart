import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';

/// Owns global presentation and localized status state. Feature controllers
/// report stable codes and messages; they do not mutate shell fields directly.
final class ClientShellController extends ChangeNotifier {
  ClientShellController({
    String appearancePresetId = AppearancePresetIds.defaultSystem,
    List<AppearancePresetConfig> appearancePresetConfigs =
        builtInAppearancePresetConfigs,
    String localePreference = LocalePreference.system,
    String statusMessageChinese = '等待扫描目标适配器。',
    String statusMessageEnglish = 'Waiting to scan target adapters.',
    String statusCaption = 'LicoUp client',
  }) : _appearancePresetId = appearancePresetId,
       _appearancePresetConfigs = List.unmodifiable(appearancePresetConfigs),
       _localePreference = LocalePreference.normalize(localePreference),
       _statusMessageSource = statusMessageChinese,
       _statusMessageChinese = statusMessageChinese,
       _statusMessageEnglish = statusMessageEnglish,
       _statusCaption = statusCaption;

  static final RegExp _stableCode = RegExp(
    r'^[a-z][a-z0-9]*(?:[._:-][a-z0-9]+)*$',
  );

  final ValueNotifier<int> _presentationRevision = ValueNotifier<int>(0);
  String _appearancePresetId;
  List<AppearancePresetConfig> _appearancePresetConfigs;
  String _appearancePresetDirectoryPath = '';
  List<String> _appearancePresetLoadErrors = const [];
  String _localePreference;
  String _statusMessageSource;
  String _statusMessageChinese;
  String _statusMessageEnglish;
  String _statusCaption;
  String _lastError = '';
  String _lastErrorCode = '';

  ValueListenable<int> get presentationListenable => _presentationRevision;
  String get appearancePresetId => _appearancePresetId;
  List<AppearancePresetConfig> get appearancePresetConfigs =>
      _appearancePresetConfigs;

  /// The presets offered as picker choices: fixed light and dark themes only.
  /// System-following and resolution-only built-ins stay out of the picker.
  List<AppearancePresetConfig> get selectableAppearancePresetConfigs =>
      _appearancePresetConfigs
          .where(
            (config) =>
                !AppearancePresetIds.resolutionOnly.contains(config.id) &&
                config.mode != AppearancePresetMode.system,
          )
          .toList(growable: false);
  String get appearancePresetDirectoryPath => _appearancePresetDirectoryPath;
  List<String> get appearancePresetLoadErrors => _appearancePresetLoadErrors;
  String get localePreference => _localePreference;
  String get statusMessage => _statusMessageSource;
  String get statusCaption => _statusCaption;
  String get lastError => _lastError;
  String get lastErrorCode => _lastErrorCode;
  ClientApplicationStrings get strings =>
      ClientApplicationStrings.forPreference(_localePreference);

  String get appearancePresetLabel => findAppearancePresetConfig(
    _appearancePresetId,
    _appearancePresetConfigs,
  ).labelFor(strings.isChinese ? 'zh-CN' : 'en');

  String get displayStatusMessage =>
      strings.isChinese ? _statusMessageChinese : _statusMessageEnglish;

  String get displayStatusCaption => strings.statusCaptionLabel(_statusCaption);

  bool replaceAppearancePreset(String value) {
    final normalized =
        hasAppearancePresetConfig(value, _appearancePresetConfigs)
        ? value
        : AppearancePresetIds.defaultSystem;
    if (_appearancePresetId == normalized) return false;
    _appearancePresetId = normalized;
    _notifyPresentationChanged();
    return true;
  }

  bool replaceLocalePreference(String value) {
    final normalized = LocalePreference.normalize(value);
    if (_localePreference == normalized) return false;
    _localePreference = normalized;
    _notifyPresentationChanged();
    return true;
  }

  bool applyAppearanceCatalog({
    required List<AppearancePresetConfig> configs,
    required String directoryPath,
    Iterable<String> errorCodes = const [],
  }) {
    _appearancePresetConfigs = List.unmodifiable(
      mergeAppearancePresetConfigs(configs),
    );
    _appearancePresetDirectoryPath = directoryPath;
    _appearancePresetLoadErrors = List.unmodifiable(
      errorCodes.map(_safeCode).where((code) => code.isNotEmpty),
    );
    final fellBack = !hasAppearancePresetConfig(
      _appearancePresetId,
      _appearancePresetConfigs,
    );
    if (fellBack) {
      _appearancePresetId = AppearancePresetIds.defaultSystem;
    }
    _notifyPresentationChanged();
    return fellBack;
  }

  void setLocalizedStatus(
    String chinese,
    String english, {
    required String caption,
    String errorCode = '',
    String? displayChinese,
  }) {
    _statusMessageSource = chinese;
    _statusMessageChinese = displayChinese ?? chinese;
    _statusMessageEnglish = english;
    _statusCaption = caption;
    if (errorCode.isNotEmpty) {
      _lastError = errorCode;
      _lastErrorCode = _safeCode(errorCode);
    }
    notifyListeners();
  }

  void replaceStatusMessage(String value) {
    _statusMessageSource = value;
    _statusMessageChinese = value;
    _statusMessageEnglish = value;
    notifyListeners();
  }

  void replaceStatusCaption(String value) {
    _statusCaption = value;
    notifyListeners();
  }

  void replaceLastError(String value) {
    _lastError = value;
    _lastErrorCode = _safeCode(value);
    notifyListeners();
  }

  void notifyPresentationChanged() => _notifyPresentationChanged();

  void _notifyPresentationChanged() {
    _presentationRevision.value += 1;
    notifyListeners();
  }

  static String _safeCode(String value) {
    final normalized = value.trim().toLowerCase();
    return _stableCode.hasMatch(normalized) ? normalized : '';
  }

  @override
  void dispose() {
    _presentationRevision.dispose();
    super.dispose();
  }
}
