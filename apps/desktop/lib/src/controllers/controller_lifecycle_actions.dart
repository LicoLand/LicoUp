part of 'future_client_controller.dart';

extension FutureClientControllerLifecycleActions on FutureClientController {
  Future<void> initialize() async {
    try {
      final dataDir = await portableData.dataDirectory();
      portableDataPath = dataDir.path;
      final catalog = await appearancePreferencesService.loadCatalog(
        portableData,
      );
      _applyAppearancePresetCatalog(catalog);
      appearancePresetId = await appearancePreferencesService
          .loadSelectedPresetId(portableData, appearancePresetConfigs);
      localRuntimePreferences = await localRuntimePreferencesService.load(
        portableData,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      await _refreshSecureMeshStatusSilently();
      await refreshConversationSnapshotRoot();
      await refreshPreferredSnapshotCurator();
      await _refreshLocalRuntimeStatusSilently();
      initialized = true;
      statusMessage = appearancePresetLoadErrors.isEmpty
          ? 'Future client 已就绪。'
          : 'Future client 已就绪，部分外观方案配置无效。';
      statusCaption = 'Ready';
      if (mobileRelayConfig.relayEnabled && mobileRelayConfig.hasPairing) {
        startMobileRelayPolling();
      }
    } catch (error) {
      lastError = error.toString();
      statusMessage = '初始化失败。';
      statusCaption = 'Error';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> setAppearancePreset(String presetId) async {
    if (!hasAppearancePresetConfig(presetId, appearancePresetConfigs)) {
      presetId = AppearancePresetIds.defaultSystem;
    }
    appearancePresetId = presetId;
    _notifyStateChanged();
    await appearancePreferencesService.save(portableData, presetId);
  }

  Future<void> cycleAppearancePreset() {
    return setAppearancePreset(
      nextAppearancePresetId(appearancePresetId, appearancePresetConfigs),
    );
  }

  Future<void> reloadAppearancePresets() async {
    try {
      final catalog = await appearancePreferencesService.loadCatalog(
        portableData,
      );
      _applyAppearancePresetCatalog(catalog);
      if (!hasAppearancePresetConfig(
        appearancePresetId,
        appearancePresetConfigs,
      )) {
        appearancePresetId = AppearancePresetIds.defaultSystem;
        await appearancePreferencesService.save(
          portableData,
          appearancePresetId,
        );
      }
      statusMessage = appearancePresetLoadErrors.isEmpty
          ? '外观方案已重新加载。'
          : '外观方案已重新加载，部分配置无效。';
      statusCaption = 'Appearance';
    } catch (error) {
      lastError = error.toString();
      statusMessage = '外观方案重新加载失败。';
      statusCaption = 'Error';
    } finally {
      _notifyStateChanged();
    }
  }

  void _applyAppearancePresetCatalog(
    AppearancePresetCatalogLoadResult catalog,
  ) {
    appearancePresetConfigs = catalog.configs;
    appearancePresetDirectoryPath = catalog.directory.path;
    appearancePresetLoadErrors = catalog.errors;
  }
}
