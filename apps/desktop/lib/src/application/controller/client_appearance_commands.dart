import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/application/controller/appearance_preference_owner.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/platform/appearance/appearance_preset_catalog_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Appearance-only commands and state access.
mixin ClientAppearanceCommands {
  AppearancePreferenceOwner get appearancePreferenceOwner;
  LayoutManager get layoutManager;
  PortableDataRoot get portableData;
  AppearancePresetCatalogService get appearancePresetCatalogService;
  void reportAppearanceReloadOutcome({required bool hasErrors});
  void reportAppearanceReloadFailure();

  String get appearancePresetId => appearancePreferenceOwner.presetId;
  set appearancePresetId(String value) {
    appearancePreferenceOwner.replacePreset(value);
  }

  List<AppearancePresetConfig> get appearancePresetConfigs =>
      appearancePreferenceOwner.presets;
  List<AppearancePresetConfig> get selectableAppearancePresetConfigs =>
      appearancePreferenceOwner.selectablePresets;
  String get appearancePresetDirectoryPath =>
      appearancePreferenceOwner.directoryPath;
  List<String> get appearancePresetLoadErrors =>
      appearancePreferenceOwner.loadErrors;

  Future<void> setAppearancePreset(
    String presetId, {
    ApplicationCause? cause,
  }) async {
    if (!hasAppearancePresetConfig(presetId, appearancePresetConfigs)) {
      presetId = AppearancePresetIds.licoSoda;
    }
    if (await layoutManager.setAppearancePreset(presetId, cause: cause)) {
      appearancePreferenceOwner.replacePreset(presetId, cause: cause);
    }
  }

  Future<void> reloadAppearancePresets() async {
    try {
      final catalog = await appearancePresetCatalogService.loadCatalog(
        portableData,
      );
      final fellBack = applyAppearancePresetCatalog(catalog);
      if (fellBack) {
        await layoutManager.setAppearancePreset(appearancePresetId);
      }
      reportAppearanceReloadOutcome(
        hasErrors: appearancePresetLoadErrors.isNotEmpty,
      );
    } catch (_) {
      reportAppearanceReloadFailure();
    }
  }

  bool applyAppearancePresetCatalog(AppearancePresetCatalogLoadResult catalog) {
    return appearancePreferenceOwner.applyCatalog(
      configs: catalog.configs,
      directoryPath: catalog.directory.path,
      errorCodes: catalog.errors,
    );
  }
}
