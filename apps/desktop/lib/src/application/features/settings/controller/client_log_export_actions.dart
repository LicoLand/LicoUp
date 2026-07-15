part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientLogExportActions on ClientController {
  Future<void> exportClientLogs(String destinationPath) async {
    final trimmed = destinationPath.trim();
    if (trimmed.isEmpty || isExportingClientLogs) {
      return;
    }
    isExportingClientLogs = true;
    lastError = '';
    _setLocalizedStatusMessage('正在导出日志...', 'Exporting logs...');
    statusCaption = 'Client logs';
    _notifyStateChanged();
    try {
      final result = await clientLogExportService.exportLogs(
        portableData: portableData,
        destinationPath: trimmed,
      );
      clientLogExportPath = result.path;
      _setLocalizedStatusMessage(
        result.sourceExists ? '客户端日志已导出。' : '暂无客户端日志，已导出空日志文件。',
        result.sourceExists
            ? 'Client logs exported.'
            : 'No client logs were available; an empty log file was exported.',
      );
      statusCaption = result.path;
    } catch (error) {
      debugPrint('Failed to export client logs: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage('客户端日志导出失败。', 'Failed to export client logs.');
      statusCaption = 'Error';
    } finally {
      isExportingClientLogs = false;
      _notifyStateChanged();
    }
  }
}
