import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/client_log_export.dart';

final class ClientLogExportStatusUpdate {
  const ClientLogExportStatusUpdate({
    required this.chinese,
    required this.english,
    required this.caption,
    this.error,
  });

  final String chinese;
  final String english;
  final String caption;
  final Object? error;
}

typedef ClientLogExportStatusSink =
    void Function(ClientLogExportStatusUpdate update);

/// Isolated log-export workflow with a narrow storage port.
final class ClientLogExportController extends ChangeNotifier {
  ClientLogExportController({
    required ClientLogExporter exporter,
    required Object portableData,
    required ClientLogExportStatusSink onStatus,
  }) : _exporter = exporter,
       _portableData = portableData,
       _onStatus = onStatus;

  final ClientLogExporter _exporter;
  final Object _portableData;
  final ClientLogExportStatusSink _onStatus;

  String _exportedPath = '';
  bool _busy = false;

  String get exportedPath => _exportedPath;
  bool get busy => _busy;

  Future<void> export(String destinationPath) async {
    final trimmed = destinationPath.trim();
    if (trimmed.isEmpty || _busy) return;

    _busy = true;
    _onStatus(
      const ClientLogExportStatusUpdate(
        chinese: '正在导出日志...',
        english: 'Exporting logs...',
        caption: 'Client logs',
      ),
    );
    notifyListeners();
    try {
      final result = await _exporter.exportLogs(
        portableData: _portableData,
        destinationPath: trimmed,
      );
      _exportedPath = result.path;
      _onStatus(
        ClientLogExportStatusUpdate(
          chinese: result.sourceExists ? '客户端日志已导出。' : '暂无客户端日志，已导出空日志文件。',
          english: result.sourceExists
              ? 'Client logs exported.'
              : 'No client logs were available; an empty log file was exported.',
          caption: result.path,
        ),
      );
    } catch (error) {
      _onStatus(
        ClientLogExportStatusUpdate(
          chinese: '客户端日志导出失败。',
          english: 'Failed to export client logs.',
          caption: 'Error',
          error: error,
        ),
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
