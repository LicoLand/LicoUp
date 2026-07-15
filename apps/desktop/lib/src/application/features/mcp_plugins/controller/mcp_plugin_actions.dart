part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientMcpPluginActions on ClientController {
  Future<void> refreshMcpPluginStatus(TargetCandidate target) async {
    await _runMcpPluginAction(
      target,
      statusCaptionWhenBusy: 'MCP plugin',
      statusMessageWhenBusy: '正在读取 ${target.label} MCP 插件状态。',
      statusMessageWhenBusyEnglish:
          'Reading ${target.label} MCP plugin status.',
      action: () => agentService.mcpPluginStatus(
        target: target.target,
        configPath: target.configPath ?? '',
      ),
      onResult: (result) {
        mcpPluginStatuses = {...mcpPluginStatuses, target.target: result};
        _setLocalizedStatusMessage(
          '已读取 ${target.label} MCP 插件状态。',
          'Read ${target.label} MCP plugin status.',
        );
        statusCaption = 'MCP plugin';
      },
      onErrorMessage: '${target.label} MCP 插件状态读取失败。',
      onErrorMessageEnglish:
          'Failed to read ${target.label} MCP plugin status.',
    );
  }

  Future<void> updateMcpPlugin(TargetCandidate target) async {
    if (!target.canUpdateMcpPlugin) {
      lastError = '${target.label} target does not support MCP plugin update.';
      _setLocalizedStatusMessage('${target.label} 不支持更新 MCP 插件。', lastError);
      statusCaption = 'MCP plugin';
      _notifyStateChanged();
      return;
    }
    await _applyMcpPluginUpdate(target: target, actionLabel: '更新');
  }

  Future<void> reinstallMcpPlugin(TargetCandidate target) async {
    await _applyMcpPluginUpdate(target: target, actionLabel: '重新安装');
  }

  Future<void> _applyMcpPluginUpdate({
    required TargetCandidate target,
    required String actionLabel,
  }) async {
    final actionLabelEnglish = actionLabel == '重新安装' ? 'reinstall' : 'update';
    await _runMcpPluginAction(
      target,
      statusCaptionWhenBusy: 'MCP plugin',
      statusMessageWhenBusy: '正在$actionLabel ${target.label} MCP 插件。',
      statusMessageWhenBusyEnglish:
          '${actionLabelEnglish == 'reinstall' ? 'Reinstalling' : 'Updating'} the ${target.label} MCP plugin.',
      action: () => agentService.updateMcpPlugin(
        target: target.target,
        configPath: target.configPath ?? '',
      ),
      onResult: (result) async {
        final ok = result['ok'] == true;
        if (ok) {
          mcpPluginActionResult = result;
          mcpPluginStatuses = {...mcpPluginStatuses, target.target: result};
          scannedTargets = await agentService.scanTargets();
          _setLocalizedStatusMessage(
            '已$actionLabel ${target.label} MCP 插件。',
            '${actionLabelEnglish == 'reinstall' ? 'Reinstalled' : 'Updated'} the ${target.label} MCP plugin.',
          );
          statusCaption = 'MCP plugin';
        } else {
          final status = result['status'] ?? 'failed';
          lastError = '${target.label} plugin $actionLabel failed: $status';
          _setLocalizedStatusMessage(
            '${target.label} MCP 插件$actionLabel失败: $status',
            'Failed to $actionLabelEnglish the ${target.label} MCP plugin: $status',
          );
          statusCaption = 'MCP plugin';
        }
      },
      onErrorMessage: '${target.label} MCP 插件$actionLabel失败。',
      onErrorMessageEnglish:
          'Failed to $actionLabelEnglish the ${target.label} MCP plugin.',
    );
  }

  Future<void> rollbackLatestMcpPlugin(TargetCandidate target) async {
    if (!target.canRollbackMcpPlugin) {
      lastError =
          '${target.label} target does not support MCP plugin rollback.';
      _setLocalizedStatusMessage('${target.label} 不支持回滚 MCP 插件。', lastError);
      statusCaption = 'MCP plugin';
      _notifyStateChanged();
      return;
    }
    await _runMcpPluginAction(
      target,
      statusCaptionWhenBusy: 'MCP plugin',
      statusMessageWhenBusy: '正在回滚 ${target.label} LicoLite MCP 插件。',
      statusMessageWhenBusyEnglish:
          'Rolling back the ${target.label} LicoLite MCP plugin.',
      action: () async {
        final snapshots = await agentService.listSnapshots(
          target: target.target,
        );

        if (snapshots.isEmpty) {
          throw Exception('No snapshot found for target: ${target.target}');
        }

        snapshots.sort((a, b) {
          final aCapturedAt = a['capturedAt']?.toString() ?? '';
          final bCapturedAt = b['capturedAt']?.toString() ?? '';
          if (aCapturedAt.isEmpty && bCapturedAt.isEmpty) return 0;
          if (aCapturedAt.isEmpty) return 1;
          if (bCapturedAt.isEmpty) return -1;

          DateTime? dateA = DateTime.tryParse(aCapturedAt);
          DateTime? dateB = DateTime.tryParse(bCapturedAt);

          if (dateA == null && dateB == null) {
            return aCapturedAt.compareTo(bCapturedAt) * -1;
          }
          if (dateA == null) return 1;
          if (dateB == null) return -1;

          return dateB.compareTo(dateA); // Descending
        });

        final snapshotId = snapshots.first['snapshotId']?.toString() ?? '';
        if (snapshotId.isEmpty) {
          throw Exception(
            'Most recent snapshot has no ID for target: ${target.target}',
          );
        }

        return agentService.rollbackMcpPlugin(
          target: target.target,
          snapshotId: snapshotId,
          configPath: target.configPath ?? '',
        );
      },
      onResult: (result) async {
        final ok = result['ok'] == true;
        if (ok) {
          mcpPluginActionResult = result;
          mcpPluginStatuses = {...mcpPluginStatuses, target.target: result};
          scannedTargets = await agentService.scanTargets();
          _setLocalizedStatusMessage(
            '已回滚 ${target.label} LicoLite MCP 插件。',
            'Rolled back the ${target.label} LicoLite MCP plugin.',
          );
          statusCaption = 'MCP plugin';
        } else {
          final status = result['status'] ?? 'failed';
          lastError = '${target.label} plugin rollback failed: $status';
          _setLocalizedStatusMessage(
            '${target.label} LicoLite MCP 插件回滚失败: $status',
            'Failed to roll back the ${target.label} LicoLite MCP plugin: $status',
          );
          statusCaption = 'MCP plugin';
        }
      },
      onErrorMessage: '${target.label} LicoLite MCP 插件回滚失败。',
      onErrorMessageEnglish:
          'Failed to roll back the ${target.label} LicoLite MCP plugin.',
    );
  }

  Future<void> _runMcpPluginAction(
    TargetCandidate target, {
    required String statusCaptionWhenBusy,
    required String statusMessageWhenBusy,
    required String statusMessageWhenBusyEnglish,
    required Future<Map<String, dynamic>> Function() action,
    required FutureOr<void> Function(Map<String, dynamic> result) onResult,
    required String onErrorMessage,
    required String onErrorMessageEnglish,
  }) async {
    if (_mcpPluginBusyTargets.contains(target.target)) {
      return;
    }
    _mcpPluginBusyTargets.add(target.target);
    lastError = '';
    _setLocalizedStatusMessage(
      statusMessageWhenBusy,
      statusMessageWhenBusyEnglish,
    );
    statusCaption = statusCaptionWhenBusy;
    _notifyStateChanged();
    try {
      final result = await action();
      await onResult(result);
    } catch (error) {
      debugPrint('Failed to run MCP plugin action: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(onErrorMessage, onErrorMessageEnglish);
      statusCaption = statusCaptionWhenBusy;
    } finally {
      _mcpPluginBusyTargets.remove(target.target);
      _notifyStateChanged();
    }
  }
}
