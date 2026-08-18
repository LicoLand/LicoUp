import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Enforces one running LicoUp client instance per machine.
///
/// The guard owns an exclusive operating-system file lock inside the
/// client-controlled state directory for the process lifetime. The lock is
/// acquired without waiting, so a duplicate exits before any bootstrap work
/// (target scans, bridge workloads) can start.
///
/// A file lock avoids the probe/delete/bind race inherent in a Unix socket
/// guard and works across all desktop platforms. The lock file is deliberately
/// retained after release: deleting it could replace the inode while another
/// process still holds a valid lock.
class SingleInstanceGuard {
  SingleInstanceGuard._(this._handle, this._lockKey);

  static final Set<String> _processLocks = <String>{};
  final RandomAccessFile _handle;
  final String _lockKey;
  bool _released = false;

  /// Resolves the lock file inside the canonical client state directory.
  static Future<File> lockFileFor(PortableDataRoot portableData) async {
    final directory = await portableData.clientDirectory();
    final raw = File(p.join(directory.path, 'client.instance.lock'));
    return File(
      PortableDataRoot.stripMacosDataVolume(p.normalize(p.absolute(raw.path))),
    );
  }

  /// Claims the instance lock. Returns null when another running client owns
  /// it or when the lock cannot be established safely.
  static Future<SingleInstanceGuard?> tryAcquire(File lockFile) async {
    final lockKey = p.normalize(p.absolute(lockFile.path));
    if (!_processLocks.add(lockKey)) {
      return null;
    }
    final RandomAccessFile handle;
    try {
      await lockFile.parent.create(recursive: true);
      handle = await lockFile.open(mode: FileMode.append);
    } on FileSystemException {
      _processLocks.remove(lockKey);
      return null;
    }
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      _processLocks.remove(lockKey);
      return null;
    }
    return SingleInstanceGuard._(handle, lockKey);
  }

  /// Releases the lock early. Process exit releases it regardless; this is for
  /// controlled shutdown and tests.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _handle.unlock();
    } finally {
      try {
        await _handle.close();
      } finally {
        _processLocks.remove(_lockKey);
      }
    }
  }
}
