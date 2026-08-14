import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/contracts/agent_resource_usage_gateway.dart';
import 'package:licoup/src/contracts/agent_resource_usage_models.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_resource_usage_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/resource_usage_shared.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/client_resource_usage_probe.dart';

import 'fixtures/agent_usage_panel/usage_panel_fixtures.dart';

final class _StepProbe implements ClientResourceUsageProbe {
  static const int _baseRss = 512 * 1024 * 1024;

  int calls = 0;

  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() {
    final index = calls++;
    return ResourceProbeReading(
      rssBytes: _baseRss + index * 1024,
      diskReadBytes: 0,
      diskWriteBytes: 0,
    );
  }
}

final class _SequenceGateway implements AgentResourceUsageGateway {
  _SequenceGateway(this.reports);

  final List<AgentResourceUsageReport> reports;
  int calls = 0;

  @override
  Future<AgentResourceUsageReport> scan() async {
    return reports[calls++ % reports.length];
  }
}

void main() {
  group('formatRssBytes', () {
    test('formats megabytes and gigabytes', () {
      expect(formatRssBytes(0), '0');
      expect(formatRssBytes((1.3 * 1024 * 1024).round()), '1.3');
      expect(formatRssBytes(512 * 1024 * 1024), '512');
      expect(formatRssBytes(3 * 1024 * 1024 * 1024), '3.0');
    });
  });

  group('formatMemoryCapacity', () {
    test('formats machine capacity', () {
      expect(formatMemoryCapacity(0), '0 B');
      expect(formatMemoryCapacity(512 * 1024 * 1024), '512 MB');
      expect(formatMemoryCapacity(64 * 1024 * 1024 * 1024), '64 GB');
    });
  });

  group('ClientResourceUsageCard', () {
    testWidgets('renders only the memory ring', (tester) async {
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
            child: ClientResourceUsageCard(
              controller: controller,
              totalMemoryBytes: 64 * 1024 * 1024 * 1024,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 250));
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(find.text('LicoUp'), findsOneWidget);
      expect(find.text('512'), findsOneWidget);
      expect(find.textContaining('of 64 GB machine'), findsOneWidget);
      expect(find.text('Disk Read'), findsNothing);
      expect(find.text('Disk Write'), findsNothing);
      expect(find.text('Agent Resources'), findsNothing);
      expect(find.textContaining('Since opened'), findsNothing);

      controller.stop();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('includes running agents as ring segments', (tester) async {
      final probe = _StepProbe();
      var now = DateTime(2026, 7, 31, 12, 0, 0);
      final clientController = ClientResourceUsageController(
        probe: probe,
        now: () => now,
      );
      final gateway = _SequenceGateway([
        AgentResourceUsageReport(
          schemaVersion: AgentResourceUsageReport.currentSchemaVersion,
          generatedAt: '2026-07-31T12:00:00Z',
          agents: [
            AgentResourceUsageAgent(
              target: 'claude-code',
              label: 'claude-code',
              running: true,
              processes: const [],
              totalRssBytes: 455 * 1024 * 1024,
              totalDiskReadBytes: 1000,
              totalDiskWriteBytes: 2000,
            ),
          ],
          summary: const {},
        ),
        AgentResourceUsageReport(
          schemaVersion: AgentResourceUsageReport.currentSchemaVersion,
          generatedAt: '2026-07-31T12:00:05Z',
          agents: [
            AgentResourceUsageAgent(
              target: 'claude-code',
              label: 'claude-code',
              running: true,
              processes: const [],
              totalRssBytes: 455 * 1024 * 1024,
              totalDiskReadBytes: 1500,
              totalDiskWriteBytes: 2500,
            ),
          ],
          summary: const {},
        ),
      ]);
      final agentController = AgentResourceUsageController(
        gateway: gateway,
        now: () => now,
      );
      addTearDown(clientController.dispose);
      addTearDown(agentController.dispose);
      clientController.start(interval: const Duration(milliseconds: 200));
      agentController.start(interval: const Duration(milliseconds: 200));

      await tester.pumpWidget(
        usageTestApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 700,
            height: 420,
            child: ClientResourceUsageCard(
              controller: clientController,
              agentController: agentController,
              totalMemoryBytes: 64 * 1024 * 1024 * 1024,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 250));
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(find.text('LicoUp'), findsOneWidget);
      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('455'), findsOneWidget);
      expect(find.text('Agent Resources'), findsNothing);

      clientController.stop();
      agentController.stop();
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
        find.text(
          'Process resource statistics are not supported on this platform.',
        ),
        findsOneWidget,
      );
      expect(find.text('LicoUp'), findsNothing);

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
            child: ClientResourceUsageCard(
              totalMemoryBytes: 16 * 1024 * 1024 * 1024,
            ),
          ),
        ),
      );
      expect(find.text('Resource Usage'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
