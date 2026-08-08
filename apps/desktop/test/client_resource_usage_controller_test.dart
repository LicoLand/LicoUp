import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/platform/client_resource_usage_probe.dart';

final class _SequenceProbe implements ClientResourceUsageProbe {
  _SequenceProbe(this.readings);

  final List<ResourceProbeReading> readings;
  int calls = 0;

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() => readings[calls++ % readings.length];
}

final class _RssOnlyProbe implements ClientResourceUsageProbe {
  _RssOnlyProbe(this.rssReadings);

  final List<int> rssReadings;
  int calls = 0;

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() {
    final rss = rssReadings[calls++ % rssReadings.length];
    return ResourceProbeReading(
      rssBytes: rss,
      diskReadBytes: 0,
      diskWriteBytes: 0,
    );
  }
}

void main() {
  group('ClientResourceUsageController', () {
    test('first reading establishes the baseline and produces no sample', () {
      final probe = _SequenceProbe([
        ResourceProbeReading(
          rssBytes: 100,
          diskReadBytes: 1000,
          diskWriteBytes: 2000,
        ),
        ResourceProbeReading(
          rssBytes: 110,
          diskReadBytes: 1600,
          diskWriteBytes: 2100,
        ),
      ]);
      final controller = ClientResourceUsageController(probe: probe);
      addTearDown(controller.dispose);

      controller.refresh();
      expect(controller.samples, isEmpty);
      expect(controller.sessionReadBytes, 0);

      controller.refresh();
      expect(controller.samples, hasLength(1));
      final sample = controller.samples.single;
      expect(sample.rssBytes, 110);
      expect(sample.deltaReadBytes, 600);
      expect(sample.deltaWriteBytes, 100);
      expect(controller.sessionReadBytes, 600);
      expect(controller.sessionWriteBytes, 100);
    });

    test('non-increasing counters produce zero deltas', () {
      final probe = _SequenceProbe([
        ResourceProbeReading(
          rssBytes: 100,
          diskReadBytes: 1000,
          diskWriteBytes: 2000,
        ),
        ResourceProbeReading(
          rssBytes: 100,
          diskReadBytes: 800,
          diskWriteBytes: 2000,
        ),
      ]);
      final controller = ClientResourceUsageController(probe: probe);
      addTearDown(controller.dispose);

      controller.refresh();
      controller.refresh();
      final sample = controller.samples.single;
      expect(sample.deltaReadBytes, 0);
      expect(sample.deltaWriteBytes, 0);
      expect(controller.sessionReadBytes, 0);
    });

    test('samples carry the wall-clock interval between readings', () {
      var now = DateTime(2026, 7, 31, 12, 0, 0);
      final probe = _SequenceProbe([
        ResourceProbeReading(
          rssBytes: 100,
          diskReadBytes: 1000,
          diskWriteBytes: 0,
        ),
        ResourceProbeReading(
          rssBytes: 100,
          diskReadBytes: 1500,
          diskWriteBytes: 0,
        ),
      ]);
      final controller = ClientResourceUsageController(
        probe: probe,
        now: () => now,
      );
      addTearDown(controller.dispose);

      controller.refresh();
      now = now.add(const Duration(seconds: 5));
      controller.refresh();

      expect(controller.samples.single.interval, const Duration(seconds: 5));
    });

    test('retains at most the configured number of samples', () {
      final probe = _RssOnlyProbe([for (var i = 0; i < 220; i += 1) 100 + i]);
      final controller = ClientResourceUsageController(probe: probe);
      addTearDown(controller.dispose);

      controller.refresh();
      for (var i = 0; i < 200; i += 1) {
        controller.refresh();
      }

      expect(controller.samples.length, clientResourceUsageMaxSamples);
      expect(controller.samples.first.rssBytes, 121);
      expect(controller.samples.last.rssBytes, 300);
    });

    test('unsupported platforms never sample', () {
      final controller = ClientResourceUsageController(probe: null);
      addTearDown(controller.dispose);

      expect(controller.supported, isFalse);
      controller.start();
      controller.refresh();
      expect(controller.samples, isEmpty);
    });

    test('start schedules periodic sampling and stop cancels it', () {
      final probe = _RssOnlyProbe([100, 110]);
      final controller = ClientResourceUsageController(probe: probe);
      addTearDown(controller.dispose);

      controller.start(interval: const Duration(seconds: 1));
      expect(controller.isSampling, isTrue);
      controller.stop();
      expect(controller.isSampling, isFalse);
      controller.refresh();
      controller.refresh();
      expect(controller.samples, hasLength(1));
    });

    test('probe failures are skipped without producing samples', () {
      var calls = 0;
      final controller = ClientResourceUsageController(
        probe: _FailingAfterBaselineProbe(() => calls += 1),
      );
      addTearDown(controller.dispose);

      controller.refresh();
      controller.refresh();
      expect(controller.samples, isEmpty);
      expect(calls, 2);
    });

    test('notifies listeners only when a sample is produced', () {
      final probe = _SequenceProbe([
        ResourceProbeReading(
          rssBytes: 100,
          diskReadBytes: 1000,
          diskWriteBytes: 0,
        ),
        ResourceProbeReading(
          rssBytes: 110,
          diskReadBytes: 1500,
          diskWriteBytes: 0,
        ),
      ]);
      final controller = ClientResourceUsageController(probe: probe);
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.refresh();
      expect(notifications, 0);
      controller.refresh();
      expect(notifications, 1);
    });
  });
}

final class _FailingAfterBaselineProbe implements ClientResourceUsageProbe {
  _FailingAfterBaselineProbe(this.onCall);

  final void Function() onCall;
  var _calls = 0;

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() {
    onCall();
    _calls += 1;
    if (_calls > 1) {
      throw const FileSystemException('probe unavailable');
    }
    return const ResourceProbeReading(
      rssBytes: 100,
      diskReadBytes: 0,
      diskWriteBytes: 0,
    );
  }
}
