import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_resource_usage_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/resource_usage_shared.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/client_resource_usage_probe.dart';

import 'fixtures/agent_usage_panel/usage_panel_fixtures.dart';

final class _StepProbe implements ClientResourceUsageProbe {
  static const int _baseRss = 512 * 1024 * 1024;
  static const int _readStep = 4096;
  static const int _writeStep = 2048;

  int calls = 0;

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() {
    final index = calls++;
    return ResourceProbeReading(
      rssBytes: _baseRss + index * 1024,
      diskReadBytes: index * _readStep,
      diskWriteBytes: index * _writeStep,
    );
  }
}

void main() {
  group('formatBytes', () {
    test('formats byte quantities across units', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
    });
  });

  group('formatRateKbPerSec', () {
    test('clamps near-zero rates to zero', () {
      expect(formatRateKbPerSec(0), '0');
      expect(formatRateKbPerSec(0.04), '0');
      expect(formatRateKbPerSec(0.05), '0');
    });

    test('keeps KB and switches to MB for large rates', () {
      expect(formatRateKbPerSec(12.6), '13');
      expect(formatRateKbPerSec(1536), '1.5');
    });
  });

  group('formatRssBytes', () {
    test('formats megabytes and gigabytes', () {
      expect(formatRssBytes(0), '0');
      expect(formatRssBytes(512 * 1024 * 1024), '512');
      expect(formatRssBytes(3 * 1024 * 1024 * 1024), '3.0');
    });
  });

  group('ClientResourceUsageCard', () {
    testWidgets('renders current memory, read, and write values', (tester) async {
      final probe = _StepProbe();
      var now = DateTime(2026, 7, 31, 12, 0, 0);
      final controller = ClientResourceUsageController(
        probe: probe,
        now: () => now,
      );
      addTearDown(controller.dispose);
      controller.start(interval: const Duration(milliseconds: 200));

      await tester.pumpWidget(
        usageTestApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 700,
            height: 420,
            child: ClientResourceUsageCard(controller: controller),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 250));
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(find.text('512'), findsOneWidget);
      expect(find.text('512 MB'), findsNothing);
      expect(find.text('Memory'), findsOneWidget);
      expect(find.text('Disk Read'), findsOneWidget);
      expect(find.text('Disk Write'), findsOneWidget);
      expect(
        find.textContaining('Since opened'),
        findsOneWidget,
      );

      controller.stop();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('shows an unsupported notice when the probe is absent', (
      tester,
    ) async {
      final controller = ClientResourceUsageController(probe: null);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        usageTestApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 700,
            height: 200,
            child: ClientResourceUsageCard(controller: controller),
          ),
        ),
      );

      expect(
        find.text('Process resource statistics are not supported on this platform.'),
        findsOneWidget,
      );
      expect(find.text('Memory'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('owns and disposes a live controller when none is injected', (
      tester,
    ) async {
      await tester.pumpWidget(
        usageTestApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: const SizedBox(
            width: 700,
            height: 420,
            child: ClientResourceUsageCard(),
          ),
        ),
      );
      expect(find.text('Resource Usage'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
