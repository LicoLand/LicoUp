part of 'future_client_controller.dart';

extension FutureClientLocalRuntimeActions on FutureClientController {
  Future<void> refreshLocalRuntimeStatus() async {
    try {
      localRuntimeState = await agentService.localRuntimeStatus();
      statusMessage = '本地运行时状态已刷新。';
      statusCaption = 'Runtime';
    } catch (error) {
      lastError = error.toString();
      statusMessage = '本地运行时状态刷新失败。';
      statusCaption = 'Error';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> ensureLocalRuntime({
    int port = 17328,
    bool rebuild = false,
  }) async {
    await _runLocalRuntimeAction(
      busyMessage: '本地运行时启用中。',
      successMessage: '本地运行时已就绪。',
      errorMessage: '本地运行时启用失败。',
      action: () async {
        await saveLocalRuntimePreferences(port: port);
        localRuntimeState = await agentService.ensureLocalRuntime(
          port: port,
          rebuild: rebuild,
        );
      },
    );
  }

  Future<void> ensureConfiguredLocalRuntime({bool rebuild = false}) {
    return ensureLocalRuntime(
      port: localRuntimePreferences.port,
      rebuild: rebuild,
    );
  }

  Future<void> saveLocalRuntimePreferences({required int port}) async {
    localRuntimePreferences = LocalRuntimePreferences(port: port);
    await localRuntimePreferencesService.save(
      portableData,
      localRuntimePreferences,
    );
    localRuntimePreferences = await localRuntimePreferencesService.load(
      portableData,
    );
    _notifyStateChanged();
  }

  Future<void> startLocalRuntime({int port = 17328}) async {
    await _runLocalRuntimeAction(
      busyMessage: '本地运行时启动中。',
      successMessage: '本地运行时已启动。',
      errorMessage: '本地运行时启动失败。',
      action: () async {
        localRuntimeState = await agentService.startLocalRuntime(port: port);
      },
    );
  }

  Future<void> startConfiguredLocalRuntime() {
    return startLocalRuntime(port: localRuntimePreferences.port);
  }

  Future<void> restartLocalRuntime({int port = 17328}) async {
    await _runLocalRuntimeAction(
      busyMessage: '本地运行时重启中。',
      successMessage: '本地运行时已重启。',
      errorMessage: '本地运行时重启失败。',
      action: () async {
        localRuntimeState = await agentService.restartLocalRuntime(port: port);
      },
    );
  }

  Future<void> restartConfiguredLocalRuntime() {
    return restartLocalRuntime(port: localRuntimePreferences.port);
  }

  Future<void> stopLocalRuntime() async {
    await _runLocalRuntimeAction(
      busyMessage: '本地运行时停止中。',
      successMessage: '本地运行时已停止。',
      errorMessage: '本地运行时停止失败。',
      action: () async {
        localRuntimeState = await agentService.stopLocalRuntime();
      },
    );
  }

  Future<void> loadLocalRuntimeLogs({int tail = 120}) async {
    try {
      final result = await agentService.localRuntimeLogs(tail: tail);
      localRuntimeLogLines =
          (result['lines'] as List?)?.whereType<String>().toList() ?? const [];
      statusMessage = '本地运行时日志已刷新。';
      statusCaption = 'Runtime';
    } catch (error) {
      lastError = error.toString();
      statusMessage = '本地运行时日志读取失败。';
      statusCaption = 'Error';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> _refreshLocalRuntimeStatusSilently() async {
    try {
      localRuntimeState = await agentService.localRuntimeStatus();
    } catch (_) {
      localRuntimeState = null;
    }
  }

  Future<void> _runLocalRuntimeAction({
    required String busyMessage,
    required String successMessage,
    required String errorMessage,
    required Future<void> Function() action,
  }) async {
    isLocalRuntimeBusy = true;
    statusMessage = busyMessage;
    statusCaption = 'Runtime';
    _notifyStateChanged();
    try {
      await action();
      statusMessage = successMessage;
      statusCaption = 'Runtime';
    } catch (error) {
      lastError = error.toString();
      statusMessage = errorMessage;
      statusCaption = 'Error';
    } finally {
      isLocalRuntimeBusy = false;
      _notifyStateChanged();
    }
  }
}
