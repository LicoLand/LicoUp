import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/platform/storage/bounded_json_lines.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

/// Stores only bounded process-RSS and conversation-count samples.
final class ClientMemoryDiagnosticLog implements ClientMemoryDiagnosticSink {
  ClientMemoryDiagnosticLog({required PortableDataRoot portableData})
    : _portableData = portableData;

  static const int maxBytes = 256 * 1024;
  static const String fileName = 'client-memory.jsonl';

  final PortableDataRoot _portableData;
  Future<void>? _pendingWrite;

  /// Waits for writes already accepted by the log to release their files.
  Future<void> flush() => _pendingWrite ?? Future<void>.value();

  @override
  Future<void> record(ClientMemoryDiagnosticRecord record) {
    return _portableData.withAppManagedWriter(() {
      final write = (_pendingWrite ?? Future<void>.value()).then(
        (_) => _append(record),
      );
      late final Future<void> settled;
      settled = write.catchError((_) {}).whenComplete(() {
        if (identical(_pendingWrite, settled)) _pendingWrite = null;
      });
      _pendingWrite = settled;
      return write;
    });
  }

  Future<void> _append(ClientMemoryDiagnosticRecord record) async {
    final clientDirectory = await _portableData.clientDirectory();
    final diagnosticsDirectory = Directory(
      p.join(clientDirectory.path, 'diagnostics'),
    );
    await _ensurePlainDirectory(diagnosticsDirectory);
    final file = File(p.join(diagnosticsDirectory.path, fileName));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file)) {
      throw const FileSystemException(
        'Memory diagnostic path is not a regular file.',
      );
    }

    final line = '${jsonEncode(record.toJson())}\n';
    final encoded = utf8.encode(line);
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      final length = await handle.length();
      if (length + encoded.length <= maxBytes) {
        await handle.writeFrom(encoded);
        await handle.flush();
        return;
      }
      await handle.flush();
    } finally {
      try {
        await handle.unlock();
      } on FileSystemException {
        // The handle may not have acquired the lock if opening failed late.
      }
      await handle.close();
    }

    final retained = retainJsonLinesTail(
      await file.readAsBytes(),
      encoded,
      maxBytes,
    );
    await file.writeAsBytes(retained, flush: true);
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
        'Memory diagnostic directory is not a regular directory.',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
    }
  }
}
