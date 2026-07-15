part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientControllerLifecycleActions on ClientController {
  Future<void> initialize() async {
    try {
      final dataDir = await portableData.dataDirectory();
      portableDataPath = dataDir.path;
      final catalog = await appearancePresetCatalogService.loadCatalog(
        portableData,
      );
      _applyAppearancePresetCatalog(catalog);
      await layoutManager.initialize();
      final presentation = layoutManager.preferences;
      appearancePresetId =
          presentation?.appearancePresetId ?? AppearancePresetIds.defaultSystem;
      if (!hasAppearancePresetConfig(
        appearancePresetId,
        appearancePresetConfigs,
      )) {
        appearancePresetId = AppearancePresetIds.defaultSystem;
        await layoutManager.setAppearancePreset(appearancePresetId);
      }
      localePreference = LocalePreference.normalize(
        presentation?.localePreference ?? LocalePreference.system,
      );
      agentTabOrder = await agentTabOrderStore.load(portableData);
      await _hydrateScannedTargetsCache();
      await _ensureRoutingModuleReady(rootDirectory: dataDir);
      localRuntimePreferences = await localRuntimePreferencesStore.load(
        portableData,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
        authorizeSecrets: false,
      );
      mobileAgentAccounts = await mobileAgentAccountService.load(portableData);
      await loadMobileProviderConversations();
      syncMobileAgentAccountsWithDesktopRelay();
      await _writeMobileProviderSyncDiagnostic('initialize_loaded');
      mobileHomeLayout = await mobileHomeLayoutService.load(portableData);
      skillHubPreferences = await skillHubPreferencesService.load(portableData);
      await loadFeedTimeline();

      // Notify readiness early so first paint is not gated on heavy scans,
      // then finish desktop bootstrap loads in parallel before initialize ends.
      initialized = true;
      _setLocalizedStatusMessage(
        appearancePresetLoadErrors.isEmpty
            ? 'LicoArc client 已就绪。'
            : 'LicoArc client 已就绪，部分外观方案配置无效。',
        appearancePresetLoadErrors.isEmpty
            ? 'LicoArc client is ready.'
            : 'LicoArc client is ready, but some appearance preset configurations are invalid.',
        displayChinese: appearancePresetLoadErrors.isEmpty
            ? '客户端已就绪。'
            : '客户端已就绪，但部分外观方案配置无效。',
      );
      statusCaption = 'Ready';
      _notifyAppPresentationChanged();
      _notifyStateChanged();

      if (!_mobileClientRuntimePlatform) {
        await _bootstrapDesktopBackgroundLoads();
      }
    } catch (error) {
      lastError = error.toString();
      _setLocalizedStatusMessage('初始化失败。', 'Initialization failed.');
      statusCaption = 'Error';
      initialized = false;
      _notifyStateChanged();
    }
  }

  Future<void> _bootstrapDesktopBackgroundLoads() async {
    await Future.wait<void>([
      _runBootstrapStep(
        'refresh conversation snapshot root',
        refreshConversationSnapshotRoot,
      ),
      _runBootstrapStep(
        'refresh preferred snapshot curator',
        refreshPreferredSnapshotCurator,
      ),
      _runBootstrapStep(
        'refresh local runtime status',
        _refreshLocalRuntimeStatusSilently,
      ),
      _runBootstrapStep('ensure OpenCode serve', _ensureOpencodeServeSilently),
      _runBootstrapStep(
        'scan targets',
        () => scanTargets(showProgress: false, surfaceErrors: true),
      ),
      _runBootstrapStep('refresh feed posts', refreshFeedPosts),
      _runBootstrapStep(
        'load agent usage',
        () => ensureAgentUsageLoadedAndFresh(limit: 20),
      ),
    ]);
    if (_disposed) {
      return;
    }
    startAgentUsagePolling();
    final agentId = selectedConversationAgentId.trim();
    if (agentId.isNotEmpty &&
        !selectedConversationIsOrchestration &&
        !_mobileClientRuntimePlatform) {
      unawaited(loadConversationSessions(agentId));
    }
  }

  Future<void> _runBootstrapStep(
    String label,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      debugPrint('Failed to $label during bootstrap: $error');
    }
  }

  Future<void> _ensureOpencodeServeSilently() async {
    try {
      opencodeServeState = await agentService.ensureOpencodeServe();
      final status = (opencodeServeState?['status'] as String?)?.trim() ?? '';
      final running = opencodeServeState?['ok'] == true;
      if (!running) {
        final code =
            (opencodeServeState?['errorCode'] as String?)?.trim() ??
            'opencode_serve_unavailable';
        debugPrint('OpenCode serve bootstrap status=$status code=$code');
      }
    } catch (error) {
      opencodeServeState = <String, dynamic>{
        'ok': false,
        'status': 'unavailable',
        'errorCode': 'opencode_serve_unavailable',
      };
      debugPrint('Failed to ensure OpenCode serve during bootstrap: $error');
    }
  }

  Future<void> _stopOpencodeServeSilently() async {
    try {
      opencodeServeState = await agentService.stopOpencodeServe();
    } catch (error) {
      debugPrint('Failed to stop OpenCode serve during shutdown: $error');
    }
  }

  Future<RoutingModuleRegistration> _ensureRoutingModuleReady({
    Directory? rootDirectory,
  }) async {
    final existing = _routingModule;
    if (existing != null && (existing.isReady || !existing.isEnabled)) {
      return existing;
    }
    final dataDir = rootDirectory ?? await portableData.dataDirectory();
    final registration = createRoutingModuleRegistration(
      rootDirectory: dataDir,
    );
    await registration.activate();
    _routingModule = registration;
    agentOrchestrationPolicy = orchestrationEditorFromRoutingPolicy(
      registration.activePolicy,
    );
    await _bindRoutingModulePolicyEvents(registration);
    return registration;
  }

  Future<void> _bindRoutingModulePolicyEvents(
    RoutingModuleRegistration registration,
  ) async {
    await _routingPolicySubscription?.cancel();
    _routingPolicySubscription = registration.policyEvents.listen((event) {
      switch (event) {
        case RoutingPolicyStoreLoaded(:final document):
          agentOrchestrationPolicy = orchestrationEditorFromRoutingPolicy(
            document,
          );
          _syncAgentOrchestrationPolicy();
          _notifyStateChanged();
          final taskId = _activeOrchestrationTaskId;
          final coordinator = registration.coordinator;
          if (taskId.isNotEmpty && coordinator?.sessionFor(taskId) != null) {
            coordinator!.queuePolicy(document);
          }
        case RoutingPolicyStoreReloaded(:final document):
          agentOrchestrationPolicy = orchestrationEditorFromRoutingPolicy(
            document,
          );
          _syncAgentOrchestrationPolicy();
          _notifyStateChanged();
          final taskId = _activeOrchestrationTaskId;
          final coordinator = registration.coordinator;
          if (taskId.isNotEmpty && coordinator?.sessionFor(taskId) != null) {
            coordinator!.queuePolicy(document);
          }
        case RoutingPolicyStoreValidationFailed(:final error):
          lastError = error.toString();
          statusCaption = 'Agent orchestration';
          _notifyStateChanged();
      }
    });
  }

  Future<void> setAppearancePreset(String presetId) async {
    if (!hasAppearancePresetConfig(presetId, appearancePresetConfigs)) {
      presetId = AppearancePresetIds.defaultSystem;
    }
    if (await layoutManager.setAppearancePreset(presetId)) {
      appearancePresetId = presetId;
      _notifyAppPresentationChanged();
      _notifyStateChanged();
    }
  }

  Future<void> setLocalePreference(String value) async {
    final normalized = LocalePreference.normalize(value);
    if (await layoutManager.setLocalePreference(normalized)) {
      localePreference = normalized;
      _notifyAppPresentationChanged();
      _notifyStateChanged();
    }
  }

  Future<void> reloadAppearancePresets() async {
    try {
      final catalog = await appearancePresetCatalogService.loadCatalog(
        portableData,
      );
      _applyAppearancePresetCatalog(catalog);
      if (!hasAppearancePresetConfig(
        appearancePresetId,
        appearancePresetConfigs,
      )) {
        appearancePresetId = AppearancePresetIds.defaultSystem;
        await layoutManager.setAppearancePreset(appearancePresetId);
      }
      _setLocalizedStatusMessage(
        appearancePresetLoadErrors.isEmpty ? '外观方案已重新加载。' : '外观方案已重新加载，部分配置无效。',
        appearancePresetLoadErrors.isEmpty
            ? 'Appearance presets reloaded.'
            : 'Appearance presets reloaded, but some configurations are invalid.',
      );
      statusCaption = 'Appearance';
    } catch (error) {
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '外观方案重新加载失败。',
        'Failed to reload appearance presets.',
      );
      statusCaption = 'Error';
    } finally {
      _notifyAppPresentationChanged();
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
