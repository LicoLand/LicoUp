import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

/// Stores only bounded process-RSS and conversation-count samples.
final class ClientMemoryDiagnosticLog implements ClientMemoryDiagnosticSink {
  ClientMemoryDiagnosticLog({required PortableDataRoot portableData})
    : _portableData = portableData;

  static const int maxBytes = 256 * 1024;
  static const String fileName = 'client-memory.jsonl';

  final PortableDataRoot _portableData;
  Future<void> _pendingWrite = Future<void>.value();

  @override
  Future<void> record(ClientMemoryDiagnosticRecord record) {
    final write = _pendingWrite.then((_) => _append(record));
    _pendingWrite = write.catchError((_) {});
    return write;
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

    final retained = retainMemoryDiagnosticTail(
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

/// Keeps the newest complete JSONL lines so a long session can still record
/// the samples that precede a crash.
List<int> retainMemoryDiagnosticTail(
  List<int> current,
  List<int> incoming,
  int maxBytes,
) {
  if (incoming.length >= maxBytes) {
    return incoming.sublist(incoming.length - maxBytes);
  }
  final combined = <int>[...current, ...incoming];
  if (combined.length <= maxBytes) {
    return combined;
  }
  final overflow = combined.length - maxBytes;
  var start = overflow;
  while (start < combined.length && combined[start] != 10) {
    start += 1;
  }
  if (start < combined.length && combined[start] == 10) {
    start += 1;
  }
  return combined.sublist(start);
}
