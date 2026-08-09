import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Reads the machine's total physical memory in bytes, or null when the
/// platform cannot report it.
///
/// The value is stable for the process lifetime and is cached after the first
/// successful read.
int? readSystemTotalMemoryBytes() {
  return _cachedTotalMemoryBytes ??= _readSystemTotalMemoryBytes();
}

/// Clears the cached capacity. Exposed for tests.
void clearSystemTotalMemoryBytesCache() {
  _cachedTotalMemoryBytes = null;
}

/// Parses Linux `/proc/meminfo` `MemTotal` lines. Exposed for tests.
int? parseProcMeminfoTotalBytes(String contents) {
  for (final line in const LineSplitter().convert(contents)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('MemTotal:')) {
      continue;
    }
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      return null;
    }
    final kiloBytes = int.tryParse(parts[1]);
    if (kiloBytes == null || kiloBytes <= 0) {
      return null;
    }
    return kiloBytes * 1024;
  }
  return null;
}

int? _cachedTotalMemoryBytes;

int? _readSystemTotalMemoryBytes() {
  try {
    if (Platform.isMacOS) {
      return _darwinTotalMemoryBytes();
    }
    if (Platform.isWindows) {
      return _windowsTotalMemoryBytes();
    }
    if (Platform.isLinux || Platform.isAndroid) {
      final contents = File('/proc/meminfo').readAsStringSync();
      return parseProcMeminfoTotalBytes(contents);
    }
  } catch (_) {
    return null;
  }
  return null;
}

int? _darwinTotalMemoryBytes() {
  final sysctlbyname = DynamicLibrary.process()
      .lookupFunction<_SysctlbynameNative, _SysctlbynameDart>('sysctlbyname');
  final name = 'hw.memsize'.toNativeUtf8();
  final length = calloc<Size>();
  length.value = sizeOf<Uint64>();
  final value = calloc<Uint64>();
  try {
    final result = sysctlbyname(
      name,
      value.cast(),
      length,
      nullptr,
      0,
    );
    if (result != 0 || length.value != sizeOf<Uint64>()) {
      return null;
    }
    final bytes = value.value;
    return bytes > 0 ? bytes : null;
  } finally {
    calloc.free(name);
    calloc.free(length);
    calloc.free(value);
  }
}

typedef _SysctlbynameNative =
    Int32 Function(
      Pointer<Utf8> name,
      Pointer<Void> oldp,
      Pointer<Size> oldlenp,
      Pointer<Void> newp,
      IntPtr newlen,
    );
typedef _SysctlbynameDart =
    int Function(
      Pointer<Utf8> name,
      Pointer<Void> oldp,
      Pointer<Size> oldlenp,
      Pointer<Void> newp,
      int newlen,
    );

int? _windowsTotalMemoryBytes() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final globalMemoryStatusEx = kernel32
      .lookupFunction<_GlobalMemoryStatusExNative, _GlobalMemoryStatusExDart>(
        'GlobalMemoryStatusEx',
      );
  final status = calloc.allocate<_MemoryStatusEx>(sizeOf<_MemoryStatusEx>());
  try {
    status.ref.length = sizeOf<_MemoryStatusEx>();
    final result = globalMemoryStatusEx(status);
    if (result == 0) {
      return null;
    }
    final bytes = status.ref.totalPhys;
    return bytes > 0 ? bytes : null;
  } finally {
    calloc.free(status);
  }
}

typedef _GlobalMemoryStatusExNative =
    Int32 Function(Pointer<_MemoryStatusEx> status);
typedef _GlobalMemoryStatusExDart =
    int Function(Pointer<_MemoryStatusEx> status);

final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int memoryLoad;
  @Uint64()
  external int totalPhys;
  @Uint64()
  external int availPhys;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availPageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availVirtual;
  @Uint64()
  external int availExtendedVirtual;
}
