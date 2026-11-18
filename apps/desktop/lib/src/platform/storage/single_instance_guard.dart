import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Enforces one running LicoUp client instance per machine.
///
/// Desktop uses an exclusive operating-system lock beside the boot locator,
/// so changing roots or recovering an unavailable volume cannot admit a
/// second client. Mobile and isolated tests keep the lock inside their sandbox
/// root. The lock is acquired without waiting, before bootstrap work starts.
///
/// A file lock avoids the probe/delete/bind race inherent in a Unix socket
/// guard and works across all desktop platforms. The lock file is deliberately
/// retained after release: deleting it could replace the inode while another
/// process still holds a valid lock.
class SingleInstanceGuard {
  SingleInstanceGuard._(
    this._lockKey, {
    RandomAccessFile? handle,
    int posixFd = -1,
  }) : _handle = handle,
       _posixFd = posixFd;

  static final Set<String> _processLocks = <String>{};
  final RandomAccessFile? _handle;
  final int _posixFd;
  final String _lockKey;
  bool _released = false;

  /// Resolves the stable desktop lock beside the boot locator.
  static Future<File> lockFileFor(PortableDataRoot portableData) async {
    final raw = await portableData.bootInstanceLockFile();
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
    final guard = await _claim(lockFile, lockKey);
    if (guard == null) {
      _processLocks.remove(lockKey);
    }
    return guard;
  }

  static Future<SingleInstanceGuard?> _claim(
    File lockFile,
    String lockKey,
  ) async {
    try {
      await lockFile.parent.create(recursive: true);
    } on FileSystemException {
      return null;
    }
    final posixLock = _PosixFileLock.resolve();
    if (posixLock != null) {
      final fd = posixLock.tryAcquire(lockFile.path);
      return fd == null ? null : SingleInstanceGuard._(lockKey, posixFd: fd);
    }
    final RandomAccessFile handle;
    try {
      handle = await lockFile.open(mode: FileMode.append);
    } on FileSystemException {
      return null;
    }
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      return null;
    }
    return SingleInstanceGuard._(lockKey, handle: handle);
  }

  /// Releases the lock early. Process exit releases it regardless; this is for
  /// controlled shutdown and tests.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      if (_posixFd >= 0) {
        _PosixFileLock.resolve()!.release(_posixFd);
      } else {
        await _handle!.unlock();
      }
    } finally {
      try {
        await _handle?.close();
      } finally {
        _processLocks.remove(_lockKey);
      }
    }
  }

  /// Drops the descriptor without unlocking, reproducing a process crash in
  /// tests: the lock survives only while another descriptor on the same open
  /// file description is still alive.
  @visibleForTesting
  void debugCloseWithoutUnlock() {
    _released = true;
    try {
      if (_posixFd >= 0) {
        _PosixFileLock.resolve()!.closeOnly(_posixFd);
      }
    } finally {
      _processLocks.remove(_lockKey);
    }
  }
}

typedef _NativeOpen = Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>);
typedef _NativeFlock = Int32 Function(Int32, Int32);
typedef _NativeClose = Int32 Function(Int32);
typedef _DartOpen = int Function(Pointer<Utf8>, int, int);
typedef _DartFlock = int Function(int, int);
typedef _DartClose = int Function(int);

/// `flock(2)`-based claim used on macOS and Linux.
///
/// `RandomAccessFile.lock` keeps a plain descriptor: every spawned child
/// inherits it through fork+exec, and POSIX locks bind to the open file
/// description — so an orphaned sidecar outliving its client kept the
/// instance lock held and silently rejected every later launch. Opening the
/// lock file with `O_CLOEXEC` drops the descriptor from each child's table at
/// exec time; only the owning process can ever hold the lock.
final class _PosixFileLock {
  _PosixFileLock._(this._open, this._flock, this._close);

  static _PosixFileLock? _resolved;
  static bool _resolutionAttempted = false;

  static _PosixFileLock? resolve() {
    if (!_resolutionAttempted) {
      _resolutionAttempted = true;
      _resolved = _tryResolve();
    }
    return _resolved;
  }

  static _PosixFileLock? _tryResolve() {
    if (!Platform.isMacOS && !Platform.isLinux) return null;
    try {
      final lib = DynamicLibrary.process();
      return _PosixFileLock._(
        lib.lookupFunction<_NativeOpen, _DartOpen>('open'),
        lib.lookupFunction<_NativeFlock, _DartFlock>('flock'),
        lib.lookupFunction<_NativeClose, _DartClose>('close'),
      );
    } on ArgumentError {
      return null;
    }
  }

  final _DartOpen _open;
  final _DartFlock _flock;
  final _DartClose _close;

  static const int _oWronly = 0x0001;
  static const int _lockExclusiveNonBlocking = 0x02 | 0x04; // LOCK_EX|LOCK_NB
  static const int _lockUnlock = 0x08; // LOCK_UN

  // O_CREAT and O_CLOEXEC differ between the BSD and Linux fcntl surfaces.
  static int get _oCreat => Platform.isMacOS ? 0x0200 : 0x0040;
  static int get _oCloexec => Platform.isMacOS ? 0x01000000 : 0x00080000;

  /// Opens the lock file and claims an exclusive non-blocking flock. Returns
  /// the owned descriptor, or null when the lock is held elsewhere.
  int? tryAcquire(String path) {
    final nativePath = path.toNativeUtf8();
    try {
      final fd = _open(
        nativePath,
        _oWronly | _oCreat | _oCloexec,
        0x1A4, // 0644
      );
      if (fd < 0) return null;
      if (_flock(fd, _lockExclusiveNonBlocking) != 0) {
        _close(fd);
        return null;
      }
      return fd;
    } finally {
      malloc.free(nativePath);
    }
  }

  void release(int fd) {
    _flock(fd, _lockUnlock);
    _close(fd);
  }

  void closeOnly(int fd) => _close(fd);
}
