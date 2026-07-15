part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientDirectoryPathActions on ClientController {
  Future<void> openDirectoryPath(String path, {String caption = ''}) async {
    final directoryPath = path.trim();
    final resolvedCaption = caption.trim().isEmpty
        ? _strings.directory
        : caption;
    if (directoryPath.isEmpty) {
      lastError = 'Directory path is not configured.';
      _setLocalizedStatusMessage('请先指定目录。', 'Choose a directory first.');
      statusCaption = resolvedCaption;
      _notifyStateChanged();
      return;
    }
    try {
      final result = await runtimePlatformBridge.openDirectory(directoryPath);
      if (result.exitCode != 0) {
        final detail = [
          result.stderr.trim(),
          result.stdout.trim(),
        ].where((value) => value.isNotEmpty).join('\n');
        lastError = detail.isEmpty ? 'Failed to open directory.' : detail;
        _setLocalizedStatusMessage('目录打开失败。', 'Failed to open the directory.');
        statusCaption = directoryPath;
      } else {
        lastError = '';
        _setLocalizedStatusMessage('已打开目录。', 'Directory opened.');
        statusCaption = directoryPath;
      }
    } catch (error) {
      debugPrint('Failed to open directory path: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage('目录打开失败。', 'Failed to open the directory.');
      statusCaption = directoryPath;
    } finally {
      _notifyStateChanged();
    }
  }
}
