part of 'future_client_controller.dart';

extension FutureClientTargetActions on FutureClientController {
  Future<void> scanTargets() async {
    if (isScanningTargets) {
      return;
    }
    isScanningTargets = true;
    lastError = '';
    statusMessage = '正在扫描目标适配器。';
    statusCaption = 'Targets';
    _notifyStateChanged();
    try {
      scannedTargets = await agentService.scanTargets();
      _selectDefaultConversationAgent();
      statusMessage = '已扫描 ${scannedTargets.length} 个目标适配器。';
      statusCaption = 'Targets';
      if (selectedConversationAgentId.isNotEmpty) {
        await loadConversationSessions(selectedConversationAgentId);
      }
    } catch (error) {
      debugPrint('Failed to scan targets: $error');
      lastError = error.toString();
      statusMessage = '目标适配器扫描失败。';
      statusCaption = 'Targets';
    } finally {
      isScanningTargets = false;
      _notifyStateChanged();
    }
  }

  void _selectDefaultConversationAgent() {
    final visibleTargets = scannedTargets
        .where((target) => target.visibleInClient)
        .toList(growable: false);
    if (visibleTargets.isEmpty) {
      selectedConversationAgentId = '';
      selectedConversationSessionId = '';
      return;
    }
    if (visibleTargets.any(
      (target) => target.target == selectedConversationAgentId,
    )) {
      return;
    }
    var preferred = visibleTargets.first;
    for (final target in visibleTargets) {
      if (target.status != 'not-detected') {
        preferred = target;
        break;
      }
    }
    selectedConversationAgentId = preferred.target;
    selectedConversationSessionId = '';
  }

  Future<void> inspectTarget(String target) async {
    lastError = '';
    try {
      targetInspection = await agentService.inspectTarget(target);
      statusMessage = '已读取 $target 目标适配器。';
      statusCaption = 'Target inspect';
    } catch (error) {
      debugPrint('Failed to inspect target: $error');
      lastError = error.toString();
      statusMessage = '$target 目标适配器读取失败。';
      statusCaption = 'Target inspect';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> addManualTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
  }) async {
    final trimmed = target.trim();
    if (trimmed.isEmpty || isAddingTarget) {
      return;
    }
    final trimmedConfigPath = configPath.trim();
    final trimmedBinaryPath = binaryPath.trim();
    final trimmedHistoryRoot = historyRoot.trim();
    isAddingTarget = true;
    lastError = '';
    statusMessage = '正在添加手动目标。';
    statusCaption = 'Targets';
    _notifyStateChanged();
    try {
      await agentService.addTarget(
        target: trimmed,
        configPath: trimmedConfigPath,
        binaryPath: trimmedBinaryPath,
        historyRoot: trimmedHistoryRoot,
      );
      scannedTargets = await agentService.scanTargets();
      statusMessage = '已添加 $trimmed 手动目标。';
      statusCaption = 'Targets';
    } catch (error) {
      debugPrint('Failed to add manual target: $error');
      lastError = error.toString();
      statusMessage = '$trimmed 手动目标添加失败。';
      statusCaption = 'Targets';
    } finally {
      isAddingTarget = false;
      _notifyStateChanged();
    }
  }

  Future<void> planTargetConfig(String target) async {
    lastError = '';
    try {
      targetConfigPlan = await agentService.planTargetConfig(target);
      statusMessage = '已生成 $target MCP 配置计划。';
      statusCaption = 'MCP config plan';
    } catch (error) {
      debugPrint('Failed to plan target config: $error');
      lastError = error.toString();
      statusMessage = '$target MCP 配置计划生成失败。';
      statusCaption = 'MCP config plan';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> restoreSnapshot(String snapshotId) async {
    final trimmed = snapshotId.trim();
    if (trimmed.isEmpty) {
      return;
    }
    lastError = '';
    statusMessage = '正在恢复配置快照。';
    statusCaption = 'Snapshots';
    _notifyStateChanged();
    try {
      snapshotRestoreResult = await agentService.restoreSnapshot(trimmed);
      statusMessage = '已恢复配置快照 $trimmed。';
      statusCaption = 'Snapshots';
    } catch (error) {
      debugPrint('Failed to restore snapshot: $error');
      lastError = error.toString();
      statusMessage = '配置快照恢复失败。';
      statusCaption = 'Snapshots';
    } finally {
      _notifyStateChanged();
    }
  }
}
