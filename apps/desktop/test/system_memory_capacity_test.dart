import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/system_memory_capacity.dart';

void main() {
  tearDown(clearSystemTotalMemoryBytesCache);

  group('parseProcMeminfoTotalBytes', () {
    test('parses MemTotal kilobytes into bytes', () {
      expect(
        parseProcMeminfoTotalBytes('''
MemTotal:       16384000 kB
MemFree:         1024000 kB
'''),
        16384000 * 1024,
      );
    });

    test('returns null when MemTotal is missing or invalid', () {
      expect(parseProcMeminfoTotalBytes('MemFree: 1 kB\n'), isNull);
      expect(parseProcMeminfoTotalBytes('MemTotal: not-a-number kB\n'), isNull);
      expect(parseProcMeminfoTotalBytes('MemTotal: 0 kB\n'), isNull);
    });
  });

  group('readSystemTotalMemoryBytes', () {
    test('returns a positive capacity on host platforms', () {
      final bytes = readSystemTotalMemoryBytes();
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        expect(bytes, isNotNull);
        expect(bytes!, greaterThan(0));
        expect(readSystemTotalMemoryBytes(), bytes);
      }
    });
  });
}
