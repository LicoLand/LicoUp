import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// One process-level resource reading.
final class ResourceProbeReading {
  const ResourceProbeReading({
    required this.rssBytes,
    required this.diskReadBytes,
    required this.diskWriteBytes,
  });

  final int rssBytes;
  final int diskReadBytes;
  final int diskWriteBytes;
}

/// Reads cumulative process-level resource counters.
///
/// Every counter is cumulative since process start. Rates must be derived by
/// the caller from deltas between consecutive readings.
abstract interface class ClientResourceUsageProbe {
  ResourceProbeReading read();

  /// Whether the current platform can produce readings.
  bool get supported;
}

/// Creates the probe for the current platform, or returns null when the
/// platform cannot report process-level resource usage (for example iOS).
ClientResourceUsageProbe? createClientResourceUsageProbe() {
  if (Platform.isMacOS) {
    return _DarwinResourceProbe();
  }
  if (Platform.isWindows) {
    return _WindowsResourceProbe();
  }
  if (Platform.isLinux || Platform.isAndroid) {
    return _ProcIoResourceProbe();
  }
  return null;
}

/// Parses the `/proc/self/io` payload. Exposed for tests.
ResourceProbeReading parseProcIo(String contents) {
  int readBytes = 0;
  int writeBytes = 0;
  for (final line in const LineSplitter().convert(contents)) {
    final colon = line.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    final key = line.substring(0, colon).trim();
    final value = line.substring(colon + 1).trim();
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) {
      continue;
    }
    if (key == 'read_bytes') {
      readBytes = parsed;
    } else if (key == 'write_bytes') {
      writeBytes = parsed;
    }
  }
  return ResourceProbeReading(
    rssBytes: _currentRssBytes(),
    diskReadBytes: readBytes,
    diskWriteBytes: writeBytes,
  );
}

int _currentRssBytes() => ProcessInfo.currentRss;

/// macOS: `getrusage(RUSAGE_SELF)` disk I/O counters plus resident set size.
final class _DarwinResourceProbe implements ClientResourceUsageProbe {
  final (int, int) Function() _rusage;
  final int Function() _rss;

  _DarwinResourceProbe({
    (int, int) Function()? rusage,
    int Function()? rss,
  }) : _rusage = rusage ?? _darwinRusageBytes,
       _rss = rss ?? _currentRssBytes;

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() {
    final (readBytes, writeBytes) = _rusage();
    return ResourceProbeReading(
      rssBytes: _rss(),
      diskReadBytes: readBytes,
      diskWriteBytes: writeBytes,
    );
  }
}

typedef _GetrusageNative = Int32 Function(Int32 who, Pointer<_Rusage> usage);
typedef _GetrusageDart = int Function(int who, Pointer<_Rusage> usage);

/// `struct rusage` as exposed by macOS, including the 10.6+ disk I/O fields.
final class _Rusage extends Struct {
  @Int64()
  external int ruUtimeSec;
  @Int64()
  external int ruUtimeUsec;
  @Int64()
  external int ruStimeSec;
  @Int64()
  external int ruStimeUsec;
  @Int64()
  external int ruMaxrss;
  @Int64()
  external int ruIxrss;
  @Int64()
  external int ruIdrss;
  @Int64()
  external int ruIsrss;
  @Int64()
  external int ruMinflt;
  @Int64()
  external int ruMajflt;
  @Int64()
  external int ruNswap;
  @Int64()
  external int ruInblock;
  @Int64()
  external int ruOublock;
  @Int64()
  external int ruMsgsnd;
  @Int64()
  external int ruMsgrcv;
  @Int64()
  external int ruNsignals;
  @Int64()
  external int ruNvcsw;
  @Int64()
  external int ruNivcsw;
  @Uint64()
  external int riDiskioBytesread;
  @Uint64()
  external int riDiskioByteswritten;
}

(int, int) _darwinRusageBytes() {
  final getrusage = DynamicLibrary
      .process()
      .lookupFunction<_GetrusageNative, _GetrusageDart>('getrusage');
  final usage = calloc.allocate<_Rusage>(sizeOf<_Rusage>());
  try {
    final result = getrusage(0, usage);
    if (result != 0) {
      throw const FileSystemException('getrusage failed');
    }
    return (usage.ref.riDiskioBytesread, usage.ref.riDiskioByteswritten);
  } finally {
    calloc.free(usage);
  }
}

/// Windows: `GetProcessIoCounters` transfer counts plus resident set size.
final class _WindowsResourceProbe implements ClientResourceUsageProbe {
  final (int, int) Function() _transferCounts;
  final int Function() _rss;

  _WindowsResourceProbe({
    (int, int) Function()? transferCounts,
    int Function()? rss,
  }) : _transferCounts = transferCounts ?? _windowsTransferCounts,
       _rss = rss ?? _currentRssBytes;

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() {
    final (readBytes, writeBytes) = _transferCounts();
    return ResourceProbeReading(
      rssBytes: _rss(),
      diskReadBytes: readBytes,
      diskWriteBytes: writeBytes,
    );
  }
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _GetProcessIoCountersNative = Int32 Function(
  IntPtr process,
  Pointer<_IoCounters> counters,
);
typedef _GetProcessIoCountersDart = int Function(
  int process,
  Pointer<_IoCounters> counters,
);

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

(int, int) _windowsTransferCounts() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getCurrentProcess = kernel32
      .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
        'GetCurrentProcess',
      );
  final getProcessIoCounters = kernel32
      .lookupFunction<_GetProcessIoCountersNative, _GetProcessIoCountersDart>(
        'GetProcessIoCounters',
      );
  final counters = calloc.allocate<_IoCounters>(sizeOf<_IoCounters>());
  try {
    final result = getProcessIoCounters(getCurrentProcess(), counters);
    if (result == 0) {
      throw const FileSystemException('GetProcessIoCounters failed');
    }
    return (
      counters.ref.readTransferCount,
      counters.ref.writeTransferCount,
    );
  } finally {
    calloc.free(counters);
  }
}

/// Linux and Android: `/proc/self/io` plus resident set size.
final class _ProcIoResourceProbe implements ClientResourceUsageProbe {
  const _ProcIoResourceProbe();

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() {
    final io = File('/proc/self/io').readAsStringSync();
    return parseProcIo(io);
  }
}
