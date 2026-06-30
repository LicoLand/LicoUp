part of 'future_client_controller.dart';

extension FutureClientModelForwardingActions on FutureClientController {
  Future<void> refreshModelProfiles() async {
    await _runModelForwardingAction('正在刷新模型转发 Profile。', () async {
      modelProfiles = await agentService.listModelProfiles();
      statusMessage = '已刷新 ${modelProfiles.length} 个模型转发 Profile。';
    });
  }

  Future<void> saveCommandModelProfile({
    required String profileId,
    required String command,
  }) async {
    await _runModelForwardingAction('正在保存模型转发 Profile。', () async {
      modelForwardingResult = await agentService.saveCommandModelProfile(
        profileId: profileId,
        command: command,
      );
      modelProfiles = await agentService.listModelProfiles();
      statusMessage = '已保存模型转发 Profile $profileId。';
    });
  }

  Future<void> forwardModelText({
    required String profileId,
    required String text,
  }) async {
    await _runModelForwardingAction('正在执行 thin-forward。', () async {
      modelForwardingResult = await agentService.forwardText(
        profileId: profileId,
        text: text,
      );
      statusMessage = '已完成 $profileId thin-forward。';
    });
  }

  Future<void> _runModelForwardingAction(
    String busyMessage,
    Future<void> Function() action,
  ) async {
    if (isModelForwardingBusy) {
      return;
    }
    isModelForwardingBusy = true;
    lastError = '';
    statusMessage = busyMessage;
    statusCaption = 'Model Forwarding';
    _notifyStateChanged();
    try {
      await action();
      statusCaption = 'Model Forwarding';
    } catch (error) {
      debugPrint('Failed to run model forwarding action: $error');
      lastError = error.toString();
      statusMessage = 'Model Forwarding 操作失败。';
      statusCaption = 'Model Forwarding';
    } finally {
      isModelForwardingBusy = false;
      _notifyStateChanged();
    }
  }
}
