import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/platform/storage/portable_data_root.dart';

class MobileRelayJsonStore {
  const MobileRelayJsonStore();

  static int _atomicWriteSequence = 0;
  static final Map<String, Future<void>> _writeQueues = {};

  Future<Object?> read(Object portableData, String fileName) async {
    final file = await _file(portableData, fileName);
    if (!await file.exists()) {
      return null;
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return null;
    }
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  /// Reads a startup-admitted durable document. Missing is allowed for a
  /// fresh domain; an existing empty or malformed file is never projected as
  /// absence because that would silently reset durable state.
  Future<Object?> readCurrent(Object portableData, String fileName) async {
    final file = await _file(portableData, fileName);
    if (!await file.exists()) {
      return null;
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      throw const FormatException('durable_state_document_invalid');
    }
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw const FormatException('durable_state_document_invalid');
    }
  }

  Future<void> write(
    Object portableData,
    String fileName,
    Object? payload, {
    bool lock = false,
  }) async {
    final file = await _file(portableData, fileName);
    await file.parent.create(recursive: true);
    if (lock) {
      await _enqueueWrite(
        file,
        () => _writeJsonAtomicallyWithLock(file, payload),
      );
      return;
    }
    await _enqueueWrite(file, () => _writeJsonAtomically(file, payload));
  }

  Future<File> _file(Object portableData, String fileName) async {
    if (portableData is! PortableDataRoot) {
      throw ArgumentError.value(portableData, 'portableData');
    }
    final root = await portableData.clientDirectory();
    return File(p.join(root.path, fileName));
  }

  Future<void> _writeJsonAtomically(File file, Object? payload) async {
    await file.parent.create(recursive: true);
    final temp = _tempFileFor(file);
    try {
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
    }
  }

  Future<void> _writeJsonAtomicallyWithLock(File file, Object? payload) async {
    final lock = File(
      p.join(file.parent.path, '${p.basename(file.path)}.lock'),
    );
    final RandomAccessFile lockHandle = await lock.open(mode: FileMode.write);
    try {
      await lockHandle.lock(FileLock.exclusive);
      await _writeJsonAtomically(file, payload);
    } finally {
      try {
        await lockHandle.unlock();
      } finally {
        await lockHandle.close();
      }
    }
  }

  Future<void> _enqueueWrite(File file, Future<void> Function() write) async {
    final key = file.absolute.path;
    final previous = _writeQueues[key] ?? Future<void>.value();
    final queued = previous.catchError((_) {}).then((_) => write());
    _writeQueues[key] = queued;
    try {
      await queued;
    } finally {
      if (identical(_writeQueues[key], queued)) {
        _writeQueues.remove(key);
      }
    }
  }

  File _tempFileFor(File file) {
    final sequence = ++_atomicWriteSequence;
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    return File(
      p.join(
        file.parent.path,
        '.${p.basename(file.path)}.$pid.$sequence.$timestamp.tmp',
      ),
    );
  }
}
