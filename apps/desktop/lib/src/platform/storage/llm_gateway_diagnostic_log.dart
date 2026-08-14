import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/contracts/llm_gateway_diagnostics.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

/// Stores only bounded, redacted Gateway recovery codes for local diagnosis.
final class LlmGatewayDiagnosticLog implements LlmGatewayDiagnosticSink {
  LlmGatewayDiagnosticLog({required PortableDataRoot portableData})
    : _portableData = portableData;

  static const int _maxBytes = 256 * 1024;
  static const String _schema = 'licoup.llm-gateway-diagnostic.v1';

  final PortableDataRoot _portableData;
  Future<void> _pendingWrite = Future<void>.value();

  @override
  Future<void> record(LlmGatewayDiagnosticRecord record) {
    final write = _pendingWrite.then((_) => _append(record));
    _pendingWrite = write.catchError((_) {});
    return write;
  }

  Future<void> _append(LlmGatewayDiagnosticRecord record) async {
    final clientDirectory = await _portableData.clientDirectory();
    final diagnosticsDirectory = Directory(
      p.join(clientDirectory.path, 'diagnostics'),
    );
    await _ensurePlainDirectory(diagnosticsDirectory);
    final file = File(
      p.join(diagnosticsDirectory.path, 'llm-gateway-recovery.jsonl'),
    );
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file)) {
      throw const FileSystemException(
        'Gateway diagnostic path is not a regular file.',
      );
    }

    final line =
        '${jsonEncode({'schemaVersion': _schema, 'createdAt': record.createdAt.toUtc().toIso8601String(), 'event': record.event.wireName, 'runtimeState': record.runtimeState, 'errorCode': record.errorCode, 'attempt': record.attempt})}\n';
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      final length = await handle.length();
      if (length + utf8.encode(line).length <= _maxBytes) {
        await handle.writeString(line);
        await handle.flush();
      }
    } finally {
      try {
        await handle.unlock();
      } on FileSystemException {
        // The handle may not have acquired the lock if opening failed late.
      }
      await handle.close();
    }
  }

  Future<void> _ensurePlainDirectory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw const FileSystemException(
        'Gateway diagnostic directory is not a regular directory.',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
    }
  }
}
