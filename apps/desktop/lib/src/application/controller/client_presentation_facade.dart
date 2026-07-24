import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:licoup/src/application/controller/client_conversation_facade.dart';
import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/platform/appearance/appearance_preset_catalog_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

mixin ClientPresentationFacade
    on AgentWorkspaceCoordinator, ClientConversationFacade {
  ClientShellController get shellController;
  LayoutManager get layoutManager;
  PortableDataRoot get portableData;
  AppearancePresetCatalogService get appearancePresetCatalogService;

  String get appearancePresetId => shellController.appearancePresetId;
  set appearancePresetId(String value) {
    shellController.replaceAppearancePreset(value);
  }

  String get localePreference => shellController.localePreference;
  set localePreference(String value) {
    shellController.replaceLocalePreference(value);
  }

  List<AppearancePresetConfig> get appearancePresetConfigs =>
      shellController.appearancePresetConfigs;
  String get appearancePresetDirectoryPath =>
      shellController.appearancePresetDirectoryPath;
  List<String> get appearancePresetLoadErrors =>
      shellController.appearancePresetLoadErrors;

  @override
  String get statusMessage => shellController.statusMessage;
  @override
  set statusMessage(String value) {
    shellController.replaceStatusMessage(value);
  }

  @override
  String get statusCaption => shellController.statusCaption;
  @override
  set statusCaption(String value) {
    shellController.replaceStatusCaption(value);
  }

  @override
  String get lastError => shellController.lastError;
  @override
  set lastError(String value) {
    shellController.replaceLastError(value);
  }

  ValueListenable<int> get appPresentationListenable =>
      shellController.presentationListenable;
  String get appearancePresetLabel => shellController.appearancePresetLabel;
  String get displayStatusMessage => shellController.displayStatusMessage;
  String get displayStatusCaption => shellController.displayStatusCaption;
  ClientApplicationStrings get clientStrings => shellController.strings;

  void notifyAppPresentationChanged() {
    if (!lifecycleProjection.disposed) {
      shellController.notifyPresentationChanged();
    }
  }

  void setLocalizedStatusMessage(
    String chinese,
    String english, {
    String? displayChinese,
  }) {
    shellController.setLocalizedStatus(
      chinese,
      english,
      caption: statusCaption,
      displayChinese: displayChinese,
    );
  }

  Future<void> setAppearancePreset(String presetId) async {
    if (!hasAppearancePresetConfig(presetId, appearancePresetConfigs)) {
      presetId = AppearancePresetIds.defaultSystem;
    }
    if (await layoutManager.setAppearancePreset(presetId)) {
      appearancePresetId = presetId;
    }
  }

  Future<void> setLocalePreference(String value) async {
    final normalized = LocalePreference.normalize(value);
    if (await layoutManager.setLocalePreference(normalized)) {
      localePreference = normalized;
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
      setLocalizedStatusMessage(
        appearancePresetLoadErrors.isEmpty ? '外观方案已重新加载。' : '外观方案已重新加载，部分配置无效。',
        appearancePresetLoadErrors.isEmpty
            ? 'Appearance presets reloaded.'
            : 'Appearance presets reloaded, but some configurations are invalid.',
      );
      statusCaption = 'Appearance';
    } catch (_) {
      lastError = 'appearance_preset_reload_failed';
      setLocalizedStatusMessage(
        '外观方案重新加载失败。',
        'Failed to reload appearance presets.',
      );
      statusCaption = 'Error';
    } finally {
      notifyAppPresentationChanged();
      notifyClientStateChanged();
    }
  }

  bool applyAppearancePresetCatalog(AppearancePresetCatalogLoadResult catalog) {
    return shellController.applyAppearanceCatalog(
      configs: catalog.configs,
      directoryPath: catalog.directory.path,
      errorCodes: catalog.errors,
    );
  }

  @override
  ClientApplicationStrings get agentWorkspaceStrings => clientStrings;

  @override
  void agentWorkspaceSetLocalizedStatusMessage(
    String chinese,
    String english, {
    String? displayChinese,
  }) => setLocalizedStatusMessage(
    chinese,
    english,
    displayChinese: displayChinese,
  );
}
