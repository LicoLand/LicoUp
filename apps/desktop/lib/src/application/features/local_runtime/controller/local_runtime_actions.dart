part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientLocalRuntimeActions on ClientController {
  Future<void> refreshLocalRuntimeStatus() async {
    if (_rejectLocalRuntimeOnMobile()) {
      return;
    }
    try {
      localRuntimeState = await agentService.localRuntimeStatus();
      _setLocalizedStatusMessage(
        '本地服务端状态已刷新。',
        'Local server status refreshed.',
      );
      statusCaption = 'Runtime';
    } catch (error) {
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '本地服务端状态刷新失败。',
        'Failed to refresh local server status.',
      );
      statusCaption = 'Error';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> ensureLocalRuntime({
    required String sourceRoot,
    required String presetConfig,
    int port = 17328,
    bool rebuild = false,
  }) async {
    if (_rejectLocalRuntimeOnMobile()) {
      return;
    }
    await _runLocalRuntimeAction(
      busyMessage: '本地服务端启用中。',
      busyMessageEnglish: 'Enabling the local server.',
      successMessage: '本地服务端已就绪。',
      successMessageEnglish: 'The local server is ready.',
      errorMessage: '本地服务端启用失败。',
      errorMessageEnglish: 'Failed to enable the local server.',
      action: () async {
        await saveLocalRuntimePreferences(
          sourceRoot: sourceRoot,
          presetConfig: presetConfig,
          port: port,
        );
        localRuntimeState = await agentService.ensureLocalRuntime(
          sourceRoot: sourceRoot,
          presetConfig: presetConfig,
          port: port,
          rebuild: rebuild,
        );
      },
    );
  }

  Future<void> ensureConfiguredLocalRuntime({bool rebuild = false}) {
    return ensureLocalRuntime(
      sourceRoot: localRuntimePreferences.sourceRoot,
      presetConfig: localRuntimePreferences.presetConfig,
      port: localRuntimePreferences.port,
      rebuild: rebuild,
    );
  }

  Future<void> saveLocalRuntimePreferences({
    required String sourceRoot,
    required String presetConfig,
    required int port,
  }) async {
    if (_rejectLocalRuntimeOnMobile()) {
      return;
    }
    localRuntimePreferences = LocalRuntimePreferences(
      sourceRoot: sourceRoot.trim(),
      presetConfig: presetConfig.trim(),
      port: port,
    );
    await localRuntimePreferencesStore.save(
      portableData,
      localRuntimePreferences,
    );
    localRuntimePreferences = await localRuntimePreferencesStore.load(
      portableData,
    );
    _notifyStateChanged();
  }

  Future<void> startLocalRuntime({int port = 17328}) async {
    if (_rejectLocalRuntimeOnMobile()) {
      return;
    }
    await _runLocalRuntimeAction(
      busyMessage: '本地服务端启动中。',
      busyMessageEnglish: 'Starting the local server.',
      successMessage: '本地服务端已启动。',
      successMessageEnglish: 'The local server started.',
      errorMessage: '本地服务端启动失败。',
      errorMessageEnglish: 'Failed to start the local server.',
      action: () async {
        localRuntimeState = await agentService.startLocalRuntime(port: port);
      },
    );
  }

  Future<void> startConfiguredLocalRuntime() {
    return startLocalRuntime(port: localRuntimePreferences.port);
  }

  Future<void> restartLocalRuntime({int port = 17328}) async {
    if (_rejectLocalRuntimeOnMobile()) {
      return;
    }
    await _runLocalRuntimeAction(
      busyMessage: '本地服务端重启中。',
      busyMessageEnglish: 'Restarting the local server.',
      successMessage: '本地服务端已重启。',
      successMessageEnglish: 'The local server restarted.',
      errorMessage: '本地服务端重启失败。',
      errorMessageEnglish: 'Failed to restart the local server.',
      action: () async {
        localRuntimeState = await agentService.restartLocalRuntime(port: port);
      },
    );
  }

  Future<void> restartConfiguredLocalRuntime() {
    return restartLocalRuntime(port: localRuntimePreferences.port);
  }

  Future<void> stopLocalRuntime() async {
    if (_rejectLocalRuntimeOnMobile()) {
      return;
    }
    await _runLocalRuntimeAction(
      busyMessage: '本地服务端停止中。',
      busyMessageEnglish: 'Stopping the local server.',
      successMessage: '本地服务端已停止。',
      successMessageEnglish: 'The local server stopped.',
      errorMessage: '本地服务端停止失败。',
      errorMessageEnglish: 'Failed to stop the local server.',
      action: () async {
        localRuntimeState = await agentService.stopLocalRuntime();
      },
    );
  }

  Future<void> loadLocalRuntimeLogs({int tail = 120}) async {
    if (_rejectLocalRuntimeOnMobile()) {
      return;
    }
    try {
      final result = await agentService.localRuntimeLogs(tail: tail);
      localRuntimeLogLines =
          (result['lines'] as List?)?.whereType<String>().toList() ?? const [];
      _setLocalizedStatusMessage('本地服务端日志已刷新。', 'Local server logs refreshed.');
      statusCaption = 'Runtime';
    } catch (error) {
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '本地服务端日志读取失败。',
        'Failed to load local server logs.',
      );
      statusCaption = 'Error';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> _refreshLocalRuntimeStatusSilently() async {
    if (_mobileClientRuntimePlatform) {
      localRuntimeState = null;
      return;
    }
    try {
      localRuntimeState = await agentService.localRuntimeStatus();
    } catch (_) {
      localRuntimeState = null;
    }
  }

  Future<void> _runLocalRuntimeAction({
    required String busyMessage,
    required String busyMessageEnglish,
    required String successMessage,
    required String successMessageEnglish,
    required String errorMessage,
    required String errorMessageEnglish,
    required Future<void> Function() action,
  }) async {
    isLocalRuntimeBusy = true;
    _setLocalizedStatusMessage(busyMessage, busyMessageEnglish);
    statusCaption = 'Runtime';
    _notifyStateChanged();
    try {
      await action();
      _setLocalizedStatusMessage(successMessage, successMessageEnglish);
      statusCaption = 'Runtime';
    } catch (error) {
      lastError = error.toString();
      _setLocalizedStatusMessage(errorMessage, errorMessageEnglish);
      statusCaption = 'Error';
    } finally {
      isLocalRuntimeBusy = false;
      _notifyStateChanged();
    }
  }

  bool _rejectLocalRuntimeOnMobile() {
    if (!_mobileClientRuntimePlatform) {
      return false;
    }
    localRuntimeState = null;
    localRuntimeLogLines = const [];
    isLocalRuntimeBusy = false;
    _setLocalizedStatusMessage(
      '手机端不支持本地服务端。',
      'The local server is unavailable on mobile.',
    );
    statusCaption = 'Runtime';
    _notifyStateChanged();
    return true;
  }
}
