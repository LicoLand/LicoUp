part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientMobileRelayPollingActions on ClientController {
  void startMobileRelayPolling() {
    if (!mobileRelayConfig.hasPairing) {
      return;
    }
    if (runtimePlatformBridge.isIos) {
      _mobileRelayTimer?.cancel();
      _mobileRelayTimer = null;
      mobileRelayConfig = mobileRelayConfig.copyWith(relayEnabled: false);
      _notifyStateChanged();
      return;
    }
    if (runtimePlatformBridge.isAndroid) {
      _mobileRelayTimer?.cancel();
      _mobileRelayTimer = null;
      if (!mobileRelayConfig.relayEnabled) {
        mobileRelayConfig = mobileRelayConfig.copyWith(relayEnabled: true);
        unawaited(
          mobileRelayService.saveConfig(
            agentService: agentService,
            config: mobileRelayConfig,
          ),
        );
        _notifyStateChanged();
      }
      return;
    }
    _mobileRelayTimer?.cancel();
    final interval = Duration(
      seconds: mobileRelayConfig.pollIntervalSeconds.clamp(3, 60),
    );
    _mobileRelayTimer = Timer.periodic(interval, (_) {
      unawaited(pollMobileRelayOnce());
    });
    mobileRelayConfig = mobileRelayConfig.copyWith(relayEnabled: true);
    unawaited(
      mobileRelayService.saveConfig(
        agentService: agentService,
        config: mobileRelayConfig,
      ),
    );
    _notifyStateChanged();
  }

  void stopMobileRelayPolling() {
    _mobileRelayTimer?.cancel();
    _mobileRelayTimer = null;
    mobileRelayConfig = mobileRelayConfig.copyWith(relayEnabled: false);
    unawaited(
      mobileRelayService.saveConfig(
        agentService: agentService,
        config: mobileRelayConfig,
      ),
    );
    _notifyStateChanged();
  }

  Future<void> pollMobileRelayOnce({bool showProgress = false}) async {
    if (_mobileClientRuntimePlatform) {
      return;
    }
    if (showProgress) {
      _mobileRelayAuthorizationRequired = false;
    } else if (_mobileRelayAuthorizationRequired) {
      return;
    }
    if (isMobileRelayPolling || !mobileRelayConfig.hasPairing) {
      return;
    }
    isMobileRelayPolling = true;
    lastError = '';
    var notifyState = false;
    if (showProgress) {
      _setLocalizedStatusMessage(
        '正在同步手机中转命令。',
        'Syncing mobile relay commands.',
      );
      statusCaption = 'Mobile relay';
      notifyState = true;
      _notifyStateChanged();
    }
    try {
      mobileRelayActionResult = await mobileRelayService.syncCommands(
        agentService: agentService,
        // Timer-driven work must never open a system authorization sheet. A
        // visible, user-triggered sync may establish or refresh the session.
        allowInteraction: showProgress,
      );
      _mobileRelayAuthorizationRequired = false;
      final commandMaps = (mobileRelayActionResult?['commands'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final commands = commandMaps.map(MobileRelayCommand.fromJson).toList();
      lastMobileRelayCommands = commands;
      final secureMeshExecutions = await _executeSecureMeshRelayCommands(
        commands,
      );
      lastSecureMeshCommandExecutions = secureMeshExecutions;
      if (commands.isNotEmpty || showProgress) {
        final syncStatus = _mobileRelaySyncStatus(
          commandCount: commands.length,
          secureExecutionCount: secureMeshExecutions.length,
        );
        _setLocalizedStatusMessage(syncStatus.$1, syncStatus.$2);
        statusCaption = 'Mobile relay';
        notifyState = true;
      }
    } on LicoClientRpcException catch (error) {
      if (error.authorizationRequired && !showProgress) {
        _mobileRelayAuthorizationRequired = true;
        lastError = error.toString();
        _setLocalizedStatusMessage(
          '手机中转等待本机授权，请手动同步。',
          'Mobile relay is waiting for local authorization; sync manually.',
        );
        statusCaption = 'Mobile relay';
        notifyState = true;
      } else {
        lastError = error.toString();
        _setLocalizedStatusMessage(
          '手机中转同步失败。',
          'Failed to sync the mobile relay.',
        );
        statusCaption = 'Mobile relay';
        notifyState = true;
      }
    } catch (error) {
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '手机中转同步失败。',
        'Failed to sync the mobile relay.',
      );
      statusCaption = 'Mobile relay';
      notifyState = true;
    } finally {
      isMobileRelayPolling = false;
      if (notifyState) {
        _notifyStateChanged();
      }
    }
  }

  Future<List<Map<String, dynamic>>> _executeSecureMeshRelayCommands(
    List<MobileRelayCommand> commands,
  ) async {
    final executions = <Map<String, dynamic>>[];
    for (final command in commands) {
      final request = _secureMeshCommandExecutionRequest(command);
      if (request == null) {
        continue;
      }
      try {
        final execution = await mobileRelayService.executeSecureMeshCommand(
          agentService: agentService,
          payload: request.payload,
          context: request.context,
        );
        executions.add({
          'commandId': command.commandId,
          'ok': execution['ok'] == true,
          'execution': execution,
        });
      } catch (error) {
        executions.add({
          'commandId': command.commandId,
          'ok': false,
          'error': error.toString(),
        });
        lastError = error.toString();
      }
    }
    return executions;
  }

  _SecureMeshCommandExecutionRequest? _secureMeshCommandExecutionRequest(
    MobileRelayCommand command,
  ) {
    final payload = command.payload;
    final wrappedPayload =
        _asJsonMap(payload['secureCommandPayload']) ??
        _asJsonMap(payload['commandPayload']) ??
        _asJsonMap(payload['payload']);
    final commandPayload =
        wrappedPayload ??
        (command.type == 'secure_mesh.command' ? payload : null);
    if (commandPayload == null) {
      return null;
    }
    final context =
        _asJsonMap(payload['secureCommandContext']) ??
        _asJsonMap(payload['context']) ??
        const <String, dynamic>{};
    return _SecureMeshCommandExecutionRequest(
      payload: commandPayload,
      context: context,
    );
  }

  Map<String, dynamic>? _asJsonMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  (String, String) _mobileRelaySyncStatus({
    required int commandCount,
    required int secureExecutionCount,
  }) {
    if (commandCount == 0) {
      return ('手机中转已同步，暂无新命令。', 'Mobile relay synced; no new commands.');
    }
    if (secureExecutionCount == 0) {
      return (
        '已处理 $commandCount 条手机中转命令。',
        'Processed $commandCount mobile relay commands.',
      );
    }
    return (
      '已处理 $commandCount 条手机中转命令，执行 $secureExecutionCount 条 Secure Mesh 命令。',
      'Processed $commandCount mobile relay commands and executed $secureExecutionCount Secure Mesh commands.',
    );
  }
}

class _SecureMeshCommandExecutionRequest {
  const _SecureMeshCommandExecutionRequest({
    required this.payload,
    required this.context,
  });

  final Map<String, dynamic> payload;
  final Map<String, dynamic> context;
}
