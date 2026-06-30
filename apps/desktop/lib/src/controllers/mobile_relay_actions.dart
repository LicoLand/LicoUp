part of 'future_client_controller.dart';

extension FutureClientMobileRelayActions on FutureClientController {
  Future<void> configureMobileRelayGateway({
    required bool useCustomGateway,
    required String customGatewayUrl,
  }) async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    statusMessage = '正在保存移动中转网关配置。';
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      mobileRelayConfig = await mobileRelayService.configureGateway(
        agentService: agentService,
        useCustomGateway: useCustomGateway,
        customGatewayUrl: customGatewayUrl,
      );
      statusMessage = '已保存移动中转网关配置。';
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to configure mobile relay gateway: $error');
      lastError = error.toString();
      statusMessage = '移动中转网关配置失败。';
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> createMobilePairing() async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    statusMessage = '正在创建手机配对码。';
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      mobileRelayActionResult = await mobileRelayService.createPairing(
        agentService: agentService,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      if (scannedTargets.isEmpty) {
        scannedTargets = await agentService.scanTargets();
        _selectDefaultConversationAgent();
      }
      startMobileRelayPolling();
      statusMessage = '已创建手机配对码 ${mobileRelayConfig.lastPairingCode}。';
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to create mobile pairing: $error');
      lastError = error.toString();
      statusMessage = '手机配对码创建失败。';
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> refreshMobilePairingStatus() async {
    if (isMobileRelayBusy || !mobileRelayConfig.hasPairing) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    statusMessage = '正在刷新手机配对状态。';
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      mobileRelayActionResult = await mobileRelayService.refreshPairingStatus(
        agentService: agentService,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      statusMessage = mobileRelayConfig.paired ? '手机已配对。' : '等待手机配对。';
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to refresh mobile pairing status: $error');
      lastError = error.toString();
      statusMessage = '手机配对状态刷新失败。';
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  void startMobileRelayPolling() {
    if (!mobileRelayConfig.hasPairing) {
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

  Future<void> pollMobileRelayOnce() async {
    if (isMobileRelayPolling || !mobileRelayConfig.hasPairing) {
      return;
    }
    isMobileRelayPolling = true;
    lastError = '';
    statusMessage = '正在同步手机中转命令。';
    statusCaption = 'Mobile relay';
    _notifyStateChanged();
    try {
      mobileRelayActionResult = await mobileRelayService.syncCommands(
        agentService: agentService,
      );
      final commandMaps = (mobileRelayActionResult?['commands'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final commands = commandMaps.map(MobileRelayCommand.fromJson).toList();
      lastMobileRelayCommands = commands;
      final secureMeshExecutions = <Map<String, dynamic>>[];
      for (final command in commands) {
        final executionRequest = _secureMeshCommandExecutionRequest(command);
        if (executionRequest == null) {
          continue;
        }
        try {
          final execution = await mobileRelayService.executeSecureMeshCommand(
            agentService: agentService,
            payload: executionRequest.payload,
            context: executionRequest.context,
          );
          secureMeshExecutions.add({
            'commandId': command.commandId,
            'ok': execution['ok'] == true,
            'execution': execution,
          });
        } catch (error) {
          secureMeshExecutions.add({
            'commandId': command.commandId,
            'ok': false,
            'error': error.toString(),
          });
          lastError = error.toString();
        }
      }
      lastSecureMeshCommandExecutions = secureMeshExecutions;
      statusMessage = commands.isEmpty
          ? '手机中转已同步，暂无新命令。'
          : secureMeshExecutions.isEmpty
          ? '已处理 ${commands.length} 条手机中转命令。'
          : '已处理 ${commands.length} 条手机中转命令，执行 ${secureMeshExecutions.length} 条 Secure Mesh 命令。';
      statusCaption = 'Mobile relay';
    } catch (error) {
      debugPrint('Failed to poll mobile relay: $error');
      lastError = error.toString();
      statusMessage = '手机中转同步失败。';
      statusCaption = 'Mobile relay';
    } finally {
      isMobileRelayPolling = false;
      _notifyStateChanged();
    }
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
}

class _SecureMeshCommandExecutionRequest {
  const _SecureMeshCommandExecutionRequest({
    required this.payload,
    required this.context,
  });

  final Map<String, dynamic> payload;
  final Map<String, dynamic> context;
}
