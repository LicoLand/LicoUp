import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/client_resource_usage_probe.dart';

void main() {
  group('parseProcIo', () {
    test('parses read and write byte counters', () {
      final reading = parseProcIo('''
rchar: 1024
wchar: 2048
syscr: 10
syscw: 20
read_bytes: 5120
write_bytes: 6144
cancelled_write_bytes: 0
''');
      expect(reading.diskReadBytes, 5120);
      expect(reading.diskWriteBytes, 6144);
      expect(reading.rssBytes, greaterThanOrEqualTo(0));
    });

    test('handles missing counters as zero', () {
      final reading = parseProcIo('rchar: 1\n');
      expect(reading.diskReadBytes, 0);
      expect(reading.diskWriteBytes, 0);
    });

    test('ignores malformed and negative values', () {
      final reading = parseProcIo('''
read_bytes: not-a-number
write_bytes: -5
read_bytes: 42
''');
      expect(reading.diskReadBytes, 42);
      expect(reading.diskWriteBytes, 0);
    });

    test('ignores unrelated keys', () {
      final reading = parseProcIo('''
read_bytes: 9
cpu: 0.5
read_bytes: 8
''');
      expect(reading.diskReadBytes, 8);
    });
  });

  group('createClientResourceUsageProbe', () {
    test('returns a probe on host platforms and null on unsupported ones', () {
      final probe = createClientResourceUsageProbe();
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        expect(probe, isNotNull);
        expect(probe!.supported, isTrue);
        expect(() => probe.read(), returnsNormally);
      } else {
        expect(probe, isNull);
      }
    });
  });
}
